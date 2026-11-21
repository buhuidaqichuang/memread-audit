#include "memread_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>
#include <mach/vm_prot.h>

// libproc 是 iOS 私有头，但符号在 libSystem 里，手动声明即可
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);

// iOS SDK 的 <mach/mach_vm.h> 被 #error 屏蔽，但符号在 libSystem 里，手动声明
extern kern_return_t mach_vm_region(
    vm_map_t target_task,
    mach_vm_address_t *address,
    mach_vm_size_t *size,
    vm_region_flavor_t flavor,
    vm_region_info_t info,
    mach_msg_type_number_t *infoCnt,
    mach_port_t *object_name);

extern kern_return_t mach_vm_read_overwrite(
    vm_map_t target_task,
    mach_vm_address_t address,
    mach_vm_size_t size,
    mach_vm_address_t data,
    mach_vm_size_t *outsize);

// 判断一段缓冲区是否全零（按 8 字节步进，足够快）
static int all_zero(const unsigned char *p, size_t n) {
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        uint64_t v = 0;
        memcpy(&v, p + i, 8);
        if (v) return 0;
    }
    for (; i < n; i++) {
        if (p[i]) return 0;
    }
    return 1;
}

int memread_dump_ex(pid_t pid, const char *out_path, int rw_only,
                    memread_region_cb cb, void *ctx) {
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "task_for_pid 失败: (%d) %s\n", kr, mach_error_string(kr));
        return -1;
    }

    FILE *f = fopen(out_path, "wb");
    if (!f) { perror("fopen"); return -2; }

    // 4MB 分块：既降低单次分配的失败率，也让进度能持续回调
    const mach_vm_size_t CHUNK = 4ULL * 1024 * 1024;
    unsigned char *buf = (unsigned char *)malloc((size_t)CHUNK);
    if (!buf) { fclose(f); return -4; }

    mach_vm_address_t addr = 0;
    unsigned long long total = 0;
    unsigned long long skipped_total = 0;
    int regions = 0;

    while (1) {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;

        kr = mach_vm_region(task, &addr, &size, VM_REGION_BASIC_INFO_64,
                            (vm_region_info_t)&info, &cnt, &obj);
        if (kr != KERN_SUCCESS || size == 0) break;

        int readable = (info.protection & VM_PROT_READ) != 0;
        int writable = (info.protection & VM_PROT_WRITE) != 0;
        int shared = info.shared;  /* boolean_t，iOS SDK 无 share_mode 字段 */

        if (readable && !shared && (!rw_only || writable) &&
            size <= (mach_vm_size_t)(512ULL * 1024 * 1024)) {
            regions++;
            mach_vm_address_t off = 0;
            while (off < size) {
                mach_vm_size_t cur = (size - off > CHUNK) ? CHUNK : (size - off);
                mach_vm_size_t got = 0;
                kr = mach_vm_read_overwrite(task, addr + off, cur,
                                            (mach_vm_address_t)buf, &got);
                int ok = (kr == KERN_SUCCESS && got == cur);
                int skipped = 0;
                if (ok) {
                    if (all_zero(buf, (size_t)cur)) {
                        skipped = 1;
                        skipped_total += cur;
                    } else {
                        // 块内再按 4KB 页判零：整页全零就不写，dump 体积能砍掉一大半
                        const size_t PS = 4096;
                        size_t po = 0;
                        while (po < (size_t)cur) {
                            size_t pl = ((size_t)cur - po >= PS) ? PS : ((size_t)cur - po);
                            if (all_zero(buf + po, pl)) {
                                skipped_total += pl;
                            } else {
                                fwrite(buf + po, 1, pl, f);
                                total += pl;
                            }
                            po += pl;
                        }
                    }
                }
                if (cb) cb((unsigned long long)(addr + off),
                           (unsigned long long)cur,
                           total, skipped, ctx);
                off += cur;
            }
        }
        addr += size;
    }

    free(buf);
    fclose(f);
    fprintf(stderr, "读取完成: %llu 字节写入, %llu 字节零页跳过, %d 个区域 -> %s\n",
            total, skipped_total, regions, out_path);
    return total > 0 ? 0 : -3;
}

// 旧接口适配：把详细回调降级成累计字节回调
struct cb_wrap {
    void (*progress)(unsigned long long, void *);
    void *ctx;
};

static void wrap_cb(unsigned long long addr, unsigned long long chunk,
                    unsigned long long total, int skipped, void *ctx) {
    (void)addr; (void)chunk; (void)skipped;
    struct cb_wrap *w = (struct cb_wrap *)ctx;
    if (w && w->progress) w->progress(total, w->ctx);
}

