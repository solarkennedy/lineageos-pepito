/* xtra-probe — raw QMI LOC client to test XTRA (predicted orbits) injection
 * on pepito without xtra-daemon (see memory gps-xtra-assist-lane).
 *
 * Question it answers: does the modem accept an XTRA3 file injected by a
 * plain QMI LOC client, so the GNSS HAL could do it for the framework's PSDS
 * downloader instead of running Qualcomm's xtra-daemon?
 *
 *   source            QMI_LOC_GET_PREDICTED_ORBITS_DATA_SOURCE (0x36): the URLs
 *                     and size limits the modem wants
 *   validity          QMI_LOC_GET_PREDICTED_ORBITS_DATA_VALIDITY (0x37)
 *   info              QMI_LOC_QUERY_XTRA_INFO (0xB0), xtraConfig=0 (bit 0 would
 *                     DISABLE the modem's auto-download timer — never sent)
 *   time              QMI_LOC_INJECT_UTC_TIME (0x38) from the AP clock, 1 s unc
 *   inject FILE [old] QMI_LOC_INJECT_XTRA_DATA (0xA7) in 1024-byte parts, or the
 *                     deprecated INJECT_PREDICTED_ORBITS_DATA (0x35) with "old"
 *
 * TLV ids from Qualcomm's open location_service_v02.c (IDL 2.74, msm8937 CAF).
 * Request messages are acked with a plain QMI response; the real answer is an
 * indication with the same message id, delivered to ind_cb.
 *
 * Run as root with the force-ipcr shim (modem QMI lives on ipc_router):
 *   LD_PRELOAD=/vendor/lib64/libqmi_force_ipcr.so \
 *   LD_LIBRARY_PATH=/vendor/lib64 ./xtra-probe validity
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>
#include <ctype.h>

#include "qcci_compat.h"

#define TIMEOUT_MS 8000
#define IND_WAIT_MS 10000
#define PART_LEN 1024

extern int qmi_client_send_raw_msg_sync(
	qmi_client_type h, unsigned int msg_id,
	void *req, unsigned int req_len,
	void *resp, unsigned int resp_len,
	unsigned int *resp_recv_len, unsigned int timeout_msecs);

/* exported by /vendor/lib64/libloc_api_v02.so */
extern struct qmi_idl_service_object loc_qmi_idl_service_object_v02;

#define LOC_GET_PO_SOURCE    0x0036
#define LOC_GET_PO_VALIDITY  0x0037
#define LOC_INJECT_PO_DATA   0x0035
#define LOC_INJECT_XTRA_DATA 0x00A7
#define LOC_QUERY_XTRA_INFO  0x00B0
#define LOC_INJECT_UTC_TIME  0x0038

static const char *loc_status(uint32_t s)
{
	static const char *n[] = { "SUCCESS", "GENERAL_FAILURE", "UNSUPPORTED",
		"INVALID_PARAMETER", "ENGINE_BUSY", "PHONE_OFFLINE", "TIMEOUT",
		"CONFIG_NOT_SUPPORTED", "INSUFFICIENT_MEMORY",
		"MAX_GEOFENCE_PROGRAMMED", "XTRA_VERSION_CHECK_FAILURE",
		"GNSS_DISABLED" };
	return s < sizeof(n) / sizeof(n[0]) ? n[s] : "?";
}

/* ------------------------------------------------------------ indications -- */
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static unsigned int g_want;          /* msg id we are waiting for */
static int g_have;
static uint8_t g_ind[8192];
static unsigned int g_ind_len;

static void ind_cb(qmi_client_type h, unsigned int msg_id,
                   void *buf, unsigned int len, void *cbd)
{
	(void)h; (void)cbd;
	pthread_mutex_lock(&g_mu);
	if (msg_id == g_want && !g_have) {
		g_ind_len = len < sizeof(g_ind) ? len : sizeof(g_ind);
		memcpy(g_ind, buf, g_ind_len);
		g_have = 1;
		pthread_cond_signal(&g_cv);
	} else {
		printf("  <- other ind msg=0x%04x len=%u\n", msg_id, len);
	}
	pthread_mutex_unlock(&g_mu);
}

