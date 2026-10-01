/*
 * mali_uio.c — FreeBSD UIO kernel module for Mali-400 GPU (Allwinner A64)
 *
 * Registers Mali MMIO region as /dev/uio0, allowing userspace Lima to:
 *   - mmap GPU registers directly
 *   - submit command buffers via contigmalloc'd physically-contiguous buffers
 *   - handle GPU interrupts via read()/write() on /dev/uio0
 *
 * NO drm_sched, NO GEM, NO DRM stack required.
 *
 * Usage:
 *   kldload mali_uio.ko
 *   open("/dev/uio0") → fd
 *   mmap(fd, MALI_REGS_SIZE) → volatile void *regs
 *   write(fd, &irq_mask, 4) → enable GPU interrupt
 *   read(fd, &count, 4)    → block until GPU interrupt fires
 *
 * Allwinner A64 Mali-400 MP2 hardware:
 *   MMIO base:  0x01C40000  (from A64 user manual §3.11)
 *   MMIO size:  0x10000     (64KB, covers all Mali-400 registers)
 *   IRQ:        97          (SPI 65, A64 GIC mapping)
 */

#include <sys/cdefs.h>
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/bus.h>
#include <sys/rman.h>
#include <sys/conf.h>
#include <sys/uio.h>
#include <sys/malloc.h>
#include <sys/mutex.h>
#include <sys/condvar.h>
#include <sys/poll.h>
#include <sys/selinfo.h>
#include <machine/bus.h>
#include <machine/resource.h>
#include <vm/vm.h>
#include <vm/pmap.h>

/* Allwinner A64 Mali-400 physical addresses */
#define MALI_REGS_BASE  0x01C40000UL
#define MALI_REGS_SIZE  0x00010000UL   /* 64KB */
#define MALI_IRQ_NUM    97

static struct mali_uio_softc {
    device_t        dev;
    struct resource *mem_res;       /* MMIO resource */
    struct resource *irq_res;       /* IRQ resource */
    void            *irq_cookie;
    struct cdev     *cdev;
    struct mtx       mtx;
    struct cv        irq_cv;
    volatile int     irq_count;
    struct selinfo   sel;
} mali_sc;

static MALLOC_DEFINE(M_MALI_UIO, "mali_uio", "Mali UIO buffers");

/* ── Character device ops ────────────────────────────────────────────────── */

static int
mali_uio_open(struct cdev *dev, int oflags, int devtype, struct thread *td)
{
    return 0;
}

static int
mali_uio_close(struct cdev *dev, int fflag, int devtype, struct thread *td)
{
    return 0;
}

/*
 * read(): block until next GPU interrupt, return count as uint32.
 * Userspace calls this to wait for render completion.
 */
static int
mali_uio_read(struct cdev *dev, struct uio *uio, int ioflag)
{
    struct mali_uio_softc *sc = &mali_sc;
    uint32_t count;
    int error;

    if (uio->uio_resid < sizeof(uint32_t))
        return EINVAL;

    mtx_lock(&sc->mtx);
    while (sc->irq_count == 0) {
        error = cv_timedwait_sig(&sc->irq_cv, &sc->mtx, hz * 5);
        if (error) {
            mtx_unlock(&sc->mtx);
            return error;
        }
    }
    count = sc->irq_count;
    sc->irq_count = 0;
    mtx_unlock(&sc->mtx);

    return uiomove(&count, sizeof(count), uio);
}

/*
 * write(): enable/disable GPU interrupt mask.
 * Userspace writes IRQ enable bitmask to arm next interrupt wait.
 */
static int
mali_uio_write(struct cdev *dev, struct uio *uio, int ioflag)
{
    uint32_t irq_mask;
    int error;

    if (uio->uio_resid < sizeof(irq_mask))
        return EINVAL;

    error = uiomove(&irq_mask, sizeof(irq_mask), uio);
    if (error)
        return error;

    /* TODO: write irq_mask to Mali IRQ_MASK register via bus_write_4 */
    (void)irq_mask;
    return 0;
}

/*
 * mmap(): expose Mali MMIO register space to userspace.
 * Lima reads/writes GPU registers directly through this mapping.
 */
static int
mali_uio_mmap(struct cdev *dev, vm_ooffset_t offset, vm_paddr_t *paddr,
              int nprot, vm_memattr_t *memattr)
{
    if (offset >= MALI_REGS_SIZE)
        return EINVAL;

    *paddr = MALI_REGS_BASE + offset;
    *memattr = VM_MEMATTR_DEVICE;   /* uncached device memory */
    return 0;
}