int memread_dump(pid_t pid, const char *out_path, int rw_only,
                 void (*progress)(unsigned long long done, void *ctx), void *ctx) {
    struct cb_wrap w;
    w.progress = progress;
    w.ctx = ctx;
    return memread_dump_ex(pid, out_path, rw_only,
                           progress ? wrap_cb : NULL,
                           progress ? &w : NULL);
}

// ===== 扫描模式 =====

#define SCAN_MIN_LEN 6
#define SCAN_MAX_STR 400
#define SCAN_CTX 64
#define SCAN_MAX_DETAIL 2000
#define DEDUP_N 8192

static int ascii_printable(unsigned char c) {
    return c >= 0x20 && c < 0x7F;
}

static uint64_t fnv1a(const void *data, size_t n) {
    const unsigned char *p = (const unsigned char *)data;
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) {
        h ^= p[i];
        h *= 1099511628211ULL;
    }
    return h;
}

// 上下文里是否出现敏感键名（不区分大小写，ctx 最多 SCAN_CTX 字节）
static int ctx_has_word(const char *ctx, size_t n) {
    static const char *words[] = {
        "token", "password", "passwd", "secret", "apikey", "api_key",
        "authorization", "cookie", "session", "bearer", "private", "encrypt",
        "aes", "iv", "credential", "auth", NULL
    };
    if (n == 0) return 0;
    char low[SCAN_CTX + 1];
    size_t m = n > SCAN_CTX ? SCAN_CTX : n;
    for (size_t i = 0; i < m; i++) {
        char c = ctx[i];
        low[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
    }
    low[m] = 0;
    for (int i = 0; words[i]; i++) {
        if (strstr(low, words[i])) return 1;
    }
    return 0;
}

static int is_jwt(const char *s, size_t n) {
    if (n < 32 || strncmp(s, "eyJ", 3) != 0) return 0;
    int dots = 0;
    for (size_t i = 0; i < n; i++) if (s[i] == '.') dots++;
    return dots >= 2;
}

static int is_pem(const char *s, size_t n) {
    return (strstr(s, "PRIVATE KEY") != NULL || strstr(s, "BEGIN OPENSSH") != NULL);
}

static int is_b64ish(const char *s, size_t n) {
    int pad = 0;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        int ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                 (c >= '0' && c <= '9') || c == '+' || c == '/' || c == '=' ||
                 c == '-' || c == '_';
        if (c == '=') pad++;
        if (!ok) return 0;
    }
    return pad <= 2;
}

static int is_hexish(const char *s, size_t n) {
    int digits = 0, alpha = 0;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        if (c >= '0' && c <= '9') { digits++; continue; }
        if ((c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) { alpha++; continue; }
        return 0;
    }
    return digits > 0 && alpha > 0;
}

static int is_email(const char *s, size_t n) {
    const char *at = strchr(s, '@');
    if (!at || at == s) return 0;
    if (strchr(at + 1, '.') == NULL) return 0;
    if (strchr(s, ' ') || strchr(s, '\t')) return 0;
    if (n < 6 || n > 254) return 0;
    return 1;
}

static int is_url(const char *s) {
    return strncmp(s, "http://", 7) == 0 || strncmp(s, "https://", 8) == 0;
}

static int is_cn_phone(const char *s) {
    // 允许 +86 / 86 前缀，主体 1[3-9] + 9 位
    const char *p = s;
    int digits = 0;
    if (*p == '+') p++;
    for (; *p; p++) {
        if (*p >= '0' && *p <= '9') { digits++; continue; }
        if (*p == ' ' || *p == '-') continue;
        return 0;
    }
    if (digits < 11) return 0;
    const char *body = s;
    while (*body && !(*body >= '0' && *body <= '9')) body++;
    while (*body == '0' || *body == '8' || *body == '6') body++;  // 跳过 86 前缀的首位 8/6
    if (*body != '1') return 0;
    if (body[1] < '3' || body[1] > '9') return 0;
    return digits == 11 || digits == 13;
}

static int luhn_ok(const int *d, int n) {
    int sum = 0, alt = 0;
    for (int i = n - 1; i >= 0; i--) {
        int v = d[i];
        if (alt) { v *= 2; if (v > 9) v -= 9; }
        sum += v;
        alt = !alt;
    }
    return (sum % 10) == 0;
}

