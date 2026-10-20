/* nas-probe — black-box QMI NAS/DMS state reader for the pepito LTE-attach
 * investigation (see sim-uicc-toggle-trap.md, "ATTACH DEBUG SESSION").
 *
 * Bypasses the ENTIRE AP telephony stack (framework -> radiocompat bridge ->
 * qcrild -> force-ipcr) and asks the modem directly, over the same ipc_router
 * transport, what state its NAS actually holds:
 *   - DMS GET_OPERATING_MODE            (0x2D)  online vs LPM
 *   - NAS GET_SERVING_SYSTEM            (0x24)  reg_state + CS/PS ATTACH STATE
 *   - NAS GET_SYSTEM_SELECTION_PREFERENCE (0x34) mode_pref + SRV_DOMAIN_PREF
 *   - NAS GET_SYS_INFO                  (0x4D)  per-RAT srv_status/domain
 *
 * The decisive experiment: if `status` shows PS detached / srv_domain_pref
 * wrong, `attach` issues NAS SET_SYSTEM_SELECTION_PREFERENCE with
 * srv_domain_pref=PS_ATTACH — exactly what a healthy qcril does on allowData.
 * If the modem then registers, the network/modem/SIM are fine and our AP
 * stack simply never commands the attach (Kyle's "bridge in the way" theory).
 *
 * TLV ids ground-truthed from the on-device libqmiservices.so IDL tables
 * (parse_idl_any.py): GET 0x34 resp srv_domain_pref = TLV 0x18 (u32);
 * SET 0x33 req srv_domain_pref = TLV 0x1B (alias 0x18), change_duration =
 * TLV 0x17 (enum8, 0=power-cycle), mode_pref = TLV 0x11 (u16).
 *
 * Run (as root, force-ipcr preload mandatory — modem QMI lives on ipc_router):
 *   LD_PRELOAD=/vendor/lib64/libqmi_force_ipcr.so \
 *   LD_LIBRARY_PATH=/vendor/lib64 ./nas-probe status
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>

#include "qcci_compat.h"

#define TIMEOUT_MS 8000

/* raw-TLV entry point (verified exported by /vendor/lib64/libqmi_cci.so) */
extern int qmi_client_send_raw_msg_sync(
	qmi_client_type h, unsigned int msg_id,
	void *req, unsigned int req_len,
	void *resp, unsigned int resp_len,
	unsigned int *resp_recv_len, unsigned int timeout_msecs);

/* service objects: version args read from the blob's own descriptor structs */
extern qmi_idl_service_object_type nas_get_service_object_internal_v01(int, int, int);
extern qmi_idl_service_object_type dms_get_service_object_internal_v01(int, int, int);
extern qmi_idl_service_object_type wds_get_service_object_internal_v01(int, int, int);
extern qmi_idl_service_object_type uim_get_service_object_internal_v01(int, int, int);
#define UIM_SO() uim_get_service_object_internal_v01(1, 97, 6)
#define NAS_SO() nas_get_service_object_internal_v01(1, 321, 6)
#define DMS_SO() dms_get_service_object_internal_v01(1, 83, 6)
#define WDS_SO() wds_get_service_object_internal_v01(1, 192, 6)

/* NAS message ids */
#define NAS_GET_SERVING_SYSTEM   0x0024
#define NAS_SET_SYS_SEL_PREF     0x0033
#define NAS_GET_SYS_SEL_PREF     0x0034
#define NAS_GET_SYS_INFO         0x004D
/* DMS */
#define DMS_GET_OPERATING_MODE   0x002D
#define DMS_SET_OPERATING_MODE   0x002E
#define DMS_GET_BAND_CAPABILITY  0x0045
/* WDS */
#define WDS_GET_PROFILE_LIST         0x002A
#define WDS_GET_PROFILE_SETTINGS     0x002B
#define WDS_GET_LTE_ATTACH_PARAMS    0x0085
#define WDS_GET_LTE_MAX_ATTACH_PDN   0x0092
#define WDS_GET_LTE_ATTACH_PDN_LIST  0x0094
/* UIM */
#define UIM_READ_TRANSPARENT         0x0020
#define UIM_GET_CARD_STATUS          0x002F
#define UIM_SEND_APDU                0x003B
#define UIM_LOGICAL_CHANNEL          0x003F
#define UIM_OPEN_LOGICAL_CHANNEL     0x0042

/* ------------------------------------------------------------------ misc -- */
static void ind_cb(qmi_client_type h, unsigned int msg_id,
                   void *buf, unsigned int len, void *cbd)
{
	(void)h; (void)buf; (void)cbd;
	printf("  <- unsolicited ind msg=0x%04x len=%u\n", msg_id, len);
}

