#include "memread_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <time.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/statvfs.h>
#include <fcntl.h>
#include <unistd.h>
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

// 上下文里是否出现"电话"语义（用来把孤立 11 位数字与真号码区分开）
static int ctx_has_phone_word(const char *ctx, size_t n) {
    static const char *words[] = {
        "phone", "mobile", "msisdn", "tel", "telephone", "contact", NULL
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

// 严格 base64：只认标准字符集，不含 _ / - / ，避免把 UE/SDK 标识符、路径当成密钥
static int is_b64ish(const char *s, size_t n) {
    int pad = 0;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        int ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                 (c >= '0' && c <= '9') || c == '+' || c == '=';
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
    if (n < 6 || n > 254) return 0;
    const char *at = strchr(s, '@');
    if (!at || at == s) return 0;
    if (strchr(at + 1, '@')) return 0;                 // 只能有一个 @
    for (const char *p = s; p < at; p++) {             // 本地部分：只允许合法字符
        char c = *p;
        int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                 (c >= '0' && c <= '9') || c == '.' || c == '_' ||
                 c == '%' || c == '+' || c == '-';
        if (!ok) return 0;
    }
    const char *d = at + 1;                            // 域名部分
    if (!*d) return 0;
    const char *lastdot = NULL;
    for (const char *p = d; *p; p++) {
        char c = *p;
        if (c == '.') { lastdot = p; continue; }
        int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                 (c >= '0' && c <= '9') || c == '-';
        if (!ok) return 0;
    }
    if (!lastdot || lastdot == d) return 0;
    const char *tld = lastdot + 1;
    size_t tl = strlen(tld);
    if (tl < 2 || tl > 10) return 0;
    for (const char *p = tld; *p; p++) {               // TLD 必须是纯字母
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z'))) return 0;
    }
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

// 纯数字长串：12 位以上、又不是手机号/卡号/身份证的那种（编号、密钥、随机数字）
static int is_digits_only(const char *s, size_t n) {
    if (n < 12 || n > 512) return 0;
    for (size_t i = 0; i < n; i++) {
        if (s[i] < '0' || s[i] > '9') return 0;
    }
    return 1;
}

// 混合随机串：12 字符以上、无空格、同时含字母和数字（自写密钥最常见的形态）
static int is_mixed_token(const char *s, size_t n) {
    if (n < 12 || n > 200) return 0;
    int hasLower = 0, hasUpper = 0, hasDigit = 0;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        if (c == ' ' || c == '\t') return 0;
        if (c >= 'a' && c <= 'z') hasLower = 1;
        else if (c >= 'A' && c <= 'Z') hasUpper = 1;
        else if (c >= '0' && c <= '9') hasDigit = 1;
    }
    if (!hasDigit) return 0;
    return (hasLower || hasUpper) ? 1 : 0;
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
    // 手机号：只有周围出现 phone/mobile/tel 这类语义才算高可信；孤立数字串降到 B 档
    if (is_cn_phone(s)) {
        if (ctx_has_phone_word(ctx, ctxn)) { *conf = 0; *type = "phone"; return 0; }
        *conf = 1; *type = "phone(no-ctx)"; return 1;
    }
    if (is_card_number(s)) { *conf = 0; *type = "card"; return 0; }
    if (is_idcard(s)) { *conf = 0; *type = "idcard"; return 0; }
    // 自写密钥最常落在这一档：纯数字长串 / 字母数字混合长串
    if (is_digits_only(s, n)) { *conf = 2; *type = "digits"; return 2; }
    if (is_mixed_token(s, n)) { *conf = 2; *type = "mixed-token"; return 2; }
    if (is_url(s)) { *conf = 1; *type = "url"; return 2; }
    if (strncmp(s, "sk-", 3) == 0 && n >= 20) { *conf = 0; *type = "openai-key"; return 0; }
    if ((is_hexish(s, n) || is_b64ish(s, n)) && n >= 24) {
        *conf = 2; *type = "opaque-blob"; return 2;
    }
    *conf = 2;
    *type = "string";
    return 3;
}

// ---- 扫描结果收集：同一个值只留一条并记出现次数，扫完按“独特程度”排序输出 ----
#define SCAN_HASH_N 16384
#define SCAN_ENTS_MAX (SCAN_MAX_DETAIL * 3)

typedef struct {
    int tier;
    int conf;
    const char *type;
    unsigned long long addr;
    size_t len;
    unsigned count;
    char *val;
} scan_ent_t;

static scan_ent_t *g_scanEnts = NULL;

static int scan_ent_cmp(const void *a, const void *b) {
    int ia = *(const int *)a, ib = *(const int *)b;
    const scan_ent_t *x = &g_scanEnts[ia];
    const scan_ent_t *y = &g_scanEnts[ib];
    if (x->count != y->count) return (x->count < y->count) ? -1 : 1;  // 只出现 1 次的更可能是“独有值”
    if (x->len != y->len) return (x->len > y->len) ? -1 : 1;          // 同频次时长的在前
    return 0;
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

    // 分档临时文件不再使用：结果先在内存里去重收集，扫完统一排序写盘
    struct tm tmv;
    time_t now = time(NULL);
    localtime_r(&now, &tmv);
    fprintf(f, "# MemRead scan\n");
    fprintf(f, "# time=%04d-%02d-%02d %02d:%02d:%02d\n",
            tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
            tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
    fprintf(f, "# app=%s\n", label ? label : "(unknown)");
    fprintf(f, "# mode=%s\n", rw_only ? "rw-only" : "all-readable");
    fprintf(f, "# 分级：A=高可信(凭证/密钥/手机号/银行卡/身份证)  B=中等(邮箱等身份信息)  "
               "C=疑似值(URL/hex-base64 blob/纯数字长串/字母数字混合串)  D=普通字符串(只计数不列明细)\n\n");

    const mach_vm_size_t CHUNK = 4ULL * 1024 * 1024;
    unsigned char *buf = (unsigned char *)malloc((size_t)CHUNK);
    if (!buf) { fclose(f); return -4; }

    scan_ent_t *ents = (scan_ent_t *)calloc(SCAN_ENTS_MAX, sizeof(scan_ent_t));
    if (!ents) { free(buf); fclose(f); return -4; }
    static uint32_t htab[SCAN_HASH_N];
    memset(htab, 0, sizeof(htab));
    int entCount = 0;
    unsigned long long tierCap[3] = {0, 0, 0};
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

                            // A/B/C 档收集进内存（按值去重，记次数）；D 档只计数
                            if (tier < 3) {
                                uint64_t h = fnv1a(tmp, n);
                                uint32_t slot = (uint32_t)(h & (SCAN_HASH_N - 1));
                                for (int k = 0; k < 256; k++) {
                                    uint32_t s2 = (uint32_t)((slot + (uint32_t)k) & (SCAN_HASH_N - 1));
                                    if (htab[s2] == 0) {
                                        if (tierCap[tier] >= (unsigned long long)SCAN_MAX_DETAIL) break;
                                        scan_ent_t *e = &ents[entCount];
                                        e->tier = tier;
                                        e->conf = conf;
                                        e->type = type;
                                        e->addr = (unsigned long long)(addr + off + i);
                                        e->len = n;
                                        e->count = 1;
                                        e->val = (char *)malloc(n + 1);
                                        if (!e->val) break;
                                        memcpy(e->val, tmp, n + 1);
                                        htab[s2] = (uint32_t)(entCount + 1);
                                        entCount++;
                                        tierCap[tier]++;
                                        break;
                                    }
                                    scan_ent_t *e2 = &ents[htab[s2] - 1];
                                    if (e2->len == n && memcmp(e2->val, tmp, n) == 0) {
                                        e2->count++;
                                        break;
                                    }
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

    // 扫完统一输出：按 A → B → C 分节，节内按“出现次数少、长度长”排序（独特值排最前）
    static const char tierc[4] = {'A', 'B', 'C', 'D'};
    static const char *confc[3] = {"high", "medium", "low"};
    static const char *tierTitle[3] = {
        "A 档（高可信：密钥 / 凭证 / 手机号 / 银行卡 / 身份证）",
        "B 档（中等：邮箱等个人身份信息）",
        "C 档（低可信：URL / 疑似 blob / 纯数字长串 / 字母数字混合串）"
    };

    unsigned long long written_total = 0;
    int *idxs = (int *)malloc(sizeof(int) * (size_t)SCAN_MAX_DETAIL);
    g_scanEnts = ents;

    for (int t = 0; t < 3; t++) {
        fprintf(f, "\n========== %s ==========\n", tierTitle[t]);
        if (tierCap[t] == 0) {
            fprintf(f, "（本档无命中）\n");
            continue;
        }
        int ni = 0;
        for (int i = 0; i < entCount && ni < SCAN_MAX_DETAIL; i++) {
            if (ents[i].tier == t) idxs[ni++] = i;
        }
        if (idxs) qsort(idxs, (size_t)ni, sizeof(int), scan_ent_cmp);
        for (int k = 0; k < ni; k++) {
            scan_ent_t *e = &ents[idxs[k]];
            fprintf(f, "[%c/%s] 0x%016llX len=%zu 出现%u次  %s\n    %s\n",
                    tierc[t], confc[e->conf], e->addr, e->len, e->count, e->type, e->val);
            written_total++;
        }
    }
    if (idxs) free(idxs);

    // 类型汇总：一眼看出这堆东西都是什么，不用逐条翻
    {
        const char *tnames[64];
        unsigned long long tcnt[64], tex[64];
        int tn = 0;
        for (int i = 0; i < entCount; i++) {
            int found = -1;
            for (int j = 0; j < tn; j++) {
                if (strcmp(tnames[j], ents[i].type) == 0) { found = j; break; }
            }
            if (found < 0 && tn < 64) {
                tnames[tn] = ents[i].type;
                tcnt[tn] = 0;
                tex[tn] = 0;
                found = tn++;
            }
            if (found >= 0) {
                tcnt[found]++;
                if (ents[i].count == 1) tex[found]++;
            }
        }
        fprintf(f, "\n========== 类型汇总（unique = 只出现 1 次的条数，通常最值得看）==========\n");
        for (int i = 0; i < tn; i++) {
            for (int j = i + 1; j < tn; j++) {
                if (tcnt[j] > tcnt[i]) {
                    const char *tn2 = tnames[i]; tnames[i] = tnames[j]; tnames[j] = tn2;
                    unsigned long long tc = tcnt[i]; tcnt[i] = tcnt[j]; tcnt[j] = tc;
                    unsigned long long te = tex[i]; tex[i] = tex[j]; tex[j] = te;
                }
            }
        }
        for (int i = 0; i < tn; i++) {
            fprintf(f, "  %-14s %5llu 条   unique=%llu\n", tnames[i], tcnt[i], tex[i]);
        }
    }

    fprintf(f, "\n# scanned=%llu bytes  regions=%d  A=%llu B=%llu C=%llu D=%llu  detail=%llu  unique_values=%d\n",
            bytes, regions,
            (unsigned long long)(hits ? hits[0] : 0),
            (unsigned long long)(hits ? hits[1] : 0),
            (unsigned long long)(hits ? hits[2] : 0),
            (unsigned long long)(hits ? hits[3] : 0),
            written_total, entCount);

    for (int i = 0; i < entCount; i++) if (ents[i].val) free(ents[i].val);
    free(ents);
    free(buf);
    fclose(f);
    fprintf(stderr, "扫描完成: %llu 字节, %d 区域, A=%llu B=%llu C=%llu D=%llu, 唯一值 %d -> %s\n",
            bytes, regions,
            (unsigned long long)(hits ? hits[0] : 0),
            (unsigned long long)(hits ? hits[1] : 0),
            (unsigned long long)(hits ? hits[2] : 0),
            (unsigned long long)(hits ? hits[3] : 0),
            entCount, out_path);
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

// ================= 关键词精确搜索 =================
// 用途：自己往内存里写了一个值（密钥 / 标记串），想确认它到底在不在目标进程里
// 扫描时无论内容长什么样都会被找出来（不受 A/B/C/D 分级规则限制）

#define FIND_MAX_HITS 500

static int find_hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// "DE AD BE EF" / "deadbeef" / "0xdeadbeef" → 字节
static int find_parse_hex(const char *s, unsigned char *out, size_t cap, size_t *outn) {
    size_t n = 0;
    const char *p = s;
    while (*p) {
        if (*p == ' ' || *p == '\t' || *p == ':' || *p == ',' || *p == '\n' || *p == '-') { p++; continue; }
        if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) { p += 2; continue; }
        int hi = find_hexval(p[0]);
        if (hi < 0) return -1;
        int lo = find_hexval(p[1]);
        if (lo < 0) return -1;
        if (n >= cap) return -1;
        out[n++] = (unsigned char)((hi << 4) | lo);
        p += 2;
    }
    *outn = n;
    return n > 0 ? 0 : -1;
}

static void find_lower(unsigned char *dst, const unsigned char *src, size_t n) {
    for (size_t i = 0; i < n; i++) {
        unsigned char c = src[i];
        dst[i] = (c >= 'A' && c <= 'Z') ? (unsigned char)(c + 32) : c;
    }
}

int memread_find_ex(pid_t pid, const char *out_path, const char *needle,
                    int as_hex, int fold, int rw_only,
                    memread_region_cb cb, void *ctx, unsigned long long *phits,
                    volatile int *cancel) {
    if (phits) *phits = 0;
    if (!out_path || !needle || !*needle) return -2;

    unsigned char nd[512];
    size_t nlen = 0;
    if (as_hex) {
        if (find_parse_hex(needle, nd, sizeof(nd), &nlen) != 0) return -2;
    } else {
        nlen = strlen(needle);
        if (nlen > sizeof(nd)) nlen = sizeof(nd);
        memcpy(nd, needle, nlen);
    }
    if (nlen == 0) return -2;

    unsigned char ndc[512];
    if (fold) find_lower(ndc, nd, nlen);

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
    fprintf(f, "========== 关键词搜索 ==========\n");
    fprintf(f, "# pid=%d  %04d-%02d-%02d %02d:%02d:%02d  needle=\"%s\"  mode=%s  fold=%d  scope=%s\n\n",
            pid, tmv ? tmv->tm_year + 1900 : 0, tmv ? tmv->tm_mon + 1 : 0, tmv ? tmv->tm_mday : 0,
            tmv ? tmv->tm_hour : 0, tmv ? tmv->tm_min : 0, tmv ? tmv->tm_sec : 0,
            needle, as_hex ? "hex" : "text", fold, rw_only ? "rw-only" : "all-readable");

    const mach_vm_size_t CHUNK = 4ULL * 1024 * 1024;
    unsigned char *buf = (unsigned char *)malloc((size_t)CHUNK);
    unsigned char *work = (unsigned char *)malloc((size_t)CHUNK + nlen);
    unsigned char *low = fold ? (unsigned char *)malloc((size_t)CHUNK + nlen) : NULL;
    if (!buf || !work || (fold && !low)) {
        free(buf); free(work); if (low) free(low);
        fclose(f);
        return -4;
    }

    unsigned long long nhits = 0;
    unsigned long long bytes = 0;
    int regions = 0;
    int stopped = 0;
    unsigned long long lastAbs = 0;
    int hasLast = 0;
    mach_vm_address_t addr = 0;

    while (!stopped) {
        if (cancel && *cancel) break;
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
            size_t carry = 0;

            while (off < size && !stopped) {
                if (cancel && *cancel) { stopped = 1; break; }
                mach_vm_size_t cur = (size - off > CHUNK) ? CHUNK : (size - off);
                mach_vm_size_t got = 0;
                kr = mach_vm_read_overwrite(task, addr + off, cur,
                                            (mach_vm_address_t)buf, &got);
                if (kr == KERN_SUCCESS && got > 0) {
                    memcpy(work + carry, buf, (size_t)got);
                    size_t wlen = carry + (size_t)got;
                    const unsigned char *hay = work;
                    if (fold) { find_lower(low, work, wlen); hay = low; }
                    const unsigned char *ndp = fold ? ndc : nd;

                    size_t i = carry;
                    while (i + nlen <= wlen) {
                        size_t hp = 0;
                        int found = 0;
                        size_t j = i;
                        while (j + nlen <= wlen) {
                            // 用 memchr 跳着找首字节，比逐字节比较快一个量级
                            size_t avail = wlen - j - (nlen - 1);
                            const unsigned char *p2 =
                                (const unsigned char *)memchr(hay + j, ndp[0], avail);
                            if (!p2) break;
                            j = (size_t)(p2 - hay);
                            if (memcmp(hay + j, ndp, nlen) == 0) { hp = j; found = 1; break; }
                            j++;
                        }
                        if (!found) break;

                        unsigned long long abs =
                            (unsigned long long)(addr + off - carry + hp);
                        if (!(hasLast && abs == lastAbs)) {
                            hasLast = 1; lastAbs = abs;
                            nhits++;
                            if (nhits <= FIND_MAX_HITS) {
                                fprintf(f, "0x%016llX  len=%zu\n", abs, nlen);
                                size_t hs = (hp >= 16) ? hp - 16 : 0;
                                size_t he = hp + nlen + 16;
                                if (he > wlen) he = wlen;
                                fprintf(f, "    hex: ");
                                for (size_t k = hs; k < he; k++) fprintf(f, "%02X ", work[k]);
                                fprintf(f, "\n");
                                size_t ts = hs, te = he;
                                while (ts > 0 && work[ts - 1] != '\n') ts--;
                                while (te < wlen && work[te] != '\n' && work[te] != '\r') te++;
                                fprintf(f, "    ctx: ");
                                size_t lim = ts + 160;
                                for (size_t k = ts; k < te && k < lim; k++) {
                                    unsigned char c = work[k];
                                    fputc((c >= 0x20 && c < 0x7F) ? (int)c : '.', f);
                                }
                                fprintf(f, "\n\n");
                            } else {
                                stopped = 1;
                                break;
                            }
                        }
                        i = hp + 1;
                    }

                    // 末尾 nlen-1 字节留给下一块，避免跨界命中丢
                    carry = (nlen > 1) ? nlen - 1 : 0;
                    if (carry > wlen) carry = wlen;
                    if (carry) memcpy(work, work + wlen - carry, carry);
                }
                bytes += (unsigned long long)got;
                if (cb) cb((unsigned long long)(addr + off),
                           (unsigned long long)cur, bytes, 0, ctx);
                off += cur;
            }
        }
        addr += size;
    }

    free(buf); free(work); if (low) free(low);
    fprintf(f, "\n# 命中 %llu 处%s\n",
            nhits, nhits > FIND_MAX_HITS ? "（已达上限 500，已停止扫描）" : "");
    fclose(f);
    fprintf(stderr, "关键词搜索完成: 扫描 %llu 字节, 命中 %llu 处, %d 个区域 -> %s\n",
            bytes, nhits, regions, out_path);
    if (phits) *phits = nhits;
    return 0;
}

// ================= 数值扫描 =================
// 两段式：首扫按 4/8 字节对齐收集候选（只存地址 + 上一轮值），
// 之后每轮只重读候选地址，用条件收敛。候选常驻本进程，供多轮 refine 与结果列表 peek。

#define MEMREAD_VALSCAN_MAX 2000000

typedef struct {
    uint64_t addr;
    uint64_t prev;   // 上一轮原始位：int 零扩展存值；float/double 存位模式
    int type;        // 该候选的类型（auto 扫描逐条记录；其余等于全局类型）
} memread_valent_t;

static memread_valent_t *g_valents = NULL;
static unsigned long long g_valcount = 0;

void memread_valscan_reset(void) {
    if (g_valents) { free(g_valents); g_valents = NULL; }
    g_valcount = 0;
}

unsigned long long memread_valscan_count(void) {
    return g_valcount;
}

static size_t valsize(int type) {
    return (type == MEMREAD_VALTYPE_INT64 || type == MEMREAD_VALTYPE_DOUBLE) ? 8 : 4;
}

double memread_valscan_raw2double(uint64_t raw, int type) {
    if (type == MEMREAD_VALTYPE_INT32) return (double)(int32_t)(uint32_t)raw;
    if (type == MEMREAD_VALTYPE_INT64) return (double)(int64_t)raw;
    if (type == MEMREAD_VALTYPE_FLOAT) {
        uint32_t u = (uint32_t)raw;
        float f;
        memcpy(&f, &u, 4);
        return (double)f;
    }
    double d;
    memcpy(&d, &raw, 8);
    return d;
}

static int val_read_raw(task_t task, uint64_t addr, int type, uint64_t *out) {
    size_t sz = valsize(type);
    unsigned char b[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(task, (mach_vm_address_t)addr, sz,
                                              (mach_vm_address_t)b, &got);
    if (kr != KERN_SUCCESS || got != sz) return -1;
    if (sz == 4) {
        uint32_t v;
        memcpy(&v, b, 4);
        *out = (uint64_t)v;
    } else {
        memcpy(out, b, 8);
    }
    return 0;
}

// 按地址读一个标量：给"已保存地址"页面刷新当前值用，不依赖扫描候选表
int memread_read_scalar(pid_t pid, uint64_t addr, int type, double *out_value) {
    if (type < MEMREAD_VALTYPE_INT32 || type > MEMREAD_VALTYPE_DOUBLE) return -2;
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return -1;
    uint64_t raw = 0;
    int rc = val_read_raw(task, addr, type, &raw);
    mach_port_deallocate(mach_task_self(), task);   // 逐条刷新会调用很多次，必须还端口
    if (rc != 0) return -3;
    if (out_value) *out_value = memread_valscan_raw2double(raw, type);
    return 0;
}

// 预统计与首扫完全相同的区域过滤条件，得到总量用于进度百分比（只枚举，不读内存）
int memread_writable_bytes(pid_t pid, int rw_only,
                           unsigned long long *out_bytes, unsigned long long *out_regions) {
    if (out_bytes) *out_bytes = 0;
    if (out_regions) *out_regions = 0;

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return -1;

    unsigned long long bytes = 0;
    unsigned long long regions = 0;
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
        if (readable && !info.shared && (!rw_only || writable) &&
            size <= (mach_vm_size_t)(512ULL * 1024 * 1024)) {
            bytes += size;
            regions++;
        }
        addr += size;
    }

    if (out_bytes) *out_bytes = bytes;
    if (out_regions) *out_regions = regions;
    return 0;
}

int memread_valscan_first(pid_t pid, int rw_only, int type, double value, double tol,
                          memread_region_cb cb, void *ctx,
                          unsigned long long *phits, volatile int *cancel) {
    if (phits) *phits = 0;
    if (type != MEMREAD_VALTYPE_AUTO &&
        (type < MEMREAD_VALTYPE_INT32 || type > MEMREAD_VALTYPE_DOUBLE)) return -2;
    if (tol < 0) tol = -tol;

    memread_valscan_reset();
    size_t sz = (type == MEMREAD_VALTYPE_AUTO) ? 4 : valsize(type);

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "task_for_pid 失败: (%d) %s\n", kr, mach_error_string(kr));
        return -1;
    }

    g_valents = (memread_valent_t *)calloc(MEMREAD_VALSCAN_MAX, sizeof(memread_valent_t));
    if (!g_valents) {
        mach_port_deallocate(mach_task_self(), task);
        return -4;
    }

    const mach_vm_size_t CHUNK = 4ULL * 1024 * 1024;
    unsigned char *buf = (unsigned char *)malloc((size_t)CHUNK + 8);
    if (!buf) { memread_valscan_reset(); mach_port_deallocate(mach_task_self(), task); return -4; }

    unsigned long long count = 0;
    unsigned long long bytes = 0;
    int regions = 0;
    int stopped = 0;
    mach_vm_address_t addr = 0;

    while (!stopped) {
        if (cancel && *cancel) break;
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
            while (off < size && !stopped) {
                if (cancel && *cancel) { stopped = 1; break; }
                mach_vm_size_t cur = (size - off > CHUNK) ? CHUNK : (size - off);
                mach_vm_size_t got = 0;
                kr = mach_vm_read_overwrite(task, addr + off, cur,
                                            (mach_vm_address_t)buf, &got);
                if (kr == KERN_SUCCESS && got == cur) {
                    bytes += cur;
                    size_t i = 0;
                    size_t limit = (size_t)cur;
                    if (type == MEMREAD_VALTYPE_AUTO) {
                        // 四种类型一起扫：4 字节位置同时看 int32 / float，8 字节对齐处再看 int64 / double
                        for (; i + 4 <= limit; i += 4) {
                            uint32_t v;
                            memcpy(&v, buf + i, 4);

                            double di = (double)(int32_t)v - value;
                            if (di < 0) di = -di;
                            if (di <= tol && count < MEMREAD_VALSCAN_MAX) {
                                g_valents[count].addr = (uint64_t)(addr + off + i);
                                g_valents[count].prev = (uint64_t)v;
                                g_valents[count].type = MEMREAD_VALTYPE_INT32;
                                count++;
                            }

                            float f;
                            memcpy(&f, &v, 4);
                            if (!isnan(f)) {
                                double df = (double)f - value;
                                if (df < 0) df = -df;
                                if (df <= tol && count < MEMREAD_VALSCAN_MAX) {
                                    g_valents[count].addr = (uint64_t)(addr + off + i);
                                    g_valents[count].prev = (uint64_t)v;
                                    g_valents[count].type = MEMREAD_VALTYPE_FLOAT;
                                    count++;
                                }
                            }

                            if ((i & 7) == 0 && i + 8 <= limit) {
                                uint64_t raw;
                                memcpy(&raw, buf + i, 8);

                                double dq = (double)(int64_t)raw - value;
                                if (dq < 0) dq = -dq;
                                if (dq <= tol && count < MEMREAD_VALSCAN_MAX) {
                                    g_valents[count].addr = (uint64_t)(addr + off + i);
                                    g_valents[count].prev = raw;
                                    g_valents[count].type = MEMREAD_VALTYPE_INT64;
                                    count++;
                                }

                                double dd;
                                memcpy(&dd, &raw, 8);
                                if (!isnan(dd)) {
                                    double e = dd - value;
                                    if (e < 0) e = -e;
                                    if (e <= tol && count < MEMREAD_VALSCAN_MAX) {
                                        g_valents[count].addr = (uint64_t)(addr + off + i);
                                        g_valents[count].prev = raw;
                                        g_valents[count].type = MEMREAD_VALTYPE_DOUBLE;
                                        count++;
                                    }
                                }
                            }
                        }
                    } else if (sz == 4) {
                        for (; i + 4 <= limit; i += 4) {
                            uint32_t v;
                            memcpy(&v, buf + i, 4);
                            uint64_t raw = (uint64_t)v;
                            double curd = memread_valscan_raw2double(raw, type);
                            double d = curd - value;
                            if (d < 0) d = -d;
                            if (d <= tol) {
                                if (count < MEMREAD_VALSCAN_MAX) {
                                    g_valents[count].addr = (uint64_t)(addr + off + i);
                                    g_valents[count].prev = raw;
                                    g_valents[count].type = type;
                                    count++;
                                }
                            }
                        }
                    } else {
                        for (; i + 8 <= limit; i += 8) {
                            uint64_t raw;
                            memcpy(&raw, buf + i, 8);
                            double curd = memread_valscan_raw2double(raw, type);
                            double d = curd - value;
                            if (d < 0) d = -d;
                            if (d <= tol) {
                                if (count < MEMREAD_VALSCAN_MAX) {
                                    g_valents[count].addr = (uint64_t)(addr + off + i);
                                    g_valents[count].prev = raw;
                                    g_valents[count].type = type;
                                    count++;
                                }
                            }
                        }
                    }
                }
                if (cb) cb((unsigned long long)(addr + off),
                           (unsigned long long)cur, bytes, 0, ctx);
                off += cur;
            }
        }
        addr += size;
    }

    g_valcount = count;
    free(buf);
    mach_port_deallocate(mach_task_self(), task);
    fprintf(stderr, "数值首扫完成: 扫描 %llu 字节, 候选 %llu, %d 个区域\n",
            bytes, count, regions);
    if (phits) *phits = count;
    return 0;
}

static int val_eq(double a, double b, int type) {
    if (type == MEMREAD_VALTYPE_INT32 || type == MEMREAD_VALTYPE_INT64) return a == b;
    double d = a - b;
    if (d < 0) d = -d;
    return d <= 1e-6;
}

int memread_valscan_refine(pid_t pid, int type, int cond, double target,
                           memread_region_cb cb, void *ctx,
                           unsigned long long *phits, volatile int *cancel) {
    if (phits) *phits = 0;
    if (type != MEMREAD_VALTYPE_AUTO &&
        (type < MEMREAD_VALTYPE_INT32 || type > MEMREAD_VALTYPE_DOUBLE)) return -2;
    if (!g_valents || g_valcount == 0) return 0;

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "task_for_pid 失败: (%d) %s\n", kr, mach_error_string(kr));
        return -1;
    }

    unsigned long long n = g_valcount;
    unsigned long long kept = 0;

    for (unsigned long long i = 0; i < n; i++) {
        if (cancel && *cancel) break;
        uint64_t raw = 0;
        int vt = g_valents[i].type;
        if (vt < MEMREAD_VALTYPE_INT32 || vt > MEMREAD_VALTYPE_DOUBLE) vt = type;
        if (vt < 0) vt = MEMREAD_VALTYPE_INT32;
        if (val_read_raw(task, g_valents[i].addr, vt, &raw) != 0) {
            continue;  // 地址已不可读（内存被回收/释放），丢弃
        }
        double cur = memread_valscan_raw2double(raw, vt);
        double prev = memread_valscan_raw2double(g_valents[i].prev, vt);
        int match = 0;
        switch (cond) {
            case MEMREAD_VALCOND_EQUAL:     match = val_eq(cur, target, vt); break;
            case MEMREAD_VALCOND_NOT_EQUAL: match = !val_eq(cur, target, vt); break;
            case MEMREAD_VALCOND_GREATER:   match = cur > target; break;
            case MEMREAD_VALCOND_LESS:      match = cur < target; break;
            case MEMREAD_VALCOND_INCREASED: match = cur > prev; break;
            case MEMREAD_VALCOND_DECREASED: match = cur < prev; break;
            case MEMREAD_VALCOND_CHANGED:   match = !val_eq(cur, prev, vt); break;
            case MEMREAD_VALCOND_UNCHANGED: match = val_eq(cur, prev, vt); break;
            case MEMREAD_VALCOND_DELTA:     match = val_eq(cur - prev, target, vt); break;
            default: break;
        }
        if (match) {
            g_valents[kept].addr = g_valents[i].addr;
            g_valents[kept].prev = raw;
            g_valents[kept].type = vt;
            kept++;
        }
        if (cb && ((i & 0x3FFF) == 0)) {
            cb((unsigned long long)i, n, i, 0, ctx);
        }
    }

    // 一条都没留下：拒绝清零（kept==0 时数组没被写过，直接恢复计数即可）
    if (kept == 0 && n > 0) {
        g_valcount = n;
        fprintf(stderr, "收敛结果会是 0，已拒绝并保留 %llu 条\n", n);
        mach_port_deallocate(mach_task_self(), task);
        if (phits) *phits = n;
        return MEMREAD_VALSCAN_ZERO;
    }

    g_valcount = kept;
    fprintf(stderr, "数值收敛完成: %llu -> %llu\n", n, kept);
    mach_port_deallocate(mach_task_self(), task);
    if (phits) *phits = kept;
    return 0;
}