static int is_card_number(const char *s) {
    int d[32], n = 0;
    for (const char *p = s; *p; p++) {
        if (*p >= '0' && *p <= '9') {
            if (n >= 32) return 0;
            d[n++] = *p - '0';
        } else if (*p == ' ' || *p == '-') {
            continue;
        } else {
            return 0;
        }
    }
    if (n < 16 || n > 19) return 0;
    return luhn_ok(d, n);
}

static int is_idcard(const char *s) {
    size_t n = strlen(s);
    if (n != 18) return 0;
    for (int i = 0; i < 17; i++) {
        if (!(s[i] >= '0' && s[i] <= '9')) return 0;
    }
    char c = s[17];
    return (c >= '0' && c <= '9') || c == 'X' || c == 'x';
}

// 返回值：档位 0=A 1=B 2=C 3=D；conf: 0=high 1=medium 2=low
static int classify(const char *s, size_t n, const char *ctx, size_t ctxn,
                    int *conf, const char **type) {
    *conf = 1;
    if (is_jwt(s, n)) { *conf = 0; *type = "jwt"; return 0; }
    if (strstr(s, "Bearer ")) { *conf = 0; *type = "bearer"; return 0; }
    if (is_pem(s, n)) { *conf = 0; *type = "private-key"; return 0; }
    if (strncmp(s, "AKIA", 4) == 0 && n >= 20) { *conf = 0; *type = "aws-access-key"; return 0; }
    if (strncmp(s, "ghp_", 4) == 0 || strncmp(s, "github_pat_", 11) == 0) { *conf = 0; *type = "github-token"; return 0; }
    if (strncmp(s, "xoxb-", 5) == 0 || strncmp(s, "xoxp-", 5) == 0) { *conf = 0; *type = "slack-token"; return 0; }
    if (strncmp(s, "ya29.", 5) == 0) { *conf = 0; *type = "oauth-token"; return 0; }
    if ((is_hexish(s, n) || is_b64ish(s, n)) && n >= 20 && ctx_has_word(ctx, ctxn)) {
        *conf = 0; *type = (n >= 32) ? "secret(hex/b64)" : "secret"; return 0;
    }
    if (is_email(s, n)) { *conf = 0; *type = "email"; return 1; }
    if (is_cn_phone(s)) { *conf = 0; *type = "phone"; return 1; }
    if (is_card_number(s)) { *conf = 0; *type = "card"; return 1; }
    if (is_idcard(s)) { *conf = 0; *type = "idcard"; return 1; }
    if (is_url(s)) { *conf = 1; *type = "url"; return 2; }
    if (strncmp(s, "sk-", 3) == 0 && n >= 20) { *conf = 0; *type = "openai-key"; return 0; }
    if ((is_hexish(s, n) || is_b64ish(s, n)) && n >= 24) {
        *conf = 2; *type = "opaque-blob"; return 2;
    }
    *conf = 2;
    *type = "string";
    return 3;
}