static qmi_client_type connect_svc(qmi_idl_service_object_type so, const char *name)
{
	char osbuf[512];
	memset(osbuf, 0, sizeof(osbuf));
	qmi_client_type c = NULL;
	int rc = qmi_client_init_instance(so, QMI_CLIENT_INSTANCE_ANY, ind_cb, NULL,
	                                  (qmi_client_os_params *)osbuf,
	                                  TIMEOUT_MS, &c);
	if (rc || !c) {
		fprintf(stderr, "ERROR: %s connect rc=%d\n", name, rc);
		return NULL;
	}
	printf("[%s] connected\n", name);
	return c;
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

static uint32_t get_le(const uint8_t *v, int n)
{
	uint32_t x = 0;
	for (int i = n - 1; i >= 0; i--) x = (x << 8) | v[i];
	return x;
}

static int g_wds_raw = 0;   /* 'wdsraw': hexdump profile TLVs we don't decode */

static void hexdump_tlv(const struct tlv *t)
{
	printf("  TLV 0x%02x len=%u:", t->t, t->l);
	for (int i = 0; i < t->l && i < 48; i++) printf(" %02x", t->v[i]);
	if (t->l > 48) printf(" ...");
	printf("\n");
}

/* result TLV 0x02: {result u16, error u16}; returns error, -1 if missing */
static int check_result(const uint8_t *buf, unsigned int len, const char *tag)
{
	const uint8_t *p = buf, *end = buf + len;
	struct tlv t;
	while (tlv_next(&p, end, &t))
		if (t.t == 0x02 && t.l >= 4) {
			uint16_t res = (uint16_t)get_le(t.v, 2);
			uint16_t err = (uint16_t)get_le(t.v + 2, 2);
			if (res) printf("[%s] FAILED result=%u error=%u\n", tag, res, err);
			return err;
		}
	printf("[%s] no result TLV?\n", tag);
	return -1;
}

static int send_raw(qmi_client_type c, const char *tag, unsigned int msg,
                    const uint8_t *req, unsigned int req_len,
                    uint8_t *resp, unsigned int resp_sz, unsigned int *got)
{
	*got = 0;
	int rc = qmi_client_send_raw_msg_sync(c, msg, (void *)req, req_len,
	                                      resp, resp_sz, got, TIMEOUT_MS);
	if (rc) {
		fprintf(stderr, "[%s] send rc=%d\n", tag, rc);
		return rc;
	}
	return check_result(resp, *got, tag) > 0 ? -1 : 0;
}

/* ------------------------------------------------------------- decoders --- */
static const char *reg_state_name(uint8_t v)
{
	switch (v) {
	case 0: return "NOT_REGISTERED (not searching)";
	case 1: return "REGISTERED";
	case 2: return "NOT_REGISTERED, SEARCHING";
	case 3: return "REGISTRATION DENIED";
	default: return "UNKNOWN";
	}
}
static const char *attach_name(uint8_t v)
{
	return v == 1 ? "ATTACHED" : v == 2 ? "DETACHED" : "unknown";
}
static const char *radio_if_name(uint8_t v)
{
	switch (v) {
	case 0x01: return "cdma1x"; case 0x02: return "evdo";
	case 0x04: return "gsm";    case 0x05: return "umts";
	case 0x08: return "lte";    default:   return "?";
	}
}
static const char *srv_domain_name(uint32_t v)
{
	switch (v) {
	case 0: return "CS_ONLY";  case 1: return "PS_ONLY";
	case 2: return "CS_PS";    case 3: return "PS_ATTACH";
	case 4: return "PS_DETACH"; case 5: return "ON_DEMAND_PS_ATTACH";
	default: return "?";
	}
}
static const char *srv_status_name(uint8_t v)
{
	switch (v) {
	case 0: return "NO_SERVICE"; case 1: return "LIMITED";
	case 2: return "FULL SERVICE"; case 3: return "LIMITED_REGIONAL";
	case 4: return "POWER_SAVE"; default: return "?";
	}
}

static void mode_pref_bits(uint16_t m)
{
	printf("(");
	if (m & 0x01) printf(" 1X");
	if (m & 0x02) printf(" EVDO");
	if (m & 0x04) printf(" GSM");
	if (m & 0x08) printf(" UMTS");
	if (m & 0x10) printf(" LTE");
	if (m & 0x20) printf(" TDSCDMA");
	printf(" )");
}

static void do_operating_mode(qmi_client_type dms)
{
	uint8_t resp[512]; unsigned int got;
	puts("\n== DMS GET_OPERATING_MODE (0x2D) ==");
	if (send_raw(dms, "opmode", DMS_GET_OPERATING_MODE, NULL, 0,
	             resp, sizeof(resp), &got))
		return;
	const uint8_t *p = resp, *end = resp + got; struct tlv t;
	static const char *om[] = { "ONLINE", "LOW_POWER", "FACTORY_TEST",
		"OFFLINE", "RESETTING", "SHUTTING_DOWN", "PERSISTENT_LOW_POWER" };
	while (tlv_next(&p, end, &t)) {
		if (t.t == 0x01 && t.l >= 1)
			printf("  operating mode = %u (%s)\n", t.v[0],
			       t.v[0] < 7 ? om[t.v[0]] : "?");
	}
}

/* DMS GET_BAND_CAPABILITY (0x45): what the modem+RF actually supports, as
 * opposed to the wide-open NAS band *preference* masks.
 * TLV 0x01 u64 legacy mask (CDMA BCs + GSM + WCDMA, same bit layout as the
 * NAS band_pref — layout confirmed by decoding our own band_pref value),
 * TLV 0x10 u64 LTE mask (bit n = band n+1),
 * TLV 0x12 extended LTE band list (u8 count + u16 band numbers). */
static void do_band_capability(qmi_client_type dms)
{
	uint8_t resp[2048]; unsigned int got;
	puts("\n== DMS GET_BAND_CAPABILITY (0x45) ==");
	if (send_raw(dms, "bandcap", DMS_GET_BAND_CAPABILITY, NULL, 0,
	             resp, sizeof(resp), &got))
		return;
	static const struct { int bit; const char *name; } legacy[] = {
		{ 0, "CDMA-BC0-A" }, { 1, "CDMA-BC0-B" }, { 2, "CDMA-BC1" },
		{ 4, "CDMA-BC3-A" }, { 5, "CDMA-BC4" },   { 6, "CDMA-BC5" },
		{ 7, "GSM-DCS-1800" }, { 8, "GSM-900-ext" }, { 9, "GSM-900-pri" },
		{ 10, "CDMA-BC6" }, { 11, "CDMA-BC7" }, { 12, "CDMA-BC8" },
		{ 13, "CDMA-BC9" }, { 14, "CDMA-BC10" }, { 15, "CDMA-BC11" },
		{ 16, "GSM-450" }, { 17, "GSM-480" }, { 18, "GSM-750" },
		{ 19, "GSM-850" }, { 20, "GSM-900-railways" }, { 21, "GSM-PCS-1900" },
		{ 22, "WCDMA-2100(B1)" }, { 23, "WCDMA-PCS-1900(B2)" },
		{ 24, "WCDMA-DCS-1800(B3)" }, { 25, "WCDMA-AWS-1700(B4)" },
		{ 26, "WCDMA-850(B5)" }, { 27, "WCDMA-800(B6)" },
		{ 28, "CDMA-BC12" }, { 29, "CDMA-BC14" }, { 31, "CDMA-BC15" },
		{ 48, "WCDMA-2600(B7)" }, { 49, "WCDMA-900(B8)" },
		{ 50, "WCDMA-1700-JP(B9)" }, { 56, "CDMA-BC16" },
		{ 60, "WCDMA-1500(B11)" }, { 61, "WCDMA-850-JP(B19)" },
		{ -1, NULL }
	};
	const uint8_t *p = resp, *end = resp + got; struct tlv t;
	while (tlv_next(&p, end, &t)) {
		switch (t.t) {
		case 0x02: break;
		case 0x01: {
			uint64_t m = (uint64_t)get_le(t.v, 4) |
			             ((uint64_t)get_le(t.v + 4, 4) << 32);
			printf("  legacy band cap    = 0x%016llx\n", (unsigned long long)m);
			for (int i = 0; legacy[i].name; i++)
				if (m & (1ULL << legacy[i].bit))
					printf("    %s\n", legacy[i].name);
			break; }
		case 0x10: {
			uint64_t m = (uint64_t)get_le(t.v, 4) |
			             ((uint64_t)get_le(t.v + 4, 4) << 32);
			printf("  LTE band cap       = 0x%016llx\n    LTE bands:", (unsigned long long)m);
			for (int b = 0; b < 64; b++)
				if (m & (1ULL << b)) printf(" B%d", b + 1);
			printf("\n");
			break; }
		case 0x11:
			printf("  TDS band cap       = 0x%016llx\n",
			       (unsigned long long)((uint64_t)get_le(t.v, 4) |
			       ((uint64_t)get_le(t.v + 4, 4) << 32)));
			break;
		case 0x12: {
			/* u8 count + u16 BIG-endian band numbers (verified on-device:
			 * LE read gives 512/1024/... = obvious byte swap) */
			if (t.l < 1) break;
			unsigned n = t.v[0];
			printf("  extended LTE bands (%u):", n);
			for (unsigned i = 0; i < n && 1 + 2 * i + 1 < t.l; i++)
				printf(" B%u", (t.v[1 + 2 * i] << 8) | t.v[2 + 2 * i]);
			printf("\n");
			break; }
		default: hexdump_tlv(&t);
		}
	}
}

/* eUICC ISD-R probe: prove the QMI-UIM raw-APDU path that an on-device LPA
 * (lpac / NekokoLPA-telephony) would ride. Read-only: SELECT ISD-R + ES10b
 * GetEUICCInfo1. Msg layouts per libqmi qmi-service-uim.json:
 *   OPEN_LOGICAL_CHANNEL 0x42: in 0x01 slot u8, 0x10 AID (u8-len array);
 *     out 0x10 channel u8, 0x11 card result {sw1,sw2}, 0x12 select resp.
 *   SEND_APDU 0x3B: in 0x01 slot u8, 0x02 APDU (u16-len array), 0x10 chan;
 *     out 0x10 APDU response (u16-len array).
 *   LOGICAL_CHANNEL 0x3F: in 0x01 slot u8, 0x11 channel u8 (close). */
static const uint8_t ISDR_AID[16] = { 0xA0,0x00,0x00,0x05,0x59,0x10,0x10,
	0xFF,0xFF,0xFF,0xFF,0x89,0x00,0x00,0x01,0x00 };

/* isdr-scan targets. The modem's ISD-R refusal is (per the 10-15 RE) a
 * recognizer on the GSMA eUICC prefix A0000005591010FFFFFFFF89; vendor
 * cards that answer on a non-GSMA ISD-R AID may slip past it. AIDs from
 * euicc-manual.osmocom.org/docs/lpa/applet-id-oem/. On a card that lacks
 * the AID, "modem passed it" looks like the card's own not-found SW
 * (6A82), versus QMI error 82 (ACCESS_DENIED) when the modem blocks it. */
static const struct { const char *name, *hex; } SCAN_AIDS[] = {
	{ "ARA-M (control: known to open)", "A00000015141434C00" },
	{ "junk (control: card not-found)", "A0000000DEADBEEF0001" },
	{ "GSMA ISD-R (known: modem denies)", "A0000005591010FFFFFFFF8900000100" },
	{ "ESTKme SE0",                     "A06573746B6D65FFFF4953442D522030" },
	{ "ESTKme SE1",                     "A06573746B6D65FFFF4953442D522031" },
	{ "ESTKme AUX (deprecated)",        "A06573746B6D65FFFFFFFF4953442D52" },
	{ "eSIM.me",                        "A0000005591010000000008900000300" },
	{ "LinksField",                     "A000000559104C696E6B736669656C64" },
	{ "5ber (GSMA prefix)",             "A0000005591010FFFFFFFF8900050500" },
	{ "Xesim (GSMA prefix)",            "A0000005591010FFFFFFFF8900000177" },
};

static int parse_aid(const char *hex, uint8_t *out, unsigned max)
{
	unsigned n = 0;
	for (const char *p = hex; *p; p += 2) {
		unsigned v;
		if (!p[1] || n >= max || sscanf(p, "%2x", &v) != 1) return -1;
		out[n++] = (uint8_t)v;
	}
	return n >= 5 ? (int)n : -1;
}

/* quick=1: open + report + close only (isdr-scan); quick=0: full ES10 probe. */
static void do_isdr(qmi_client_type uim, const uint8_t *aid, unsigned alen,
                    int quick)
{
	uint8_t req[300], resp[2048]; unsigned int n, got;
	int channel = -1;
	if (!aid) { aid = ISDR_AID; alen = sizeof(ISDR_AID); }
	printf("AID:");
	for (unsigned i = 0; i < alen; i++) printf("%02X", aid[i]);
	printf("\n");

	/* Try the encodings the various modem vintages accept:
	 * v1: 0x42, AID as u8-len-prefixed array   (libqmi layout)
	 * v2: 0x42, AID raw bytes (no prefix)
	 * v3: 0x3F, AID u8-prefixed in TLV 0x10    (legacy open-by-AID) */
	struct { uint16_t msg; int prefix; const char *what; } enc[] = {
		{ UIM_OPEN_LOGICAL_CHANNEL, 1, "0x42 prefixed" },
		{ UIM_OPEN_LOGICAL_CHANNEL, 0, "0x42 raw" },
		{ UIM_LOGICAL_CHANNEL,      1, "0x3F prefixed" },
	};
	for (unsigned e = 0; e < sizeof(enc)/sizeof(enc[0]) && channel < 0; e++) {
		printf("\n== UIM open ISD-R [%s] ==\n", enc[e].what);
		n = 0;
		req[n++] = 0x01; req[n++] = 1; req[n++] = 0; req[n++] = 1;  /* slot 1 */
		req[n++] = 0x10;
		req[n++] = (uint8_t)(alen + enc[e].prefix); req[n++] = 0;
		if (enc[e].prefix) req[n++] = (uint8_t)alen;
		memcpy(req + n, aid, alen); n += alen;
		/* On a QMI error still decode the reply: TLV 0x11 carries the
		 * card's SW, which separates "card said no" from "modem said no". */
		send_raw(uim, "open_ch", enc[e].msg, req, n,
		         resp, sizeof(resp), &got);
		const uint8_t *p = resp, *end = resp + got; struct tlv t;
		while (tlv_next(&p, end, &t)) {
			if (t.t == 0x10 && t.l >= 1) {
				channel = t.v[0];
				printf("  channel id     = %d\n", channel);
			} else if (t.t == 0x11 && t.l >= 2) {
				printf("  card result    = SW %02X %02X %s\n",
				       t.v[0], t.v[1],
				       (t.v[0] == 0x90 && t.v[1] == 0x00) ? "(OK)" : "");
			} else if (t.t == 0x12) {
				printf("  select resp    :");
				for (int i = 1; i < t.l && i < 40; i++) printf(" %02x", t.v[i]);
				printf("\n");
			} else if (t.t != 0x02) hexdump_tlv(&t);
		}
	}
	if (quick) {
		if (channel < 0) { puts("  no channel id"); return; }
		goto close_ch;
	}
	if (channel < 0) {
		/* Channel-open denied — is raw SEND_APDU itself allowed?
		 * MANAGE CHANNEL (open): 00 70 00 00 01, basic channel, harmless. */
		puts("\n== UIM SEND_APDU (0x3B): MANAGE CHANNEL open ==");
		uint8_t mc[] = { 0x00, 0x70, 0x00, 0x00, 0x01 };
		n = 0;
		req[n++] = 0x01; req[n++] = 1; req[n++] = 0; req[n++] = 1;
		req[n++] = 0x02; req[n++] = 2 + sizeof(mc); req[n++] = 0;
		req[n++] = sizeof(mc); req[n++] = 0;
		memcpy(req + n, mc, sizeof(mc)); n += sizeof(mc);
		if (!send_raw(uim, "manage_ch", UIM_SEND_APDU, req, n,
		              resp, sizeof(resp), &got)) {
			const uint8_t *p = resp, *end = resp + got; struct tlv t;
			while (tlv_next(&p, end, &t)) {
				if (t.t == 0x10 && t.l >= 2) {
					unsigned rlen = (unsigned)get_le(t.v, 2);
					printf("  APDU response (%u):", rlen);
					for (unsigned i = 0; i < rlen && i < 16; i++)
						printf(" %02x", t.v[2 + i]);
					printf("\n");
					if (rlen == 3 && t.v[2 + 1] == 0x90) {
						channel = t.v[2];
						printf("  channel %d opened via raw APDU — SEND_APDU path OPEN\n", channel);
					}
				} else if (t.t != 0x02) hexdump_tlv(&t);
			}
		}
	}
	if (channel < 0) { puts("  no channel id — path NOT usable"); return; }

	/* SELECT ISD-R on the channel (needed after MANAGE CHANNEL open;
	 * harmless repeat after 0x42-open). CLA = channel, INS A4 04 04. */
	puts("\n== UIM SEND_APDU (0x3B): SELECT ISD-R on channel ==");
	{
		uint8_t sel[5 + 16 + 1];
		sel[0] = (uint8_t)(channel & 0x03); sel[1] = 0xA4;
		sel[2] = 0x04; sel[3] = 0x04; sel[4] = (uint8_t)alen;
		memcpy(sel + 5, aid, alen); sel[5 + alen] = 0x00;
		unsigned sel_len = 5 + alen + 1;
		n = 0;
		req[n++] = 0x01; req[n++] = 1; req[n++] = 0; req[n++] = 1;
		req[n++] = 0x02; req[n++] = (uint8_t)(2 + sel_len); req[n++] = 0;
		req[n++] = (uint8_t)sel_len; req[n++] = 0;
		memcpy(req + n, sel, sel_len); n += sel_len;
		if (!send_raw(uim, "select", UIM_SEND_APDU, req, n,
		              resp, sizeof(resp), &got)) {
			const uint8_t *p = resp, *end = resp + got; struct tlv t;
			while (tlv_next(&p, end, &t))
				if (t.t == 0x10 && t.l >= 2) {
					unsigned rlen = (unsigned)get_le(t.v, 2);
					printf("  SELECT resp (%u):", rlen);
					for (unsigned i = 0; i < rlen && i < 40; i++)
						printf(" %02x", t.v[2 + i]);
					printf("\n");
				}
		}
	}

	puts("\n== UIM SEND_APDU (0x3B): ES10b GetEUICCInfo1 (BF20) ==");
	/* STORE DATA: CLA 0x80|ch (last block), INS E2, P1 91, P2 00, Lc 3, BF 20 00 */
	uint8_t apdu[] = { (uint8_t)(0x80 | (channel & 0x03)), 0xE2, 0x91, 0x00,
	                   0x03, 0xBF, 0x20, 0x00, 0x00 };
	n = 0;
	req[n++] = 0x01; req[n++] = 1; req[n++] = 0; req[n++] = 1;      /* slot 1 */
	req[n++] = 0x02; req[n++] = (uint8_t)(2 + sizeof(apdu)); req[n++] = 0;
	req[n++] = (uint8_t)sizeof(apdu); req[n++] = 0;                 /* u16 len */
	memcpy(req + n, apdu, sizeof(apdu)); n += sizeof(apdu);
	req[n++] = 0x10; req[n++] = 1; req[n++] = 0; req[n++] = (uint8_t)channel;
	if (!send_raw(uim, "send_apdu", UIM_SEND_APDU, req, n,
	              resp, sizeof(resp), &got)) {
		const uint8_t *p = resp, *end = resp + got; struct tlv t;
		while (tlv_next(&p, end, &t)) {
			if (t.t == 0x10 && t.l >= 2) {
				unsigned rlen = (unsigned)get_le(t.v, 2);
				printf("  APDU response (%u):", rlen);
				for (unsigned i = 0; i < rlen && i < 96; i++)
					printf(" %02x", t.v[2 + i]);
				if (rlen > 96) printf(" ...");
				printf("\n");
				if (rlen >= 2 && t.v[2] == 0xBF && t.v[3] == 0x20)
					puts("  ^^ BF20 EUICCInfo1 — full ES10 path WORKS");
			} else if (t.t != 0x02) hexdump_tlv(&t);
		}
	}

close_ch:
	puts("\n== UIM LOGICAL_CHANNEL (0x3F): close ==");
	n = 0;
	req[n++] = 0x01; req[n++] = 1; req[n++] = 0; req[n++] = 1;
	req[n++] = 0x11; req[n++] = 1; req[n++] = 0; req[n++] = (uint8_t)channel;
	if (send_raw(uim, "close_ch", UIM_LOGICAL_CHANNEL, req, n,
	             resp, sizeof(resp), &got))
		puts("  (close failed — benign, channel clears on card reset)");
	else
		puts("  closed");
}

static void do_serving_system(qmi_client_type nas)
{
	uint8_t resp[2048]; unsigned int got;
	puts("\n== NAS GET_SERVING_SYSTEM (0x24) ==");
	if (send_raw(nas, "srvsys", NAS_GET_SERVING_SYSTEM, NULL, 0,
	             resp, sizeof(resp), &got))
		return;
	const uint8_t *p = resp, *end = resp + got; struct tlv t;
	while (tlv_next(&p, end, &t)) {
		switch (t.t) {
		case 0x02: break;
		case 0x01:
			if (t.l >= 5) {
				printf("  registration_state = %u (%s)\n", t.v[0], reg_state_name(t.v[0]));
				printf("  CS attach state    = %u (%s)\n", t.v[1], attach_name(t.v[1]));
				printf("  PS attach state    = %u (%s)   <<<< the money field\n",
				       t.v[2], attach_name(t.v[2]));
				printf("  selected network   = %u (%s)\n", t.v[3],
				       t.v[3] == 1 ? "3GPP2" : t.v[3] == 2 ? "3GPP" : "unknown");
				printf("  radio_if           =");
				for (int i = 0; i < t.v[4] && 5 + i < t.l; i++)
					printf(" %s", radio_if_name(t.v[5 + i]));
				printf("\n");
			}
			break;
		case 0x12:
			if (t.l >= 5) {
				printf("  current PLMN       = mcc %u mnc %u \"%.*s\"\n",
				       (unsigned)get_le(t.v, 2), (unsigned)get_le(t.v + 2, 2),
				       (int)t.v[4], (const char *)t.v + 5);
			}
			break;
		default:
			hexdump_tlv(&t);
		}
	}
}

static void do_sys_sel_pref(qmi_client_type nas)
{
	uint8_t resp[2048]; unsigned int got;
	puts("\n== NAS GET_SYSTEM_SELECTION_PREFERENCE (0x34) ==");
	if (send_raw(nas, "syssel", NAS_GET_SYS_SEL_PREF, NULL, 0,
	             resp, sizeof(resp), &got))
		return;
	const uint8_t *p = resp, *end = resp + got; struct tlv t;
	while (tlv_next(&p, end, &t)) {
		switch (t.t) {
		case 0x02: break;
		case 0x10:
			printf("  emergency_mode     = %u\n", t.v[0]); break;
		case 0x11:
			printf("  mode_pref          = 0x%04x ", (unsigned)get_le(t.v, 2));
			mode_pref_bits((uint16_t)get_le(t.v, 2));
			printf("\n"); break;
		case 0x12:
			printf("  band_pref          = 0x%016llx\n",
			       (unsigned long long)get_le(t.v, 4) |
			       ((unsigned long long)get_le(t.v + 4, 4) << 32)); break;
		case 0x14:
			printf("  roaming_pref       = %u\n", (unsigned)get_le(t.v, 2)); break;
		case 0x15:
			printf("  lte_band_pref      = 0x%016llx\n",
			       (unsigned long long)get_le(t.v, 4) |
			       ((unsigned long long)get_le(t.v + 4, 4) << 32)); break;
		case 0x16:
			printf("  net_sel_pref       = %u (%s)\n", t.v[0],
			       t.v[0] ? "MANUAL" : "AUTOMATIC"); break;
		case 0x18:
			printf("  srv_domain_pref    = %u (%s)   <<<< the money field\n",
			       (unsigned)get_le(t.v, 4), srv_domain_name(get_le(t.v, 4)));
			break;
		case 0x19:
			printf("  gw_acq_order_pref  = %u\n", (unsigned)get_le(t.v, 4)); break;
		case 0x1F:
			/* libqmi GET 0x34 output 0x1F = Usage Preference (u32):
			 * 0=unknown 1=VOICE_CENTRIC 2=DATA_CENTRIC */
			printf("  usage_preference   = %u (%s)   <<<< domain-selection input\n",
			       (unsigned)get_le(t.v, 4),
			       get_le(t.v, 4) == 1 ? "VOICE_CENTRIC" :
			       get_le(t.v, 4) == 2 ? "DATA_CENTRIC" : "unknown");
			break;
		case 0x20:
			/* libqmi GET 0x34 output 0x20 = Voice Domain Preference (u32):
			 * 0=CS_ONLY 1=PS_ONLY 2=CS_PREF 3=PS_PREF */
			printf("  voice_domain_pref  = %u (%s)\n", (unsigned)get_le(t.v, 4),
			       get_le(t.v, 4) == 0 ? "CS_ONLY" :
			       get_le(t.v, 4) == 1 ? "PS_ONLY" :
			       get_le(t.v, 4) == 2 ? "CS_PREFERRED" :
			       get_le(t.v, 4) == 3 ? "PS_PREFERRED" : "?");
			break;
		default:
			hexdump_tlv(&t);
		}
	}
}

static void decode_rat_srv_status(const char *rat, const struct tlv *t)
{
	/* {srv_status u8, true_srv_status u8, is_pref_data_path u8} (CDMA/HDR: 2) */
	printf("  %-6s srv_status = %u (%s)", rat, t->v[0], srv_status_name(t->v[0]));
	if (t->l >= 3)
		printf(", true_srv_status = %u (%s), pref_data_path=%u",
		       t->v[1], srv_status_name(t->v[1]), t->v[2]);
	printf("\n");
}

static void decode_lte_sys_info(const struct tlv *t)
{
	/* wire: domain_valid u8, domain u8, service_cap_valid u8, service_cap u8,
	 * roam_status_valid u8, roam_status u8, forbidden_valid u8, forbidden u8,
	 * lac_valid u8, lac u16, cell_id_valid u8, cell_id u32,
	 * reg_reject_valid u8, reject_srv_domain u8, reject_cause u8,
	 * network_id_valid u8, mcc[3], mnc[3], tac_valid u8, tac u16 */
	const uint8_t *v = t->v; int l = t->l;
	static const char *dom[] = { "NO_SRV", "CS_ONLY", "PS_ONLY", "CS_PS", "CAMPED" };
	printf("  LTE sys_info:\n");
	if (l >= 2 && v[0])  printf("    srv_domain     = %u (%s)\n", v[1], v[1] < 5 ? dom[v[1]] : "?");
	if (l >= 4 && v[2])  printf("    srv_capability = %u (%s)\n", v[3], v[3] < 5 ? dom[v[3]] : "?");
	if (l >= 6 && v[4])  printf("    roam_status    = %u\n", v[5]);
	if (l >= 8 && v[6])  printf("    is_forbidden   = %u\n", v[7]);
	if (l >= 11 && v[8]) printf("    lac            = %u\n", (unsigned)get_le(v + 9, 2));
	if (l >= 16 && v[11]) printf("    cell_id        = %u\n", (unsigned)get_le(v + 12, 4));
	if (l >= 19 && v[16]) printf("    REG REJECT: srv_domain=%u cause=%u\n", v[17], v[18]);
	if (l >= 26 && v[19]) printf("    plmn           = %.3s/%.3s\n", (const char *)v + 20, (const char *)v + 23);
	if (l >= 29 && v[26]) printf("    tac            = %u\n", (unsigned)get_le(v + 27, 2));
}

static void do_sys_info(qmi_client_type nas)
{
	uint8_t resp[4096]; unsigned int got;
	puts("\n== NAS GET_SYS_INFO (0x4D) ==");
	if (send_raw(nas, "sysinfo", NAS_GET_SYS_INFO, NULL, 0,
	             resp, sizeof(resp), &got))
		return;
	const uint8_t *p = resp, *end = resp + got; struct tlv t;
	while (tlv_next(&p, end, &t)) {
		switch (t.t) {
		case 0x02: break;
		case 0x10: decode_rat_srv_status("CDMA", &t); break;
		case 0x11: decode_rat_srv_status("HDR", &t); break;
		case 0x12: decode_rat_srv_status("GSM", &t); break;
		case 0x13: decode_rat_srv_status("WCDMA", &t); break;
		case 0x14: decode_rat_srv_status("LTE", &t); break;
		case 0x19: decode_lte_sys_info(&t); hexdump_tlv(&t); break;
		default:
			hexdump_tlv(&t);
		}
	}
}

/* ------------------------------------------- serving-cell measurement --- */
/* NAS GET_SIG_INFO (0x4F) + GET_CELL_LOCATION_INFO (0x43): the modem's own
 * serving-cell RSRP and S-criterion (srxlev) for the OOS sampler
 * (PLAN-oos-time E0). The framework's RSRP is threshold-reported with nothing
 * below -115 dBm, so it under-reports the hold; these are polled truth.
 * Output is one greppable line per item. Read-only. */
#define NAS_GET_CELL_LOCATION_INFO 0x0043
#define NAS_GET_SIG_INFO           0x004F

static int16_t get_s16(const uint8_t *v) { return (int16_t)get_le(v, 2); }

static void print_plmn(const uint8_t *b)
{
	/* 3GPP PLMN BCD: b0 = mcc2<<4|mcc1, b1 = mnc3<<4|mcc3, b2 = mnc2<<4|mnc1 */
	printf("plmn=%u%u%u", b[0] & 0xf, b[0] >> 4, b[1] & 0xf);
	printf("%u%u", b[2] & 0xf, b[2] >> 4);
	if ((b[1] >> 4) != 0xf) printf("%u", b[1] >> 4);
}

static void do_sig_info(qmi_client_type nas)
{
	uint8_t resp[1024]; unsigned int got;
	if (send_raw(nas, "siginfo", NAS_GET_SIG_INFO, NULL, 0,
	             resp, sizeof(resp), &got))
		return;
	const uint8_t *p = resp, *end = resp + got; struct tlv t;
	while (tlv_next(&p, end, &t)) {
		switch (t.t) {
		case 0x14: /* LTE: rssi s8, rsrq s8, rsrp s16, snr s16 (0.1 dB) */
			if (t.l >= 6)
				printf("SIG lte rsrp=%d rsrq=%d snr=%.1f rssi=%d\n",
				       get_s16(t.v + 2), (int8_t)t.v[1],
				       get_s16(t.v + 4) / 10.0, (int8_t)t.v[0]);
			break;
		case 0x12: if (t.l >= 1) printf("SIG gsm rssi=%d\n", (int8_t)t.v[0]); break;
		case 0x13: if (t.l >= 3) printf("SIG wcdma rssi=%d ecio=%d\n",
		                                (int8_t)t.v[0], get_s16(t.v + 1)); break;
		default: break;
		}
	}
}

static void print_lte_cells(const uint8_t *c, unsigned n, const uint8_t *end,
                            unsigned serving_pci)
{
	for (unsigned i = 0; i < n && c + 10 <= end; i++, c += 10) {
		unsigned pci = (unsigned)get_le(c, 2);
		printf(" [%spci=%u rsrp=%.1f rsrq=%.1f srxlev=%d]",
		       pci == serving_pci ? "*" : "", pci,
		       get_s16(c + 4) / 10.0, get_s16(c + 2) / 10.0, get_s16(c + 8));
	}
}

static void do_cell_location(qmi_client_type nas)
{
	uint8_t resp[4096]; unsigned int got;
	if (send_raw(nas, "cellloc", NAS_GET_CELL_LOCATION_INFO, NULL, 0,
	             resp, sizeof(resp), &got))
		return;
	const uint8_t *p = resp, *end = resp + got; struct tlv t;
	unsigned serving_pci = 0xffff;
	while (tlv_next(&p, end, &t)) {
		const uint8_t *v = t.v, *tend = t.v + t.l;
		if (t.t == 0x13 && t.l >= 19) {
			/* LTE intra-freq: ue_in_idle u8, plmn[3], tac u16, global_cell_id u32,
			 * earfcn u16, serving_cell_id u16, cell_resel_priority u8,
			 * s_non_intra_search u8, thresh_serving_low u8, s_intra_search u8,
			 * cells_len u8, cells[]{pci u16, rsrq s16, rsrp s16, rssi s16, srxlev s16} */
			serving_pci = (unsigned)get_le(v + 12, 2);
			printf("CELL lte idle=%u ", v[0]); print_plmn(v + 1);
			printf(" tac=%u gci=%u earfcn=%u pci=%u prio=%u s_nonintra=%u thresh_srv_low=%u s_intra=%u n=%u",
			       (unsigned)get_le(v + 4, 2), (unsigned)get_le(v + 6, 4),
			       (unsigned)get_le(v + 10, 2), serving_pci, v[14], v[15], v[16], v[17], v[18]);
			print_lte_cells(v + 19, v[18], tend, serving_pci);
			printf("\n");
		} else if (t.t == 0x14 && t.l >= 2) {
			/* LTE inter-freq: ue_in_idle u8, freqs_len u8, freqs[]{earfcn u16,
			 * srxlev_low u8, srxlev_high u8, cell_resel_priority u8, cells_len u8, cells[]} */
			const uint8_t *c = v + 2;
			for (unsigned f = 0; f < v[1] && c + 6 <= tend; f++) {
				unsigned n = c[5];
				printf("CELLX earfcn=%u prio=%u thrX_low=%u thrX_high=%u n=%u",
				       (unsigned)get_le(c, 2), c[4], c[2], c[3], n);
				print_lte_cells(c + 6, n, tend, 0xffff);
				printf("\n");
				c += 6 + 10 * n;
			}
		}
	}
}

/* ------------------------------------------------------------ WDS reads --- */
static void print_u16_list(const char *tag, const struct tlv *t)
{
	/* {num u8, u16[num]} */
	if (t->l < 1) return;
	printf("  %s (%u):", tag, t->v[0]);
	for (int i = 0; i < t->v[0] && 1 + 2 * i + 1 < t->l; i++)
		printf(" %u", (unsigned)get_le(t->v + 1 + 2 * i, 2));
	printf("\n");
}

static void do_attach_pdn(qmi_client_type wds)
{
	uint8_t resp[2048]; unsigned int got;
	puts("\n== WDS GET_LTE_MAX_ATTACH_PDN_NUM (0x92) ==");
	if (!send_raw(wds, "maxpdn", WDS_GET_LTE_MAX_ATTACH_PDN, NULL, 0,
	              resp, sizeof(resp), &got)) {
		const uint8_t *p = resp, *end = resp + got; struct tlv t;
		while (tlv_next(&p, end, &t))
			if (t.t == 0x10) printf("  max attach PDNs = %u\n", t.v[0]);
	}

	puts("\n== WDS GET_LTE_ATTACH_PDN_LIST (0x94) ==");
	if (!send_raw(wds, "pdnlist", WDS_GET_LTE_ATTACH_PDN_LIST, NULL, 0,
	              resp, sizeof(resp), &got)) {
		const uint8_t *p = resp, *end = resp + got; struct tlv t;
		int any = 0;
		while (tlv_next(&p, end, &t)) {
			if (t.t == 0x10) { print_u16_list("attach PDN profile ids ", &t); any = 1; }
			else if (t.t == 0x11) { print_u16_list("PENDING attach PDN ids", &t); any = 1; }
		}
		if (!any) printf("  <no attach PDN list TLVs — EMPTY>   <<<< suspect\n");
	}

	puts("\n== WDS GET_LTE_ATTACH_PARAMS (0x85) ==");
	if (!send_raw(wds, "attachparams", WDS_GET_LTE_ATTACH_PARAMS, NULL, 0,
	              resp, sizeof(resp), &got)) {
		const uint8_t *p = resp, *end = resp + got; struct tlv t;
		while (tlv_next(&p, end, &t)) {
			switch (t.t) {
			case 0x02: break;
			case 0x10: printf("  attach APN     = \"%.*s\"\n", t.l, (const char *)t.v); break;
			case 0x11: printf("  ip type        = %u\n", t.v[0]); break;
			case 0x12: printf("  ota_attach_performed = %u\n", t.v[0]); break;
			default: hexdump_tlv(&t);
			}
		}
	}
}

static void do_profiles(qmi_client_type wds)
{
	uint8_t resp[4096]; unsigned int got;
	/* GET_PROFILE_LIST, profile_type TLV 0x10 = 0 (3GPP) */
	uint8_t req[4] = { 0x10, 1, 0, 0 };
	puts("\n== WDS GET_PROFILE_LIST (0x2A, 3GPP) ==");
	if (send_raw(wds, "proflist", WDS_GET_PROFILE_LIST, req, sizeof(req),
	             resp, sizeof(resp), &got))
		return;
	uint8_t idx_list[64]; int n_idx = 0;
	const uint8_t *p = resp, *end = resp + got; struct tlv t;
	while (tlv_next(&p, end, &t)) {
		if (t.t != 0x01) continue;
		/* {num u8, then per profile: type u8, index u8, name_len u8, name[]} */
		const uint8_t *q = t.v, *qe = t.v + t.l;
		if (q >= qe) break;
		int num = *q++;
		printf("  %d profiles:\n", num);
		for (int i = 0; i < num && q + 3 <= qe; i++) {
			uint8_t ptype = q[0], pidx = q[1], nlen = q[2];
			q += 3;
			if (q + nlen > qe) break;
			printf("    [%u] type=%u name=\"%.*s\"\n", pidx, ptype, nlen, (const char *)q);
			q += nlen;
			if (n_idx < 64) idx_list[n_idx++] = pidx;
		}
	}
	/* settings per profile: req mandatory TLV 0x01 {type u8, index u8} */
	for (int i = 0; i < n_idx; i++) {
		uint8_t sreq[5] = { 0x01, 2, 0, 0 /*3gpp*/, idx_list[i] };
		printf("  -- profile %u settings:\n", idx_list[i]);
		if (send_raw(wds, "profset", WDS_GET_PROFILE_SETTINGS, sreq, sizeof(sreq),
		             resp, sizeof(resp), &got))
			continue;
		const uint8_t *pp = resp, *pe = resp + got; struct tlv s;
		while (tlv_next(&pp, pe, &s)) {
			switch (s.t) {
			case 0x02: break;
			case 0x10: printf("     name       = \"%.*s\"\n", s.l, (const char *)s.v); break;
			case 0x11: printf("     pdp_type   = %u (0=v4 1=v6 2=v4v6 3=ppp)\n", s.v[0]); break;
			case 0x14: printf("     apn        = \"%.*s\"\n", s.l, (const char *)s.v); break;
			case 0x1B: printf("     username   = \"%.*s\"\n", s.l, (const char *)s.v); break;
			case 0x2A: printf("     apn_disabled = %u\n", s.v[0]); break;
			case 0x2B: printf("     pdn_inactivity_timeout = %u\n", (unsigned)get_le(s.v, 4)); break;
			case 0x2C: printf("     apn_class  = %u\n", s.v[0]); break;
			default: if (g_wds_raw) hexdump_tlv(&s); break;
			}
		}
	}
}

/* dump every TLV of one 3GPP profile (raw) */
static void do_profile_get_one(qmi_client_type wds, uint8_t idx)
{
	uint8_t resp[4096]; unsigned int got;
	uint8_t sreq[5] = { 0x01, 2, 0, 0 /*3gpp*/, idx };
	printf("\n== WDS GET_PROFILE_SETTINGS (0x2B) profile %u ==\n", idx);
	if (send_raw(wds, "profget", WDS_GET_PROFILE_SETTINGS, sreq, sizeof(sreq),
	             resp, sizeof(resp), &got))
		return;
	const uint8_t *pp = resp, *pe = resp + got; struct tlv s;
	while (tlv_next(&pp, pe, &s))
		if (s.t != 0x02) hexdump_tlv(&s);
}

/* WDS MODIFY_PROFILE_SETTINGS (0x28): mandatory TLV 0x01 {type,index} + one
 * caller-chosen TLV written as an LE integer. Layout ground-truthed from the
 * on-device IDL (parse_idl_any.py, wds object 0x25440, msg 0x28). */
static int do_profile_modify(qmi_client_type wds, uint8_t idx,
                             unsigned tlv_id, unsigned len,
                             unsigned long long val)
{
	uint8_t req[64]; unsigned n = 0;
	uint8_t resp[512]; unsigned int got;
	if (len < 1 || len > 8) { fprintf(stderr, "len must be 1..8\n"); return 1; }
	req[n++] = 0x01; req[n++] = 2; req[n++] = 0;      /* TLV 0x01 len=2 */
	req[n++] = 0;    req[n++] = idx;                  /* {type=0 3gpp, index} */
	req[n++] = (uint8_t)tlv_id;
	req[n++] = (uint8_t)(len & 0xff); req[n++] = (uint8_t)(len >> 8);
	for (unsigned i = 0; i < len; i++) req[n++] = (uint8_t)(val >> (8 * i));
	printf("\n== WDS MODIFY_PROFILE_SETTINGS (0x28) profile %u: TLV 0x%02x len %u val 0x%llx ==\n",
	       idx, tlv_id, len, val);
	if (send_raw(wds, "profmod", 0x0028, req, n, resp, sizeof(resp), &got)) {
		/* dump extended-error TLV (0xE0) if present */
		const uint8_t *pp = resp, *pe = resp + got; struct tlv s;
		while (tlv_next(&pp, pe, &s))
			if (s.t != 0x02) hexdump_tlv(&s);
		return 1;
	}
	puts("  -> accepted");
	return 0;
}

/* ------------------------------------------------------------ UIM reads --- */
static const char *app_type_name(uint8_t v)
{
	static const char *n[] = { "unknown", "SIM", "USIM", "RUIM", "CSIM", "ISIM" };
	return v < 6 ? n[v] : "?";
}
static const char *app_state_name(uint8_t v)
{
	static const char *n[] = { "UNKNOWN", "DETECTED", "PIN1_REQ", "PUK1_REQ",
		"INITIALIZING", "PERSO", "PERSO_BLOCKED", "READY" };
	return v < 8 ? n[v] : "?";
}
static void print_prov_index(const char *tag, uint16_t v)
{
	if (v == 0xFFFF)
		printf("  %s = 0xFFFF (NOT PROVISIONED)   <<<< suspect if GW pri\n", tag);
	else
		printf("  %s = slot %u app %u\n", tag, (v >> 8) + 1, v & 0xFF);
}

static void do_card_status(qmi_client_type uim)
{
	uint8_t resp[4096]; unsigned int got;
	puts("\n== UIM GET_CARD_STATUS (0x2F) ==");
	if (send_raw(uim, "cardstatus", UIM_GET_CARD_STATUS, NULL, 0,
	             resp, sizeof(resp), &got))
		return;
	const uint8_t *p = resp, *end = resp + got; struct tlv t;
	while (tlv_next(&p, end, &t)) {
		if (t.t != 0x10) continue;
		const uint8_t *v = t.v, *ve = t.v + t.l;
		if (v + 9 > ve) break;
		print_prov_index("GW  primary  ", (uint16_t)get_le(v, 2));
		print_prov_index("1X  primary  ", (uint16_t)get_le(v + 2, 2));
		print_prov_index("GW  secondary", (uint16_t)get_le(v + 4, 2));
		print_prov_index("1X  secondary", (uint16_t)get_le(v + 6, 2));
		int nslots = v[8]; v += 9;
		for (int s = 0; s < nslots && v + 6 <= ve; s++) {
			printf("  slot %d: card_state=%u upin=%u err=%u apps=%u\n",
			       s + 1, v[0], v[1], v[4], v[5]);
			int napps = v[5]; v += 6;
			for (int a = 0; a < napps && v + 7 <= ve; a++) {
				uint8_t app_type = v[0], app_state = v[1];
				uint8_t perso_state = v[2];
				uint8_t aid_len = v[6];
				v += 7 + aid_len;
				if (v + 7 > ve) break;
				uint8_t univ_pin = v[0], pin1 = v[1], pin2 = v[4];
				v += 7;
				printf("    app %d: %-5s state=%u (%s) perso=%u pin1_state=%u pin2_state=%u univ_pin=%u\n",
				       a, app_type_name(app_type), app_state,
				       app_state_name(app_state), perso_state, pin1, pin2, univ_pin);
			}
		}
	}
}

/* Read a transparent EF under the USIM ADF via the GW-primary session.
 * Wire: 0x01 session {type u8=0 GW-pri, aid_len u8=0}
 *       0x02 file  {file_id u16le, path_len u8, path bytes 3F00 7FFF}
 *       0x03 read  {offset u16=0, length u16=0 (whole file)}            */
static void do_sim_read(qmi_client_type uim, uint16_t efid)
{
	uint8_t req[32]; unsigned int n = 0;
	req[n++] = 0x01; req[n++] = 2; req[n++] = 0;      /* session TLV */
	req[n++] = 0;    req[n++] = 0;                    /* GW pri, aid_len 0 */
	req[n++] = 0x02; req[n++] = 7; req[n++] = 0;      /* file TLV */
	req[n++] = (uint8_t)efid; req[n++] = (uint8_t)(efid >> 8);
	req[n++] = 4;                                     /* path_len */
	req[n++] = 0x00; req[n++] = 0x3F;                 /* 3F00 (LE) */
	req[n++] = 0xFF; req[n++] = 0x7F;                 /* 7FFF (LE) */
	req[n++] = 0x03; req[n++] = 4; req[n++] = 0;      /* read TLV */
	req[n++] = 0; req[n++] = 0;                       /* offset 0 */
	req[n++] = 0; req[n++] = 0;                       /* length 0 = all */

	uint8_t resp[4096]; unsigned int got;
	printf("\n== UIM READ_TRANSPARENT EF 0x%04X ==\n", efid);
	if (send_raw(uim, "simread", UIM_READ_TRANSPARENT, req, n,
	             resp, sizeof(resp), &got)) {
		/* card result TLV 0x10 = {sw1,sw2} if present */
		const uint8_t *p = resp, *end = resp + got; struct tlv t;
		while (tlv_next(&p, end, &t))
			if (t.t == 0x10 && t.l >= 2)
				printf("  sw1=%02x sw2=%02x\n", t.v[0], t.v[1]);
		return;
	}
	const uint8_t *p = resp, *end = resp + got; struct tlv t;
	while (tlv_next(&p, end, &t)) {
		if (t.t == 0x10 && t.l >= 2)
			printf("  sw1=%02x sw2=%02x\n", t.v[0], t.v[1]);
		if (t.t == 0x11 && t.l >= 2) {
			uint16_t cl = (uint16_t)get_le(t.v, 2);
			printf("  content (%u):", cl);
			for (int i = 0; i < cl && 2 + i < t.l; i++) printf(" %02x", t.v[2 + i]);
			printf("\n");
			/* FPLMN-style decode: 3-byte PLMN records */
			if (efid == 0x6F7B) {
				for (int i = 0; i + 3 <= cl; i += 3) {
					const uint8_t *b = t.v + 2 + i;
					if (b[0] == 0xFF && b[1] == 0xFF && b[2] == 0xFF) continue;
					int mcc = (b[0] & 15) * 100 + (b[0] >> 4) * 10 + (b[1] & 15);
					int mnc3 = b[1] >> 4;
					int mnc = (b[2] & 15) * 10 + (b[2] >> 4);
					if (mnc3 != 0xF) mnc = mnc * 10 + mnc3;
					printf("    FPLMN[%d] = %03d/%d   %s\n", i / 3, mcc, mnc,
					       (mcc == 311 && mnc == 480) ? "<<<< HOME PLMN FORBIDDEN" : "");
				}
			}
		}
	}
}

/* --------------------------------------------------------------- writes --- */
static int do_set_domain(qmi_client_type nas, uint32_t pref, int power_cycle_only)
{
	/* SET_SYSTEM_SELECTION_PREFERENCE: TLV 0x1B srv_domain_pref u32
	 * (+ TLV 0x17 change_duration=0 power-cycle for the persistent prefs;
	 * PS_ATTACH/PS_DETACH are one-shot actions, duration not applicable) */
	uint8_t req[32]; unsigned int n = 0;
	req[n++] = 0x1B; req[n++] = 4; req[n++] = 0;
	req[n++] = (uint8_t)pref; req[n++] = (uint8_t)(pref >> 8);
	req[n++] = (uint8_t)(pref >> 16); req[n++] = (uint8_t)(pref >> 24);
	if (power_cycle_only) {
		req[n++] = 0x17; req[n++] = 1; req[n++] = 0; req[n++] = 0;
	}
	uint8_t resp[512]; unsigned int got;
	printf("\n== NAS SET_SYSTEM_SELECTION_PREFERENCE srv_domain_pref=%u (%s) ==\n",
	       pref, srv_domain_name(pref));
	int rc = send_raw(nas, "set_domain", NAS_SET_SYS_SEL_PREF, req, n,
	                  resp, sizeof(resp), &got);
	printf("  -> %s\n", rc ? "FAILED" : "accepted (watch reg state now)");
	return rc;
}

static int do_set_mode(qmi_client_type nas, uint16_t mask)
{
	uint8_t req[16]; unsigned int n = 0;
	req[n++] = 0x11; req[n++] = 2; req[n++] = 0;
	req[n++] = (uint8_t)mask; req[n++] = (uint8_t)(mask >> 8);
	req[n++] = 0x17; req[n++] = 1; req[n++] = 0; req[n++] = 0; /* power-cycle */
	uint8_t resp[512]; unsigned int got;
	printf("\n== NAS SET_SYSTEM_SELECTION_PREFERENCE mode_pref=0x%04x ", mask);
	mode_pref_bits(mask); puts(" (power-cycle) ==");
	int rc = send_raw(nas, "set_mode", NAS_SET_SYS_SEL_PREF, req, n,
	                  resp, sizeof(resp), &got);
	printf("  -> %s\n", rc ? "FAILED" : "accepted");
	return rc;
}

/* SET 0x0033 LTE band preference, change_duration=0 (power-cycle: a reboot
 * restores the full set). TLV 0x15 u64 = legacy LTE mask (bit n = B(n+1));
 * TLV 0x24 = extended LTE band pref, 4 x u64 (bands 1..256), sent too unless
 * --no-ext so a B66-capable modem cannot keep B66 through the ext mask.
 * Bench lock for the B12 lane: `lteband 0x800`. Restore: `lteband 0x1181a`
 * plus B66 (ext bit 65) or just reboot. */
static int do_set_lteband(qmi_client_type nas, uint64_t mask, uint64_t ext1, int with_ext)
{
	uint8_t req[64]; unsigned int n = 0;
	req[n++] = 0x15; req[n++] = 8; req[n++] = 0;
	for (int i = 0; i < 8; i++) req[n++] = (uint8_t)(mask >> (8 * i));
	if (with_ext) {
		uint64_t e[4] = { mask, ext1, 0, 0 };
		req[n++] = 0x24; req[n++] = 32; req[n++] = 0;
		for (int w = 0; w < 4; w++)
			for (int i = 0; i < 8; i++) req[n++] = (uint8_t)(e[w] >> (8 * i));
	}
	req[n++] = 0x17; req[n++] = 1; req[n++] = 0; req[n++] = 0; /* power-cycle */
	uint8_t resp[512]; unsigned int got;
	printf("\n== NAS SET_SYSTEM_SELECTION_PREFERENCE lte_band_pref=0x%016llx ext1=0x%016llx%s (power-cycle) ==\n",
	       (unsigned long long)mask, (unsigned long long)ext1, with_ext ? "" : " [no ext TLV]");
	int rc = send_raw(nas, "set_lteband", NAS_SET_SYS_SEL_PREF, req, n,
	                  resp, sizeof(resp), &got);
	printf("  -> %s\n", rc ? "FAILED" : "accepted (poll status)");
	return rc;
}

/* DMS SET_OPERATING_MODE (0x2E), mandatory TLV 0x01 u8:
 * 0=ONLINE 1=LOW_POWER — LPM->ONLINE = clean radio power-cycle (EMM restart,
 * fresh PLMN selection with current NV) without SSR/framework/wifi impact. */
static int do_set_opmode(qmi_client_type dms, uint8_t mode)
{
	uint8_t req[4] = { 0x01, 1, 0, mode };
	uint8_t resp[512]; unsigned int got;
	printf("\n== DMS SET_OPERATING_MODE %u (%s) ==\n", mode,
	       mode == 0 ? "ONLINE" : mode == 1 ? "LOW_POWER" : "?");
	int rc = send_raw(dms, "set_opmode", DMS_SET_OPERATING_MODE, req, sizeof(req),
	                  resp, sizeof(resp), &got);
	printf("  -> %s\n", rc ? "FAILED" : "accepted");
	return rc;
}

/* SET 0x0033 Usage Preference = TLV 0x21 u32 (libqmi; blob IDL confirms u32
 * at that id): 1=VOICE_CENTRIC 2=DATA_CENTRIC. The data-centric experiment
 * for the attach blocker: voice-centric UE + VoLTE-only PLMN + IMS unavailable
 * is the leading theory for CM refusing to attach on 311480. */
static int do_set_usage(qmi_client_type nas, uint32_t pref)
{
	uint8_t req[16]; unsigned int n = 0;
	req[n++] = 0x21; req[n++] = 4; req[n++] = 0;
	req[n++] = (uint8_t)pref; req[n++] = (uint8_t)(pref >> 8);
	req[n++] = (uint8_t)(pref >> 16); req[n++] = (uint8_t)(pref >> 24);
	uint8_t resp[512]; unsigned int got;
	printf("\n== NAS SET_SYSTEM_SELECTION_PREFERENCE usage_preference=%u (%s) ==\n",
	       pref, pref == 1 ? "VOICE_CENTRIC" : pref == 2 ? "DATA_CENTRIC" : "?");
	int rc = send_raw(nas, "set_usage", NAS_SET_SYS_SEL_PREF, req, n,
	                  resp, sizeof(resp), &got);
	printf("  -> %s\n", rc ? "FAILED" : "accepted (re-read 0x34, poll status)");
	return rc;
}

/* SET 0x0033 Voice Domain Preference = TLV 0x23 u32 (libqmi):
 * 0=CS_ONLY 1=PS_ONLY 2=CS_PREF 3=PS_PREF */
static int do_set_voicedom(qmi_client_type nas, uint32_t pref)
{
	uint8_t req[16]; unsigned int n = 0;
	req[n++] = 0x23; req[n++] = 4; req[n++] = 0;
	req[n++] = (uint8_t)pref; req[n++] = (uint8_t)(pref >> 8);
	req[n++] = (uint8_t)(pref >> 16); req[n++] = (uint8_t)(pref >> 24);
	uint8_t resp[512]; unsigned int got;
	printf("\n== NAS SET_SYSTEM_SELECTION_PREFERENCE voice_domain_pref=%u ==\n", pref);
	int rc = send_raw(nas, "set_voicedom", NAS_SET_SYS_SEL_PREF, req, n,
	                  resp, sizeof(resp), &got);
	printf("  -> %s\n", rc ? "FAILED" : "accepted");
	return rc;
}

static int do_manual_select(qmi_client_type nas, uint16_t mcc, uint16_t mnc)
{
	/* TLV 0x16 net_sel_pref {pref u8 (0=auto,1=manual), mcc u16, mnc u16}
	 * TLV 0x1A mnc_includes_pcs_digit u8=1 (480 is a 3-digit MNC) */
	int automatic = (mcc == 0 && mnc == 0);
	uint8_t req[16]; unsigned int n = 0;
	req[n++] = 0x16; req[n++] = 5; req[n++] = 0;
	req[n++] = automatic ? 0 : 1;
	req[n++] = (uint8_t)mcc; req[n++] = (uint8_t)(mcc >> 8);
	req[n++] = (uint8_t)mnc; req[n++] = (uint8_t)(mnc >> 8);
	req[n++] = 0x1A; req[n++] = 1; req[n++] = 0; req[n++] = 1;
	uint8_t resp[512]; unsigned int got;
	printf("\n== NAS SET_SYSTEM_SELECTION_PREFERENCE %s select %u/%u ==\n",
	       automatic ? "AUTOMATIC" : "manual", mcc, mnc);
	int rc = send_raw(nas, "manual", NAS_SET_SYS_SEL_PREF, req, n,
	                  resp, sizeof(resp), &got);
	printf("  -> %s\n", rc ? "FAILED" : "accepted (poll status)");
	return rc;
}

/* ----------------------------------------------------------------- main --- */
static void usage(const char *a0)
{
	fprintf(stderr,
	  "usage: %s <cmd>\n"
	  "  status                       read-only: DMS opmode + NAS 0x24/0x34/0x4D\n"
  "  sig                          read-only: NAS 0x4F sig info + 0x43 cell location (serving RSRP, srxlev, neighbours)\n"
	  "  bands                        read-only: DMS 0x45 band capability (hw truth)\n"
	  "  isdr [aid-hex]               read-only: open+SELECT ISD-R (or <aid>), ES10b GetEUICCInfo1\n"
	  "  isdr-scan [aid-hex...]       read-only: try opening each AID (default: known vendor ISD-R AIDs)\n"
	  "  wds                          read-only: LTE attach PDN list + params + profiles\n"
"  wdsraw                       as wds, plus hexdump of every undecoded profile TLV\n"
"  wdsget <idx>                 read-only: one 3GPP profile, all TLVs hexdumped\n"
"  wdsmod <idx> <tlv> <len> <val> --yes-touch-nas\n"
"                               WDS MODIFY_PROFILE_SETTINGS (0x28) on 3GPP profile <idx>:\n"
"                               write TLV <tlv> (hex) as <len>-byte LE integer <val>\n"
"                               (e.g. apn_bearer: wdsmod 1 0x35 8 0x8000000000000000)\n"
	  "  attach   --yes-touch-nas     send srv_domain_pref=PS_ATTACH (one-shot)\n"
	  "  detach   --yes-touch-nas     send srv_domain_pref=PS_DETACH (one-shot)\n"
	  "  domain <0-5> --yes-touch-nas set srv_domain_pref raw value (power-cycle)\n"
	  "  mode <hex-u16> --yes-touch-nas  set mode_pref bitmask (power-cycle)\n"
	  "  usage <1|2> --yes-touch-nas  set usage_preference (1=voice-centric 2=data-centric)\n"
	  "  lteband <hex-u64> [ext1-hex] [--no-ext] --yes-touch-nas\n"
	  "                               set LTE band pref (bit n = B(n+1); ext1 bit k = B(65+k)), power-cycle\n"
	  "  voicedom <0-3> --yes-touch-nas  set voice_domain_pref (0=CS 1=PS 2=CSpref 3=PSpref)\n"
	  "  radiocycle --yes-touch-nas   DMS LPM -> ONLINE (clean EMM/PLMN-selection restart)\n"
	  "\nRun with LD_PRELOAD=/vendor/lib64/libqmi_force_ipcr.so "
	  "LD_LIBRARY_PATH=/vendor/lib64\n", a0);
}

int main(int argc, char **argv)
{
	if (argc < 2) { usage(argv[0]); return 2; }
	const char *cmd = argv[1];

	int confirmed = 0;
	for (int i = 2; i < argc; i++)
		if (!strcmp(argv[i], "--yes-touch-nas")) confirmed = 1;

	if (!strcmp(cmd, "status")) {
		qmi_client_type dms = connect_svc(DMS_SO(), "DMS");
		if (dms) { do_operating_mode(dms); qmi_client_release(dms); }
		qmi_client_type nas = connect_svc(NAS_SO(), "NAS");
		if (!nas) return 1;
		do_serving_system(nas);
		do_sys_sel_pref(nas);
		do_sys_info(nas);
		qmi_client_release(nas);
		return 0;
	}

	if (!strcmp(cmd, "sig")) {
		qmi_client_type nas = connect_svc(NAS_SO(), "NAS");
		if (!nas) return 1;
		do_sig_info(nas);
		do_cell_location(nas);
		qmi_client_release(nas);
		return 0;
	}

	if (!strcmp(cmd, "isdr")) {
		uint8_t aid[16]; int alen = 0;
		if (argc >= 3 && (alen = parse_aid(argv[2], aid, sizeof(aid))) < 0) {
			fprintf(stderr, "bad AID hex (5..16 bytes): %s\n", argv[2]);
			return 2;
		}
		qmi_client_type uim = connect_svc(UIM_SO(), "UIM");
		if (!uim) return 1;
		do_isdr(uim, alen ? aid : NULL, (unsigned)alen, 0);
		qmi_client_release(uim);
		return 0;
	}

	if (!strcmp(cmd, "isdr-scan")) {
		qmi_client_type uim = connect_svc(UIM_SO(), "UIM");
		if (!uim) return 1;
		/* With AIDs on the command line, scan those instead of the table. */
		unsigned cnt = argc > 2 ? (unsigned)(argc - 2)
		                        : sizeof(SCAN_AIDS)/sizeof(SCAN_AIDS[0]);
		for (unsigned i = 0; i < cnt; i++) {
			const char *hex = argc > 2 ? argv[2 + i] : SCAN_AIDS[i].hex;
			uint8_t aid[16];
			int alen = parse_aid(hex, aid, sizeof(aid));
			if (alen < 0) { fprintf(stderr, "bad AID hex: %s\n", hex); continue; }
			printf("\n######## %s ########\n", argc > 2 ? hex : SCAN_AIDS[i].name);
			do_isdr(uim, aid, (unsigned)alen, 1);
		}
		qmi_client_release(uim);
		return 0;
	}

	if (!strcmp(cmd, "bands")) {
		qmi_client_type dms = connect_svc(DMS_SO(), "DMS");
		if (!dms) return 1;
		do_band_capability(dms);
		qmi_client_release(dms);
		return 0;
	}

	if (!strcmp(cmd, "uim")) {
		qmi_client_type uim = connect_svc(UIM_SO(), "UIM");
		if (!uim) return 1;
		do_card_status(uim);
		qmi_client_release(uim);
		return 0;
	}

	if (!strcmp(cmd, "fplmn")) {
		qmi_client_type uim = connect_svc(UIM_SO(), "UIM");
		if (!uim) return 1;
		do_sim_read(uim, 0x6F7B);  /* FPLMN */
		do_sim_read(uim, 0x6FE3);  /* EPSLOCI: GUTI + last TAI + EPS upd status */
		do_sim_read(uim, 0x6F7E);  /* LOCI */
		do_sim_read(uim, 0x6F73);  /* PSLOCI */
		qmi_client_release(uim);
		return 0;
	}

	if (!strcmp(cmd, "simread") && argc >= 3) {
		qmi_client_type uim = connect_svc(UIM_SO(), "UIM");
		if (!uim) return 1;
		do_sim_read(uim, (uint16_t)strtoul(argv[2], NULL, 16));
		qmi_client_release(uim);
		return 0;
	}

	if (!strcmp(cmd, "wdsget") && argc >= 3) {
		qmi_client_type wds = connect_svc(WDS_SO(), "WDS");
		if (!wds) return 1;
		do_profile_get_one(wds, (uint8_t)strtoul(argv[2], NULL, 0));
		qmi_client_release(wds);
		return 0;
	}

	if (!strcmp(cmd, "wdsmod")) {
		if (argc < 6) { usage(argv[0]); return 2; }
		if (!confirmed) {
			fprintf(stderr, "refusing 'wdsmod': profile-mutating command needs --yes-touch-nas\n");
			return 3;
		}
		qmi_client_type wds = connect_svc(WDS_SO(), "WDS");
		if (!wds) return 1;
		int rc = do_profile_modify(wds,
			(uint8_t)strtoul(argv[2], NULL, 0),
			(unsigned)strtoul(argv[3], NULL, 0),
			(unsigned)strtoul(argv[4], NULL, 0),
			strtoull(argv[5], NULL, 0));
		/* read back */
		do_profile_get_one(wds, (uint8_t)strtoul(argv[2], NULL, 0));
		qmi_client_release(wds);
		return rc;
	}

	if (!strcmp(cmd, "wds") || !strcmp(cmd, "wdsraw")) {
		g_wds_raw = !strcmp(cmd, "wdsraw");
		qmi_client_type wds = connect_svc(WDS_SO(), "WDS");
		if (!wds) return 1;
		do_attach_pdn(wds);
		do_profiles(wds);
		qmi_client_release(wds);
		return 0;
	}

	int is_write = !strcmp(cmd, "attach") || !strcmp(cmd, "detach") ||
	               !strcmp(cmd, "domain") || !strcmp(cmd, "mode") ||
	               !strcmp(cmd, "manual") || !strcmp(cmd, "usage") ||
	               !strcmp(cmd, "voicedom") || !strcmp(cmd, "radiocycle") ||
	               !strcmp(cmd, "lteband");
	if (!is_write) { usage(argv[0]); return 2; }
	if (!confirmed) {
		fprintf(stderr, "refusing '%s': NAS-mutating command needs --yes-touch-nas\n", cmd);
		return 3;
	}

	if (!strcmp(cmd, "radiocycle")) {
		qmi_client_type dms = connect_svc(DMS_SO(), "DMS");
		if (!dms) return 1;
		int rc = do_set_opmode(dms, 1);          /* LPM */
		if (!rc) {
			for (int i = 0; i < 30; i++) usleep(100000); /* 3s */
			rc = do_set_opmode(dms, 0);          /* ONLINE */
		}
		qmi_client_release(dms);
		return rc;
	}

	qmi_client_type nas = connect_svc(NAS_SO(), "NAS");
	if (!nas) return 1;
	int rc = 1;
	if (!strcmp(cmd, "attach"))      rc = do_set_domain(nas, 3, 0);
	else if (!strcmp(cmd, "detach")) rc = do_set_domain(nas, 4, 0);
	else if (!strcmp(cmd, "domain") && argc >= 3)
		rc = do_set_domain(nas, (uint32_t)strtoul(argv[2], NULL, 0), 1);
	else if (!strcmp(cmd, "mode") && argc >= 3)
		rc = do_set_mode(nas, (uint16_t)strtoul(argv[2], NULL, 16));
	else if (!strcmp(cmd, "manual") && argc >= 4)
		rc = do_manual_select(nas, (uint16_t)strtoul(argv[2], NULL, 10),
		                      (uint16_t)strtoul(argv[3], NULL, 10));
	else if (!strcmp(cmd, "usage") && argc >= 3)
		rc = do_set_usage(nas, (uint32_t)strtoul(argv[2], NULL, 0));
	else if (!strcmp(cmd, "lteband") && argc >= 3) {
		int with_ext = 1; uint64_t ext1 = 0;
		for (int i = 3; i < argc; i++) {
			if (!strcmp(argv[i], "--no-ext")) with_ext = 0;
			else if (argv[i][0] != '-') ext1 = strtoull(argv[i], NULL, 16);
		}
		rc = do_set_lteband(nas, strtoull(argv[2], NULL, 16), ext1, with_ext);
	}
	else if (!strcmp(cmd, "voicedom") && argc >= 3)
		rc = do_set_voicedom(nas, (uint32_t)strtoul(argv[2], NULL, 0));
	else usage(argv[0]);
	/* leave a beat for the resulting serving-system indication to print */
	if (!rc) { do_serving_system(nas); }
	qmi_client_release(nas);
	return rc;
}
