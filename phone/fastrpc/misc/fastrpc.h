/*
 * fastrpcd: the parts of Linux's <misc/fastrpc.h> (include/uapi/misc/fastrpc.h) that hexagonrpcd's
 * sources use, with the Linux kernel's work done in userland by transport.c: there is no Linux
 * fastrpc driver on this phone, only /dev/redwood-fastrpc, which carries 40-byte messages (XNU
 * patch 0950). hexagonrpc.c, apps_mem.c and fastrpcd.c call fastrpc_ioctl() where hexagonrpcd
 * calls ioctl() on /dev/fastrpc-adsp; its "fd" is a session of transport.c.
 *
 * Copyright (C) 2026 the ios-flame contributors. GPL-3.0-or-later (part of fastrpcd, see LICENSE.hexagonrpc).
 */
#ifndef FASTRPCD_MISC_FASTRPC_H
#define FASTRPCD_MISC_FASTRPC_H

#include <stdint.h>

typedef uint64_t __u64;
typedef uint32_t __u32;
typedef int32_t __s32;

#define FASTRPC_IOCTL_INVOKE		3
#define FASTRPC_IOCTL_INIT_ATTACH	4
#define FASTRPC_IOCTL_MMAP		6
#define FASTRPC_IOCTL_MUNMAP		7
#define FASTRPC_IOCTL_INIT_ATTACH_SNS	8

struct fastrpc_invoke_args {
	__u64 ptr;
	__u64 length;
	__s32 fd;
	__u32 attr;
};

struct fastrpc_invoke {
	__u32 handle;
	__u32 sc;
	__u64 args;
};

struct fastrpc_req_mmap {
	__s32 fd;
	__u32 flags;	/* flags for dsp to map with */
	__u64 vaddrin;	/* optional virtual address */
	__u64 size;	/* size */
	__u64 vaddrout;	/* dsp virtual address */
};

struct fastrpc_req_munmap {
	__u64 vaddrout;
	__u64 size;
};

/* transport.c: what ioctl(2) on /dev/fastrpc-adsp does on Linux. -1 and errno, or the DSP's AEE result. */
int fastrpc_ioctl(int fd, unsigned long request, void *arg);

#endif