// 自动收敛：定时器每轮先看有没有候选真的变了；没变就原样返回，避免空跑把候选全筛掉
int memread_valscan_autorefine(pid_t pid, int type, int cond, double target,
                               unsigned long long *pleft, int *pchanged) {
    if (pleft) *pleft = g_valcount;
    if (pchanged) *pchanged = 0;
    if (type != MEMREAD_VALTYPE_AUTO &&
        (type < MEMREAD_VALTYPE_INT32 || type > MEMREAD_VALTYPE_DOUBLE)) return -2;
    if (!g_valents || g_valcount == 0) return 0;

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return -1;

    int changed = 0;
    unsigned long long n = g_valcount;
    // 候选特别多时抽样探测（每轮只读约 4096 条），避免每秒扫几百万地址
    unsigned long long step = (n > 4096) ? (n / 4096) : 1;
    for (unsigned long long i = 0; i < n; i += step) {
        uint64_t raw = 0;
        int vt = g_valents[i].type;
        if (vt < MEMREAD_VALTYPE_INT32 || vt > MEMREAD_VALTYPE_DOUBLE) vt = type;
        if (vt < 0) vt = MEMREAD_VALTYPE_INT32;
        if (val_read_raw(task, g_valents[i].addr, vt, &raw) != 0) continue;
        double cur = memread_valscan_raw2double(raw, vt);
        double prev = memread_valscan_raw2double(g_valents[i].prev, vt);
        // 只认「符合收敛方向」的变化：变小了就要求真的有人变小，
        // 否则无关地址的变大/抖动会把候选误判成全部不符合，一次清零。
        int want = 0;
        switch (cond) {
            case MEMREAD_VALCOND_DECREASED: want = (cur < prev); break;
            case MEMREAD_VALCOND_INCREASED: want = (cur > prev); break;
            case MEMREAD_VALCOND_CHANGED:   want = !val_eq(cur, prev, vt); break;
            case MEMREAD_VALCOND_UNCHANGED: want = val_eq(cur, prev, vt); break;
            case MEMREAD_VALCOND_EQUAL:     want = val_eq(cur, target, vt); break;
            case MEMREAD_VALCOND_DELTA:     want = val_eq(cur - prev, target, vt); break;
            default:                        want = !val_eq(cur, prev, vt); break;
        }
        if (want) { changed = 1; break; }
    }
    mach_port_deallocate(mach_task_self(), task);

    if (pchanged) *pchanged = changed;
    if (!changed) {
        if (pleft) *pleft = n;
        return 0;
    }

    // refine 内部已保证「不把候选清零」，这里不需要再备份
    unsigned long long left = 0;
    int rc = memread_valscan_refine(pid, type, cond, target, NULL, NULL, &left, NULL);
    if (rc == MEMREAD_VALSCAN_ZERO) {
        left = n;
        if (pchanged) *pchanged = 0;
        fprintf(stderr, "自动收敛结果会是 0，已拒绝并保留 %llu 条\n", n);
        if (pleft) *pleft = left;
        return 0;
    }
    if (pleft) *pleft = left;
    return rc;
}

