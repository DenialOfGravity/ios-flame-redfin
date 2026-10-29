/*
 * fastrpcd: the DSP's apps_std file service (handle 1 of the reverse tunnel), served from a directory
 * tree on the phone (default /private/var/local/hexagon). What hexagonrpcd's apps_std.c + hexagonfs do,
 * written again for a plain tree: the DSP's path is mapped onto ROOT (see apps_std.h), every open, stat
 * and directory listing is logged with its result, writes are allowed under /persist only (the sensors
 * registry), and anything else the DSP asks for gets an error answer, never an exit.
 *
 * Method numbers and argument layouts: Qualcomm's apps_std IDL (fastrpc.git apps_std_skel.c).
 * Copyright (C) 2026 the ios-flame contributors. GPL-3.0-or-later (part of fastrpcd).
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>

#include <libhexagonrpc/error.h>
#include "apps_std.h"
#include "interface/apps_std.h"
#include "iobuffer.h"
#include "listener.h"
#include "log.h"

#define MAX_FILES	64
#define MAX_DIRS	16
#define HANDLE_BASE	0x100	/* handles are never 0 */

struct apps_std_ctx {
	char root[PATH_MAX];
	struct {
		int fd;
		int eof;
		char path[256];
	} file[MAX_FILES];
	struct {
		struct dent *ent;	/* the listing, sorted the DSP's way (see dent_cmp), read at opendir */
		int n, at;		/* n < 0: not in use */
		char path[256];
	} dir[MAX_DIRS];
};

struct dent {
	uint32_t ino;
	char name[256];
};

/*
 * The order readdir hands the names out in: the sensors PD reads the registry item by item (stat, fopen,
 * fread, fclose each) and CHRE's SEE helper gives up if the sensors it needs have not been published within
 * a few seconds of its start (r24a: sar.cc chre_utils fatal with the registry read up to "sns_d..."): the
 * proximity/light sensor, the IMU and the framework's own items first, everything else after; by name within.
 */
static int dent_rank(const char *n)
{
	if (!strncmp(n, "tcs3701", 7))
		return 0;
	if (!strncmp(n, "lsm6dsr", 7))
		return 1;
	if (!strncmp(n, "sns_", 4))
		return 2;
	return 3;
}

static int dent_cmp(const void *a, const void *b)
{
	const struct dent *x = a, *y = b;
	int rx = dent_rank(x->name), ry = dent_rank(y->name);

	return rx != ry ? rx - ry : strcmp(x->name, y->name);
}

/* An errno for the DSP: its file code expects the small POSIX numbers (Android returns errno). */
static uint32_t err_out(int e)
{
	return (e > 0 && e <= 34) ? (uint32_t)e : AEE_EFAILED;
}

/* "a/./b/../c" -> "/a/c" into out; -1 if not absolute, too long, or ".." would leave "/". */
static int canonical(const char *in, char *out, size_t n_out)
{
	size_t len = 0;
	const char *p = in, *seg;

	if (*p != '/')
		return -1;
	out[0] = '\0';
	while (*p) {
		size_t sl;

		while (*p == '/')
			p++;
		if (!*p)
			break;
		seg = p;
		while (*p && *p != '/')
			p++;
		sl = (size_t)(p - seg);
		if (sl == 1 && seg[0] == '.')
			continue;
		if (sl == 2 && seg[0] == '.' && seg[1] == '.') {
			char *slash;

			if (len == 0)
				return -1;	/* escape above the root */
			slash = strrchr(out, '/');
			len = (size_t)(slash - out);
			out[len] = '\0';
			continue;
		}
		if (len + 1 + sl + 1 > n_out)
			return -1;
		out[len++] = '/';
		memcpy(out + len, seg, sl);
		len += sl;
		out[len] = '\0';
	}
	if (len == 0) {
		if (n_out < 2)
			return -1;
		strcpy(out, "/");
	}
	return 0;
}

static int has_prefix(const char *s, const char *prefix)
{
	size_t n = strlen(prefix);

	return strncmp(s, prefix, n) == 0 && (s[n] == '\0' || s[n] == '/');
}

/* The resolved host path must stay inside root (symbolic links included). A path that does not exist
 * passes when its parent is inside (or missing too): open() then fails with ENOENT or, for a write,
 * creates the file there (O_NOFOLLOW: never through a link). */