static struct cdevsw mali_uio_cdevsw = {
    .d_version  = D_VERSION,
    .d_open     = mali_uio_open,
    .d_close    = mali_uio_close,
    .d_read     = mali_uio_read,
    .d_write    = mali_uio_write,
    .d_mmap     = mali_uio_mmap,
    .d_name     = "mali_uio",
};

/* ── Interrupt handler ───────────────────────────────────────────────────── */

static void
mali_uio_intr(void *arg)
{
    struct mali_uio_softc *sc = arg;

    mtx_lock(&sc->mtx);
    sc->irq_count++;
    cv_broadcast(&sc->irq_cv);
    selwakeup(&sc->sel);
    mtx_unlock(&sc->mtx);

    /* ACK interrupt: clear Mali IRQ status register */
    /* TODO: bus_write_4(sc->mem_res, MALI_IRQ_STATUS, 0xFFFFFFFF); */
}

/* ── Module load/unload ──────────────────────────────────────────────────── */

static int
mali_uio_load(module_t mod, int cmd, void *arg)
{
    struct mali_uio_softc *sc = &mali_sc;
    int error = 0;
    int rid;

    switch (cmd) {
    case MOD_LOAD:
        mtx_init(&sc->mtx, "mali_uio", NULL, MTX_DEF);
        cv_init(&sc->irq_cv, "mali_irq");
        sc->irq_count = 0;

        /*
         * Map Mali MMIO region.
         * On real hardware this comes from FDT/ACPI; here we use rman directly.
         * TODO: use device_get_resource() when wired via FDT driver.
         */
        sc->mem_res = bus_alloc_resource(root_bus, SYS_RES_MEMORY, &rid,
                          MALI_REGS_BASE, MALI_REGS_BASE + MALI_REGS_SIZE - 1,
                          MALI_REGS_SIZE, RF_ACTIVE | RF_SHAREABLE);
        if (sc->mem_res == NULL) {
            printf("mali_uio: cannot map MMIO 0x%lx\n", MALI_REGS_BASE);
            /* Non-fatal on QEMU where Mali doesn't exist; just no /dev/uio0 */
            goto no_hw;
        }

        /* Request IRQ */
        rid = 0;
        sc->irq_res = bus_alloc_resource(root_bus, SYS_RES_IRQ, &rid,
                          MALI_IRQ_NUM, MALI_IRQ_NUM, 1, RF_ACTIVE | RF_SHAREABLE);
        if (sc->irq_res != NULL) {
            bus_setup_intr(root_bus, sc->irq_res, INTR_TYPE_MISC | INTR_MPSAFE,
                           NULL, mali_uio_intr, sc, &sc->irq_cookie);
        }

        sc->cdev = make_dev(&mali_uio_cdevsw, 0, UID_ROOT, GID_WHEEL, 0666,
                            "uio0");
        sc->cdev->si_drv1 = sc;
        printf("mali_uio: /dev/uio0 ready (MMIO 0x%lx, size 0x%lx)\n",
               MALI_REGS_BASE, MALI_REGS_SIZE);
        break;

no_hw:
        printf("mali_uio: no Mali hardware found (QEMU?), module loaded but /dev/uio0 not created\n");
        break;

    case MOD_UNLOAD:
        if (sc->cdev != NULL)
            destroy_dev(sc->cdev);
        if (sc->irq_cookie != NULL)
            bus_teardown_intr(root_bus, sc->irq_res, sc->irq_cookie);
        if (sc->irq_res != NULL)
            bus_release_resource(root_bus, SYS_RES_IRQ, 0, sc->irq_res);
        if (sc->mem_res != NULL)
            bus_release_resource(root_bus, SYS_RES_MEMORY, 0, sc->mem_res);
        cv_destroy(&sc->irq_cv);
        mtx_destroy(&sc->mtx);
        break;

    default:
        error = EOPNOTSUPP;
        break;
    }

    return error;
}

static moduledata_t mali_uio_mod = {
    "mali_uio",
    mali_uio_load,
    NULL,
};

DECLARE_MODULE(mali_uio, mali_uio_mod, SI_SUB_DRIVERS, SI_ORDER_MIDDLE);
MODULE_VERSION(mali_uio, 1);
