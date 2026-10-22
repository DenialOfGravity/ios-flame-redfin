/*
 * rmtfs: the modem's EFS lives in the modemst1/modemst2/fsg/fsc partitions,
 * which the modem reaches through this QMI service (14) on the apps side
 * (protocol as github.com/andersson/rmtfs; memory set up as the downstream
 * msm_sharedmem rmtfs client: 2 MB, guarded by 4K at both ends, shared with
 * the modem's VM by hyp_assign). The partitions are files on the phone.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include "link.h"
#include "pmem.h"
#include "qmi.h"
#include "rmtfs.h"
#include "scm.h"

#define RMTFS_DIR	"/var/local/fw/rmtfs"
#define BUF_SIZE	0x200000u
#define SECTOR		512

enum { RMTFS_OPEN = 1, RMTFS_CLOSE, RMTFS_RW_IOVEC, RMTFS_ALLOC_BUFF, RMTFS_GET_DEV_ERROR, RMTFS_FORCE_SYNC_IND };

static const struct { const char *path, *file; } parts[] = {
	{ "/boot/modem_fs1", "modemst1.img" },
	{ "/boot/modem_fs2", "modemst2.img" },
	{ "/boot/modem_fsg", "fsg.img" },
	{ "/boot/modem_fsc", "fsc.img" },
};
#define NPARTS (sizeof(parts) / sizeof(parts[0]))
static int fds[NPARTS] = { -1, -1, -1, -1 };
static uint64_t buf_pa;

int rmtfs_init(void)
{
	for (unsigned i = 0; i < NPARTS; i++) {
		char p[128];
		snprintf(p, sizeof(p), RMTFS_DIR "/%s", parts[i].file);
		fds[i] = open(p, O_RDWR);
		if (fds[i] < 0) {
			printf("rmtfs: %s: %s\n", p, strerror(errno));
			return -1;
		}
	}
	/*
	 * One buffer per phone boot, kept across modem restarts: a fresh 2 MB hyp_assign after
	 * every restart (the old ones never handed back) ends with an SMC that never returns.
	 */
	struct timeval bt;
	size_t btl = sizeof(bt);
	sysctlbyname("kern.boottime", &bt, &btl, NULL, 0);
	FILE *f = fopen(RMTFS_DIR "/.buffer", "r");
	long long fb = 0;
	unsigned long long fpa = 0;
	if (f) {
		if (fscanf(f, "%lld %llx", &fb, &fpa) != 2)
			fpa = 0;
		fclose(f);
	}
	if (fpa && fb == (long long)bt.tv_sec) {
		buf_pa = fpa;
		printf("rmtfs: buffer %llx from this boot's first run\n", (unsigned long long)buf_pa);
	} else {
		uint64_t a = pm_alloc(BUF_SIZE + 0x2000, 0x1000);
		if (!a)
			return -1;
		buf_pa = a + 0x1000;
		static const uint32_t src[] = { VMID_HLOS }, dst[] = { VMID_HLOS, VMID_MSS_MSA };
		if (hyp_assign(buf_pa, BUF_SIZE, src, 1, dst, 2))
			return -1;
		if ((f = fopen(RMTFS_DIR "/.buffer", "w"))) {
			fprintf(f, "%lld %llx\n", (long long)bt.tv_sec, (unsigned long long)buf_pa);
			fclose(f);
		}
	}
	if (qrtr_new_server(RMTFS_SERVICE, 1, 0, RMTFS_PORT))
		return -1;
	printf("rmtfs: serving at %u:%x, buffer %llx\n", QRTR_NODE_APPS, RMTFS_PORT, (unsigned long long)buf_pa);
	return 0;
}

static void reply(const struct qrtr_hdr *h, struct qmi_buf *q)
{
	qrtr_send(QRTR_TYPE_DATA, RMTFS_PORT, h->src_node, h->src_port, q->b, (uint32_t)qmi_finish(q));
}