static void arm(unsigned int msg)
{
	pthread_mutex_lock(&g_mu);
	g_want = msg;
	g_have = 0;
	pthread_mutex_unlock(&g_mu);
}

static int wait_ind(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	ts.tv_sec += IND_WAIT_MS / 1000;
	pthread_mutex_lock(&g_mu);
	while (!g_have)
		if (pthread_cond_timedwait(&g_cv, &g_mu, &ts) == ETIMEDOUT)
			break;
	int ok = g_have;
	pthread_mutex_unlock(&g_mu);
	return ok;
}

/* -------------------------------------------------------------- TLV walk -- */
struct tlv { uint8_t t; uint16_t l; const uint8_t *v; };

static int tlv_next(const uint8_t **p, const uint8_t *end, struct tlv *out)
{
	if (*p + 3 > end) return 0;
	out->t = (*p)[0];
	out->l = (uint16_t)((*p)[1] | ((*p)[2] << 8));
	out->v = *p + 3;
	if (out->v + out->l > end) return 0;
	*p = out->v + out->l;
	return 1;
}

static uint64_t get_le(const uint8_t *v, int n)
{
	uint64_t x = 0;
	for (int i = n - 1; i >= 0; i--) x = (x << 8) | v[i];
	return x;
}

static void hexdump_tlv(const struct tlv *t)
{
	printf("  TLV 0x%02x len=%u:", t->t, t->l);
	for (int i = 0; i < t->l && i < 48; i++) printf(" %02x", t->v[i]);
	if (t->l > 48) printf(" ...");
	printf("\n");
}

/* print runs of printable characters (URLs inside server-list aggregates) */
static void print_strings(const struct tlv *t)
{
	int start = -1;
	for (int i = 0; i <= t->l; i++) {
		int pr = i < t->l && isprint(t->v[i]);
		if (pr && start < 0) start = i;
		if (!pr && start >= 0) {
			if (i - start >= 6)
				printf("    \"%.*s\"\n", i - start, t->v + start);
			start = -1;
		}
	}
}

/* QMI response: TLV 0x02 {result u16, error u16} */
static int send_req(qmi_client_type c, const char *tag, unsigned int msg,
                    const uint8_t *req, unsigned int req_len)
{
	uint8_t resp[512];
	unsigned int got = 0;
	int rc = qmi_client_send_raw_msg_sync(c, msg, (void *)req, req_len,
	                                      resp, sizeof(resp), &got, TIMEOUT_MS);
	if (rc) {
		printf("[%s] send rc=%d\n", tag, rc);
		return -1;
	}
	const uint8_t *p = resp, *end = resp + got;
	struct tlv t;
	while (tlv_next(&p, end, &t))
		if (t.t == 0x02 && t.l >= 4) {
			unsigned res = (unsigned)get_le(t.v, 2), err = (unsigned)get_le(t.v + 2, 2);
			if (res) {
				printf("[%s] QMI resp FAILED result=%u error=%u\n", tag, res, err);
				return -1;
			}
			return 0;
		}
	printf("[%s] no result TLV in response\n", tag);
	return -1;
}

/* send, then wait for the same-id indication; returns its status TLV or -1 */
static long req_ind(qmi_client_type c, const char *tag, unsigned int msg,
                    const uint8_t *req, unsigned int req_len)
{
	arm(msg);
	if (send_req(c, tag, msg, req, req_len)) return -1;
	if (!wait_ind()) {
		printf("[%s] no indication within %d ms\n", tag, IND_WAIT_MS);
		return -1;
	}
	const uint8_t *p = g_ind, *end = g_ind + g_ind_len;
	struct tlv t;
	long status = -1;
	while (tlv_next(&p, end, &t))
		if (t.t == 0x01 && t.l == 4) status = (long)get_le(t.v, 4);
	return status;
}