int memread_valscan_peek(pid_t pid, int type, unsigned long long index,
                         uint64_t *out_addr, double *out_value) {
    if (!g_valents || index >= g_valcount) return -1;
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return -2;
    int vt = g_valents[index].type;
    if (vt < MEMREAD_VALTYPE_INT32 || vt > MEMREAD_VALTYPE_DOUBLE) vt = type;
    if (vt < 0) vt = MEMREAD_VALTYPE_INT32;
    uint64_t raw = 0;
    int rc = val_read_raw(task, g_valents[index].addr, vt, &raw);
    mach_port_deallocate(mach_task_self(), task);
    if (rc != 0) return -3;
    if (out_addr) *out_addr = g_valents[index].addr;
    if (out_value) *out_value = memread_valscan_raw2double(raw, vt);
    return 0;
}

int memread_valscan_get(unsigned long long index, uint64_t *out_addr, uint64_t *out_prev) {
    return memread_valscan_get_ex(index, out_addr, out_prev, NULL);
}

int memread_valscan_get_ex(unsigned long long index, uint64_t *out_addr,
                           uint64_t *out_prev, int *out_type) {
    if (!g_valents || index >= g_valcount) return -1;
    if (out_addr) *out_addr = g_valents[index].addr;
    if (out_prev) *out_prev = g_valents[index].prev;
    if (out_type) *out_type = g_valents[index].type;
    return 0;
}

