// ipcr-mtu-probe.c — how big a router packet can the AP send to the modem
// over the legacy IPC Router (AF_MSM_IPC) on this kernel, and does the modem
// answer it?
//
// Background (PLAN-qmux-bridge.md, 2026-11-07 review): ipc_router_rpmsg_xprt
// hands each router packet to the SMD driver as ONE SMD packet, and the kona
// qcom_smd driver refuses a packet that does not fit the IPCRTR FIFO
// (-EINVAL). The stock 3.18 SMD xprt streamed a large SMD packet through the
// FIFO with smd_write_start/segment/end, so stock had no such limit. This
// probe measures the limit from userspace and shows whether a big request
// that does fit is still answered by the modem.
//
// Method: a valid QMI DMS GET_DEVICE_CAP request (msg 0x0020, no mandatory
// TLVs) padded with one optional TLV (type 0xF0) of the requested size. QMI
// services skip unknown optional TLVs, so the modem answers normally when the
// whole packet arrives; a sendto() failure means the transport refused it.
//
// Usage (as root on the phone):
//   ipcr-mtu-probe                    # sweep the built-in size list
//   ipcr-mtu-probe 1000 8000 20000    # specific padding sizes
//   ipcr-mtu-probe -s 0x03 ...        # another service (default DMS 0x02)
// Output per size: total QMI bytes sent, sendto result/errno, response
// (result/error codes) or timeout.
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef AF_MSM_IPC
#define AF_MSM_IPC 27
#endif
#define MSM_IPC_ADDR_NAME 1
#define MSM_IPC_ADDR_ID 2

struct msm_ipc_port_addr { uint32_t node_id; uint32_t port_id; };
struct msm_ipc_port_name { uint32_t service; uint32_t instance; };
struct msm_ipc_addr {
	unsigned char addrtype;
	union {
		struct msm_ipc_port_addr port_addr;
		struct msm_ipc_port_name port_name;
	} addr;
};
struct sockaddr_msm_ipc {
	unsigned short family;
	struct msm_ipc_addr address;
	unsigned char reserved;
};
struct msm_ipc_server_info {
	uint32_t node_id, port_id, service, instance;
};
struct server_lookup_args {
	struct msm_ipc_port_name port_name;
	int num_entries_in_array;
	int num_entries_found;
	uint32_t lookup_mask;
	struct msm_ipc_server_info srv_info[8];
};
#define IPC_ROUTER_IOCTL_MAGIC 0xC3
#define IPC_ROUTER_IOCTL_GET_MTU _IOR(IPC_ROUTER_IOCTL_MAGIC, 1, unsigned int)
#define IPC_ROUTER_IOCTL_LOOKUP_SERVER \
	_IOWR(IPC_ROUTER_IOCTL_MAGIC, 2, struct sockaddr_msm_ipc)

#define QMI_DMS_GET_DEVICE_CAP_REQ 0x0020
#define PAD_TLV_TYPE 0xF0

static const int default_sizes[] = {
	64, 1024, 4096, 7000, 7900, 8000, 8100, 8120, 8140, 8150, 8160,
	8192, 9000, 12000, 16000, 32000, 60000, 0
};

static int lookup(int fd, uint32_t service, uint32_t instance,
		  struct msm_ipc_server_info *out)
{
	struct server_lookup_args args;

	memset(&args, 0, sizeof(args));
	args.port_name.service = service;
	args.port_name.instance = instance;
	args.num_entries_in_array = 8;
	args.lookup_mask = 0xFFFFFFFF;
	if (ioctl(fd, IPC_ROUTER_IOCTL_LOOKUP_SERVER, &args) < 0)
		return -errno;
	if (args.num_entries_found < 1)
		return -ENOENT;
	*out = args.srv_info[0];
	return args.num_entries_found;
}