/* ---------------------------------------------------------------- commands -- */
static int cmd_source(qmi_client_type c)
{
	long s = req_ind(c, "source", LOC_GET_PO_SOURCE, NULL, 0);
	printf("[source] status=%ld %s\n", s, s >= 0 ? loc_status(s) : "");
	const uint8_t *p = g_ind, *end = g_ind + g_ind_len;
	struct tlv t;
	while (tlv_next(&p, end, &t)) {
		if (t.t == 0x10 && t.l >= 8)
			printf("  allowed: maxFileSize=%llu maxPartSize=%llu\n",
			       (unsigned long long)get_le(t.v, 4),
			       (unsigned long long)get_le(t.v + 4, 4));
		else if (t.t == 0x11) {
			printf("  servers:\n");
			print_strings(&t);
		} else if (t.t != 0x01)
			hexdump_tlv(&t);
	}
	return s == 0 ? 0 : 1;
}

static void print_utc(const char *label, uint64_t v)
{
	/* dut1 (C1-214411) reports UTC seconds here despite the IDL's "UTC" ms
	 * wording; print it as seconds */
	time_t t = (time_t)v;
	char a[64];
	strftime(a, sizeof(a), "%F %T", gmtime(&t));
	printf("  %s=%llu  (%s UTC)\n", label, (unsigned long long)v, a);
}

static int cmd_validity(qmi_client_type c)
{
	long s = req_ind(c, "validity", LOC_GET_PO_VALIDITY, NULL, 0);
	printf("[validity] status=%ld %s\n", s, s >= 0 ? loc_status(s) : "");
	const uint8_t *p = g_ind, *end = g_ind + g_ind_len;
	struct tlv t;
	int seen = 0;
	while (tlv_next(&p, end, &t)) {
		if (t.t == 0x10 && t.l >= 10) {
			print_utc("startTime", get_le(t.v, 8));
			printf("  durationHours=%llu\n", (unsigned long long)get_le(t.v + 8, 2));
			seen = 1;
		} else if (t.t != 0x01)
			hexdump_tlv(&t);
	}
	if (!seen && s == 0) printf("  (no validity TLV: modem holds no XTRA data)\n");
	return s == 0 ? 0 : 1;
}

static int cmd_info(qmi_client_type c)
{
	uint8_t req[7] = { 0x01, 0x04, 0x00, 0, 0, 0, 0 };   /* xtraConfig = 0 */
	long s = req_ind(c, "info", LOC_QUERY_XTRA_INFO, req, sizeof(req));
	printf("[info] status=%ld %s\n", s, s >= 0 ? loc_status(s) : "");
	const uint8_t *p = g_ind, *end = g_ind + g_ind_len;
	struct tlv t;
	while (tlv_next(&p, end, &t)) {
		if (t.t == 0x02 && t.l >= 14) {
			printf("  reportMask=0x%llx absAgeHrs=%llu\n",
			       (unsigned long long)get_le(t.v, 4),
			       (unsigned long long)get_le(t.v + 4, 2));
			print_utc("relAge(last download)", get_le(t.v + 6, 8));
			print_strings(&t);
			hexdump_tlv(&t);
		} else if (t.t != 0x01)
			hexdump_tlv(&t);
	}
	return s == 0 ? 0 : 1;
}