int memread_scan_ex(pid_t pid, const char *out_path, const char *label, int rw_only,
                    memread_region_cb cb, void *ctx,
                    unsigned long long hits[4]) {
    for (int i = 0; i < 4; i++) if (hits) hits[i] = 0;

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "task_for_pid 失败: (%d) %s\n", kr, mach_error_string(kr));
        return -1;
    }

    FILE *f = fopen(out_path, "w");
    if (!f) { perror("fopen"); return -2; }

    struct tm tmv;
    time_t now = time(NULL);
    localtime_r(&now, &tmv);
    fprintf(f, "# MemRead scan\n");
    fprintf(f, "# time=%04d-%02d-%02d %02d:%02d:%02d\n",
            tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
            tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
    fprintf(f, "# app=%s\n", label ? label : "(unknown)");
    fprintf(f, "# mode=%s\n\n", rw_only ? "rw-only" : "all-readable");

    const mach_vm_size_t CHUNK = 4ULL * 1024 * 1024;
    unsigned char *buf = (unsigned char *)malloc((size_t)CHUNK);
    if (!buf) { fclose(f); return -4; }

    static uint64_t dedup[DEDUP_N];
    memset(dedup, 0, sizeof(dedup));
    unsigned long long written = 0;
    unsigned long long bytes = 0;
    int regions = 0;
    mach_vm_address_t addr = 0;

    while (1) {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;

        kr = mach_vm_region(task, &addr, &size, VM_REGION_BASIC_INFO_64,
                            (vm_region_info_t)&info, &cnt, &obj);
        if (kr != KERN_SUCCESS || size == 0) break;

        int readable = (info.protection & VM_PROT_READ) != 0;
        int writable = (info.protection & VM_PROT_WRITE) != 0;
        int shared = info.shared;

        if (readable && !shared && (!rw_only || writable) &&
            size <= (mach_vm_size_t)(512ULL * 1024 * 1024)) {
            regions++;
            mach_vm_address_t off = 0;
            while (off < size) {
                mach_vm_size_t cur = (size - off > CHUNK) ? CHUNK : (size - off);
                mach_vm_size_t got = 0;
                kr = mach_vm_read_overwrite(task, addr + off, cur,
                                            (mach_vm_address_t)buf, &got);
                if (kr == KERN_SUCCESS && got == cur) {
                    bytes += cur;
                    size_t i = 0;
                    while (i < (size_t)cur) {
                        if (!ascii_printable(buf[i])) { i++; continue; }
                        size_t j = i;
                        while (j < (size_t)cur && ascii_printable(buf[j])) j++;
                        size_t len = j - i;
                        if (len >= SCAN_MIN_LEN) {
                            char tmp[SCAN_MAX_STR + 1];
                            size_t n = len > SCAN_MAX_STR ? SCAN_MAX_STR : len;
                            memcpy(tmp, buf + i, n);
                            tmp[n] = 0;

                            char cbuf[SCAN_CTX + 1];
                            size_t cn = 0;
                            if (i >= SCAN_CTX) {
                                memcpy(cbuf, buf + i - SCAN_CTX, SCAN_CTX);
                                cn = SCAN_CTX;
                            } else if (i > 0) {
                                memcpy(cbuf, buf, i);
                                cn = i;
                            }
                            cbuf[cn] = 0;

                            int conf = 1;
                            const char *type = "string";
                            int tier = classify(tmp, n, cbuf, cn, &conf, &type);
                            if (hits) hits[tier]++;

                            if (tier < 3 && written < SCAN_MAX_DETAIL) {
                                uint64_t h = fnv1a(tmp, n);
                                int seen = 0;
                                for (int k = 0; k < 64; k++) {
                                    size_t idx = (size_t)((h + (uint64_t)k) % DEDUP_N);
                                    if (dedup[idx] == 0) {
                                        dedup[idx] = h ? h : 1;
                                        break;
                                    }
                                    if (dedup[idx] == h) { seen = 1; break; }
                                }
                                if (!seen) {
                                    static const char tierc[4] = {'A', 'B', 'C', 'D'};
                                    static const char *confc[3] = {"high", "medium", "low"};
                                    fprintf(f, "[%c/%s] 0x%08llX len=%zu %s\n    %s\n",
                                            tierc[tier], confc[conf],
                                            (unsigned long long)(addr + off + i),
                                            len, type, tmp);
                                    written++;
                                }
                            }
                        }
                        i = j + 1;
                    }
                }
                if (cb) cb((unsigned long long)(addr + off), (unsigned long long)cur, bytes, 0, ctx);
                off += cur;
            }
        }
        addr += size;
    }

    fprintf(f, "\n# scanned=%llu bytes  regions=%d  A=%llu B=%llu C=%llu D=%llu  detail=%llu\n",
            bytes, regions,
            (unsigned long long)(hits ? hits[0] : 0),
            (unsigned long long)(hits ? hits[1] : 0),
            (unsigned long long)(hits ? hits[2] : 0),
            (unsigned long long)(hits ? hits[3] : 0),
            written);

    free(buf);
    fclose(f);
    fprintf(stderr, "扫描完成: %llu 字节, %d 区域, A=%llu B=%llu C=%llu -> %s\n",
            bytes, regions,
            (unsigned long long)(hits ? hits[0] : 0),
            (unsigned long long)(hits ? hits[1] : 0),
            (unsigned long long)(hits ? hits[2] : 0),
            out_path);
    return 0;
}

int memread_list_procs(pid_t *pids, int max) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) < 0) return 0;

    struct kinfo_proc *kp = (struct kinfo_proc *)malloc(len);
    if (!kp) return 0;
    if (sysctl(mib, 4, kp, &len, NULL, 0) < 0) { free(kp); return 0; }

    int count = (int)(len / sizeof(struct kinfo_proc));
    int n = 0;
    for (int i = 0; i < count && n < max; i++) {
        pid_t p = kp[i].kp_proc.p_pid;
        if (p > 0) pids[n++] = p;
    }
    free(kp);
    return n;
}