#pragma mark - 模块基址 + 偏移（Mach-O 解析，跨重启定位模块内地址）

#define MEMREAD_MOD_SEG_MAX 96
#define MEMREAD_MOD_CMD_MAX (16u * 1024 * 1024)

typedef struct {
    uint64_t base;          // 模块 Mach-O header 地址（本轮运行的基址）
    uint64_t seg_start;
    uint64_t seg_end;
    int writable;           // initprot 含 VM_PROT_WRITE
    char segname[17];
    char uuid[40];
    char name[64];
} memread_modseg_t;

static memread_modseg_t *g_modsegs = NULL;
static int g_modsegn = 0;
static pid_t g_modpid = 0;
static time_t g_modtime = 0;
static char g_main_uuid[40] = {0};
static uint64_t g_main_base = 0;

static void module_cache_reset(void) {
    if (g_modsegs) free(g_modsegs);
    g_modsegs = NULL;
    g_modsegn = 0;
    g_modpid = 0;
    g_modtime = 0;
    g_main_uuid[0] = 0;
    g_main_base = 0;
}

static void uuid_to_str(const unsigned char *u, char *out, size_t cap) {
    if (!out || cap < 33) { if (out && cap) out[0] = 0; return; }
    for (int i = 0; i < 16; i++) snprintf(out + 2 * i, cap - 2 * i, "%02X", u[i]);
    out[32] = 0;
}

