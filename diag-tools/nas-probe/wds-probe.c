/* dsd-probe — black-box QMI DSD (data system determination, svc 0x2A)
 * reader/writer for the WFC lane (PLAN-wifi-calling.md).
 *
 * Context: the legacy modem-centric VoWiFi path needs the AP to tell the
 * modem that WLAN is available (stock: netmgrd's OnNetConfigChange /
 * nightly: cnd's CneQmiDsd::sendWifiAvailableStatus — neither runs in our
 * build today). The modem's ds_wlan_proxy_dsd_if.c consumes it and gates the
 * ePDG (ds_iwlan_s2b) bring-up on it. This probe hand-sends that report so
 * we can A/B the modem's reaction before investing in CnE packaging.
 *
 * Message layout ground-truthed from libqmiservices.so via parse_idl_any.py
 * (service object dsd_qmi_idl_service_object_v01 @ 0x25508):
 *   0x20 WLAN_AVAILABLE_REQ: man 0x01 u8[6] ap_mac; opt 0x10 u32 ipv4;
 *        opt 0x11 {u8[16] ipv6, u8 prefix}; opt 0x12/0x13 u32 dns_v4_1/2;
 *        opt 0x14 u32 (epdg/gw v4); opt 0x15/0x16 u8[16] dns_v6_1/2
 *   0x21 WLAN_NOT_AVAILABLE_REQ: opt 0x10 u32
 *   0x24 GET_SYSTEM_STATUS_REQ: empty req (resp = available-systems dump)
 *   0x25 SYSTEM_STATUS_CHANGE_REQ (register): 4 opt u8 flags
 *   0x27 BIND_SUBSCRIPTION_REQ: man 0x01 u32 (1=primary — 0 returns
 *        INVALID_ARG; the enum is 1-based)
 *   0x38 INDICATION_REGISTER_REQ: 12 opt u8 (0x10..0x1b)
 *   0x53 SET_WIFI_SERVICE_CAP_REQ: man 0x01 u64 capability bitmask
 *
 * ⭐ Stock-CnE call order (disassembled from the stock A8 vendor
 * libcne.so, CneQmiDsd): bindAndRegisterForDsdInd() sends 0x27(sub) then
 * 0x38(inds 0x11/0x12/0x14/0x19=1); sendInitialModemNotifications() then
 * sends 0x20 WLAN_AVAILABLE followed by 0x53 SET_WIFI_SERVICE_CAP with the
 * literal u64 value 1. A bare 0x20 (what we sent before) is only one of
 * four steps — `arm` below replays the whole sequence.
 *
 * ⭐⭐ 0x20 WLAN_AVAILABLE TLV map, ground-truthed 2026-08-05 by sending
 * distinctive values and reading the modem's own F3 echo (ds_qmi_dsd.c
 * 1181-1458).  `wlanup` below sends only 0x01+0x10, which makes the modem
 * record connection_status / assoc_type / network_mode as 255 = INVALID
 * (ds_wlan_meas_conn_status.c complains).  Send the full set instead:
 *   0x01 u8[6] mac (man)   0x10 u32 ipv4 (NETWORK byte order)
 *   0x11 ipv6+prefix       0x12 u32 wqe_status  <-- NOT dns; putting a DNS
 *                             address here is what caused the old
 *                             "DNS TLVs are rejected / INVALID_ARG 48"
 *   0x13/0x14 u32 dns ipv4 1/2      0x15/0x16 u8[16] dns ipv6 1/2
 *   0x17/0x18 u32 epdg ipv4 1/2     0x19/0x1a u8[16] epdg ipv6 1/2
 *   0x1b ssid (1-byte len prefix)   0x1c u16 channel   0x1d u16 chan bw
 *   0x1e u64 wqe_profile_type       0x1f u32 assoc_type
 *   0x20 u32 network_enum           0x21 u32 connection_status
 * Full report with no rebuild (note `raw` parses bytes as HEX):
 *   dsd-probe raw 0x20 0x01:6:0x78:0x24:0xaf:0x7b:0x47:0xea 0x10:4:10:0:2:106 \
 *     0x12:4:1:0:0:0 0x1b:8:7:121:101:108:112:112:117:98 0x1c:2:11:0 \
 *     0x1d:2:20:0 0x1e:8:1:0:0:0:0:0:0:0 0x1f:4:1:0:0:0 0x20:4:2:0:0:0 \
 *     0x21:4:3:0:0:0
 * Accepted (result=0) and parsed cleanly — but ANDSF still ignores it while
 * req_wqe_prof_mask is 0 (see PLAN-wifi-calling.md part 12).
 *
 *   dsd-probe                       # GET_SYSTEM_STATUS, dump TLVs
 *   dsd-probe get 0x28              # arbitrary empty-req GET, dump TLVs
 *   dsd-probe wlanup <mac> <ipv4> [dns1] [dns2]   # ⚠️ minimal/invalid, see above
 *   dsd-probe wlandown              # WLAN_NOT_AVAILABLE (no TLVs)
 *   dsd-probe svccap [u64]          # 0x53 SET_WIFI_SERVICE_CAP (default 1)
 *   dsd-probe arm <mac> <ipv4> [hold_s]
 *                                   # full stock sequence, then hold the
 *                                   # client open printing indications
 *   dsd-probe raw <msgid> [T:len:val ...]
 *                                   # generic sender; val is a number
 *                                   # (little-endian, len bytes) or hex
 *                                   # bytes "aa:bb:cc"
 *
 * Run (as root, force-ipcr preload mandatory):
 *   LD_PRELOAD=/vendor/lib64/libqmi_force_ipcr.so \
 *   LD_LIBRARY_PATH=/vendor/lib64 ./dsd-probe
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <arpa/inet.h>

#include "qcci_compat.h"

#define TIMEOUT_MS 8000

extern int qmi_client_send_raw_msg_sync(
	qmi_client_type h, unsigned int msg_id,
	void *req, unsigned int req_len,
	void *resp, unsigned int resp_len,
	unsigned int *resp_recv_len, unsigned int timeout_msecs);

extern qmi_idl_service_object_type wds_get_service_object_internal_v01(int, int, int);

#define DSD_WLAN_AVAILABLE_REQ      0x0020
#define DSD_WLAN_NOT_AVAILABLE_REQ  0x0021
#define DSD_GET_SYSTEM_STATUS_REQ   0x0024
#define DSD_BIND_SUBSCRIPTION_REQ   0x0027
#define DSD_IND_REGISTER_REQ        0x0038
#define DSD_SET_WIFI_SVC_CAP_REQ    0x0053

static volatile uint32_t g_wqe_pending, g_wqe_known;
static void ind_cb(qmi_client_type h, unsigned int msg_id,
                   void *buf, unsigned int len, void *cbd)
{
	(void)h; (void)cbd;
	const uint8_t *b = buf;
	/* 0x45 WQE profile prepare: TLV 01 u32 profile id. Reply later from
	 * the main loop (no sync sends from the QCCI callback thread). */
	if (msg_id == 0x45 && len >= 7 && b[0] == 0x01 && b[3] < 32) {
		g_wqe_pending |= 1u << b[3];
		g_wqe_known |= 1u << b[3];
	}
	printf("  <- IND msg=0x%04x len=%u:", msg_id, len);
	for (unsigned int i = 0; i < len && i < 96; i++) printf(" %02x", b[i]);
	if (len > 96) printf(" ...");
	printf("\n");
	fflush(stdout);
}

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