static int cmd_time(qmi_client_type c)
{
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	uint64_t ms = (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
	uint32_t unc = 1000;
	uint8_t req[18], *w = req;
	*w++ = 0x01; *w++ = 8; *w++ = 0;
	for (int i = 0; i < 8; i++) *w++ = (uint8_t)(ms >> (8 * i));
	*w++ = 0x02; *w++ = 4; *w++ = 0;
	for (int i = 0; i < 4; i++) *w++ = (uint8_t)(unc >> (8 * i));
	long s = req_ind(c, "time", LOC_INJECT_UTC_TIME, req, sizeof(req));
	printf("[time] utc_ms=%llu unc=%u -> status=%ld %s\n", (unsigned long long)ms,
	       unc, s, s >= 0 ? loc_status(s) : "");
	return s == 0 ? 0 : 1;
}

static int cmd_inject(qmi_client_type c, const char *path, int old)
{
	FILE *f = fopen(path, "rb");
	if (!f) { perror(path); return 1; }
	static uint8_t data[512 * 1024];
	size_t n = fread(data, 1, sizeof(data), f);
	fclose(f);
	if (!n) { printf("empty file\n"); return 1; }
	unsigned int msg = old ? LOC_INJECT_PO_DATA : LOC_INJECT_XTRA_DATA;
	uint16_t parts = (uint16_t)((n + PART_LEN - 1) / PART_LEN);
	printf("[inject] %s: %zu bytes, %u parts, msg 0x%04x\n", path, n, parts, msg);

	int fails = 0;
	for (uint16_t part = 1; part <= parts; part++) {
		size_t off = (size_t)(part - 1) * PART_LEN;
		uint16_t len = (uint16_t)(n - off < PART_LEN ? n - off : PART_LEN);
		uint8_t req[32 + PART_LEN], *w = req;
		/* 0x01 totalSize u32 */
		*w++ = 0x01; *w++ = 4; *w++ = 0;
		for (int i = 0; i < 4; i++) *w++ = (uint8_t)(n >> (8 * i));
		/* 0x02 totalParts u16 */
		*w++ = 0x02; *w++ = 2; *w++ = 0; *w++ = parts & 0xff; *w++ = parts >> 8;
		/* 0x03 partNum u16 */
		*w++ = 0x03; *w++ = 2; *w++ = 0; *w++ = part & 0xff; *w++ = part >> 8;
		/* 0x04 partData: u16 count + bytes */
		uint16_t tl = (uint16_t)(len + 2);
		*w++ = 0x04; *w++ = tl & 0xff; *w++ = tl >> 8;
		*w++ = len & 0xff; *w++ = len >> 8;
		memcpy(w, data + off, len); w += len;
		/* 0x10 formatType u32 = 0 (QCOM XTRA) */
		*w++ = 0x10; *w++ = 4; *w++ = 0; *w++ = 0; *w++ = 0; *w++ = 0; *w++ = 0;

		long s = req_ind(c, "inject", msg, req, (unsigned)(w - req));
		long ipart = -1;
		uint64_t cmask = 0; int has_cmask = 0;
		const uint8_t *p = g_ind, *end = g_ind + g_ind_len;
		struct tlv t;
		while (s >= 0 && tlv_next(&p, end, &t)) {
			if (t.t == 0x10 && t.l == 2) ipart = (long)get_le(t.v, 2);
			if (t.t == 0x11 && t.l == 8) { cmask = get_le(t.v, 8); has_cmask = 1; }
		}
		if (s != 0 || part == parts || part == 1) {
			printf("  part %u/%u len=%u -> status=%ld %s ind.part=%ld",
			       part, parts, len, s, s >= 0 ? loc_status(s) : "", ipart);
			if (has_cmask) printf(" constellations=0x%llx", (unsigned long long)cmask);
			printf("\n");
		}
		if (s != 0) fails++;
		if (s < 0) break;
	}
	printf("[inject] done, %d failed part(s)\n", fails);
	return fails ? 1 : 0;
}

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	if (argc < 2) {
		fprintf(stderr, "usage: %s source|validity|info|time|inject FILE [old]\n", argv[0]);
		return 2;
	}
	char osbuf[512];
	memset(osbuf, 0, sizeof(osbuf));
	qmi_client_type c = NULL;
	int rc = qmi_client_init_instance(&loc_qmi_idl_service_object_v02,
	                                  QMI_CLIENT_INSTANCE_ANY, ind_cb, NULL,
	                                  (qmi_client_os_params *)osbuf,
	                                  TIMEOUT_MS, &c);
	if (rc || !c) {
		fprintf(stderr, "ERROR: LOC connect rc=%d (force-ipcr preload missing?)\n", rc);
		return 1;
	}
	printf("[loc] connected\n");
	int ret;
	if (!strcmp(argv[1], "source")) ret = cmd_source(c);
	else if (!strcmp(argv[1], "validity")) ret = cmd_validity(c);
	else if (!strcmp(argv[1], "info")) ret = cmd_info(c);
	else if (!strcmp(argv[1], "time")) ret = cmd_time(c);
	else if (!strcmp(argv[1], "inject") && argc >= 3)
		ret = cmd_inject(c, argv[2], argc >= 4 && !strcmp(argv[3], "old"));
	else { fprintf(stderr, "bad command\n"); ret = 2; }
	qmi_client_release(c);
	return ret;
}
