/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * mali_uio.c — FreeBSD UIO driver skeleton for Allwinner A64 Mali-400 GPU
 *
 * purpose:   Register Mali-400 MMIO (0x01C40000, 64 KB) as /dev/uio0 so
 *            that the Lima userspace driver can mmap() GPU registers directly,
 *            bypassing DRM/KMS entirely (Lima phase 1.5).
 * input:     nexus/simplebus device tree node matching "arm,mali-400"
 * output:    /dev/uio0 cdev with mmap support for MMIO window
 * sideEffects: allocates one IOMEM resource; creates /dev/uio0 on attach,
 *              destroys it on detach; no interrupts claimed (polling mode)
 *
 * Target: FreeBSD 15.1 aarch64, Allwinner A64 (PinePhone Pro — Porcupine v0.3)
 * Build:  copy tree to /usr/src/sys/modules/mali_uio/ then:
 *           cd /usr/src/sys/modules/mali_uio && make
 *         or use the hal/mali_uio_Makefile in-tree.
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/module.h>
#include <sys/kernel.h>
#include <sys/bus.h>
#include <sys/conf.h>
#include <sys/malloc.h>
#include <sys/rman.h>
#include <sys/uio.h>
#include <sys/ioccom.h>
#include <sys/mman.h>

#include <machine/bus.h>
#include <machine/resource.h>
#include <vm/vm.h>
#include <vm/pmap.h>

#include "mali_uio.h"

/* ---------------------------------------------------------------------------
 * Driver-private softc
 * ------------------------------------------------------------------------- */

/*
 * struct mali_uio_softc
 *
 * purpose:  Per-instance state for the mali_uio device.
 * input:    allocated by mali_attach(); freed by mali_detach()
 * output:   holds resource handle and cdev pointer
 * sideEffects: none beyond memory lifetime
 */
struct mali_uio_softc {
    device_t        sc_dev;     /* back-pointer to bus device   */
    struct resource *sc_mem;    /* IOMEM resource for MMIO      */
    int             sc_mem_rid; /* resource ID (0)              */
    struct cdev     *sc_cdev;   /* /dev/uio0 character device   */
};

MALLOC_DEFINE(M_MALI_UIO, "mali_uio", "mali_uio softc");

/* ---------------------------------------------------------------------------
 * Character device operations
 * ------------------------------------------------------------------------- */

/*
 * mali_open
 *
 * purpose:  Accept open(2) on /dev/uio0.
 * input:    dev — cdev pointer; flag, fmt, td — standard cdevsw args
 * output:   0 always (no per-open state needed)
 * sideEffects: none
 */
static int
mali_open(struct cdev *dev, int flag, int fmt, struct thread *td)
{
    (void)dev; (void)flag; (void)fmt; (void)td;
    return (0);
}

/*
 * mali_close
 *
 * purpose:  Accept close(2) on /dev/uio0.
 * input:    dev, flag, fmt, td — standard cdevsw args
 * output:   0 always
 * sideEffects: none
 */
static int
mali_close(struct cdev *dev, int flag, int fmt, struct thread *td)
{
    (void)dev; (void)flag; (void)fmt; (void)td;
    return (0);
}

/*
 * mali_ioctl
 *
 * purpose:  Handle MALI_UIO_GET_INFO — copy physical address and size of
 *           the MMIO window to userspace.
 * input:    dev — cdev; cmd — ioctl command; data — kernel-mapped argument
 *           buffer; fflag, td — standard args
 * output:   0 on success; ENOTTY for unknown commands
 * sideEffects: writes to *data (kernel buffer, then copied to user by kernel)
 */
static int
mali_ioctl(struct cdev *dev, u_long cmd, caddr_t data, int fflag,
    struct thread *td)
{
    (void)fflag; (void)td;

    switch (cmd) {
    case MALI_UIO_GET_INFO: {
        struct mali_uio_mmap_info *info =
            (struct mali_uio_mmap_info *)(void *)data;
        info->phys_addr = MALI_MMIO_BASE;
        info->size      = MALI_MMIO_SIZE;
        return (0);
    }
    default:
        return (ENOTTY);
    }
}

/*
 * mali_mmap
 *
 * purpose:  Map the Mali MMIO physical range into the calling process VA.
 *           offset 0 corresponds to MALI_MMIO_BASE; offsets beyond
 *           MALI_MMIO_SIZE are rejected.
 * input:    dev — cdev; offset — byte offset from start of MMIO window;
 *           nprot — requested protection flags
 * output:   VM page frame number (vm_paddr_t >> PAGE_SHIFT) on success;
 *           -1 on out-of-range offset
 * sideEffects: none — physical mapping is performed by the VM layer
 *
 * Note: FreeBSD d_mmap receives offset in bytes and returns a page frame
 *       number (the physical address shifted right by PAGE_SHIFT).
 */
static int
mali_mmap(struct cdev *dev, vm_ooffset_t offset, vm_paddr_t *paddr,
    int nprot, vm_memattr_t *memattr)
{
    (void)dev; (void)nprot;

    if (offset >= MALI_MMIO_SIZE)
        return (EINVAL);

    *paddr   = (vm_paddr_t)(MALI_MMIO_BASE + offset);
    *memattr = VM_MEMATTR_DEVICE;   /* non-cacheable device memory */
    return (0);
}

static struct cdevsw mali_cdevsw = {
    .d_version  = D_VERSION,
    .d_name     = "uio0",
    .d_open     = mali_open,
    .d_close    = mali_close,
    .d_ioctl    = mali_ioctl,
    .d_mmap     = mali_mmap,
};

/* ---------------------------------------------------------------------------
 * Bus driver methods
 * ------------------------------------------------------------------------- */