static uint32_t get_le(const uint8_t *v, int n)
{
	uint32_t x = 0;
	for (int i = n - 1; i >= 0; i--) x = (x << 8) | v[i];
	return x;
}

static void dump_all(const uint8_t *buf, unsigned int len, const char *tag)
{
	const uint8_t *p = buf, *end = buf + len;
	struct tlv t;
	printf("== %s (resp %u bytes) ==\n", tag, len);
	while (tlv_next(&p, end, &t)) {
		if (t.t == 0x02 && t.l >= 4) {
			printf("  RESULT: result=%u error=%u\n",
			       (unsigned)get_le(t.v, 2), (unsigned)get_le(t.v + 2, 2));
			continue;
		}
		printf("  TLV 0x%02x len=%-3u:", t.t, t.l);
		for (int i = 0; i < t.l && i < 1024; i++) printf(" %02x", t.v[i]);
		if (t.l > 1024) printf(" ...");
		if (t.l >= 1 && t.l <= 4)
			printf("   (= %u)", (unsigned)get_le(t.v, t.l));
		printf("\n");
	}
	fflush(stdout);
}

static int put_tlv(uint8_t *req, int off, uint8_t id, const void *v, uint16_t l)
{
	req[off] = id;
	req[off + 1] = (uint8_t)(l & 0xff);
	req[off + 2] = (uint8_t)(l >> 8);
	memcpy(req + off + 3, v, l);
	return off + 3 + l;
}