static void path_basename(const char *in, char *out, size_t cap) {
    if (!out || cap == 0) return;
    const char *s = strrchr(in, '/');
    s = s ? s + 1 : in;
    size_t n = strlen(s);
    if (n >= cap) n = cap - 1;
    memcpy(out, s, n);
    out[n] = 0;
}

// 解析一个 Mach-O 头，把各段的运行区间写进 out；返回段数，0 表示不是 Mach-O
static int macho_scan(task_t task, uint64_t hdr, memread_modseg_t *out, int cap, int *out_is_main) {
    unsigned char b[32];
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(task, (mach_vm_address_t)hdr, 32,
                                             (mach_vm_address_t)b, &got);
    if (kr != KERN_SUCCESS || got != 32) return 0;
    uint32_t magic;
    memcpy(&magic, b, 4);
    if (magic != 0xFEEDFACF) return 0;

    uint32_t filetype;
    memcpy(&filetype, b + 12, 4);
    uint32_t ncmds, sizeofcmds;
    memcpy(&ncmds, b + 16, 4);
    memcpy(&sizeofcmds, b + 20, 4);
    if (ncmds == 0 || ncmds > 4096 || sizeofcmds == 0 || sizeofcmds > MEMREAD_MOD_CMD_MAX) return 0;

    unsigned char *cmds = (unsigned char *)malloc(sizeofcmds);
    if (!cmds) return 0;
    kr = mach_vm_read_overwrite(task, (mach_vm_address_t)(hdr + 32), sizeofcmds,
                                (mach_vm_address_t)cmds, &got);
    if (kr != KERN_SUCCESS || got != sizeofcmds) { free(cmds); return 0; }

    uint64_t seg_vm[32], seg_sz[32];
    uint32_t seg_prot[32];
    char seg_name[32][17];
    int nseg = 0;
    uint64_t text_vm = 0;
    int has_text = 0, has_uuid = 0;
    unsigned char uuid[16] = {0};
    char name[64] = "";

    uint64_t p = 0;
    for (uint32_t c = 0; c < ncmds && p + 8 <= sizeofcmds; c++) {
        uint32_t cmd, cmdsize;
        memcpy(&cmd, cmds + p, 4);
        memcpy(&cmdsize, cmds + p + 4, 4);
        if (cmdsize < 8 || p + cmdsize > sizeofcmds) break;

        if (cmd == 0x19 && cmdsize >= 72) {               // LC_SEGMENT_64
            char sg[17];
            memcpy(sg, cmds + p + 8, 16);
            sg[16] = 0;
            uint64_t vmaddr, vmsize, fileoff;
            uint32_t initprot = 0;
            memcpy(&vmaddr, cmds + p + 24, 8);
            memcpy(&vmsize, cmds + p + 32, 8);
            memcpy(&fileoff, cmds + p + 40, 8);
            memcpy(&initprot, cmds + p + 60, 4);
            if (nseg < 32 && vmsize) {
                seg_vm[nseg] = vmaddr;
                seg_sz[nseg] = vmsize;
                seg_prot[nseg] = initprot;
                memcpy(seg_name[nseg], sg, sizeof(seg_name[nseg]));
                nseg++;
            }
            if (strcmp(sg, "__TEXT") == 0 && fileoff == 0) {
                text_vm = vmaddr;
                has_text = 1;
            }
        } else if (cmd == 0x1b && cmdsize >= 24) {        // LC_UUID
            memcpy(uuid, cmds + p + 8, 16);
            has_uuid = 1;
        } else if (cmd == 0xd && cmdsize >= 24) {         // LC_ID_DYLIB
            uint32_t noff;
            memcpy(&noff, cmds + p + 8, 4);
            if (noff + 1 < cmdsize) path_basename((const char *)(cmds + p + noff), name, sizeof(name));
        }
        p += cmdsize;
    }
    free(cmds);

    if (!has_text || nseg == 0) return 0;
    if (filetype == 2) snprintf(name, sizeof(name), "main");

    char uuidstr[40] = "";
    if (has_uuid) uuid_to_str(uuid, uuidstr, sizeof(uuidstr));

    int64_t slide = (int64_t)hdr - (int64_t)text_vm;
    int n = 0;
    for (int i = 0; i < nseg && n < cap; i++) {
        uint64_t start = (uint64_t)((int64_t)seg_vm[i] + slide);
        if (seg_sz[i] == 0) continue;
        out[n].base = hdr;
        out[n].seg_start = start;
        out[n].seg_end = start + seg_sz[i];
        out[n].writable = ((seg_prot[i] & 0x2) != 0);   // VM_PROT_WRITE
        memcpy(out[n].segname, seg_name[i], sizeof(out[n].segname));
        memcpy(out[n].uuid, uuidstr, sizeof(out[n].uuid));
        memcpy(out[n].name, name, sizeof(out[n].name));
        n++;
    }
    if (out_is_main) *out_is_main = (filetype == 2);
    return n;
}

static int module_cache_build(pid_t pid) {
    module_cache_reset();

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return -1;

    int cap = 0, cnt = 0;
    mach_vm_address_t addr = 0;
    memread_modseg_t rows[MEMREAD_MOD_SEG_MAX];

    for (;;) {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t icnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        kr = mach_vm_region(task, &addr, &size, VM_REGION_BASIC_INFO_64,
                            (vm_region_info_t)&info, &icnt, &obj);
        if (kr != KERN_SUCCESS || size == 0) break;

        if (size >= 32) {
            int is_main = 0;
            int n = macho_scan(task, (uint64_t)addr, rows, MEMREAD_MOD_SEG_MAX, &is_main);
            if (n > 0) {
                if (cnt + n > cap) {
                    int nc = (cnt + n + 63) / 64 * 64;
                    memread_modseg_t *nr = (memread_modseg_t *)realloc(g_modsegs, (size_t)nc * sizeof(memread_modseg_t));
                    if (!nr) break;
                    g_modsegs = nr;
                    cap = nc;
                }
                memcpy(g_modsegs + cnt, rows, (size_t)n * sizeof(memread_modseg_t));
                cnt += n;
                if (is_main && !g_main_uuid[0] && n > 0) {
                    memcpy(g_main_uuid, rows[0].uuid, sizeof(g_main_uuid));
                    g_main_base = rows[0].base;
                }
            }
        }
        addr += size;
    }

    mach_port_deallocate(mach_task_self(), task);
    g_modsegn = cnt;
    g_modpid = pid;
    g_modtime = time(NULL);
    fprintf(stderr, "模块解析: %d 个段, 主模块 base=0x%llX\n", cnt, g_main_base);
    return 0;
}

static int module_cache_ensure(pid_t pid) {
    if (!g_modsegs || g_modpid != pid || time(NULL) - g_modtime > 3) {
        return module_cache_build(pid);
    }
    return 0;
}

int memread_addr_module_info(pid_t pid, uint64_t addr,
                             char *out_uuid, size_t uuid_cap,
                             char *out_name, size_t name_cap,
                             uint64_t *out_base, uint64_t *out_off) {
    if (out_uuid && uuid_cap) out_uuid[0] = 0;
    if (out_name && name_cap) out_name[0] = 0;
    if (module_cache_ensure(pid) != 0) return -1;

    for (int i = 0; i < g_modsegn; i++) {
        if (addr >= g_modsegs[i].seg_start && addr < g_modsegs[i].seg_end) {
            if (out_uuid && uuid_cap) {
                size_t n = strlen(g_modsegs[i].uuid);
                if (n >= uuid_cap) n = uuid_cap - 1;
                memcpy(out_uuid, g_modsegs[i].uuid, n);
                out_uuid[n] = 0;
            }
            if (out_name && name_cap) {
                size_t n = strlen(g_modsegs[i].name);
                if (n >= name_cap) n = name_cap - 1;
                memcpy(out_name, g_modsegs[i].name, n);
                out_name[n] = 0;
            }
            if (out_base) *out_base = g_modsegs[i].base;
            if (out_off) *out_off = addr - g_modsegs[i].base;
            return 0;
        }
    }
    return 1;
}

