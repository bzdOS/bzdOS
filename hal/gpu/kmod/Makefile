# mali_uio.ko — builds inside FreeBSD guest with src tree available
# make -C /usr/src/sys modules MODULES_OVERRIDE= KMODDIR=/boot/modules
# Or copy to /usr/src/sys/modules/mali_uio/ and include in kernel build

SRCS=   mali_uio.c
KMOD=   mali_uio

.include <bsd.kmod.mk>
