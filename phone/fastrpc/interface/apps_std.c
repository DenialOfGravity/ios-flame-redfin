/*
 * FastRPC operating system interface - method definitions
 *
 * Copyright (C) 2025 HexagonRPC Contributors
 *
 * This file is part of HexagonRPC.
 *
 * HexagonRPC is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * Modified for fastrpcd (ios-flame, 2026): definitions checked against Qualcomm's apps_std_skel.c (fastrpc.git);
 * freopen, fflush and mkdir corrected (they were never called upstream); fopen, fwrite, ftell, flen, rewind,
 * feof, print_string, getenv, fileExists, fsync, fremove, rmdir, ftrunc and frename added.
 */

#include <stdint.h>
#include <libhexagonrpc/hexagonrpc.h>

#define DEF(name, id, ...)								\
	static const struct hrpc_arg_def_interp4 name##_args[] = { __VA_ARGS__ };	\
	const struct hrpc_method_def_interp4 name##_def = {				\
		.msg_id = id,								\
		.n_args = HRPC_ARRAY_SIZE(name##_args),					\
		.args = name##_args,							\
		.n_inner_types = 0,							\
		.inner_types = NULL,							\
	}

#define W32	{ HRPC_ARG_WORD, sizeof(uint32_t) }
#define W64	{ HRPC_ARG_WORD, sizeof(uint64_t) }
#define STR	{ HRPC_ARG_BLOB_SEQ, sizeof(char) }
#define O32	{ HRPC_ARG_OUT_BLOB, sizeof(uint32_t) }
#define O64	{ HRPC_ARG_OUT_BLOB, sizeof(uint64_t) }
#define OSEQ	{ HRPC_ARG_OUT_BLOB_SEQ, sizeof(char) }

DEF(apps_std_fopen, 0, STR, STR, O32);				/* name, mode -> FILE */
DEF(apps_std_freopen, 1, W32, STR, STR, O32);			/* FILE, name, mode -> FILE */
DEF(apps_std_fflush, 2, W32);
DEF(apps_std_fclose, 3, W32);
DEF(apps_std_fread, 4, W32, OSEQ, O32, O32);			/* FILE -> buf, bytes read, eof */
DEF(apps_std_fwrite, 5, W32, STR, O32, O32);			/* FILE, buf -> bytes written, eof */
DEF(apps_std_ftell, 8, W32, O32);
DEF(apps_std_fseek, 9, W32, W32, W32);				/* FILE, offset, whence */
DEF(apps_std_flen, 10, W32, O64);
DEF(apps_std_rewind, 11, W32);
DEF(apps_std_feof, 12, W32, O32);
DEF(apps_std_print_string, 15, STR);
DEF(apps_std_getenv, 16, STR, OSEQ, O32);			/* name -> value, value length */
DEF(apps_std_fopen_with_env, 19, STR, STR, STR, STR, O32);	/* env var, delimiter, name, mode -> FILE */
DEF(apps_std_fileExists, 22, STR, { HRPC_ARG_OUT_BLOB, 1 });	/* name -> bool */
DEF(apps_std_fsync, 23, W32);
DEF(apps_std_fremove, 24, STR);
DEF(apps_std_opendir, 26, STR, O64);
DEF(apps_std_closedir, 27, W64);
DEF(apps_std_readdir, 28, W64, O32, { HRPC_ARG_OUT_BLOB, 256 }, O32);	/* DIR -> ino, name[255], eof */
DEF(apps_std_mkdir, 29, STR, W32);
DEF(apps_std_rmdir, 30, STR);
DEF(apps_std_stat, 31, STR, O64, O64, O64, O32, O32, O64, O64, O64, O64, O64, O64, O64, O64);
DEF(apps_std_ftrunc, 32, W32, W32);
DEF(apps_std_frename, 33, STR, STR);