int memread_proc_path(pid_t pid, char *buf, size_t bufsz) {
    return proc_pidpath(pid, buf, (uint32_t)bufsz);
}


// ================= 文本提取模式 =================
// 只把可打印 ASCII 串连同虚拟地址写出，体积通常只有原始 dump 的百分之几
int memread_strings_ex(pid_t pid, const char *out_path, int rw_only, int min_len,
                       memread_region_cb cb, void *ctx) {
    if (min_len < 3) min_len = 3;

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "task_for_pid 失败: (%d) %s\n", kr, mach_error_string(kr));
        return -1;
    }

    FILE *f = fopen(out_path, "wb");
    if (!f) { perror("fopen"); return -2; }

    time_t now = time(NULL);
    struct tm *tmv = localtime(&now);
    fprintf(f, "# memread strings  pid=%d  %04d-%02d-%02d %02d:%02d:%02d  minlen=%d  mode=%s\n",
            pid, tmv ? tmv->tm_year + 1900 : 0, tmv ? tmv->tm_mon + 1 : 0, tmv ? tmv->tm_mday : 0,
            tmv ? tmv->tm_hour : 0, tmv ? tmv->tm_min : 0, tmv ? tmv->tm_sec : 0,
            min_len, rw_only ? "rw-only" : "all-readable");
    fprintf(f, "# 每行： 0x<虚拟地址>\t<字符串>\n\n");

    const mach_vm_size_t CHUNK = 4ULL * 1024 * 1024;
    unsigned char *buf = (unsigned char *)malloc((size_t)CHUNK);
    if (!buf) { fclose(f); return -4; }

    enum { MAXS = 512 };
    char partial[MAXS];
    size_t plen = 0;
    unsigned long long paddr = 0;
    unsigned long long hits = 0;
    unsigned long long bytes = 0;
    int regions = 0;
    mach_vm_address_t addr = 0;

    while (1) {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;

        kr = mach_vm_region(task, &addr, &size, VM_REGION_BASIC_INFO_64,
                            (vm_region_info_t)&info, &cnt, &obj);
        if (kr != KERN_SUCCESS || size == 0) break;

        int readable = (info.protection & VM_PROT_READ) != 0;
        int writable = (info.protection & VM_PROT_WRITE) != 0;
        int shared = info.shared;

        if (readable && !shared && (!rw_only || writable) &&
            size <= (mach_vm_size_t)(512ULL * 1024 * 1024)) {
            regions++;
            mach_vm_address_t off = 0;
            while (off < size) {
                mach_vm_size_t cur = (size - off > CHUNK) ? CHUNK : (size - off);
                mach_vm_size_t got = 0;
                kr = mach_vm_read_overwrite(task, addr + off, cur,
                                            (mach_vm_address_t)buf, &got);
                if (kr == KERN_SUCCESS && got == cur && !all_zero(buf, (size_t)cur)) {
                    bytes += cur;
                    size_t i = 0;
                    while (i < (size_t)cur) {
                        unsigned char c = buf[i];
                        int okch = (c >= 0x20 && c < 0x7f) || c == '\t';
                        if (okch) {
                            if (plen == 0) paddr = (unsigned long long)(addr + off + i);
                            if (plen < (size_t)MAXS - 1) {
                                partial[plen++] = (char)c;
                            } else {
                                partial[plen] = 0;
                                fprintf(f, "0x%016llX\t%s\n", paddr, partial);
                                hits++;
                                plen = 0;
                                paddr = (unsigned long long)(addr + off + i);
                                partial[plen++] = (char)c;
                            }
                        } else {
                            if (plen >= (size_t)min_len) {
                                partial[plen] = 0;
                                fprintf(f, "0x%016llX\t%s\n", paddr, partial);
                                hits++;
                            }
                            plen = 0;
                        }
                        i++;
                    }
                }
                if (cb) cb((unsigned long long)(addr + off),
                           (unsigned long long)cur, bytes, 0, ctx);
                off += cur;
            }
            if (plen >= (size_t)min_len) {
                partial[plen] = 0;
                fprintf(f, "0x%016llX\t%s\n", paddr, partial);
                hits++;
            }
            plen = 0;
        }
        addr += size;
    }

    free(buf);
    fclose(f);
    fprintf(stderr, "文本提取完成: 扫描 %llu 字节, 命中 %llu 条, %d 个区域 -> %s\n",
            bytes, hits, regions, out_path);
    return hits > 0 ? 0 : -3;
}
