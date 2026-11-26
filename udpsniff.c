// udpsniff: 直接走 XNU BPF 的 UDP 抓包器（iOS 越狱 root 用）
// 不依赖 net/bpf.h（iOS SDK 里可能没有），结构/常量全部自定
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <sys/types.h>
#include <net/if.h>
#include <arpa/inet.h>
#include <time.h>

/* ---- BPF 最小定义（XNU 值） ---- */
struct ud_bpf_insn { u_int16_t code; u_int8_t jt; u_int8_t jf; u_int32_t k; };
struct ud_bpf_program { u_int32_t bf_len; struct ud_bpf_insn *bf_insns; };
struct ud_bpf_hdr {
    struct timeval bh_tstamp;
    u_int32_t bh_caplen;
    u_int32_t bh_datalen;
    u_int16_t bh_hdrlen;
};

#define BPF_ALIGNMENT 8
#define WORDALIGN(x) (((x) + (BPF_ALIGNMENT - 1)) & ~(BPF_ALIGNMENT - 1))

#define BIOCGBLEN   _IOR('B', 102, u_int)
#define BIOCSBLEN   _IOWR('B', 102, u_int)
#define BIOCSETF    _IOW('B', 103, struct ud_bpf_program)
#define BIOCSETIF   _IOW('B', 108, struct ifreq)
#define BIOCSRTIMEOUT _IOW('B', 109, struct timeval)
#define BIOCSSEESENT _IOW('B', 114, u_int)

#define I_LD 0x00
#define I_LDX 0x01
#define I_JMP 0x05
#define I_RET 0x06
#define I_ABS 0x20
#define I_B 0x10
#define I_H 0x08
#define I_W 0x00
#define I_JEQ 0x10
#define I_K 0x00

#define STMT(code, k) { (u_int16_t)(code), 0, 0, (u_int32_t)(k) }
#define JUMP(code, k, t, f) { (u_int16_t)(code), (u_int8_t)(t), (u_int8_t)(f), (u_int32_t)(k) }

static volatile int g_stop = 0;
static void on_sig(int s) { (void)s; g_stop = 1; }

static void hexdump(const unsigned char *p, int n, int maxn) {
    if (n > maxn) n = maxn;
    for (int i = 0; i < n; i++) {
        printf("%02x", p[i]);
        if ((i & 15) == 15) printf("\n");
        else if ((i & 3) == 3) printf(" ");
    }
    if (n & 15) printf("\n");
}

static void dump_pkt(const unsigned char *p, int caplen) {
    if (caplen < 34) return;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    if (p[12] == 0x08 && p[13] == 0x00) {
        if (p[23] != 17) return;
        unsigned char *ip = (unsigned char *)p + 14;
        int ihl = (ip[0] & 0xf) * 4;
        if (caplen < 14 + ihl + 8) return;
        unsigned char *udp = ip + ihl;
        int sport = (udp[0] << 8) | udp[1];
        int dport = (udp[2] << 8) | udp[3];
        int pay = caplen - 14 - ihl - 8;
        if (pay < 0) pay = 0;
        printf("%ld.%06ld %u.%u.%u.%u:%d -> %u.%u.%u.%u:%d pay=%d\n",
               (long)tv.tv_sec, (long)tv.tv_usec,
               ip[12], ip[13], ip[14], ip[15], sport,
               ip[16], ip[17], ip[18], ip[19], dport, pay);
        hexdump(udp + 8, pay, 128);
    } else if (p[12] == 0x86 && p[13] == 0xdd) {
        if (caplen < 14 + 40 + 8) return;
        if (p[20] != 17) return;
        unsigned char *udp = (unsigned char *)p + 54;
        int sport = (udp[0] << 8) | udp[1];
        int dport = (udp[2] << 8) | udp[3];
        int pay = caplen - 62;
        if (pay < 0) pay = 0;
        printf("%ld.%06ld v6:%d -> v6:%d pay=%d\n", (long)tv.tv_sec, (long)tv.tv_usec, sport, dport, pay);
        hexdump(udp + 8, pay, 128);
    } else if (caplen >= 14) {
        printf("%ld.%06ld ET=0x%02x%02x caplen=%d\n", (long)tv.tv_sec, (long)tv.tv_usec, p[12], p[13], caplen);
    }
}