static qmi_client_type g_c;

/* send + dump; returns the transport rc (0 = message delivered) */
static int send_dump(unsigned int msg, void *req, unsigned int len, const char *tag)
{
	uint8_t resp[8192];
	unsigned int got = 0;
	int rc = qmi_client_send_raw_msg_sync(g_c, msg, req, len,
	                                      resp, sizeof(resp), &got, TIMEOUT_MS);
	if (rc) {
		fprintf(stderr, "%s: send rc=%d\n", tag, rc);
		return rc;
	}
	dump_all(resp, got, tag);
	return 0;
}

/* 0x27 bind_subscription — the enum is 1-based (1 = primary) */
static void do_bind(uint32_t sub)
{
	uint8_t req[16];
	int off = put_tlv(req, 0, 0x01, &sub, 4);
	printf("-- BIND_SUBSCRIPTION sub=%u\n", sub);
	send_dump(DSD_BIND_SUBSCRIPTION_REQ, req, (unsigned)off, "BIND_SUBSCRIPTION");
}

/* 0x38 indication_register — stock CnE turns on 0x11/0x12/0x14/0x19 */
static void do_ind_register(int all)
{
	uint8_t req[64];
	uint8_t one = 1;
	int off = 0;
	if (all) {
		for (uint8_t t = 0x10; t <= 0x1b; t++)
			off = put_tlv(req, off, t, &one, 1);
	} else {
		static const uint8_t stock[] = { 0x11, 0x12, 0x14, 0x19 };
		for (unsigned i = 0; i < sizeof(stock); i++)
			off = put_tlv(req, off, stock[i], &one, 1);
	}
	printf("-- INDICATION_REGISTER (%s)\n", all ? "all 0x10-0x1b" : "stock subset");
	send_dump(DSD_IND_REGISTER_REQ, req, (unsigned)off, "IND_REGISTER");
}

/* 0x53 set_wifi_service_capability — stock sends the literal u64 1 */
static void do_svccap(uint64_t cap)
{
	uint8_t req[16];
	int off = put_tlv(req, 0, 0x01, &cap, 8);
	printf("-- SET_WIFI_SERVICE_CAP cap=0x%llx\n", (unsigned long long)cap);
	send_dump(DSD_SET_WIFI_SVC_CAP_REQ, req, (unsigned)off, "SET_WIFI_SERVICE_CAP");
}

/* 0x20 wlan_available — mac mandatory, ipv4 optional (network byte order;
 * the DNS TLVs 0x12/0x13 are rejected by this modem, so they are opt-in) */
static int do_wlanup(const char *macs, const char *ips, char **dns, int ndns)
{
	uint8_t mac[6];
	if (sscanf(macs, "%hhx:%hhx:%hhx:%hhx:%hhx:%hhx",
	           &mac[0], &mac[1], &mac[2], &mac[3], &mac[4], &mac[5]) != 6) {
		fprintf(stderr, "bad mac '%s'\n", macs);
		return 1;
	}
	struct in_addr ip4;
	if (inet_pton(AF_INET, ips, &ip4) != 1) {
		fprintf(stderr, "bad ipv4 '%s'\n", ips);
		return 1;
	}
	uint8_t req[128];
	int off = put_tlv(req, 0, 0x01, mac, 6);
	if (ip4.s_addr != 0)
		off = put_tlv(req, off, 0x10, &ip4.s_addr, 4);
	int di = 0x12;
	for (int a = 0; a < ndns && di <= 0x13; a++, di++) {
		struct in_addr d;
		if (inet_pton(AF_INET, dns[a], &d) != 1) {
			fprintf(stderr, "bad dns '%s'\n", dns[a]);
			return 1;
		}
		off = put_tlv(req, off, (uint8_t)di, &d.s_addr, 4);
	}
	printf("-- WLAN_AVAILABLE mac=%s ip=%s (+%d dns)\n", macs, ips, ndns);
	return send_dump(DSD_WLAN_AVAILABLE_REQ, req, (unsigned)off, "WLAN_AVAILABLE");
}