int memread_module_base(pid_t pid, const char *uuid,
                        uint64_t *out_base, char *out_name, size_t name_cap) {
    if (out_base) *out_base = 0;
    if (out_name && name_cap) out_name[0] = 0;
    if (!uuid || !uuid[0]) return 1;
    if (module_cache_ensure(pid) != 0) return -1;

    for (int i = 0; i < g_modsegn; i++) {
        if (strcmp(g_modsegs[i].uuid, uuid) == 0) {
            if (out_base) *out_base = g_modsegs[i].base;
            if (out_name && name_cap) {
                size_t n = strlen(g_modsegs[i].name);
                if (n >= name_cap) n = name_cap - 1;
                memcpy(out_name, g_modsegs[i].name, n);
                out_name[n] = 0;
            }
            return 0;
        }
    }
    return 1;
}

int memread_proc_token(pid_t pid, char *out_uuid, size_t uuid_cap, uint64_t *out_base) {
    if (out_uuid && uuid_cap) out_uuid[0] = 0;
    if (out_base) *out_base = 0;
    if (module_cache_ensure(pid) != 0) return -1;
    if (!g_main_uuid[0]) return 1;
    if (out_uuid && uuid_cap) {
        size_t n = strlen(g_main_uuid);
        if (n >= uuid_cap) n = uuid_cap - 1;
        memcpy(out_uuid, g_main_uuid, n);
        out_uuid[n] = 0;
    }
    if (out_base) *out_base = g_main_base;
    return 0;
}

#pragma mark - 未知值扫描 / 坐标扫描（磁盘快照 + 变化比对）

// 快照放磁盘再 mmap 回来：整块可写内存往往 700MB~1.5GB，纯内存拷贝会被系统直接杀掉
#define MEMREAD_SNAP_MAX_BYTES (2ULL * 1024 * 1024 * 1024)
#define MEMREAD_COORD_MAX_TRIPLETS 4000
#define MEMREAD_SNAP_REGION_MAX (512ULL * 1024 * 1024)
#define MEMREAD_SNAP_PATH "/var/mobile/Media/memread_snap.bin"

typedef struct {
    uint64_t addr;
    uint64_t size;
    uint64_t off;            // 在快照文件里的偏移
    unsigned char *buf;      // mmap 后的区域指针（= 映射基址 + off）
} memread_snapreg_t;

static memread_snapreg_t *g_sregs = NULL;
static int g_sregn = 0;
static unsigned long long g_sbytes = 0;
static int g_sfd = -1;
static void *g_smap = NULL;
static size_t g_smaplen = 0;
static pid_t g_snap_pid = 0;
static char g_snap_uuid[40] = {0};
static uint64_t g_snap_base = 0;

static int snap_proc_same(pid_t pid) {
    if (g_snap_pid && pid != g_snap_pid) return 0;
    if (!g_snap_uuid[0]) return 1;   // 没有 token 就不校验
    char u[40] = {0};
    uint64_t base = 0;
    if (memread_proc_token(pid, u, sizeof(u), &base) != 0) return 0;
    return (strcmp(u, g_snap_uuid) == 0 && base == g_snap_base);
}

void memread_snapshot_free(void) {
    if (g_smap) munmap(g_smap, g_smaplen);
    if (g_sfd >= 0) close(g_sfd);
    if (g_smap || g_sfd >= 0) unlink(MEMREAD_SNAP_PATH);
    g_smap = NULL;
    g_smaplen = 0;
    g_sfd = -1;
    if (g_sregs) free(g_sregs);
    g_sregs = NULL;
    g_sregn = 0;
    g_sbytes = 0;
    g_snap_pid = 0;
    g_snap_uuid[0] = 0;
    g_snap_base = 0;
}

// 可写、非共享、单个区域不超过 512MB：与首扫一致
static int snap_region_ok(vm_region_basic_info_data_64_t *info, mach_vm_size_t size) {
    if (!((info->protection & VM_PROT_READ) != 0)) return 0;
    if (!((info->protection & VM_PROT_WRITE) != 0)) return 0;
    if (info->shared) return 0;
    if (size > (mach_vm_size_t)MEMREAD_SNAP_REGION_MAX) return 0;
    return 1;
}

static int write_all(int fd, const void *p, size_t n) {
    const unsigned char *b = (const unsigned char *)p;
    size_t done = 0;
    while (done < n) {
        ssize_t w = write(fd, b + done, n - done);
        if (w <= 0) return -1;
        done += (size_t)w;
    }
    return 0;
}

int memread_unknown_snapshot(pid_t pid, unsigned long long *pbytes, unsigned long long *pregions) {
    if (pbytes) *pbytes = 0;
    if (pregions) *pregions = 0;
    memread_snapshot_free();

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "快照 task_for_pid 失败: %s\n", mach_error_string(kr));
        return -1;
    }

    // 第一遍：只枚举，算总量，避免中途 OOM
    mach_vm_address_t addr = 0;
    unsigned long long total = 0;
    int cap = 0;
    for (;;) {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        kr = mach_vm_region(task, &addr, &size, VM_REGION_BASIC_INFO_64,
                            (vm_region_info_t)&info, &cnt, &obj);
        if (kr != KERN_SUCCESS || size == 0) break;
        if (snap_region_ok(&info, size)) {
            total += (unsigned long long)size;
            cap++;
        }
        addr += size;
    }

    if (cap == 0 || total == 0) {
        mach_port_deallocate(mach_task_self(), task);
        return -6;
    }
    if (total > MEMREAD_SNAP_MAX_BYTES) {
        fprintf(stderr, "快照需要 %llu MB，超过上限 %llu MB\n",
                total / 1048576ULL, MEMREAD_SNAP_MAX_BYTES / 1048576ULL);
        mach_port_deallocate(mach_task_self(), task);
        return -5;
    }

    struct statvfs vfs;
    if (statvfs("/var/mobile/Media", &vfs) == 0) {
        unsigned long long freemb = (unsigned long long)vfs.f_bavail * (unsigned long long)vfs.f_frsize;
        if (freemb < total + (256ULL * 1024 * 1024)) {
            fprintf(stderr, "磁盘余量 %llu MB 不够快照 %llu MB\n",
                    freemb / 1048576ULL, total / 1048576ULL);
            mach_port_deallocate(mach_task_self(), task);
            return -8;
        }
    }

    memread_snapreg_t *regs = (memread_snapreg_t *)calloc((size_t)cap, sizeof(memread_snapreg_t));
    if (!regs) {
        mach_port_deallocate(mach_task_self(), task);
        return -4;
    }

    int fd = open(MEMREAD_SNAP_PATH, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        free(regs);
        mach_port_deallocate(mach_task_self(), task);
        return -7;
    }

    const mach_vm_size_t CHUNK = 4ULL * 1024 * 1024;
    unsigned char *tmp = (unsigned char *)malloc((size_t)CHUNK);
    if (!tmp) {
        close(fd);
        unlink(MEMREAD_SNAP_PATH);
        free(regs);
        mach_port_deallocate(mach_task_self(), task);
        return -4;
    }

    // 第二遍：逐区读出来，直接写到快照文件（不占内存）
    addr = 0;
    int idx = 0;
    unsigned long long fileoff = 0;
    int ioerr = 0;
    for (;;) {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        kr = mach_vm_region(task, &addr, &size, VM_REGION_BASIC_INFO_64,
                            (vm_region_info_t)&info, &cnt, &obj);
        if (kr != KERN_SUCCESS || size == 0) break;

        if (idx < cap && snap_region_ok(&info, size)) {
            uint64_t region_off = fileoff;
            uint64_t off = 0;
            int ok = 1;
            while (off < (uint64_t)size) {
                mach_vm_size_t cur = (size - off > CHUNK) ? CHUNK : (mach_vm_size_t)(size - off);
                mach_vm_size_t got = 0;
                kr = mach_vm_read_overwrite(task, addr + off, cur,
                                            (mach_vm_address_t)tmp, &got);
                if (kr != KERN_SUCCESS || got != cur) { ok = 0; break; }
                if (write_all(fd, tmp, (size_t)cur) != 0) { ok = 0; ioerr = 1; break; }
                fileoff += cur;
                off += cur;
            }
            if (!ok) {
                // 回滚这块区域的半截数据，避免快照里出现空洞
                if (ftruncate(fd, (off_t)region_off) != 0) ioerr = 1;
                fileoff = region_off;
                if (ioerr) break;
            } else {
                regs[idx].addr = (uint64_t)addr;
                regs[idx].size = (uint64_t)size;
                regs[idx].off = region_off;
                idx++;
            }
        }
        addr += size;
    }

    free(tmp);
    mach_port_deallocate(mach_task_self(), task);

    if (ioerr || idx == 0) {
        close(fd);
        unlink(MEMREAD_SNAP_PATH);
        free(regs);
        return ioerr ? -7 : -6;
    }

    if (ftruncate(fd, (off_t)fileoff) != 0) {
        close(fd);
        unlink(MEMREAD_SNAP_PATH);
        free(regs);
        return -7;
    }

    void *map = mmap(NULL, (size_t)fileoff, PROT_READ, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED || !map) {
        close(fd);
        unlink(MEMREAD_SNAP_PATH);
        free(regs);
        return -4;
    }

    for (int i = 0; i < idx; i++) {
        regs[i].buf = (unsigned char *)map + regs[i].off;
    }

    g_sregs = regs;
    g_sregn = idx;
    g_sbytes = fileoff;
    g_sfd = fd;
    g_smap = map;
    g_smaplen = (size_t)fileoff;

    g_snap_pid = pid;
    if (memread_proc_token(pid, g_snap_uuid, sizeof(g_snap_uuid), &g_snap_base) != 0) {
        g_snap_uuid[0] = 0;
        g_snap_base = 0;
    }

    fprintf(stderr, "内存快照(磁盘): %d 个区域 %llu MB\n", idx, fileoff / 1048576ULL);
    if (pbytes) *pbytes = fileoff;
    if (pregions) *pregions = (unsigned long long)idx;
    return 0;
}