int main(int argc, char **argv) {
    const char *ifname = argc > 1 ? argv[1] : "en0";
    int secs = argc > 2 ? atoi(argv[2]) : 30;
    const char *outpath = argc > 3 ? argv[3] : "/var/tmp/udp.txt";
#define STEP(fmt, ...) do { fprintf(stderr, "[STEP] " fmt "\n", ##__VA_ARGS__); fflush(stderr); } while (0)
    STEP("start uid=%d euid=%d", getuid(), geteuid());

    int fd = -1, idx = -1;
    for (int i = 0; i < 4; i++) {
        char path[32];
        snprintf(path, sizeof path, "/dev/bpf%d", i);
        fd = open(path, O_RDWR);
        if (fd >= 0) { idx = i; break; }
    }
    if (fd < 0) { fprintf(stderr, "打不开 /dev/bpf*: %s\n", strerror(errno)); return 1; }
    STEP("opened bpf%d fd=%d", idx, fd);

    u_int blen = 1 << 16;
    if (ioctl(fd, BIOCSBLEN, &blen) < 0)
        fprintf(stderr, "warn BIOCSBLEN: %s\n", strerror(errno));
    u_int real = 0;
    if (ioctl(fd, BIOCGBLEN, &real) == 0) blen = real;
    STEP("blen=%u", blen);

    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, BIOCSETIF, &ifr) < 0) {
        fprintf(stderr, "BIOCSETIF %s 失败: %s\n", ifname, strerror(errno));
        return 2;
    }
    STEP("BIOCSETIF %s ok", ifname);

    struct ud_bpf_insn insns[] = {
        STMT(I_LD + I_H + I_ABS, 12),
        JUMP(I_JMP + I_JEQ + I_K, 0x0800, 3, 0),
        STMT(I_LD + I_B + I_ABS, 23),
        JUMP(I_JMP + I_JEQ + I_K, 17, 3, 0),
        JUMP(I_JMP + I_JEQ + I_K, 0x86dd, 0, 4),
        STMT(I_LD + I_B + I_ABS, 20),
        JUMP(I_JMP + I_JEQ + I_K, 17, 1, 0),
        STMT(I_RET + I_K, 262144),
        STMT(I_RET + I_K, 0),
    };
    struct ud_bpf_program prog;
    prog.bf_len = sizeof(insns) / sizeof(insns[0]);
    prog.bf_insns = insns;
    if (ioctl(fd, BIOCSETF, &prog) < 0)
        fprintf(stderr, "warn BIOCSETF: %s\n", strerror(errno));
    STEP("BIOCSETF ok");

    struct timeval tv = { 1, 0 };
    if (ioctl(fd, BIOCSRTIMEOUT, &tv) < 0)
        fprintf(stderr, "warn BIOCSRTIMEOUT: %s\n", strerror(errno));
    STEP("timeout ok");
    u_int seesent = 1;
    if (ioctl(fd, BIOCSSEESENT, &seesent) < 0)
        fprintf(stderr, "warn BIOCSSEESENT: %s\n", strerror(errno));
    STEP("seesent ok");

    unsigned char *buf = malloc(blen);
    if (!buf) return 3;

    FILE *out = NULL;
    int s1 = -1;
    if (strcmp(outpath, "-") != 0) {
        out = fopen(outpath, "w");
        if (!out) { fprintf(stderr, "打不开 %s: %s\n", outpath, strerror(errno)); return 4; }
        s1 = dup(1);
        dup2(fileno(out), 1);
    }
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    time_t t0 = time(NULL);
    fprintf(stderr, "udpsniff: if=%s secs=%d out=%s dev=bpf%d blen=%u\n", ifname, secs, outpath, idx, blen);
    long nread = 0, nhit = 0, nbytes = 0;
    int rawmode = !strcmp(outpath, "RAW");
    time_t last = t0;
    while (!g_stop && (time(NULL) - t0) < secs) {
        int n = read(fd, buf, blen);
        nread++;
        if (n > 0) { nhit++; nbytes += n; }
        if (time(NULL) != last) {
            fprintf(stderr, "[STAT] reads=%ld nonzero=%ld bytes=%ld\n", nread, nhit, nbytes);
            fflush(stderr);
            last = time(NULL);
        }
        if (n <= 0) continue;
        if (rawmode) {
            printf("--- READ n=%d\n", n);
            fflush(stdout);
            hexdump(buf, n < 256 ? n : 256, 256);
            fflush(stdout);
            continue;
        }
        unsigned char *p = buf;
        while (p + sizeof(struct ud_bpf_hdr) <= buf + n) {
            struct ud_bpf_hdr *h = (struct ud_bpf_hdr *)p;
            if (h->bh_caplen > 0 && h->bh_hdrlen + h->bh_caplen <= (u_int32_t)(buf + n - p))
                dump_pkt(p + h->bh_hdrlen, (int)h->bh_caplen);
            int next = WORDALIGN(h->bh_hdrlen + h->bh_caplen);
            if (next <= 0) break;
            p += next;
        }
        fflush(stdout);
    }
    fflush(stdout);
    if (out) { dup2(s1, 1); fclose(out); }
    close(fd);
    fprintf(stderr, "udpsniff: done pkts_out\n");
    return 0;
}