static int inside_root(const char *root, const char *host)
{
	char real[PATH_MAX], parent[PATH_MAX], *slash;
	size_t n = strlen(root);

	if (realpath(host, real) == NULL) {
		if (errno != ENOENT)
			return 0;
		snprintf(parent, sizeof(parent), "%s", host);
		slash = strrchr(parent, '/');
		if (slash == NULL)
			return 0;
		*slash = '\0';
		if (realpath(parent, real) == NULL)
			return errno == ENOENT;
	}
	return strncmp(real, root, n) == 0 && (real[n] == '\0' || real[n] == '/');
}

int apps_std_map(const char *root, const char *dsp_path, int for_write, char *out, size_t n_out)
{
	char canon[PATH_MAX], tmp[PATH_MAX], real_root[PATH_MAX];
	int n;

	if (canonical(dsp_path, canon, sizeof(canon)))
		return -1;
	if (has_prefix(canon, "/system/vendor")) {
		snprintf(tmp, sizeof(tmp), "%s", canon + strlen("/system"));
		strcpy(canon, tmp);
	} else if (has_prefix(canon, "/mnt/vendor/persist")) {
		snprintf(tmp, sizeof(tmp), "%s", canon + strlen("/mnt/vendor"));
		strcpy(canon, tmp);
	}
	if (for_write && !has_prefix(canon, "/persist"))
		return -1;
	n = snprintf(out, n_out, "%s%s", root, strcmp(canon, "/") ? canon : "");
	if (n < 0 || (size_t)n >= n_out)
		return -1;
	if (realpath(root, real_root) == NULL || !inside_root(real_root, out))
		return -1;
	return 0;
}

static const char *cstr(const struct fastrpc_io_buffer *b)
{
	if (b->s == 0 || ((const char *)b->p)[b->s - 1] != '\0')
		return NULL;
	return b->p;
}

static int open_flags(const char *mode, int *for_write)
{
	int plus = strchr(mode, '+') != NULL;

	*for_write = mode[0] != 'r' || plus;
	switch (mode[0]) {
	case 'r':
		return plus ? O_RDWR : O_RDONLY;
	case 'w':
		return (plus ? O_RDWR : O_WRONLY) | O_CREAT | O_TRUNC;
	case 'a':
		return (plus ? O_RDWR : O_WRONLY) | O_CREAT | O_APPEND;
	default:
		return -1;
	}
}

/* Open a DSP path. A handle, or 0 and *err. */
static uint32_t file_open_q(struct apps_std_ctx *ctx, const char *how, const char *name, const char *mode, uint32_t *err,
			    int probing);
static uint32_t file_open(struct apps_std_ctx *ctx, const char *how, const char *name, const char *mode, uint32_t *err)
{
	return file_open_q(ctx, how, name, mode, err, 0);
}

/* probing: one of the places of a search path, a miss there is not news */
static uint32_t file_open_q(struct apps_std_ctx *ctx, const char *how, const char *name, const char *mode, uint32_t *err,
			    int probing)
{
	char host[PATH_MAX];
	int for_write, flags = open_flags(mode, &for_write), fd, i;

	if (flags < 0) {
		flog("%s %s mode \"%s\": bad mode", how, name, mode);
		*err = AEE_EBADPARM;
		return 0;
	}
	if (apps_std_map(ctx->root, name, for_write, host, sizeof(host))) {
		flog("%s %s (%s): REFUSED (outside the served tree%s)", how, name, mode, for_write ? " or not writable" : "");
		*err = for_write ? EACCES : ENOENT;
		return 0;
	}
	fd = open(host, flags | O_CLOEXEC | O_NOFOLLOW, 0644);
	if (fd < 0) {
		int e = errno;

		if (probing && e == ENOENT)
			vlog("%s %s (%s) -> %s: %s", how, name, mode, host, strerror(e));
		else
			flog("%s %s (%s) -> %s: %s", how, name, mode, host, strerror(e));
		*err = err_out(e);
		return 0;
	}
	for (i = 0; i < MAX_FILES; i++)
		if (ctx->file[i].fd < 0) {
			struct stat st;

			ctx->file[i].fd = fd;
			ctx->file[i].eof = 0;
			snprintf(ctx->file[i].path, sizeof(ctx->file[i].path), "%s", name);
			fstat(fd, &st);
			vlog("%s %s (%s) -> handle %#x, %lld bytes", how, name, mode, HANDLE_BASE + i, (long long)st.st_size);
			*err = 0;
			return HANDLE_BASE + (uint32_t)i;
		}
	close(fd);
	flog("%s %s: too many open files", how, name);
	*err = AEE_EOUTOFHANDLES;
	return 0;
}