// 找到覆盖 [addr, addr+len) 的快照区域下标；-1 表示没覆盖
static int snap_find(uint64_t addr, uint64_t len) {
    for (int i = 0; i < g_sregn; i++) {
        uint64_t a = g_sregs[i].addr;
        uint64_t e = a + g_sregs[i].size;
        if (addr >= a && addr + len <= e) return i;
    }
    return -1;
}

static int float_plausible(uint32_t raw) {
    float f;
    memcpy(&f, &raw, 4);
    if (!isfinite(f)) return 0;
    double d = (double)f;
    if (d < 0) d = -d;
    return d <= 1e6;
}

int memread_unknown_diff(pid_t pid, int cond, int float_only,
                         memread_region_cb cb, void *ctx,
                         unsigned long long *phits, volatile int *cancel) {
    if (phits) *phits = 0;
    if (!g_sregs || g_sregn == 0) return -6;
    if (!snap_proc_same(pid)) return MEMREAD_PROC_RESTARTED;

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return -1;

    if (!g_valents) {
        g_valents = (memread_valent_t *)calloc(MEMREAD_VALSCAN_MAX, sizeof(memread_valent_t));
        if (!g_valents) {
            mach_port_deallocate(mach_task_self(), task);
            return -4;
        }
    }
    g_valcount = 0;

    const mach_vm_size_t CHUNK = 4ULL * 1024 * 1024;
    unsigned char *buf = (unsigned char *)malloc((size_t)CHUNK);
    if (!buf) {
        mach_port_deallocate(mach_task_self(), task);
        return -4;
    }

    unsigned long long count = 0;
    unsigned long long total = 0;
    int stopped = 0;

    for (int r = 0; r < g_sregn && !stopped; r++) {
        uint64_t base = g_sregs[r].addr;
        uint64_t size = g_sregs[r].size;
        unsigned char *snap = g_sregs[r].buf;
        uint64_t off = 0;
        while (off < size) {
            if (cancel && *cancel) { stopped = 1; break; }
            mach_vm_size_t cur = (size - off > CHUNK) ? CHUNK : (size - off);
            mach_vm_size_t got = 0;
            kr = mach_vm_read_overwrite(task, base + off, cur,
                                        (mach_vm_address_t)buf, &got);
            if (kr != KERN_SUCCESS || got != cur) {
                off += cur;         // 读失败：保留旧快照，跳过本块
                continue;
            }
            total += cur;
            for (size_t i = 0; i + 4 <= (size_t)cur; i += 4) {
                uint32_t oldv, newv;
                memcpy(&oldv, snap + off + i, 4);
                memcpy(&newv, buf + i, 4);

                int match = 0;
                switch (cond) {
                    case MEMREAD_VALCOND_CHANGED:    match = (oldv != newv); break;
                    case MEMREAD_VALCOND_UNCHANGED:  match = (oldv == newv); break;
                    case MEMREAD_VALCOND_INCREASED:  match = ((int32_t)newv > (int32_t)oldv); break;
                    case MEMREAD_VALCOND_DECREASED:  match = ((int32_t)newv < (int32_t)oldv); break;
                    default:                         match = (oldv != newv); break;
                }
                if (!match) continue;
                if (float_only && !float_plausible(newv)) continue;
                if (count >= MEMREAD_VALSCAN_MAX) continue;

                g_valents[count].addr = base + off + i;
                g_valents[count].prev = (uint64_t)newv;
                g_valents[count].type = float_only ? MEMREAD_VALTYPE_FLOAT : MEMREAD_VALTYPE_INT32;
                count++;
            }
            // 快照保持只读（mmap PROT_READ），基线需要更新时由上层重新拍一次
            off += cur;
            if (cb) cb((unsigned long long)(base + off), cur, total, 0, ctx);
        }
    }

    free(buf);
    g_valcount = count;
    mach_port_deallocate(mach_task_self(), task);
    fprintf(stderr, "未知值比对完成: 扫描 %llu MB, 候选 %llu\n",
            total / 1048576ULL, count);
    if (phits) *phits = count;
    return 0;
}

int memread_coord_lock(pid_t pid, int *ptriplets, unsigned long long *pcands,
                       memread_region_cb cb, void *ctx) {
    if (ptriplets) *ptriplets = 0;
    if (pcands) *pcands = 0;
    if (!g_sregs || g_sregn == 0) return -6;
    if (!g_valents || g_valcount == 0) return 0;
    if (!snap_proc_same(pid)) return MEMREAD_PROC_RESTARTED;

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return -1;

    unsigned long long n = g_valcount;
    typedef struct { uint64_t base; uint32_t raw[3]; } triple_t;
    triple_t *out = (triple_t *)calloc(MEMREAD_COORD_MAX_TRIPLETS, sizeof(triple_t));
    if (!out) {
        mach_port_deallocate(mach_task_self(), task);
        return -4;
    }
    int found = 0;

    for (unsigned long long i = 0; i < n; i++) {
        if (found >= MEMREAD_COORD_MAX_TRIPLETS) break;
        uint64_t a = g_valents[i].addr;
        uint64_t bases[2] = { a, (a >= 8) ? a - 8 : a };
        int nb = (bases[1] == bases[0]) ? 1 : 2;
        for (int bi = 0; bi < nb; bi++) {
            uint64_t base = bases[bi];
            if (base < 0x1000) continue;
            int ri = snap_find(base, 12);
            if (ri < 0) continue;
            const unsigned char *sbuf = g_sregs[ri].buf + (size_t)(base - g_sregs[ri].addr);

            unsigned char now[12] = {0};
            mach_vm_size_t got = 0;
            kr = mach_vm_read_overwrite(task, (mach_vm_address_t)base, 12,
                                        (mach_vm_address_t)now, &got);
            if (kr != KERN_SUCCESS || got != 12) continue;

            int changed_idx = -1, changed_n = 0;
            uint32_t olds[3], news[3];
            for (int k = 0; k < 3; k++) {
                memcpy(&olds[k], sbuf + 4 * k, 4);
                memcpy(&news[k], now + 4 * k, 4);
                if (olds[k] != news[k]) { changed_n++; changed_idx = k; }
            }
            if (changed_n != 1) continue;

            uint64_t changed_addr = base + (uint64_t)(4 * changed_idx);
            if (changed_addr == a) continue;      // 变化的就是候选自己：走动时就该变，跳时不该是它

            int ok = 1;
            for (int k = 0; k < 3; k++) if (!float_plausible(news[k])) { ok = 0; break; }
            if (!ok) continue;

            int dup = 0;
            for (int k = 0; k < found; k++) if (out[k].base == base) { dup = 1; break; }
            if (dup) continue;

            out[found].base = base;
            for (int k = 0; k < 3; k++) out[found].raw[k] = news[k];
            found++;
        }
        if (found >= MEMREAD_COORD_MAX_TRIPLETS) break;
        if (cb && ((i & 0xFFFF) == 0)) cb(i, n, i, 0, ctx);
    }

    // 候选表改写成三连 float
    if (found > 0) {
        memread_valscan_reset();
        g_valents = (memread_valent_t *)calloc(MEMREAD_VALSCAN_MAX, sizeof(memread_valent_t));
        if (!g_valents) {
            free(out);
            mach_port_deallocate(mach_task_self(), task);
            return -4;
        }
        unsigned long long count = 0;
        for (int k = 0; k < found; k++) {
            for (int j = 0; j < 3; j++) {
                if (count >= MEMREAD_VALSCAN_MAX) break;
                g_valents[count].addr = out[k].base + (uint64_t)(4 * j);
                g_valents[count].prev = (uint64_t)out[k].raw[j];
                g_valents[count].type = MEMREAD_VALTYPE_FLOAT;
                count++;
            }
        }
        g_valcount = count;
        if (pcands) *pcands = count;
    }

    free(out);
    mach_port_deallocate(mach_task_self(), task);
    fprintf(stderr, "坐标锁定: %d 组\n", found);
    if (ptriplets) *ptriplets = found;
    return 0;
}