/* "T:len:value" — value is a decimal/hex number (little-endian, len bytes)
 * or a colon-separated byte string when it contains ':' */
static int parse_tlv_arg(const char *s, uint8_t *req, int off)
{
	unsigned t, l;
	const char *v = strchr(s, ':');
	if (!v) return -1;
	v = strchr(v + 1, ':');
	if (!v) return -1;
	v++;
	if (sscanf(s, "%i:%u:", &t, &l) != 2) return -1;
	uint8_t buf[256];
	if (l > sizeof(buf)) return -1;
	memset(buf, 0, sizeof(buf));
	if (strchr(v, ':')) {
		unsigned n = 0;
		const char *p = v;
		while (*p && n < l) {
			unsigned b;
			if (sscanf(p, "%x", &b) != 1) return -1;
			buf[n++] = (uint8_t)b;
			const char *nx = strchr(p, ':');
			if (!nx) break;
			p = nx + 1;
		}
	} else {
		unsigned long long x = strtoull(v, NULL, 0);
		for (unsigned i = 0; i < l && i < 8; i++)
			buf[i] = (uint8_t)(x >> (8 * i));
	}
	return put_tlv(req, off, (uint8_t)t, buf, (uint16_t)l);
}

int main(int argc, char **argv)
{
	qmi_idl_service_object_type so = NULL;
	int minor = -1;
	for (int m = 0; m <= 300 && !so; m++) {
		so = wds_get_service_object_internal_v01(1, m, 6);
		if (so) minor = m;
	}
	if (!so) {
		fprintf(stderr, "ERROR: no dsd service object (tool=6, major=1)\n");
		return 1;
	}
	printf("[wds] service object ok (1, %d, 6)\n", minor);

	char osbuf[512];
	memset(osbuf, 0, sizeof(osbuf));
	qmi_client_type c = NULL;
	int rc = qmi_client_init_instance(so, QMI_CLIENT_INSTANCE_ANY, ind_cb, NULL,
	                                  (qmi_client_os_params *)osbuf,
	                                  TIMEOUT_MS, &c);
	if (rc || !c) {
		fprintf(stderr, "ERROR: DSD connect rc=%d\n", rc);
		return 1;
	}
	g_c = c;
	printf("[WDS] connected\n");

	uint8_t resp[8192];
	unsigned int got = 0;
	const char *cmd = argc >= 2 ? argv[1] : "";

	if (!strcmp(cmd, "arm") && argc >= 4) {
		/* Replay the full stock-CnE bring-up sequence, then hold the
		 * client open: the modem may scope WLAN availability to the
		 * reporting client's lifetime. */
		int hold = argc >= 5 ? atoi(argv[4]) : 120;
		int all = argc >= 6 && !strcmp(argv[5], "all");
		do_bind(1);
		do_ind_register(all);
		printf("-- system status BEFORE:\n");
		send_dump(DSD_GET_SYSTEM_STATUS_REQ, NULL, 0, "SYSTEM_STATUS (before)");
		do_wlanup(argv[2], argv[3], NULL, 0);
		do_svccap(1);
		printf("-- holding client open %ds, polling system status…\n", hold);
		for (int i = 0; i < hold; i += 15) {
			sleep(15);
			send_dump(DSD_GET_SYSTEM_STATUS_REQ, NULL, 0, "SYSTEM_STATUS (poll)");
		}
	} else if (!strcmp(cmd, "wqe") && argc >= 7) {
		/* wqe <mac> <ip> <hold_s> <status> <cause>: act as CnE's WQE side.
		 * Answer every 0x45 PREPARE with 0x43 {01:prof 10:status 11:cause},
		 * and re-send for every known profile each 10 s, like stock. */
		int hold = atoi(argv[4]);
		uint32_t st = (uint32_t)strtoul(argv[5], NULL, 0);
		uint32_t cause = (uint32_t)strtoul(argv[6], NULL, 0);
		do_bind(1);
		do_ind_register(1);
		do_wlanup(argv[2], argv[3], NULL, 0);
		for (int t = 0; t < hold; t++) {
			uint32_t todo = g_wqe_pending;
			if (t % 10 == 9)
				todo |= g_wqe_known;
			g_wqe_pending &= ~todo;
			for (uint32_t p = 0; p < 32; p++) {
				if (!(todo & (1u << p)))
					continue;
				uint8_t req[32];
				int off = put_tlv(req, 0, 0x01, &p, 4);
				off = put_tlv(req, off, 0x10, &st, 4);
				off = put_tlv(req, off, 0x11, &cause, 4);
				char tag[48];
				snprintf(tag, sizeof(tag), "t=%d 0x43 prof %u st %u cause %u", t, p, st, cause);
				send_dump(0x43, req, (unsigned)off, tag);
			}
			sleep(1);
		}
	} else if (!strcmp(cmd, "wqesweep") && argc >= 3) {
		/* wqesweep <profmask>: register, then for each (status, cause) in
		 * 0..3 x 0..3 send 0x43 for every profile in the mask and wait 3 s
		 * so the 0x40 (met mask) indication that follows is printed. */
		uint32_t pm = (uint32_t)strtoul(argv[2], NULL, 0);
		do_bind(1);
		do_ind_register(1);
		for (uint32_t st = 0; st < 4; st++)
			for (uint32_t cause = 0; cause < 4; cause++) {
				printf("### status %u cause %u\n", st, cause);
				for (uint32_t p = 0; p < 32; p++) {
					if (!(pm & (1u << p)))
						continue;
					uint8_t req[32];
					int off = put_tlv(req, 0, 0x01, &p, 4);
					off = put_tlv(req, off, 0x10, &st, 4);
					off = put_tlv(req, off, 0x11, &cause, 4);
					send_dump(0x43, req, (unsigned)off, "0x43");
				}
				fflush(stdout);
				sleep(3);
			}
	} else if (!strcmp(cmd, "svccap")) {
		uint64_t cap = argc >= 3 ? strtoull(argv[2], NULL, 0) : 1;
		do_svccap(cap);
		sleep(3);
	} else if (!strcmp(cmd, "raw") && argc >= 3) {
		unsigned int msg = (unsigned int)strtoul(argv[2], NULL, 0);
		uint8_t req[512];
		int off = 0;
		for (int a = 3; a < argc; a++) {
			off = parse_tlv_arg(argv[a], req, off);
			if (off < 0) {
				fprintf(stderr, "bad tlv spec '%s' (want T:len:val)\n", argv[a]);
				return 1;
			}
		}
		char tag[64];
		snprintf(tag, sizeof(tag), "RAW msg 0x%04x", msg);
		rc = send_dump(msg, off ? req : NULL, (unsigned)off, tag);
		sleep(2);
	} else if ((!strcmp(cmd, "wlanup") || !strcmp(cmd, "session")) && argc >= 4) {
		int session = !strcmp(cmd, "session");
		if (session) {
			do_bind(1);
			do_ind_register(0);
		}
		rc = do_wlanup(argv[2], argv[3], argc > 4 ? &argv[4] : NULL,
		               argc > 4 ? argc - 4 : 0);
		if (session) {
			printf("holding client open 90s for indications…\n");
			for (int i = 0; i < 9; i++) {
				sleep(10);
				send_dump(DSD_GET_SYSTEM_STATUS_REQ, NULL, 0,
				          "SYSTEM_STATUS (poll)");
			}
		}
	} else if (!strcmp(cmd, "wlandown")) {
		printf("WLAN_NOT_AVAILABLE (0x21)\n");
		rc = send_dump(DSD_WLAN_NOT_AVAILABLE_REQ, NULL, 0, "WLAN_NOT_AVAILABLE");
	} else {
		unsigned int msg = DSD_GET_SYSTEM_STATUS_REQ;
		if (argc >= 3 && !strcmp(cmd, "get"))
			msg = (unsigned int)strtoul(argv[2], NULL, 0);
		rc = qmi_client_send_raw_msg_sync(c, msg, NULL, 0,
		                                  resp, sizeof(resp), &got, TIMEOUT_MS);
		if (rc) fprintf(stderr, "send rc=%d\n", rc);
		else {
			char tag[64];
			snprintf(tag, sizeof(tag), "GET msg 0x%04x", msg);
			dump_all(resp, got, tag);
		}
	}

	/* linger briefly for unsolicited system-status indications */
	if (!strcmp(cmd, "wlanup") || !strcmp(cmd, "wlandown"))
		sleep(3);

	qmi_client_release(c);
	return rc ? 1 : 0;
}
