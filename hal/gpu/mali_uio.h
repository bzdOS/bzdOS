/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * mali_uio.h — public header for Mali-400 UIO driver (FreeBSD)
 *
 * purpose:   Expose Mali-400 MMIO constants and ioctl interface so that
 *            Lima userspace driver can locate and map GPU registers via
 *            the /dev/uio0 character device.
 * input:     included by both kernel module (mali_uio.c) and userspace
 *            Lima integration layer.
 * output:    MALI_MMIO_* constants, struct mali_uio_mmap_info, MALI_UIO_GET_INFO
 * sideEffects: none — header only
 *
 * Target: FreeBSD 15.1 aarch64, Allwinner A64 (PinePhone Pro / Squirrel v0.1.x)
 * Lima phase 1.5: UIO shim before full sun4i-drm port.
 */

#ifndef _MALI_UIO_H_
#define _MALI_UIO_H_

#include <sys/types.h>
#include <sys/ioccom.h>

/*
 * Allwinner A64 Mali-400 MP2 hardware constants.
 * Source: Allwinner A64 User Manual v1.1, §3.12 "MALI400" base address table.
 */
#define MALI_MMIO_BASE      0x01C40000UL    /* physical base of Mali-400 MMIO */
#define MALI_MMIO_SIZE      0x00010000UL    /* 64 KB — GP + PP0 + L2 + MMU regs */

/*
 * IRQ lines (A64 GIC SPI numbers, 0-indexed from GIC base).
 * Mali GP  = SPI 97 → Linux IRQ 129, FreeBSD resource ID 0
 * Mali PP0 = SPI 98 → Linux IRQ 130, FreeBSD resource ID 1
 */
#define MALI_IRQ_GP         97
#define MALI_IRQ_PP0        98

/*
 * struct mali_uio_mmap_info
 *
 * purpose:  Carry physical address and size of the Mali MMIO window to
 *           userspace so Lima can call mmap(2) with the correct offset.
 * input:    filled by kernel via MALI_UIO_GET_INFO ioctl
 * output:   phys_addr — physical base address for mmap offset arithmetic
 *           size      — byte length of the mappable region
 * sideEffects: none
 *
 * Userspace mmap example:
 *   void *regs = mmap(NULL, info.size,
 *                     PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
 * The driver's d_mmap handler converts offset 0 → phys_addr page frame.
 */
struct mali_uio_mmap_info {
    uint64_t    phys_addr;  /* MALI_MMIO_BASE — physical address */
    uint64_t    size;       /* MALI_MMIO_SIZE — byte length      */
};

/*
 * MALI_UIO_GET_INFO
 *
 * purpose:  ioctl(2) command to retrieve mali_uio_mmap_info from /dev/uio0.
 * input:    fd — open file descriptor for /dev/uio0
 *           arg — pointer to struct mali_uio_mmap_info (output)
 * output:   fills *arg; returns 0 on success, errno on failure
 * sideEffects: none
 */
#define MALI_UIO_GET_INFO   _IOR('M', 0, struct mali_uio_mmap_info)

#endif /* _MALI_UIO_H_ */