#pragma mark - 指针链扫描（模块静态槽 + 多级偏移，跨重启复原堆地址）

typedef struct {
    uint64_t addr;       // 槽地址
    int32_t off;         // 本跳偏移：槽内容 + off = 上一层要解释的地址
    int32_t parent;      // 上一层节点下标
} chainnode_t;

static int chain_u64cmp(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x < y) ? -1 : (x > y ? 1 : 0);
}

static int chain_read_u64(task_t task, uint64_t addr, uint64_t *out) {
    uint64_t v = 0;
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(task, (mach_vm_address_t)addr, 8,
                                             (mach_vm_address_t)&v, &got);
    if (kr != KERN_SUCCESS || got != 8) return -1;
    *out = v;
    return 0;
}

static int chain_frontier_lower(const uint64_t *f, int n, uint64_t key) {
    int lo = 0, hi = n;
    while (lo < hi) {
        int mid = (lo + hi) / 2;
        if (f[mid] < key) lo = mid + 1; else hi = mid;
    }
    return lo;
}

// 扫一遍可写内存，找所有「8 字节槽，其内容 + off 落在 frontier 窗口内」的位置
static int chain_scan_level(task_t task, const uint64_t *front, int fn,
                            chainnode_t *out, int cap, int *outn,
                            volatile int *cancel) {
    *outn = 0;
    if (!front || fn <= 0) return -2;
    const mach_vm_size_t CHUNK = 4ULL * 1024 * 1024;
    unsigned char *buf = (unsigned char *)malloc((size_t)CHUNK);
    if (!buf) return -4;

    mach_vm_address_t addr = 0;
    int full = 0;
    for (;;) {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        kern_return_t kr = mach_vm_region(task, &addr, &size, VM_REGION_BASIC_INFO_64,
                                         (vm_region_info_t)&info, &cnt, &obj);
        if (kr != KERN_SUCCESS || size == 0) break;

        if (snap_region_ok(&info, size)) {
            uint64_t off = 0;
            while (off + 8 <= (uint64_t)size && !full) {
                if (cancel && *cancel) break;
                mach_vm_size_t cur = (mach_vm_size_t)((size - off > CHUNK) ? CHUNK : (size - off));
                cur -= (cur % 8);
                if (cur == 0) break;
                mach_vm_size_t got = 0;
                kr = mach_vm_read_overwrite(task, addr + off, cur,
                                           (mach_vm_address_t)buf, &got);
                if (kr != KERN_SUCCESS || got != cur) {
                    off += cur;
                    continue;
                }
                for (mach_vm_size_t o = 0; o + 8 <= cur; o += 8) {
                    uint64_t v;
                    memcpy(&v, buf + o, 8);
                    if (v < 0x100000000ULL) continue;
                    uint64_t lo = v - MEMREAD_CHAIN_OFF_WIN;
                    uint64_t hi = v + MEMREAD_CHAIN_OFF_WIN;
                    int i = chain_frontier_lower(front, fn, lo);
                    for (; i < fn && front[i] <= hi; i++) {
                        int64_t d = (int64_t)front[i] - (int64_t)v;
                        if (d < -(int64_t)MEMREAD_CHAIN_OFF_WIN || d > (int64_t)MEMREAD_CHAIN_OFF_WIN) continue;
                        if (*outn >= cap) { full = 1; break; }
                        out[*outn].addr = (uint64_t)addr + off + o;
                        out[*outn].off = (int32_t)d;
                        out[*outn].parent = i;
                        (*outn)++;
                    }
                    if (full) break;
                }
                off += cur;
            }
        }
        if (full) break;
        addr += size;
    }
    free(buf);
    return 0;
}

// 槽地址是否落在某个模块的可写段里（是 → 该地址可跨重启复原）
static int chain_module_slot(uint64_t addr, memread_modseg_t *out) {
    if (!g_modsegs) return -1;
    for (int i = 0; i < g_modsegn; i++) {
        if (g_modsegs[i].writable && addr >= g_modsegs[i].seg_start && addr < g_modsegs[i].seg_end) {
            if (out) *out = g_modsegs[i];
            return 0;
        }
    }
    return 1;
}

static int chain_verify(task_t task, uint64_t slot, const int64_t *offs, int depth, uint64_t target) {
    uint64_t a = slot;
    for (int i = 0; i < depth; i++) {
        uint64_t v = 0;
        if (chain_read_u64(task, a, &v) != 0) return -1;
        if (v < 0x100000000ULL) return 1;
        a = (uint64_t)((int64_t)v + offs[i]);
    }
    return (a == target) ? 0 : 1;
}

int memread_chain_scan(pid_t pid, uint64_t target, int max_depth,
                       memread_chain_t *out, int cap, int *found_depth,
                       volatile int *cancel) {
    if (found_depth) *found_depth = 0;
    if (!out || cap <= 0) return -2;
    if (max_depth < 1) max_depth = 1;
    if (max_depth > MEMREAD_CHAIN_MAX_DEPTH) max_depth = MEMREAD_CHAIN_MAX_DEPTH;

    task_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return -1;
    if (module_cache_ensure(pid) != 0 || g_modsegn == 0) {
        mach_port_deallocate(mach_task_self(), task);
        return -3;
    }

    chainnode_t *lv[MEMREAD_CHAIN_MAX_DEPTH + 1] = {0};
    int ln[MEMREAD_CHAIN_MAX_DEPTH + 1] = {0};
    uint64_t *front = (uint64_t *)malloc(sizeof(uint64_t));
    if (!front) {
        mach_port_deallocate(mach_task_self(), task);
        return -4;
    }
    front[0] = target;
    int fn = 1;
    int results = 0, stopdepth = 0;

    for (int lvl = 1; lvl <= max_depth && results == 0; lvl++) {
        lv[lvl] = (chainnode_t *)malloc(sizeof(chainnode_t) * MEMREAD_CHAIN_NODE_CAP);
        if (!lv[lvl]) break;
        chain_scan_level(task, front, fn, lv[lvl], MEMREAD_CHAIN_NODE_CAP, &ln[lvl], cancel);

        if (ln[lvl] > 0) {
            for (int j = 0; j < ln[lvl] && results < cap; j++) {
                memread_modseg_t seg;
                if (chain_module_slot(lv[lvl][j].addr, &seg) != 0) continue;
                int64_t offs[MEMREAD_CHAIN_MAX_DEPTH] = {0};
                int depth = lvl;
                int p = j;
                for (int k = 0; k < depth; k++) {
                    chainnode_t *nd = &lv[depth - k][p];
                    offs[k] = nd->off;
                    p = nd->parent;
                }
                if (chain_verify(task, lv[lvl][j].addr, offs, depth, target) != 0) continue;
                memread_chain_t *c = &out[results];
                memset(c, 0, sizeof(*c));
                memcpy(c->uuid, seg.uuid, sizeof(c->uuid));
                memcpy(c->name, seg.name, sizeof(c->name));
                c->static_off = lv[lvl][j].addr - seg.base;
                c->depth = depth;
                memcpy(c->offs, offs, sizeof(c->offs));
                results++;
            }
            if (results > 0) { stopdepth = lvl; break; }
        }

        free(front);
        front = (uint64_t *)malloc(sizeof(uint64_t) * (size_t)(ln[lvl] > 0 ? ln[lvl] : 1));
        if (!front) break;
        for (int j = 0; j < ln[lvl]; j++) front[j] = lv[lvl][j].addr;
        fn = ln[lvl];
        qsort(front, (size_t)fn, sizeof(uint64_t), chain_u64cmp);
    }

    if (found_depth) *found_depth = stopdepth;
    free(front);
    for (int i = 0; i <= MEMREAD_CHAIN_MAX_DEPTH; i++) if (lv[i]) free(lv[i]);
    mach_port_deallocate(mach_task_self(), task);
    fprintf(stderr, "指针链扫描: 深度=%d 条数=%d\n", stopdepth, results);
    return results;
}

// 按保存下来的链（模块 UUID + 静态槽偏移 + 各级偏移）算出本轮目标地址
// 返回 0 成功；2 = 模块未加载；-3 = 链断了（指针不可读或越界）
int memread_chain_resolve(pid_t pid, const char *uuid, uint64_t static_off,
                          const int64_t *offs, int depth, uint64_t *out_addr) {
    if (out_addr) *out_addr = 0;
    if (depth <= 0 || depth > MEMREAD_CHAIN_MAX_DEPTH) return -2;
    uint64_t base = 0;
    char nm[64] = {0};
    int br = memread_module_base(pid, uuid, &base, nm, sizeof(nm));
    if (br == 1 || base == 0) return 2;
    if (br != 0) return -1;

    task_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return -1;
    uint64_t a = base + static_off;
    int rc = 0;
    for (int i = 0; i < depth; i++) {
        uint64_t v = 0;
        if (chain_read_u64(task, a, &v) != 0 || v < 0x100000000ULL) { rc = -3; break; }
        a = (uint64_t)((int64_t)v + offs[i]);
    }
    mach_port_deallocate(mach_task_self(), task);
    if (rc == 0 && out_addr) *out_addr = a;
    return rc;
}