static int file_fd(struct apps_std_ctx *ctx, uint32_t h)
{
	if (h < HANDLE_BASE || h >= HANDLE_BASE + MAX_FILES || ctx->file[h - HANDLE_BASE].fd < 0) {
		flog("bad file handle %#x", h);
		return -1;
	}
	return ctx->file[h - HANDLE_BASE].fd;
}

/* ---- methods ---- */

static uint32_t m_fopen(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	const char *name = cstr(&in[1]), *mode = cstr(&in[2]);
	uint32_t err, *h = out[0].p;

	if (!name || !mode)
		return AEE_EBADPARM;
	*h = file_open(data, "fopen", name, mode, &err);
	return err;
}

static uint32_t m_freopen(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	const uint32_t *old = in[0].p;
	const char *name = cstr(&in[1]), *mode = cstr(&in[2]);
	uint32_t err, *h = out[0].p;
	int fd;

	if (!name || !mode)
		return AEE_EBADPARM;
	if ((fd = file_fd(ctx, *old)) >= 0) {
		close(fd);
		ctx->file[*old - HANDLE_BASE].fd = -1;
	}
	*h = file_open(ctx, "freopen", name, mode, &err);
	return err;
}

static uint32_t m_fflush(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	const uint32_t *h = in[0].p;

	(void)out;
	return file_fd(data, *h) < 0 ? AEE_EBADPARM : 0;	/* no buffering: writes go straight out */
}

static uint32_t m_fsync(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	const uint32_t *h = in[0].p;
	int fd = file_fd(data, *h);

	(void)out;
	if (fd < 0)
		return AEE_EBADPARM;
	fsync(fd);
	return 0;
}

static uint32_t m_fclose(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	const uint32_t *h = in[0].p;
	int fd = file_fd(ctx, *h);

	(void)out;
	if (fd < 0)
		return AEE_EBADPARM;
	close(fd);
	ctx->file[*h - HANDLE_BASE].fd = -1;
	vlog("fclose %#x (%s)", *h, ctx->file[*h - HANDLE_BASE].path);
	return 0;
}

static uint32_t m_fread(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	const struct {
		uint32_t h, size;
	} *a = in[0].p;
	struct {
		uint32_t got, eof;
	} *r = out[0].p;
	int fd = file_fd(ctx, a->h);
	size_t got = 0;

	if (fd < 0)
		return AEE_EBADPARM;
	while (got < out[1].s) {
		ssize_t n = read(fd, (char *)out[1].p + got, out[1].s - got);

		if (n < 0 && errno == EINTR)
			continue;
		if (n < 0) {
			flog("fread %#x (%s): %s", a->h, ctx->file[a->h - HANDLE_BASE].path, strerror(errno));
			return err_out(errno);
		}
		if (n == 0)
			break;
		got += (size_t)n;
	}
	r->got = (uint32_t)got;
	r->eof = got < out[1].s;
	ctx->file[a->h - HANDLE_BASE].eof = r->eof;
	vlog("fread %#x (%s) %u -> %zu%s", a->h, ctx->file[a->h - HANDLE_BASE].path, a->size, got, r->eof ? " eof" : "");
	return 0;
}

static uint32_t m_fwrite(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	const uint32_t *h = in[0].p;
	struct {
		uint32_t put, eof;
	} *r = out[0].p;
	int fd = file_fd(ctx, *h);
	size_t put = 0;

	if (fd < 0)
		return AEE_EBADPARM;
	while (put < in[1].s) {
		ssize_t n = write(fd, (const char *)in[1].p + put, in[1].s - put);

		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0) {
			flog("fwrite %#x (%s): %s", *h, ctx->file[*h - HANDLE_BASE].path, strerror(errno));
			return err_out(errno);
		}
		put += (size_t)n;
	}
	r->put = (uint32_t)put;
	r->eof = 0;
	flog("fwrite %#x (%s) %zu bytes", *h, ctx->file[*h - HANDLE_BASE].path, put);
	return 0;
}