static int iovec(uint32_t caller, uint8_t dir, const uint8_t *v, uint16_t len)
{
	if (caller < 1 || caller > NPARTS)
		return -1;
	int fd = fds[caller - 1];
	unsigned hdr = (len % 12 == 1) ? 1 : (len % 12 == 2) ? 2 : 4;
	unsigned n = (len - hdr) / 12;
	static uint8_t tmp[BUF_SIZE];
	for (unsigned i = 0; i < n; i++) {
		uint32_t e[3];
		memcpy(e, v + hdr + 12 * i, 12);
		uint64_t off = (uint64_t)e[0] * SECTOR, bytes = (uint64_t)e[2] * SECTOR;
		/* phys_offset: an address in the buffer (rmtfs_mem_ptr), or an offset into it */
		uint64_t pa = e[1] >= (uint32_t)buf_pa ? (buf_pa & ~0xffffffffull) + e[1] : buf_pa + e[1];
		if (pa < buf_pa || pa + bytes > buf_pa + BUF_SIZE || bytes > sizeof(tmp)) {
			printf("rmtfs: iovec out of the buffer (%x %x %x)\n", e[0], e[1], e[2]);
			return -1;
		}
		if (dir == 0) {
			ssize_t r = pread(fd, tmp, bytes, (off_t)off);
			if (r < (ssize_t)bytes)
				memset(tmp + (r > 0 ? r : 0), 0, bytes - (r > 0 ? r : 0));
			pm_wr(pa, tmp, bytes);
		} else {
			pm_rd(pa, tmp, bytes);
			if (pwrite(fd, tmp, bytes, (off_t)off) != (ssize_t)bytes)
				return -1;
		}
		printf("rmtfs: %s %s sectors %u+%u\n", dir ? "write" : "read", parts[caller - 1].file, e[0], e[2]);
	}
	if (dir)
		fsync(fd);
	return 0;
}

void rmtfs_handle(const struct qrtr_hdr *h, const uint8_t *d, uint32_t n)
{
	struct qmi_msg m;
	struct qmi_buf q;
	uint32_t caller = 0;
	if (qmi_parse(d, n, &m) || m.type != QMI_REQUEST)
		return;
	qmi_start(&q, QMI_RESPONSE, m.txn, m.id);
	qmi_get_u32(&m, 1, &caller);
	switch (m.id) {
	case RMTFS_OPEN: {
		uint16_t l;
		const uint8_t *p = qmi_get(&m, 1, &l);
		char path[64] = { 0 };
		if (p)
			memcpy(path, p, l < 63 ? l : 63);
		unsigned i;
		for (i = 0; i < NPARTS; i++)
			if (!strcmp(path, parts[i].path))
				break;
		printf("rmtfs: open \"%s\" -> %d\n", path, i < NPARTS ? (int)i + 1 : -1);
		if (i < NPARTS) {
			qmi_tlv_result(&q, 0, 0);
			qmi_tlv_u32(&q, 0x10, i + 1);
		} else {
			qmi_tlv_result(&q, 1, 3);
		}
		break;
	}
	case RMTFS_CLOSE:
		printf("rmtfs: close %u\n", caller);
		qmi_tlv_result(&q, 0, 0);
		break;
	case RMTFS_ALLOC_BUFF: {
		uint32_t size = 0;
		qmi_get_u32(&m, 2, &size);
		printf("rmtfs: alloc %u bytes for %u -> %llx\n", size, caller, (unsigned long long)buf_pa);
		if (size <= BUF_SIZE) {
			qmi_tlv_result(&q, 0, 0);
			qmi_tlv_u64(&q, 0x10, buf_pa);
		} else {
			qmi_tlv_result(&q, 1, 3);
		}
		break;
	}
	case RMTFS_RW_IOVEC: {
		uint8_t dir = 0;
		uint16_t l = 0;
		qmi_get_u8(&m, 2, &dir);
		const uint8_t *v = qmi_get(&m, 3, &l);
		int r = v ? iovec(caller, dir, v, l) : -1;
		qmi_tlv_result(&q, r ? 1 : 0, r ? 3 : 0);
		break;
	}
	case RMTFS_GET_DEV_ERROR:
		qmi_tlv_result(&q, 0, 0);
		qmi_tlv_u8(&q, 0x10, 0);
		break;
	default:
		qmi_dump(&m);
		qmi_tlv_result(&q, 1, 0x47);	/* QMI_ERR_NOT_SUPPORTED */
		break;
	}
	reply(h, &q);
}