static int one_size(int fd, const struct sockaddr_msm_ipc *dst, int pad,
		    uint16_t txn)
{
	size_t qmi_len = 7 + 3 + (size_t)pad; /* hdr + TLV hdr + pad */
	uint8_t *buf = calloc(1, qmi_len);
	uint8_t resp[512];
	struct pollfd pfd = { .fd = fd, .events = POLLIN };
	ssize_t n;
	int ret;

	if (!buf)
		return -ENOMEM;
	/* QMI (QCCI/IDL) framing over the router: type, txn, msg_id, len */
	buf[0] = 0x00;
	buf[1] = txn & 0xff;
	buf[2] = txn >> 8;
	buf[3] = QMI_DMS_GET_DEVICE_CAP_REQ & 0xff;
	buf[4] = QMI_DMS_GET_DEVICE_CAP_REQ >> 8;
	buf[5] = (3 + pad) & 0xff;
	buf[6] = (3 + pad) >> 8;
	buf[7] = PAD_TLV_TYPE;
	buf[8] = pad & 0xff;
	buf[9] = pad >> 8;
	memset(buf + 10, 0xA5, pad);

	printf("pad %6d  qmi %6zu B  ", pad, qmi_len);
	fflush(stdout);
	n = sendto(fd, buf, qmi_len, 0, (const struct sockaddr *)dst,
		   sizeof(*dst));
	if (n < 0) {
		printf("sendto FAILED: %s (errno %d)\n", strerror(errno),
		       errno);
		free(buf);
		return 1;
	}
	printf("sent %zd  ", n);
	fflush(stdout);

	/* Drain until our txn's response or a 3 s silence. */
	for (;;) {
		ret = poll(&pfd, 1, 3000);
		if (ret <= 0) {
			printf("NO RESPONSE (timeout)\n");
			free(buf);
			return 2;
		}
		n = recv(fd, resp, sizeof(resp), 0);
		if (n < 7) {
			printf("short recv %zd\n", n);
			continue;
		}
		if (resp[0] != 0x02 || (resp[1] | resp[2] << 8) != txn) {
			printf("(skipped type %u txn %u) ", resp[0],
			       resp[1] | resp[2] << 8);
			continue;
		}
		break;
	}
	/* resp: 7-byte hdr, then TLV 0x02 (result u16, error u16) */
	if (n >= 14 && resp[7] == 0x02)
		printf("response %zd B: result=%u error=%u%s\n", n,
		       resp[10] | resp[11] << 8, resp[12] | resp[13] << 8,
		       (resp[10] | resp[11] << 8) == 0 ? " OK" : "");
	else
		printf("response %zd B (unparsed)\n", n);
	free(buf);
	return 0;
}

int main(int argc, char **argv)
{
	uint32_t service = 0x02, instance = 0x01;
	struct msm_ipc_server_info srv;
	struct sockaddr_msm_ipc dst;
	unsigned int mtu = 0;
	int fd, i, rc, argi = 1;
	uint16_t txn = 0x1000;

	if (argc > 2 && !strcmp(argv[1], "-s")) {
		service = strtoul(argv[2], NULL, 0);
		argi = 3;
	}

	fd = socket(AF_MSM_IPC, SOCK_DGRAM, 0);
	if (fd < 0) {
		perror("socket(AF_MSM_IPC)");
		return 1;
	}
	if (ioctl(fd, IPC_ROUTER_IOCTL_GET_MTU, &mtu) == 0)
		printf("router MTU (ioctl): %u\n", mtu);

	rc = lookup(fd, service, instance, &srv);
	if (rc < 0) {
		fprintf(stderr, "lookup svc 0x%x inst 0x%x: %s\n", service,
			instance, strerror(-rc));
		return 1;
	}
	printf("service 0x%x inst 0x%x -> node 0x%x port 0x%x (%d found)\n",
	       srv.service, srv.instance, srv.node_id, srv.port_id, rc);

	memset(&dst, 0, sizeof(dst));
	dst.family = AF_MSM_IPC;
	dst.address.addrtype = MSM_IPC_ADDR_ID;
	dst.address.addr.port_addr.node_id = srv.node_id;
	dst.address.addr.port_addr.port_id = srv.port_id;

	if (argi < argc) {
		for (i = argi; i < argc; i++)
			one_size(fd, &dst, atoi(argv[i]), txn++);
	} else {
		for (i = 0; default_sizes[i]; i++)
			one_size(fd, &dst, default_sizes[i], txn++);
	}
	close(fd);
	return 0;
}