static uint32_t m_ftell(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	const uint32_t *h = in[0].p;
	uint32_t *pos = out[0].p;
	int fd = file_fd(data, *h);
	off_t o;

	if (fd < 0)
		return AEE_EBADPARM;
	o = lseek(fd, 0, SEEK_CUR);
	if (o < 0)
		return err_out(errno);
	*pos = (uint32_t)o;
	return 0;
}

static uint32_t m_fseek(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	static const int whence[] = { SEEK_SET, SEEK_CUR, SEEK_END };
	const struct {
		uint32_t h;
		int32_t off;
		uint32_t whence;
	} *a = in[0].p;
	int fd = file_fd(ctx, a->h);

	(void)out;
	if (fd < 0 || a->whence > 2)
		return AEE_EBADPARM;
	if (lseek(fd, a->off, whence[a->whence]) < 0)
		return err_out(errno);
	ctx->file[a->h - HANDLE_BASE].eof = 0;
	return 0;
}

static uint32_t m_flen(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	const uint32_t *h = in[0].p;
	uint64_t *len = out[0].p;
	int fd = file_fd(data, *h);
	struct stat st;

	if (fd < 0)
		return AEE_EBADPARM;
	if (fstat(fd, &st))
		return err_out(errno);
	*len = (uint64_t)st.st_size;
	return 0;
}

static uint32_t m_rewind(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	const uint32_t *h = in[0].p;
	int fd = file_fd(ctx, *h);

	(void)out;
	if (fd < 0)
		return AEE_EBADPARM;
	lseek(fd, 0, SEEK_SET);
	ctx->file[*h - HANDLE_BASE].eof = 0;
	return 0;
}

static uint32_t m_feof(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	const uint32_t *h = in[0].p;
	uint32_t *eof = out[0].p;

	if (file_fd(ctx, *h) < 0)
		return AEE_EBADPARM;
	*eof = (uint32_t)ctx->file[*h - HANDLE_BASE].eof;
	return 0;
}

static uint32_t m_ftrunc(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	const struct {
		uint32_t mid, h, len;	/* extended method: its id comes first */
	} *a = in[0].p;
	int fd = file_fd(ctx, a->h);

	(void)out;
	if (fd < 0)
		return AEE_EBADPARM;
	if (ftruncate(fd, a->len))
		return err_out(errno);
	flog("ftrunc %#x (%s) %u", a->h, ctx->file[a->h - HANDLE_BASE].path, a->len);
	return 0;
}

static uint32_t m_print_string(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	const char *s = cstr(&in[1]);

	(void)data;
	(void)out;
	flog("DSP says: %s", s ? s : "(unterminated)");
	return 0;
}

static const char *const library_path[] = { "/usr/lib/qcom/adsp", "/vendor/lib/rfsa/adsp", "/vendor/dsp", NULL };
static const char *const avs_cfg_path[] = { "/vendor/etc/acdbdata", NULL };

static uint32_t m_getenv(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	const char *name = cstr(&in[1]), *value = NULL;
	uint32_t *len = out[0].p;

	(void)data;
	if (!name)
		return AEE_EBADPARM;
	if (!strcmp(name, "ADSP_LIBRARY_PATH"))
		value = "/usr/lib/qcom/adsp;/vendor/lib/rfsa/adsp;/vendor/dsp";
	else if (!strcmp(name, "ADSP_AVS_CFG_PATH"))
		value = "/vendor/etc/acdbdata";
	flog("getenv %s -> %s", name, value ? value : "(none)");
	if (!value)
		return AEE_ENOSUCH;
	if (strlen(value) + 1 > out[1].s)
		return AEE_EBUFFERTOOSMALL;
	memset(out[1].p, 0, out[1].s);
	memcpy(out[1].p, value, strlen(value) + 1);
	*len = (uint32_t)strlen(value) + 1;
	return 0;
}