/*
 * mali_probe
 *
 * purpose:  Identify whether this bus node is the A64 Mali-400 controller.
 *           On FreeBSD simplebus the compatible string match is done by the
 *           FDT layer; we unconditionally claim a BUS_PROBE_DEFAULT score so
 *           the module can also be loaded manually against the nexus tree.
 * input:    dev — candidate device node
 * output:   BUS_PROBE_DEFAULT on match; ENXIO if already attached
 * sideEffects: sets device description string visible in dmesg
 */
static int
mali_probe(device_t dev)
{
    device_set_desc(dev, "Allwinner A64 Mali-400 MP2 (UIO shim)");
    return (BUS_PROBE_DEFAULT);
}

/*
 * mali_attach
 *
 * purpose:  Allocate IOMEM resource for MMIO and create /dev/uio0.
 * input:    dev — device node passed by bus
 * output:   0 on success; errno on failure (resource or cdev allocation)
 * sideEffects: allocates M_MALI_UIO softc; allocates IOMEM rman entry;
 *              creates /dev/uio0 visible in devfs
 */
static int
mali_attach(device_t dev)
{
    struct mali_uio_softc *sc;
    int error;

    sc = malloc(sizeof(*sc), M_MALI_UIO, M_WAITOK | M_ZERO);
    if (sc == NULL)
        return (ENOMEM);

    sc->sc_dev     = dev;
    sc->sc_mem_rid = 0;
    device_set_softc(dev, sc);

    /*
     * Allocate the MMIO window.  We use bus_set_resource() to seed the
     * rman entry with the A64 physical address before calling
     * bus_alloc_resource_any(), because simplebus on FreeBSD 15 populates
     * resources from FDT reg properties; when loaded manually (nexus) we
     * must supply them ourselves.
     */
    bus_set_resource(dev, SYS_RES_MEMORY, sc->sc_mem_rid,
        MALI_MMIO_BASE, MALI_MMIO_SIZE);

    sc->sc_mem = bus_alloc_resource_any(dev, SYS_RES_MEMORY,
        &sc->sc_mem_rid, RF_ACTIVE);
    if (sc->sc_mem == NULL) {
        device_printf(dev, "cannot allocate MMIO resource at 0x%lx+0x%lx\n",
            (unsigned long)MALI_MMIO_BASE, (unsigned long)MALI_MMIO_SIZE);
        error = ENXIO;
        goto fail_res;
    }

    /*
     * Create /dev/uio0.  makedev_args_init() is not needed on older KPIs;
     * make_dev() with uid=0, gid=0, mode=0600 is sufficient for now.
     * Phase 2: add a dedicated "video" group and 0660 permissions.
     */
    error = make_dev_p(MAKEDEV_CHECKNAME | MAKEDEV_WAITOK,
        &sc->sc_cdev, &mali_cdevsw, NULL,
        UID_ROOT, GID_WHEEL, 0600, "uio0");
    if (error != 0) {
        device_printf(dev, "make_dev_p failed: %d\n", error);
        goto fail_dev;
    }
    sc->sc_cdev->si_drv1 = sc;

    device_printf(dev,
        "Mali-400 MMIO 0x%08lx+0x%05lx mapped, /dev/uio0 ready\n",
        (unsigned long)MALI_MMIO_BASE, (unsigned long)MALI_MMIO_SIZE);

    return (0);

fail_dev:
    bus_release_resource(dev, SYS_RES_MEMORY, sc->sc_mem_rid, sc->sc_mem);
fail_res:
    free(sc, M_MALI_UIO);
    device_set_softc(dev, NULL);
    return (error);
}

/*
 * mali_detach
 *
 * purpose:  Release all resources and destroy /dev/uio0 on module unload
 *           or device removal.
 * input:    dev — attached device node
 * output:   0 always
 * sideEffects: destroys /dev/uio0; releases IOMEM rman entry; frees softc
 */
static int
mali_detach(device_t dev)
{
    struct mali_uio_softc *sc = device_get_softc(dev);

    if (sc == NULL)
        return (0);

    if (sc->sc_cdev != NULL) {
        destroy_dev(sc->sc_cdev);
        sc->sc_cdev = NULL;
    }

    if (sc->sc_mem != NULL) {
        bus_release_resource(dev, SYS_RES_MEMORY, sc->sc_mem_rid, sc->sc_mem);
        sc->sc_mem = NULL;
    }

    free(sc, M_MALI_UIO);
    device_set_softc(dev, NULL);
    return (0);
}

/* ---------------------------------------------------------------------------
 * Driver registration
 * ------------------------------------------------------------------------- */

static device_method_t mali_methods[] = {
    DEVMETHOD(device_probe,  mali_probe),
    DEVMETHOD(device_attach, mali_attach),
    DEVMETHOD(device_detach, mali_detach),
    DEVMETHOD_END
};

static driver_t mali_driver = {
    .name    = "mali_uio",
    .methods = mali_methods,
    .size    = sizeof(struct mali_uio_softc),
};

/*
 * Attach to simplebus (FDT path, PinePhone Pro runtime) and nexus
 * (manual kldload path for development on QEMU without full FDT node).
 */
DRIVER_MODULE(mali_uio, simplebus, mali_driver, 0, 0);
DRIVER_MODULE(mali_uio, nexus,     mali_driver, 0, 0);

MODULE_DEPEND(mali_uio, nexus, 1, 1, 1);
MODULE_VERSION(mali_uio, 1);
MODULE_AUTHOR("bsdOS project");
MODULE_DESCRIPTION("Mali-400 UIO shim for Lima userspace driver (A64/PinePhone Pro)");