static uint32_t m_fopen_with_env(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	const char *env = cstr(&in[1]), *name = cstr(&in[3]), *mode = cstr(&in[4]);
	const char *const *dirs = NULL;
	char path[PATH_MAX], how[64];
	uint32_t err = ENOENT, *h = out[0].p;
	int i;

	if (!env || !name || !mode)
		return AEE_EBADPARM;
	snprintf(how, sizeof(how), "fopen_with_env($%s)", env);
	if (!strcmp(env, "ADSP_LIBRARY_PATH") || !strcmp(env, "DSP_LIBRARY_PATH"))
		dirs = library_path;
	else if (!strcmp(env, "ADSP_AVS_CFG_PATH"))
		dirs = avs_cfg_path;
	if (name[0] == '/') {
		*h = file_open(ctx, how, name, mode, &err);
		return err;
	}
	if (dirs == NULL) {
		flog("%s %s: unknown search path variable", how, name);
		return ENOENT;
	}
	/* Android: "<dir>/adsp/<name>" (the subsystem's directory) first, then "<dir>/<name>" */
	for (i = 0; dirs[i]; i++) {
		snprintf(path, sizeof(path), "%s/adsp/%s", dirs[i], name);
		if ((*h = file_open_q(ctx, how, path, mode, &err, 1)) != 0)
			return 0;
		snprintf(path, sizeof(path), "%s/%s", dirs[i], name);
		if ((*h = file_open_q(ctx, how, path, mode, &err, 1)) != 0)
			return 0;
	}
	flog("%s %s (%s): not found in the search path", how, name, mode);
	return err;
}

static uint32_t m_fileExists(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	const char *name = cstr(&in[1]);
	uint8_t *exists = out[0].p;
	char host[PATH_MAX];
	struct stat st;

	if (!name)
		return AEE_EBADPARM;
	*exists = apps_std_map(ctx->root, name, 0, host, sizeof(host)) == 0 && stat(host, &st) == 0;
	vlog("fileExists %s -> %s", name, *exists ? "yes" : "no");
	return 0;
}

static uint32_t m_fremove(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	const char *name = cstr(&in[1]);
	char host[PATH_MAX];

	(void)out;
	if (!name)
		return AEE_EBADPARM;
	if (apps_std_map(ctx->root, name, 1, host, sizeof(host))) {
		flog("fremove %s: REFUSED", name);
		return EACCES;
	}
	if (unlink(host)) {
		flog("fremove %s: %s", name, strerror(errno));
		return err_out(errno);
	}
	flog("fremove %s", name);
	return 0;
}

static uint32_t m_frename(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	const char *from = cstr(&in[1]), *to = cstr(&in[2]);
	char hf[PATH_MAX], ht[PATH_MAX];

	(void)out;
	if (!from || !to)
		return AEE_EBADPARM;
	if (apps_std_map(ctx->root, from, 1, hf, sizeof(hf)) || apps_std_map(ctx->root, to, 1, ht, sizeof(ht))) {
		flog("frename %s -> %s: REFUSED", from, to);
		return EACCES;
	}
	if (rename(hf, ht)) {
		flog("frename %s -> %s: %s", from, to, strerror(errno));
		return err_out(errno);
	}
	flog("frename %s -> %s", from, to);
	return 0;
}

static uint32_t m_opendir(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	const char *name = cstr(&in[1]);
	uint64_t *h = out[0].p;
	char host[PATH_MAX];
	struct dirent *e;
	struct dent *ent = NULL;
	int n = 0, cap = 0, i;
	DIR *d;

	if (!name)
		return AEE_EBADPARM;
	if (apps_std_map(ctx->root, name, 0, host, sizeof(host))) {
		flog("opendir %s: REFUSED (outside the served tree)", name);
		return ENOENT;
	}
	for (i = 0; i < MAX_DIRS && ctx->dir[i].n >= 0; i++)
		;
	if (i == MAX_DIRS) {
		flog("opendir %s: too many open directories", name);
		return AEE_EOUTOFHANDLES;
	}
	d = opendir(host);
	if (d == NULL) {
		flog("opendir %s -> %s: %s", name, host, strerror(errno));
		return err_out(errno);
	}
	while ((e = readdir(d)) != NULL) {
		if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
			continue;
		if (n == cap) {
			struct dent *bigger = realloc(ent, (size_t)(cap = cap ? cap * 2 : 64) * sizeof(*ent));

			if (bigger == NULL) {
				free(ent);
				closedir(d);
				return AEE_ENOMEMORY;
			}
			ent = bigger;
		}
		memset(&ent[n], 0, sizeof(ent[n]));
		ent[n].ino = (uint32_t)e->d_ino;
		memcpy(ent[n].name, e->d_name, strnlen(e->d_name, 254));	/* the DSP has name[255] */
		n++;
	}
	closedir(d);
	if (n > 1)
		qsort(ent, (size_t)n, sizeof(*ent), dent_cmp);
	ctx->dir[i].ent = ent;
	ctx->dir[i].n = n;
	ctx->dir[i].at = 0;
	snprintf(ctx->dir[i].path, sizeof(ctx->dir[i].path), "%s", name);
	*h = HANDLE_BASE + (uint64_t)i;
	flog("opendir %s -> handle %#x, %d entries%s", name, HANDLE_BASE + i, n, n ? ", sensors first" : "");
	return 0;
}

static int dir_ok(struct apps_std_ctx *ctx, uint64_t h)
{
	if (h < HANDLE_BASE || h >= HANDLE_BASE + MAX_DIRS || ctx->dir[h - HANDLE_BASE].n < 0) {
		flog("bad directory handle %#llx", (unsigned long long)h);
		return 0;
	}
	return 1;
}

static uint32_t m_closedir(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	const uint64_t *h = in[0].p;

	(void)out;
	if (!dir_ok(ctx, *h))
		return AEE_EBADPARM;
	free(ctx->dir[*h - HANDLE_BASE].ent);
	ctx->dir[*h - HANDLE_BASE].ent = NULL;
	ctx->dir[*h - HANDLE_BASE].n = -1;
	return 0;
}

static uint32_t m_readdir(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	const uint64_t *h = in[0].p;
	struct {
		uint32_t ino;
		char name[256];
		uint32_t eof;
	} *r = out[0].p;

	if (!dir_ok(ctx, *h))
		return AEE_EBADPARM;
	memset(r, 0, sizeof(*r));
	if (ctx->dir[*h - HANDLE_BASE].at >= ctx->dir[*h - HANDLE_BASE].n) {
		r->eof = 1;
		flog("readdir %s -> (end, %d entries)", ctx->dir[*h - HANDLE_BASE].path, ctx->dir[*h - HANDLE_BASE].n);
		return 0;
	}
	{
		const struct dent *e = &ctx->dir[*h - HANDLE_BASE].ent[ctx->dir[*h - HANDLE_BASE].at++];

		r->ino = e->ino;
		memcpy(r->name, e->name, sizeof(r->name));
	}
	vlog("readdir %s -> %s", ctx->dir[*h - HANDLE_BASE].path, r->name);
	return 0;
}

static uint32_t m_mkdir(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	const struct {
		uint32_t len, mode;
	} *a = in[0].p;
	const char *name = cstr(&in[1]);
	char host[PATH_MAX];

	(void)out;
	if (!name)
		return AEE_EBADPARM;
	if (apps_std_map(ctx->root, name, 1, host, sizeof(host))) {
		flog("mkdir %s: REFUSED", name);
		return EACCES;
	}
	if (mkdir(host, 0755) && errno != EEXIST) {
		flog("mkdir %s: %s", name, strerror(errno));
		return err_out(errno);
	}
	flog("mkdir %s (mode %o)", name, a->mode);
	return 0;
}

static uint32_t m_rmdir(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	const char *name = cstr(&in[1]);
	char host[PATH_MAX];

	(void)out;
	if (!name)
		return AEE_EBADPARM;
	if (apps_std_map(ctx->root, name, 1, host, sizeof(host))) {
		flog("rmdir %s: REFUSED", name);
		return EACCES;
	}
	if (rmdir(host)) {
		flog("rmdir %s: %s", name, strerror(errno));
		return err_out(errno);
	}
	flog("rmdir %s", name);
	return 0;
}

static uint32_t m_stat(void *data, const struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	struct apps_std_ctx *ctx = data;
	const char *name = cstr(&in[1]);
	struct {
		uint64_t tsz, dev, ino;
		uint32_t mode, nlink;
		uint64_t rdev, size;
		int64_t atime, atimensec, mtime, mtimensec, ctime, ctimensec;
	} *r = out[0].p;
	char host[PATH_MAX];
	struct stat st;

	if (!name)
		return AEE_EBADPARM;
	if (apps_std_map(ctx->root, name, 0, host, sizeof(host))) {
		flog("stat %s: REFUSED (outside the served tree)", name);
		return ENOENT;
	}
	if (stat(host, &st)) {
		flog("stat %s -> %s: %s", name, host, strerror(errno));
		return err_out(errno);
	}
	memset(r, 0, sizeof(*r));
	r->dev = (uint64_t)st.st_dev;
	r->ino = (uint64_t)st.st_ino;
	r->mode = (uint32_t)st.st_mode;	/* S_IFMT bits are the same as Linux's */
	r->nlink = (uint32_t)st.st_nlink;
	r->rdev = (uint64_t)st.st_rdev;
	r->size = (uint64_t)st.st_size;
#ifdef __APPLE__
	r->atime = st.st_atimespec.tv_sec;
	r->atimensec = st.st_atimespec.tv_nsec;
	r->mtime = st.st_mtimespec.tv_sec;
	r->mtimensec = st.st_mtimespec.tv_nsec;
	r->ctime = st.st_ctimespec.tv_sec;
	r->ctimensec = st.st_ctimespec.tv_nsec;
#else
	r->atime = st.st_atim.tv_sec;
	r->atimensec = st.st_atim.tv_nsec;
	r->mtime = st.st_mtim.tv_sec;
	r->mtimensec = st.st_mtim.tv_nsec;
	r->ctime = st.st_ctim.tv_sec;
	r->ctimensec = st.st_ctim.tv_nsec;
#endif
	vlog("stat %s -> %s, %lld bytes", name, S_ISDIR(st.st_mode) ? "directory" : "file", (long long)st.st_size);
	return 0;
}

#define M(name) { .def = &apps_std_##name##_def, .impl = m_##name }
#define NONE { .def = NULL, .impl = NULL }

static const struct fastrpc_function_impl apps_std_procs[] = {
	M(fopen),		/* 0 */
	M(freopen),
	M(fflush),
	M(fclose),
	M(fread),
	M(fwrite),		/* 5 */
	NONE,			/* fgetpos */
	NONE,			/* fsetpos */
	M(ftell),
	M(fseek),
	M(flen),		/* 10 */
	M(rewind),
	M(feof),
	NONE,			/* ferror */
	NONE,			/* clearerr */
	M(print_string),	/* 15 */
	M(getenv),
	NONE,			/* setenv */
	NONE,			/* unsetenv */
	M(fopen_with_env),
	NONE,			/* 20 fgets */
	NONE,			/* get_search_paths_with_env */
	M(fileExists),
	M(fsync),
	M(fremove),
	NONE,			/* 25 fdopen_decrypt */
	M(opendir),
	M(closedir),
	M(readdir),
	M(mkdir),
	M(rmdir),		/* 30 */
	M(stat),
	M(ftrunc),
	M(frename),
};

const struct fastrpc_interface apps_std_interface = {
	.name = "apps_std",
	.n_procs = sizeof(apps_std_procs) / sizeof(*apps_std_procs),
	.procs = apps_std_procs,
};

struct fastrpc_interface *fastrpc_apps_std_init(const char *root)
{
	struct fastrpc_interface *iface;
	struct apps_std_ctx *ctx;
	int i;

	iface = malloc(sizeof(*iface));
	ctx = calloc(1, sizeof(*ctx));
	if (iface == NULL || ctx == NULL) {
		free(iface);
		free(ctx);
		return NULL;
	}
	if (realpath(root, ctx->root) == NULL) {
		flog("served tree %s: %s", root, strerror(errno));
		free(iface);
		free(ctx);
		return NULL;
	}
	for (i = 0; i < MAX_FILES; i++)
		ctx->file[i].fd = -1;
	for (i = 0; i < MAX_DIRS; i++)
		ctx->dir[i].n = -1;
	memcpy(iface, &apps_std_interface, sizeof(*iface));
	iface->data = ctx;
	return iface;
}

void fastrpc_apps_std_deinit(struct fastrpc_interface *iface)
{
	struct apps_std_ctx *ctx;
	int i;

	if (iface == NULL)
		return;
	ctx = iface->data;
	for (i = 0; i < MAX_FILES; i++)
		if (ctx->file[i].fd >= 0)
			close(ctx->file[i].fd);
	for (i = 0; i < MAX_DIRS; i++)
		free(ctx->dir[i].ent);
	free(ctx);
	free(iface);
}
