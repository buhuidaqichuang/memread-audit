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

// 按地址读 3 个连续 float（坐标三元组），用来在候选列表里显示 (x, y, z)
int memread_read_vec3(pid_t pid, uint64_t addr, float *out3) {
    if (!out3) return -2;
    task_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return -1;
    unsigned char b[12] = {0};
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(task, (mach_vm_address_t)addr, 12,
                                              (mach_vm_address_t)b, &got);
    mach_port_deallocate(mach_task_self(), task);
    if (kr != KERN_SUCCESS || got != 12) return -3;
    memcpy(out3, b, 12);
    return 0;
}

// 批量读 3 个 float：一次 task_for_pid，然后逐个 12 字节读（后台跟踪候选时用）
int memread_read_vec3_batch(pid_t pid, const uint64_t *addrs, int n, float *out) {
    if (!addrs || !out || n <= 0) return -2;
    task_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return -1;
    int ok = 0;
    for (int i = 0; i < n; i++) {
        unsigned char b[12] = {0};
        mach_vm_size_t got = 0;
        kern_return_t kr = mach_vm_read_overwrite(task, (mach_vm_address_t)addrs[i], 12,
                                                 (mach_vm_address_t)b, &got);
        memcpy(out + i * 3, b, 12);
        if (kr == KERN_SUCCESS && got == 12) ok++;
    }
    mach_port_deallocate(mach_task_self(), task);
    return ok;   // 成功读到的条数
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

#pragma mark - 坐标结构扫描（四元数锚定，不需要知道坐标值）

static int coord_quat_unit(const float *q, int *trivial) {
    for (int i = 0; i < 4; i++) {
        if (!isfinite(q[i]) || q[i] > 1.02f || q[i] < -1.02f) return 0;
    }
    float n = q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3];
    if (n < 0.98f || n > 1.02f) return 0;
    // UE 的 FQuat 排布 (x,y,z,w)，(0,0,0,1) 就是「无旋转」，这种命中太多，标成平凡
    if (trivial) *trivial = (fabsf(q[0]) < 1e-3f && fabsf(q[1]) < 1e-3f && fabsf(q[2]) < 1e-3f);
    return 1;
}

static int coord_ptr_ok(uint64_t p) {
    return p > 0x100000000ULL && p < 0x8000000000ULL && (p & 7) == 0;
}

static int coord_vec_ok(const float *v) {
    for (int i = 0; i < 3; i++) {
        if (!isfinite(v[i])) return 0;
        float lim = (i == 2) ? 8000.0f : 500000.0f;
        if (v[i] > lim || v[i] < -lim) return 0;
    }
    if (v[0] == 0.0f && v[1] == 0.0f && v[2] == 0.0f) return 0;
    return 1;
}

// 三种 UE 常见排布都认：
//  ① FVector 在前，四元数在 +12/+16（组件字段）
//  ② FVector 在前，FRotator 在 +12（老版本组件用角度），要求前面 8 字节像指针压噪声
//  ③ FQuat 在 -16…即四元数在前、FVector 在 +16（FTransform：Rotation/Translation/Scale3D）
static int coord_try(const unsigned char *p, float v[3], int *quat_off, int *vec_off) {
    float a[3];
    memcpy(a, p, 12);
    if (coord_vec_ok(a)) {
        for (int off = 12; off <= 16; off += 4) {
            float q[4];
            memcpy(q, p + off, 16);
            int triv = 0;
            if (coord_quat_unit(q, &triv)) {
                memcpy(v, a, 12);
                *quat_off = triv ? -off : off;
                *vec_off = 0;
                return 1;
            }
        }
        uint64_t before = 0;
        memcpy(&before, p - 8, 8);
        if (coord_ptr_ok(before)) {
            float r[3];
            memcpy(r, p + 12, 12);
            int ok = 1, nz = 0;
            for (int i = 0; i < 3; i++) {
                if (!isfinite(r[i]) || r[i] > 1080.0f || r[i] < -1080.0f) { ok = 0; break; }
                if (fabsf(r[i]) > 1e-4f) nz++;
            }
            if (ok && nz > 0) {
                memcpy(v, a, 12);
                *quat_off = 100;
                *vec_off = 0;
                return 1;
            }
        }
    }
    // FTransform：四元数在前
    {
        float q[4];
        memcpy(q, p, 16);
        int triv = 0;
        if (coord_quat_unit(q, &triv)) {
            float b[3];
            memcpy(b, p + 16, 12);
            if (coord_vec_ok(b)) {
                memcpy(v, b, 12);
                *quat_off = 0;
                *vec_off = 16;
                return 1;
            }
        }
    }
    return 0;
}

static int coord_hit_cmp(const void *pa, const void *pb) {
    const memread_coord_hit_t *a = (const memread_coord_hit_t *)pa;
    const memread_coord_hit_t *b = (const memread_coord_hit_t *)pb;
    int at = (a->quat_off < 0), bt = (b->quat_off < 0);
    if (at != bt) return at - bt;                 // 非平凡旋转优先
    if (a->addr != b->addr) return (a->addr < b->addr) ? -1 : 1;
    return 0;
}

static int coord_addr_cmp(const void *pa, const void *pb) {
    const memread_coord_hit_t *a = (const memread_coord_hit_t *)pa;
    const memread_coord_hit_t *b = (const memread_coord_hit_t *)pb;
    if (a->addr == b->addr) return 0;
    return (a->addr < b->addr) ? -1 : 1;
}

// 指针值像「堆地址」：范围内、8 字节对齐、且不落在任何模块映像里（静态表里的指针都是模块内）
static int coord_heap_ptr(uint64_t v) {
    if (v < 0x100000000ULL || v >= 0x8000000000ULL) return 0;
    if ((v & 7) != 0) return 0;
    for (int i = 0; i < g_modsegn; i++) {
        if (v >= g_modsegs[i].seg_start && v < g_modsegs[i].seg_end) return 0;
    }
    return 1;
}

// 坐标前后有没有指向堆的指针 → 说明它待在一个活对象里，而不是静态常量表
static int coord_live_at(const unsigned char *p) {
    uint64_t v = 0;
    int hits = 0;
    for (int d = 8; d <= 16; d += 8) {
        memcpy(&v, p - d, 8);
        if (coord_heap_ptr(v)) hits++;
    }
    for (int d = 24; d <= 40; d += 8) {
        memcpy(&v, p + d, 8);
        if (coord_heap_ptr(v)) hits++;
    }
    return hits >= 1;
}

// 全内存扫一遍，每个命中交给 visit；visit 返回 1 表示停止
// 1=严格（只要完整 FTransform）；0=宽松（也收 loc+非平凡四元数）
static int coord_strict_mode = 1;

static int coord_scan(pid_t pid, int (*visit)(const memread_coord_hit_t *, void *), void *vctx,
                      unsigned long long *pscanned, volatile int *cancel,
                      memread_region_cb cb, void *ctx) {
    if (pscanned) *pscanned = 0;
    task_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return -1;
    module_cache_ensure(pid);   // coord_heap_ptr 要用模块段范围，region 也要据此跳过模块映像

    const mach_vm_size_t CHUNK = 4ULL * 1024 * 1024;
    unsigned char *buf = (unsigned char *)malloc((size_t)CHUNK);
    if (!buf) {
        mach_port_deallocate(mach_task_self(), task);
        return -4;
    }
    int stop = 0;
    unsigned long long scanned = 0;
    mach_vm_address_t addr = 0;
    for (;;) {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        kern_return_t kr = mach_vm_region(task, &addr, &size, VM_REGION_BASIC_INFO_64,
                                         (vm_region_info_t)&info, &cnt, &obj);
        if (kr != KERN_SUCCESS || size == 0) break;
        // 跳过模块映像里的区域：那里的四元数/角度全是静态常量，坐标不在那儿，还会把名额占满
        int in_module = 0;
        for (int i = 0; i < g_modsegn; i++) {
            uint64_t s = g_modsegs[i].seg_start, e = g_modsegs[i].seg_end;
            if (((uint64_t)addr >= s && (uint64_t)addr < e) ||
                ((uint64_t)addr + size > s && (uint64_t)addr < e)) { in_module = 1; break; }
        }
        if (!in_module && snap_region_ok(&info, size)) {
            uint64_t off = 0;
            while (off + 32 <= (uint64_t)size) {
                if (cancel && *cancel) { stop = 1; break; }
                mach_vm_size_t cur = (mach_vm_size_t)((size - off > CHUNK) ? CHUNK : (size - off));
                cur -= (cur % 8);
                if (cur == 0) break;
                mach_vm_size_t got = 0;
                kr = mach_vm_read_overwrite(task, addr + off, cur,
                                           (mach_vm_address_t)buf, &got);
                if (kr == KERN_SUCCESS && got == cur) {
                    for (mach_vm_size_t o = 8; o + 32 <= cur; o += 4) {
                        float v[3];
                        int qo = 0, vo = 0;
                        if (!coord_try(buf + o, v, &qo, &vo)) continue;
                        // 平凡四元数、FRotator 布局噪声最大，一律不要
                        if (qo < 0 || qo == 100) continue;
                        if (coord_strict_mode) {
                            // 严格：只认完整 FTransform（四元数在前、位移 +16、scale 在 +28≈(1,1,1)）
                            if (qo != 0) continue;
                            float sc[3];
                            memcpy(sc, buf + o + 28, 12);
                            if (!(fabsf(sc[0] - 1.0f) < 0.02f && fabsf(sc[1] - 1.0f) < 0.02f &&
                                  fabsf(sc[2] - 1.0f) < 0.02f)) continue;
                        }
                        memread_coord_hit_t h;
                        h.addr = (uint64_t)addr + off + o + (uint64_t)vo;
                        h.v[0] = v[0]; h.v[1] = v[1]; h.v[2] = v[2];
                        h.quat_off = qo;
                        if (visit(&h, vctx)) { stop = 1; break; }
                    }
                    if (stop) break;
                    scanned += cur;
                }
                off += cur;
            }
        }
        if (stop) break;
        addr += size;
    }
    free(buf);
    mach_port_deallocate(mach_task_self(), task);
    if (pscanned) *pscanned = scanned;
    return 0;
}

typedef struct {
    memread_coord_hit_t *out;
    int cap, n;
    int q[4];          // 各布局已收数量
    int qcap[4];       // 各布局配额：0=四元数在后 1=平凡四元数 2=FTransform 3=FRotator
    int dropped[4];
} coord_collect_t;

static int coord_kind(int quat_off) {
    if (quat_off == 100) return 3;
    if (quat_off == 0) return 2;
    if (quat_off < 0) return 1;
    return 0;
}

static int coord_collect_visit(const memread_coord_hit_t *h, void *vctx) {
    coord_collect_t *c = (coord_collect_t *)vctx;
    if (c->n >= c->cap) return 1;
    int k = coord_kind(h->quat_off);
    if (c->q[k] >= c->qcap[k]) { c->dropped[k]++; return 0; }
    c->out[c->n++] = *h;
    c->q[k]++;
    return 0;
}

int memread_coord_probe(pid_t pid, memread_coord_hit_t *out, int cap, int *found,
                        volatile int *cancel, memread_region_cb cb, void *ctx) {
    if (found) *found = 0;
    if (!out || cap <= 0) return -2;
    coord_collect_t c;
    memset(&c, 0, sizeof(c));
    c.out = out;
    c.cap = cap;
    // 第一遍：严格模式，只要完整 FTransform（四元数在前 + 位移 + scale≈1）
    c.qcap[0] = 0;
    c.qcap[1] = 0;
    c.qcap[2] = cap;
    c.qcap[3] = 0;
    unsigned long long scanned = 0;
    coord_strict_mode = 1;
    int rc = coord_scan(pid, coord_collect_visit, &c, &scanned, cancel, cb, ctx);
    if (rc == 0 && c.n == 0) {
        // 严格模式一个都没命中（可能不是 UE 的 FTransform 排布）→ 退回宽松模式重扫
        memset(c.q, 0, sizeof(c.q));
        memset(c.dropped, 0, sizeof(c.dropped));
        c.n = 0;
        c.qcap[0] = cap * 3 / 4;
        c.qcap[2] = cap / 4;
        coord_strict_mode = 0;
        rc = coord_scan(pid, coord_collect_visit, &c, &scanned, cancel, cb, ctx);
    }
    if (rc != 0) return rc;
    qsort(out, (size_t)c.n, sizeof(memread_coord_hit_t), coord_hit_cmp);
    if (found) *found = c.n;
    fprintf(stderr, "坐标结构扫描(%s): %d 个（四元数 %d / 平凡 %d / FTransform %d / 角度 %d；丢弃 %d/%d/%d/%d）\n",
            coord_strict_mode ? "严格" : "宽松", c.n, c.q[0], c.q[1], c.q[2], c.q[3],
            c.dropped[0], c.dropped[1], c.dropped[2], c.dropped[3]);
    return 0;
}

typedef struct {
    const memread_coord_hit_t *base;
    int nbase;
    memread_coord_hit_t *out;
    int cap, n;
    int common, moved;
    float maxdelta;
    float minlen, maxlen;
    int tooSmall;
    int mode;          // 0=三轴位移长度落在 [minlen,maxlen]；1=只认「单轴变化」（跳跃）
} coord_diff_t;

static int coord_diff_visit(const memread_coord_hit_t *h, void *vctx) {
    coord_diff_t *d = (coord_diff_t *)vctx;
    memread_coord_hit_t key;
    key.addr = h->addr;
    const memread_coord_hit_t *hit =
        (const memread_coord_hit_t *)bsearch(&key, d->base, (size_t)d->nbase,
                                             sizeof(memread_coord_hit_t), coord_addr_cmp);
    if (!hit) return 0;
    d->common++;
    float dx = h->v[0] - hit->v[0];
    float dy = h->v[1] - hit->v[1];
    float dz = h->v[2] - hit->v[2];
    float len = sqrtf(dx * dx + dy * dy + dz * dz);
    if (len > 1e-3f) d->moved++;
    if (len > d->maxdelta) d->maxdelta = len;
    if (d->mode == 1) {
        // 姿态判据：蹲下/趴下这种「保持住的」单轴位移——一个轴变 >=10，另外两个轴挪动 <=5
        // （跳跃是瞬时状态，切回 App 时人已经落地，抓不到）
        float dd[3] = {dx, dy, dz};
        int big = 0, small = 0;
        for (int i = 0; i < 3; i++) {
            if (fabsf(dd[i]) >= 10.0f) big++;
            else if (fabsf(dd[i]) <= 5.0f) small++;
        }
        if (!(big == 1 && small == 2)) return 0;
    } else {
        if (len < d->minlen || len > d->maxlen) return 0;
    }
    if (d->n >= d->cap) { d->tooSmall = 1; return 0; }
    d->out[d->n++] = *h;
    return 0;
}

typedef struct { memread_coord_hit_t h; float dl; } cddelta_t;

static int cddelta_cmp(const void *pa, const void *pb) {
    float x = ((const cddelta_t *)pa)->dl, y = ((const cddelta_t *)pb)->dl;
    if (x == y) return 0;
    return (x > y) ? -1 : 1;      // 位移大的在前
}

#define MEMREAD_COORD_KEEP 300

static int coord_probe_diff_mode(pid_t pid, const memread_coord_hit_t *base, int nbase,
                                 memread_coord_hit_t *out, int cap, int *found,
                                 int *pcommon, int *pmoved, float *pmaxdelta,
                                 float min_len, float max_len, int mode,
                                 volatile int *cancel, memread_region_cb cb, void *ctx) {
    if (found) *found = 0;
    if (pcommon) *pcommon = 0;
    if (pmoved) *pmoved = 0;
    if (pmaxdelta) *pmaxdelta = 0;
    if (!base || nbase <= 0) return -2;

    memread_coord_hit_t *sorted = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * (size_t)nbase);
    if (!sorted) return -4;
    memcpy(sorted, base, sizeof(memread_coord_hit_t) * (size_t)nbase);
    qsort(sorted, (size_t)nbase, sizeof(memread_coord_hit_t), coord_addr_cmp);

    coord_diff_t d;
    memset(&d, 0, sizeof(d));
    d.base = sorted; d.nbase = nbase;
    d.out = out; d.cap = cap; d.n = 0;
    d.minlen = min_len; d.maxlen = max_len;
    d.mode = mode;

    unsigned long long scanned = 0;
    int rc = coord_scan(pid, coord_diff_visit, &d, &scanned, cancel, cb, ctx);
    if (rc == 0 && d.n > 1) {
        // 按位移从大到小排，只留前 MEMREAD_COORD_KEEP 条：人物的走路位移通常落在最大那一档
        cddelta_t *tmp = (cddelta_t *)malloc(sizeof(cddelta_t) * (size_t)d.n);
        if (tmp) {
            for (int i = 0; i < d.n; i++) {
                memread_coord_hit_t key = out[i];
                const memread_coord_hit_t *b = (const memread_coord_hit_t *)bsearch(
                    &key, sorted, (size_t)nbase, sizeof(memread_coord_hit_t), coord_addr_cmp);
                float dx = out[i].v[0] - b->v[0];
                float dy = out[i].v[1] - b->v[1];
                float dz = out[i].v[2] - b->v[2];
                tmp[i].h = out[i];
                tmp[i].dl = sqrtf(dx * dx + dy * dy + dz * dz);
            }
            qsort(tmp, (size_t)d.n, sizeof(cddelta_t), cddelta_cmp);
            int keep = d.n > MEMREAD_COORD_KEEP ? MEMREAD_COORD_KEEP : d.n;
            for (int i = 0; i < keep; i++) out[i] = tmp[i].h;
            d.n = keep;
            free(tmp);
        }
    }
    free(sorted);
    if (rc != 0) return rc;

    if (found) *found = d.n;
    if (pcommon) *pcommon = d.common;
    if (pmoved) *pmoved = d.moved;
    if (pmaxdelta) *pmaxdelta = d.maxdelta;
    fprintf(stderr, "坐标对比(%s): 共同 %d，位移非零 %d，命中 %d（最大位移 %.2f）\n",
            mode ? "跳跃" : "走动", d.common, d.moved, d.n, d.maxdelta);
    return 0;
}

int memread_coord_probe_diff(pid_t pid, const memread_coord_hit_t *base, int nbase,
                             memread_coord_hit_t *out, int cap, int *found,
                             int *pcommon, int *pmoved, float *pmaxdelta,
                             float min_len, float max_len,
                             volatile int *cancel, memread_region_cb cb, void *ctx) {
    return coord_probe_diff_mode(pid, base, nbase, out, cap, found, pcommon, pmoved, pmaxdelta,
                                 min_len, max_len, 0, cancel, cb, ctx);
}

// 跳跃过滤：只留「一个轴明显变化、另外两个轴几乎不动」的候选（竖直位移，水平不动）
int memread_coord_probe_jump(pid_t pid, const memread_coord_hit_t *base, int nbase,
                             memread_coord_hit_t *out, int cap, int *found,
                             int *pcommon, int *pmoved, float *pdelta,
                             volatile int *cancel, memread_region_cb cb, void *ctx) {
    return coord_probe_diff_mode(pid, base, nbase, out, cap, found, pcommon, pmoved, pdelta,
                                 3.0f, 20000.0f, 1, cancel, cb, ctx);
}

// 两次探测求差：同一地址的坐标位移落在 [min_len, max_len] 的留下（走动时该变、静止时不该变）
int memread_coord_diff(const memread_coord_hit_t *a, int na,
                       const memread_coord_hit_t *b, int nb,
                       memread_coord_hit_t *out, int cap, int *found,
                       float min_len, float max_len) {
    if (found) *found = 0;
    if (!a || !b || na <= 0 || nb <= 0 || !out || cap <= 0) return -2;
    memread_coord_hit_t *sa = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * (size_t)na);
    memread_coord_hit_t *sb = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * (size_t)nb);
    float *lens = (float *)malloc(sizeof(float) * (size_t)cap);
    if (!sa || !sb || !lens) { free(sa); free(sb); free(lens); return -4; }
    memcpy(sa, a, sizeof(memread_coord_hit_t) * (size_t)na);
    memcpy(sb, b, sizeof(memread_coord_hit_t) * (size_t)nb);
    qsort(sa, (size_t)na, sizeof(memread_coord_hit_t), coord_addr_cmp);
    qsort(sb, (size_t)nb, sizeof(memread_coord_hit_t), coord_addr_cmp);

    int i = 0, j = 0, n = 0;
    while (i < na && j < nb && n < cap) {
        if (sa[i].addr < sb[j].addr) { i++; continue; }
        if (sa[i].addr > sb[j].addr) { j++; continue; }
        float dx = sb[j].v[0] - sa[i].v[0];
        float dy = sb[j].v[1] - sa[i].v[1];
        float dz = sb[j].v[2] - sa[i].v[2];
        float len = sqrtf(dx * dx + dy * dy + dz * dz);
        if (len >= min_len && len <= max_len) {
            out[n] = sb[j];
            lens[n] = len;
            n++;
        }
        i++; j++;
    }
    free(sa); free(sb);
    // 位移大的排前面（走动距离更明显，最可能是人物根组件）
    for (int k = 1; k < n; k++) {
        memread_coord_hit_t h = out[k];
        float L = lens[k];
        int m = k - 1;
        while (m >= 0 && lens[m] < L) { out[m + 1] = out[m]; lens[m + 1] = lens[m]; m--; }
        out[m + 1] = h;
        lens[m + 1] = L;
    }
    free(lens);
    if (found) *found = n;
    return 0;
}

// 把一批地址直接灌进候选表（坐标结构扫描命中后用，供列表里点『链』）
int memread_valscan_set(pid_t pid, const uint64_t *addrs, int n, int type) {
    if (!addrs || n <= 0) return -2;
    if (n > MEMREAD_VALSCAN_MAX) n = MEMREAD_VALSCAN_MAX;
    memread_valscan_reset();
    g_valents = (memread_valent_t *)calloc(MEMREAD_VALSCAN_MAX, sizeof(memread_valent_t));
    if (!g_valents) return -4;
    // 顺手把当前值读出来当「上一轮值」，否则列表里全是 0
    task_t task = MACH_PORT_NULL;
    int have_task = 0;
    if (pid > 0 && task_for_pid(mach_task_self(), pid, &task) == KERN_SUCCESS) {
        have_task = 1;
    }
    for (int i = 0; i < n; i++) {
        g_valents[i].addr = addrs[i];
        g_valents[i].prev = 0;
        g_valents[i].type = type;
        uint64_t raw = 0;
        if (have_task && val_read_raw(task, addrs[i], type, &raw) == 0) {
            g_valents[i].prev = raw;
        }
    }
    if (have_task) mach_port_deallocate(mach_task_self(), task);
    g_valcount = (unsigned long long)n;
    return 0;
}

#pragma mark - 指针链扫描（模块静态槽 + 多级偏移，跨重启复原堆地址）

#define MEMREAD_CHAIN_NODE_CAP 120000    // 每层最多保留的候选槽
#define MEMREAD_CHAIN_OFF_NEG  0x20      // 允许的极小负偏移，杜绝“指针指向对象中部”的别名命中

static volatile int g_chain_level = 0;
static volatile unsigned long long g_chain_bytes = 0;
static volatile unsigned long long g_chain_total = 0;
static volatile int g_chain_nodes = 0;
static volatile int g_chain_results = 0;

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

// 地址是否落在某个已解析模块的任意段里
static int chain_addr_in_module(uint64_t addr) {
    if (!g_modsegs) return 0;
    for (int i = 0; i < g_modsegn; i++) {
        if (addr >= g_modsegs[i].seg_start && addr < g_modsegs[i].seg_end) return 1;
    }
    return 0;
}

// 对象合法性：8 字节对齐、可读，且对象开头 8 字节（vtable）指向模块内
// （UE 的 UObject 都是这个形态；能挡掉绝大多数“值凑巧相等”的别名路径）
static int chain_is_object(task_t task, uint64_t ptr) {
    if (ptr < 0x100000000ULL || (ptr & 7)) return 0;
    uint64_t vt = 0;
    if (chain_read_u64(task, ptr, &vt) != 0) return 0;
    if (vt < 0x100000000ULL || (vt & 7)) return 0;
    return chain_addr_in_module(vt);
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
                g_chain_bytes += (unsigned long long)cur;
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
                    uint64_t lo = v - MEMREAD_CHAIN_OFF_NEG;   // 只允许极小的负偏移（成员指针指向对象内部时才有）
                    uint64_t hi = v + MEMREAD_CHAIN_OFF_WIN;   // UE 的 UObject 字段偏移经常上万字节
                    int i = chain_frontier_lower(front, fn, lo);
                    for (; i < fn && front[i] <= hi; i++) {
                        int64_t d = (int64_t)front[i] - (int64_t)v;
                        if (d < -(int64_t)MEMREAD_CHAIN_OFF_NEG || d > (int64_t)MEMREAD_CHAIN_OFF_WIN) continue;
                        if (!chain_is_object(task, v)) continue;   // 值不是对象指针 → 别名，丢弃（放在匹配之后，避免每个槽都读一次）
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

// 槽地址是否落在某个模块的数据段里（是 → 该地址可跨重启复原）
// 允许 __DATA / __DATA_CONST / __common / __bss：静态指针不一定都在可写段
static int chain_module_slot(uint64_t addr, memread_modseg_t *out) {
    if (!g_modsegs) return -1;
    for (int i = 0; i < g_modsegn; i++) {
        const char *sn = g_modsegs[i].segname;
        int is_data = (strstr(sn, "DATA") != NULL) || (strstr(sn, "data") != NULL) ||
                      (strstr(sn, "common") != NULL) || (strstr(sn, "bss") != NULL);
        if (!is_data) continue;
        if (addr >= g_modsegs[i].seg_start && addr < g_modsegs[i].seg_end) {
            if (out) *out = g_modsegs[i];
            return 0;
        }
    }
    return 1;
}

// 浮点是否有限且在合理范围内（排除 NaN/Inf、垃圾数据）
static int chain_float_ok(float f, float lim) {
    if (!isfinite(f)) return 0;
    if (f > lim || f < -lim) return 0;
    return 1;
}

// 末跳地址是否像「FVector + FQuat」：3 个有限 float，紧跟 4 个分量构成模长≈1 的四元数
// UE 的 USceneComponent 里 RelativeLocation(FVector, 12B) 之后就是旋转；FQuat 需 16B 对齐，
// 所以旋转可能从 +12 开始，也可能跳 4 字节 padding 从 +16 开始，两处都试。
static int chain_vec3_quat(task_t task, uint64_t addr) {
    if ((addr & 3) != 0) return 0;
    unsigned char buf[36];
    mach_vm_size_t got = 0;
    if (mach_vm_read_overwrite(task, addr, sizeof(buf),
                               (mach_vm_address_t)buf, &got) != KERN_SUCCESS) return 0;
    if (got < sizeof(buf)) return 0;
    float v[3];
    memcpy(v, buf, 12);
    for (int i = 0; i < 3; i++) if (!chain_float_ok(v[i], 200000.0f)) return 0;
    for (int off = 12; off <= 16; off += 4) {
        float q[4];
        memcpy(q, buf + off, 16);
        int ok = 1;
        for (int i = 0; i < 4; i++) if (!chain_float_ok(q[i], 1.001f)) { ok = 0; break; }
        if (!ok) continue;
        float n = q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3];
        if (n > 0.999f && n < 1.001f) return 1;
    }
    return 0;
}

static int chain_verify(task_t task, uint64_t slot, const int64_t *offs, int depth, uint64_t target,
                        int *out_valid, int *out_flags) {
    uint64_t a = slot;
    int valid = 0;
    for (int i = 0; i < depth; i++) {
        uint64_t v = 0;
        if (chain_read_u64(task, a, &v) != 0) return -1;
        if (v < 0x100000000ULL) return 1;
        if (chain_is_object(task, v)) valid++;
        a = (uint64_t)((int64_t)v + offs[i]);
    }
    if (out_valid) *out_valid = valid;
    if (a != target) return 1;
    if (out_flags && chain_vec3_quat(task, target)) *out_flags |= MEMREAD_CHAIN_FLAG_VEC3QUAT;
    return 0;
}

static int chain_cmp(const void *pa, const void *pb) {
    const memread_chain_t *a = (const memread_chain_t *)pa;
    const memread_chain_t *b = (const memread_chain_t *)pb;
    // 对象校验通过的跳数多者优先：这才是“真对象路径”的主要判据
    if (a->valid_hops != b->valid_hops) return (b->valid_hops - a->valid_hops);
    // 末跳是「FVector + 四元数」形态（坐标字段）者优先
    int av = (a->flags & MEMREAD_CHAIN_FLAG_VEC3QUAT) ? 1 : 0;
    int bv = (b->flags & MEMREAD_CHAIN_FLAG_VEC3QUAT) ? 1 : 0;
    if (av != bv) return bv - av;
    if (a->depth != b->depth) return (a->depth < b->depth) ? -1 : 1;
    int am = (strcmp(a->name, "main") == 0);
    int bm = (strcmp(b->name, "main") == 0);
    if (am != bm) return bm - am;                 // main 模块优先
    long long sa = 0, sb = 0;
    for (int i = 0; i < a->depth; i++) sa += llabs(a->offs[i]);
    for (int i = 0; i < b->depth; i++) sb += llabs(b->offs[i]);
    if (sa != sb) return (sa < sb) ? -1 : 1;      // 偏移合计小优先
    if (a->static_off != b->static_off) return (a->static_off < b->static_off) ? -1 : 1;
    return 0;
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
    unsigned long long tb = 0, tr = 0;
    memread_writable_bytes(pid, 1, &tb, &tr);
    g_chain_total = tb;
    g_chain_bytes = 0;
    g_chain_nodes = 0;
    g_chain_results = 0;
    g_chain_level = 1;
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
        g_chain_level = lvl;
        g_chain_bytes = 0;
        g_chain_nodes = 0;
        chain_scan_level(task, front, fn, lv[lvl], MEMREAD_CHAIN_NODE_CAP, &ln[lvl], cancel);
        g_chain_nodes = ln[lvl];

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
                int valid_hops = 0;
                int flags = 0;
                if (chain_verify(task, lv[lvl][j].addr, offs, depth, target, &valid_hops, &flags) != 0) continue;
                memread_chain_t *c = &out[results];
                memset(c, 0, sizeof(*c));
                memcpy(c->uuid, seg.uuid, sizeof(c->uuid));
                memcpy(c->name, seg.name, sizeof(c->name));
                c->static_off = lv[lvl][j].addr - seg.base;
                c->depth = depth;
                c->valid_hops = valid_hops;
                c->flags = flags;
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
    g_chain_results = results;
    if (results > 1) qsort(out, (size_t)results, sizeof(memread_chain_t), chain_cmp);
    free(front);
    for (int i = 0; i <= MEMREAD_CHAIN_MAX_DEPTH; i++) if (lv[i]) free(lv[i]);
    mach_port_deallocate(mach_task_self(), task);
    fprintf(stderr, "指针链扫描: 深度=%d 条数=%d\n", stopdepth, results);
    return results;
}

#pragma mark - 从锚点（弹夹）推自己坐标（对象图 BFS，不用人工动作）

#define ANCHOR_OBJ_MAX 400
#define ANCHOR_OBJ_BYTES 0x800

static int anchor_ptr_ok(uint64_t v) {
    if (v < 0x100000000ULL || v >= 0x8000000000ULL) return 0;
    return ((v & 7) == 0);
}

static int anchor_in_module(uint64_t v) {
    for (int i = 0; i < g_modsegn; i++) {
        if (v >= g_modsegs[i].seg_start && v < g_modsegs[i].seg_end) return 1;
    }
    return 0;
}

static int anchor_read(task_t task, uint64_t addr, void *buf, size_t n) {
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(task, (mach_vm_address_t)addr, (mach_vm_size_t)n,
                                              (mach_vm_address_t)buf, &got);
    return (kr == KERN_SUCCESS && got == n) ? 0 : -1;
}

static int anchor_scale1(const float *s) {
    return fabsf(s[0] - 1.0f) < 0.02f && fabsf(s[1] - 1.0f) < 0.02f && fabsf(s[2] - 1.0f) < 0.02f;
}

int memread_coord_from_anchor(pid_t pid, uint64_t anchor, int max_depth,
                              memread_anchor_coord_t *out, int cap, int *found,
                              int *pobjects) {
    if (found) *found = 0;
    if (pobjects) *pobjects = 0;
    if (!out || cap <= 0 || anchor == 0) return -2;
    if (module_cache_ensure(pid) != 0 || g_modsegn == 0) return 2;
    if (max_depth < 1) max_depth = 1;
    if (max_depth > 6) max_depth = 6;

    task_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return -1;

    // 1) 找包含锚点的对象基址：向下扫最近处「指向模块（vtable）」的 8 字节
    uint64_t base = 0;
    for (uint64_t off = 8; off <= 0x2000; off += 8) {
        if (anchor < off + 0x100000000ULL) break;
        uint64_t b = anchor - off, v = 0;
        if (anchor_read(task, b, &v, 8) != 0) continue;
        if (anchor_in_module(v)) { base = b; break; }
    }
    if (base == 0) {
        mach_port_deallocate(mach_task_self(), task);
        return -3;   // 找不到对象基址
    }

    typedef struct { uint64_t b; int d; } aobj_t;
    aobj_t *q = (aobj_t *)calloc(ANCHOR_OBJ_MAX, sizeof(aobj_t));
    unsigned char *buf = (unsigned char *)malloc(ANCHOR_OBJ_BYTES);
    if (!q || !buf) {
        free(q); free(buf);
        mach_port_deallocate(mach_task_self(), task);
        return -4;
    }

    int qn = 0, qi = 0, found_n = 0;
    q[qn].b = base; q[qn].d = 0; qn++;

    while (qi < qn) {
        uint64_t ob = q[qi].b;
        int d = q[qi].d;
        qi++;
        if (pobjects) (*pobjects)++;
        if (anchor_read(task, ob, buf, ANCHOR_OBJ_BYTES) != 0) continue;

        for (int off = 0; off + 40 <= ANCHOR_OBJ_BYTES; off += 8) {
            // 先认 FTransform（四元数 + 位移 + scale≈1）：这是组件世界变换
            float q4[4], tr[3], sc[3];
            memcpy(q4, buf + off, 16);
            memcpy(tr, buf + off + 16, 12);
            memcpy(sc, buf + off + 28, 12);
            int triv = 1;
            if (coord_quat_unit(q4, &triv) && !triv && coord_vec_ok(tr) && anchor_scale1(sc)) {
                uint64_t ca = ob + (uint64_t)off + 16;
                int dup = 0;
                for (int i = 0; i < found_n; i++) if (out[i].coord_addr == ca) { dup = 1; break; }
                if (!dup && found_n < cap) {
                    out[found_n].coord_addr = ca;
                    out[found_n].object = ob;
                    out[found_n].v[0] = tr[0];
                    out[found_n].v[1] = tr[1];
                    out[found_n].v[2] = tr[2];
                    out[found_n].depth = d;
                    found_n++;
                }
                continue;    // 这一格是变换数据，不当指针
            }
            uint64_t v = 0;
            memcpy(&v, buf + off, 8);
            if (!anchor_ptr_ok(v) || d >= max_depth || qn >= ANCHOR_OBJ_MAX) continue;
            uint64_t vt = 0;
            if (anchor_read(task, v, &vt, 8) != 0) continue;     // 必须能读、且像对象
            if (!anchor_in_module(vt)) continue;
            int seen = 0;
            for (int i = 0; i < qn; i++) if (q[i].b == v) { seen = 1; break; }
            if (seen) continue;
            q[qn].b = v; q[qn].d = d + 1; qn++;
        }
    }

    // 层次浅的优先
    for (int i = 1; i < found_n; i++) {
        memread_anchor_coord_t key = out[i];
        int j = i - 1;
        while (j >= 0 && out[j].depth > key.depth) { out[j + 1] = out[j]; j--; }
        out[j + 1] = key;
    }

    free(q);
    free(buf);
    mach_port_deallocate(mach_task_self(), task);
    if (found) *found = found_n;
    fprintf(stderr, "锚点推坐标: 基址=0x%llX 对象=%d 坐标=%d\n",
            (unsigned long long)base, pobjects ? *pobjects : 0, found_n);
    return 0;
}

#pragma mark - 反向链扫描（从目标地址往上找「谁指向它」）

// 正向扫不到时用这个：拿目标地址当起点，反查哪块内存里的指针指向它，
// 再对那些指针的基址反查，直到槽落在模块数据段（跨重启可复原）。

typedef struct {
    uint64_t slot;    // 槽地址（命中后即静态槽候选）
    uint64_t base;    // 槽里读到的值：下一层要找的 target
    int64_t off;      // target - base
    int parent;       // 上一层节点下标
} chainrev_node_t;

typedef struct { uint64_t t; int idx; } chainrev_target_t;

static int chainrev_target_cmp(const void *pa, const void *pb) {
    uint64_t x = ((const chainrev_target_t *)pa)->t;
    uint64_t y = ((const chainrev_target_t *)pb)->t;
    if (x == y) return 0;
    return (x < y) ? -1 : 1;
}

#define MEMREAD_CHAIN_REV_NODE_CAP 3000

int memread_chain_scan_reverse(pid_t pid, uint64_t target, int max_depth,
                               memread_chain_t *out, int cap) {
    if (!out || cap <= 0 || target == 0) return -2;
    if (max_depth < 1) max_depth = 1;
    if (max_depth > MEMREAD_CHAIN_MAX_DEPTH) max_depth = MEMREAD_CHAIN_MAX_DEPTH;
    if (module_cache_ensure(pid) != 0 || g_modsegn == 0) return 2;

    task_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return -1;

    chainrev_node_t *lv[MEMREAD_CHAIN_MAX_DEPTH + 1] = {0};
    int ln[MEMREAD_CHAIN_MAX_DEPTH + 1] = {0};
    for (int i = 0; i <= max_depth; i++) {
        lv[i] = (chainrev_node_t *)calloc(MEMREAD_CHAIN_REV_NODE_CAP, sizeof(chainrev_node_t));
        if (!lv[i]) {
            for (int k = 0; k < i; k++) free(lv[k]);
            mach_port_deallocate(mach_task_self(), task);
            return -4;
        }
    }

    lv[0][0].slot = 0;
    lv[0][0].base = target;
    lv[0][0].off = 0;
    lv[0][0].parent = -1;
    ln[0] = 1;

    const mach_vm_size_t CHUNK = 4ULL * 1024 * 1024;
    unsigned char *buf = (unsigned char *)malloc((size_t)CHUNK);
    int results = 0;
    int stopdepth = 0;

    if (buf) {
        for (int d = 1; d <= max_depth && results < cap; d++) {
            chainrev_target_t *tg = (chainrev_target_t *)malloc(sizeof(chainrev_target_t) * (size_t)ln[d - 1]);
            if (!tg) break;
            for (int i = 0; i < ln[d - 1]; i++) {
                tg[i].t = lv[d - 1][i].base;
                tg[i].idx = i;
            }
            qsort(tg, (size_t)ln[d - 1], sizeof(chainrev_target_t), chainrev_target_cmp);

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
                if (!snap_region_ok(&info, size)) { addr += size; continue; }

                uint64_t off = 0;
                while (off + 8 <= (uint64_t)size && !full) {
                    mach_vm_size_t cur = (mach_vm_size_t)((size - off > CHUNK) ? CHUNK : (size - off));
                    cur -= (cur % 8);
                    if (cur == 0) break;
                    mach_vm_size_t got = 0;
                    kr = mach_vm_read_overwrite(task, addr + off, cur,
                                               (mach_vm_address_t)buf, &got);
                    if (kr != KERN_SUCCESS || got != cur) { off += cur; continue; }

                    for (mach_vm_size_t o = 0; o + 8 <= cur; o += 8) {
                        uint64_t v;
                        memcpy(&v, buf + o, 8);
                        if (v < 0x100000000ULL) continue;
                        // 在目标表里找 t ∈ [v - OFF_NEG, v + OFF_WIN]
                        uint64_t lo = v - MEMREAD_CHAIN_OFF_NEG;
                        uint64_t hi = v + MEMREAD_CHAIN_OFF_WIN;
                        int i = 0;
                        {
                            int l = 0, r = ln[d - 1] - 1, pos = ln[d - 1];
                            while (l <= r) {
                                int m = (l + r) / 2;
                                if (tg[m].t < lo) l = m + 1;
                                else { pos = m; r = m - 1; }
                            }
                            i = pos;
                        }
                        for (; i < ln[d - 1] && tg[i].t <= hi; i++) {
                            int64_t delta = (int64_t)tg[i].t - (int64_t)v;
                            if (delta < -(int64_t)MEMREAD_CHAIN_OFF_NEG || delta > (int64_t)MEMREAD_CHAIN_OFF_WIN) continue;
                            if (!chain_is_object(task, v)) continue;   // 基址必须是对象，否则不是结构指针

                            uint64_t slot = (uint64_t)addr + off + o;
                            if (ln[d] >= MEMREAD_CHAIN_REV_NODE_CAP) { full = 1; break; }
                            int node_idx = ln[d];
                            chainrev_node_t *nd = &lv[d][ln[d]];
                            nd->slot = slot;
                            nd->base = v;
                            nd->off = delta;
                            nd->parent = tg[i].idx;
                            ln[d]++;

                            memread_modseg_t seg;
                            if (chain_module_slot(slot, &seg) == 0 && results < cap) {
                                // 槽在模块数据段：把这一路的偏移串成链并验证
                                int64_t offs[MEMREAD_CHAIN_MAX_DEPTH] = {0};
                                int depth = d;
                                int p = node_idx;
                                for (int k = d; k >= 1 && p >= 0; k--) {
                                    offs[k - 1] = lv[k][p].off;   // offs[0] = 离静态槽最近的那一跳
                                    p = lv[k][p].parent;
                                }
                                int valid = 0, flags = 0;
                                if (chain_verify(task, slot, offs, depth, target, &valid, &flags) == 0) {
                                    int dup = 0;
                                    for (int q = 0; q < results; q++) {
                                        if (out[q].static_off == slot - seg.base &&
                                            strcmp(out[q].uuid, seg.uuid) == 0) { dup = 1; break; }
                                    }
                                    if (!dup) {
                                        memread_chain_t *c = &out[results];
                                        memset(c, 0, sizeof(*c));
                                        memcpy(c->uuid, seg.uuid, sizeof(c->uuid));
                                        memcpy(c->name, seg.name, sizeof(c->name));
                                        c->static_off = slot - seg.base;
                                        c->depth = depth;
                                        c->valid_hops = valid;
                                        c->flags = flags;
                                        memcpy(c->offs, offs, sizeof(c->offs));
                                        results++;
                                    }
                                }
                            }
                        }
                        if (full) break;
                    }
                    if (full) break;
                    off += cur;
                }
                if (full) break;
                addr += size;
            }
            free(tg);
            if (results > 0) { stopdepth = d; break; }
            if (ln[d] == 0) break;     // 上一层就没指针指向，再往上也没意义
        }
        free(buf);
    }

    for (int i = 0; i <= max_depth; i++) free(lv[i]);
    mach_port_deallocate(mach_task_self(), task);
    fprintf(stderr, "反向链扫描: 深度=%d 条数=%d\n", stopdepth, results);
    return results;
}

// 扫描进度：层数 / 本层已扫字节 / 本层总量 / 本层候选槽 / 已命中链
void memread_chain_progress(int *level, unsigned long long *done, unsigned long long *total,
                            int *nodes, int *results) {
    if (level) *level = g_chain_level;
    if (done) *done = g_chain_bytes;
    if (total) *total = g_chain_total;
    if (nodes) *nodes = g_chain_nodes;
    if (results) *results = g_chain_results;
}

#pragma mark - 值签名重定位（网络同步的数值：不靠指针链，靠周围字节指纹）

#define MEMREAD_SIG_PRE         32
#define MEMREAD_SIG_LEN         128
#define MEMREAD_SIG_MAX_STABLE  128
#define MEMREAD_SIG_SAMPLES     4
#define MEMREAD_SIG_RESULT_CAP  32

static int sig_read_block(task_t task, uint64_t addr, int len, unsigned char *buf) {
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(task, (mach_vm_address_t)addr, (mach_vm_size_t)len,
                                             (mach_vm_address_t)buf, &got);
    if (kr != KERN_SUCCESS || got != (mach_vm_size_t)len) return -1;
    return 0;
}

// 进度（扫描线程写、UI 定时读）：phase 0=空闲 1=采样 2=扫描
static volatile int g_sig_phase = 0;
static volatile unsigned long long g_sig_done = 0, g_sig_total = 0;
static volatile int g_sig_hits = 0;

void memread_sig_progress(int *phase, unsigned long long *done, unsigned long long *total, int *hits) {
    if (phase) *phase = g_sig_phase;
    if (done) *done = g_sig_done;
    if (total) *total = g_sig_total;
    if (hits) *hits = g_sig_hits;
}

// 单帧采样：读目标前后一段窗口（供 App 侧「切游戏改数值 → 回来采一次」的分帧指纹）
int memread_sig_read_frame(pid_t pid, uint64_t addr, unsigned char *out, int len, int pre) {
    if (!out || len <= 0 || pre < 0 || addr < (uint64_t)pre) return -2;
    task_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return -1;
    int rc = sig_read_block(task, addr - (uint64_t)pre, len, out);
    mach_port_deallocate(mach_task_self(), task);
    return (rc == 0) ? 0 : -3;
}

// 采样：连读 4 次（每次间隔 300ms），只保留完全不变的字节；目标数值本身的字节强制排除
int memread_sig_capture(pid_t pid, uint64_t addr, int value_size, memread_sig_t *out) {
    if (!out) return -2;
    memset(out, 0, sizeof(*out));
    if (addr < MEMREAD_SIG_PRE) return -3;
    task_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return -1;

    g_sig_phase = 1;
    g_sig_done = 0;
    g_sig_total = MEMREAD_SIG_SAMPLES;
    g_sig_hits = 0;

    uint64_t start = addr - MEMREAD_SIG_PRE;
    unsigned char buf[MEMREAD_SIG_SAMPLES][MEMREAD_SIG_LEN];
    int ok = 1;
    for (int k = 0; k < MEMREAD_SIG_SAMPLES; k++) {
        if (sig_read_block(task, start, MEMREAD_SIG_LEN, buf[k]) != 0) { ok = 0; break; }
        g_sig_done = (unsigned long long)(k + 1);
        if (k + 1 < MEMREAD_SIG_SAMPLES) usleep(300 * 1000);
    }
    mach_port_deallocate(mach_task_self(), task);
    if (!ok) { g_sig_phase = 0; return -3; }

    out->win = MEMREAD_SIG_LEN;
    out->target_off = MEMREAD_SIG_PRE;
    int n = 0;
    for (int i = 0; i < MEMREAD_SIG_LEN; i++) {
        if (i >= MEMREAD_SIG_PRE && i < MEMREAD_SIG_PRE + value_size) continue;   // 数值会变，不能进指纹
        int same = 1;
        for (int k = 1; k < MEMREAD_SIG_SAMPLES; k++) {
            if (buf[k][i] != buf[0][i]) { same = 0; break; }
        }
        if (!same) continue;
        if (n >= MEMREAD_SIG_MAX_STABLE) break;
        out->offs[n] = (uint8_t)i;
        out->vals[n] = buf[0][i];
        n++;
    }
    out->stable_n = n;
    g_sig_phase = 0;
    fprintf(stderr, "签名采样: 稳定字节 %d/%d\n", n, MEMREAD_SIG_LEN);
    return (n >= 12) ? 0 : -4;
}

// 在可写内存里找指纹，返回候选目标地址（按匹配度降序，最多 cap 条）
// 网络同步的结构体会带时间戳/序号等易变字段，所以不要求 100% 命中：≥75% 稳定字节即可，
// 再按匹配度高低的顺序返回。取消返回 -5。
typedef struct { uint64_t addr; int score; } sig_hit_t;

static int sig_hit_cmp(const void *a, const void *b) {
    const sig_hit_t *x = (const sig_hit_t *)a;
    const sig_hit_t *y = (const sig_hit_t *)b;
    if (x->score != y->score) return (y->score - x->score);
    return (x->addr < y->addr) ? -1 : (x->addr > y->addr);
}

int memread_sig_scan(pid_t pid, const memread_sig_t *sig, uint64_t *out, int cap,
                     volatile int *cancel) {
    if (!sig || !out || cap <= 0 || sig->stable_n <= 0) return -2;
    task_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return -1;

    int need = sig->stable_n * 3 / 4;
    if (need < 8) need = 8;
    if (need > sig->stable_n) need = sig->stable_n;

    // 先量一遍可写区域总量（只枚举 region，不读内存），给进度条用
    g_sig_phase = 2;
    g_sig_done = 0;
    g_sig_total = 0;
    g_sig_hits = 0;
    {
        mach_vm_address_t a0 = 0;
        for (;;) {
            mach_vm_size_t s0 = 0;
            vm_region_basic_info_data_64_t i0;
            mach_msg_type_number_t c0 = VM_REGION_BASIC_INFO_COUNT_64;
            mach_port_t o0 = MACH_PORT_NULL;
            kern_return_t k0 = mach_vm_region(task, &a0, &s0, VM_REGION_BASIC_INFO_64,
                                              (vm_region_info_t)&i0, &c0, &o0);
            if (k0 != KERN_SUCCESS || s0 == 0) break;
            if (snap_region_ok(&i0, s0)) g_sig_total += (unsigned long long)s0;
            a0 += s0;
        }
    }

    const mach_vm_size_t CHUNK = 4ULL * 1024 * 1024;
    unsigned char *buf = (unsigned char *)malloc((size_t)CHUNK);
    if (!buf) {
        mach_port_deallocate(mach_task_self(), task);
        return -4;
    }

    enum { HIT_CAP = 512 };
    sig_hit_t *hits = (sig_hit_t *)calloc(HIT_CAP, sizeof(sig_hit_t));
    if (!hits) { free(buf); mach_port_deallocate(mach_task_self(), task); return -4; }
    int nh = 0;
    int cancelled = 0;

    mach_vm_address_t addr = 0;
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
            while (off + 8 <= (uint64_t)size) {
                if (cancel && *cancel) { cancelled = 1; break; }
                mach_vm_size_t cur = (mach_vm_size_t)((size - off > CHUNK) ? CHUNK : (size - off));
                if (cur < (mach_vm_size_t)(sig->win + 8)) { off += cur; continue; }
                mach_vm_size_t got = 0;
                kr = mach_vm_read_overwrite(task, addr + off, cur, (mach_vm_address_t)buf, &got);
                if (kr != KERN_SUCCESS || got != cur) { off += cur; continue; }

                for (mach_vm_size_t pos = sig->target_off; pos + 4 <= cur; pos += 4) {
                    int base = (int)pos - sig->target_off;
                    if (base + sig->win > (int)cur) break;
                    // 先用前 6 个稳定字节快速过滤
                    int quick = (sig->stable_n < 6) ? sig->stable_n : 6;
                    int pass = 1;
                    for (int i = 0; i < quick; i++) {
                        if (buf[base + sig->offs[i]] != sig->vals[i]) { pass = 0; break; }
                    }
                    if (!pass) continue;
                    int score = 0;
                    for (int i = 0; i < sig->stable_n; i++) {
                        if (buf[base + sig->offs[i]] == sig->vals[i]) score++;
                    }
                    if (score < need) continue;
                    uint64_t cand = (uint64_t)addr + off + pos;
                    // 64 字节内视为同一对象，只保留分数高的那个
                    int merged = 0;
                    for (int i = 0; i < nh; i++) {
                        uint64_t d = hits[i].addr > cand ? hits[i].addr - cand : cand - hits[i].addr;
                        if (d <= 64) {
                            if (score > hits[i].score) { hits[i].addr = cand; hits[i].score = score; }
                            merged = 1;
                            break;
                        }
                    }
                    if (merged) continue;
                    if (nh < HIT_CAP) { hits[nh].addr = cand; hits[nh].score = score; nh++; }
                    g_sig_hits = nh;
                }
                g_sig_done += (unsigned long long)cur;
                off += cur;
            }
        }
        if (cancelled) break;
        addr += size;
    }

    qsort(hits, (size_t)nh, sizeof(sig_hit_t), sig_hit_cmp);
    int n = 0;
    for (int i = 0; i < nh && n < cap; i++) out[n++] = hits[i].addr;

    free(hits);
    free(buf);
    mach_port_deallocate(mach_task_self(), task);
    g_sig_phase = 0;
    fprintf(stderr, "签名扫描: 命中 %d 处（阈值 %d/%d）\n", n, need, sig->stable_n);
    if (cancelled && n == 0) return -5;
    return n;
}

// 按保存下来的链（模块 UUID + 静态槽偏移 + 各级偏移）算出本轮目标地址
// 返回 0 成功；2 = 模块未加载；-3 = 链断了（指针不可读或越界）
int memread_chain_resolve(pid_t pid, const char *uuid, uint64_t static_off,
                          const int64_t *offs, int depth, uint64_t *out_addr) {
    return memread_chain_resolve_ex(pid, uuid, static_off, offs, depth, out_addr, NULL, NULL);
}

// 带诊断：fail_hop 从 1 开始，表示第几跳的指针读不出来 / 非法；fail_val 是那一跳槽里的原值
int memread_chain_resolve_ex(pid_t pid, const char *uuid, uint64_t static_off,
                             const int64_t *offs, int depth, uint64_t *out_addr,
                             int *fail_hop, uint64_t *fail_val) {
    if (out_addr) *out_addr = 0;
    if (fail_hop) *fail_hop = 0;
    if (fail_val) *fail_val = 0;
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
        if (chain_read_u64(task, a, &v) != 0 || v < 0x100000000ULL) {
            rc = -3;
            if (fail_hop) *fail_hop = i + 1;
            if (fail_val) *fail_val = v;
            break;
        }
        // 中间指针必须是「对象」（开头是模块内 vtable），否则说明链指到了普通数据
        if (i + 1 < depth && !chain_is_object(task, v)) {
            rc = -3;
            if (fail_hop) *fail_hop = i + 1;
            if (fail_val) *fail_val = v;
            break;
        }
        a = (uint64_t)((int64_t)v + offs[i]);
    }
    mach_port_deallocate(mach_task_self(), task);
    if (rc == 0 && out_addr) *out_addr = a;
    return rc;
}

#pragma mark - 同类对象枚举（单机：NPC 与玩家角色同类）

// 取链上第 hop 跳的对象指针：hop=0 是静态槽里的值，hop=1 是再解一次引用后的对象
int memread_chain_hop_object(pid_t pid, const char *uuid, uint64_t static_off,
                             const int64_t *offs, int depth, int hop, uint64_t *out_obj) {
    if (out_obj) *out_obj = 0;
    if (!offs || hop < 0 || hop >= depth) return -2;
    uint64_t base = 0;
    char nm[64] = {0};
    int br = memread_module_base(pid, uuid, &base, nm, sizeof(nm));
    if (br == 1 || base == 0) return 2;
    if (br != 0) return -1;
    task_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return -1;
    uint64_t a = base + static_off;
    int rc = -3;
    for (int i = 0; i <= hop; i++) {
        uint64_t v = 0;
        if (chain_read_u64(task, a, &v) != 0 || v < 0x100000000ULL) {
            rc = -3;
            break;
        }
        if (i == hop) {
            if (out_obj) *out_obj = v;
            rc = 0;
            break;
        }
        a = (uint64_t)((int64_t)v + offs[i]);
    }
    mach_port_deallocate(mach_task_self(), task);
    return rc;
}

// 读某个同类对象的 RootComponent + 坐标偏移，得到它的位置
static int peer_read_coord(task_t task, uint64_t obj, int64_t root_off, int64_t loc_off, float v[3]) {
    uint64_t root = 0;
    if (chain_read_u64(task, (uint64_t)((int64_t)obj + root_off), &root) != 0) return 0;
    if (root < 0x100000000ULL) return 0;
    unsigned char buf[12];
    mach_vm_size_t got = 0;
    uint64_t la = (uint64_t)((int64_t)root + loc_off);
    if (mach_vm_read_overwrite(task, la, 12, (mach_vm_address_t)buf, &got) != KERN_SUCCESS || got != 12) return 0;
    memcpy(v, buf, 12);
    return coord_vec_ok(v);
}

static int peer_cmp(const void *pa, const void *pb) {
    const memread_peer_t *a = (const memread_peer_t *)pa;
    const memread_peer_t *b = (const memread_peer_t *)pb;
    if (a->dist == b->dist) return 0;
    return (a->dist < b->dist) ? -1 : 1;
}

// 同一个 C++ 类 ⇒ 同一个 vtable。玩家角色和同类 NPC 的 vtable 相同，
// 所以扫「对象头 8 字节 == 自己的 vtable」就能把同类单位全找出来，不用遍历场景树。
int memread_peers_scan(pid_t pid, uint64_t self_obj, int64_t root_off, int64_t loc_off,
                       memread_peer_t *out, int cap, int *found, uint64_t *out_vtable,
                       volatile int *cancel) {
    if (found) *found = 0;
    if (out_vtable) *out_vtable = 0;
    if (!out || cap <= 0 || self_obj == 0) return -2;
    task_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return -1;

    uint64_t vt = 0;
    if (chain_read_u64(task, self_obj, &vt) != 0 || vt < 0x100000000ULL) {
        mach_port_deallocate(mach_task_self(), task);
        return -3;                      // 自己这个地址不是对象头
    }
    if (out_vtable) *out_vtable = vt;

    float selfv[3] = {0, 0, 0};
    int self_ok = peer_read_coord(task, self_obj, root_off, loc_off, selfv);

    const mach_vm_size_t CHUNK = 4ULL * 1024 * 1024;
    unsigned char *buf = (unsigned char *)malloc((size_t)CHUNK);
    if (!buf) {
        mach_port_deallocate(mach_task_self(), task);
        return -4;
    }
    int n = 0;
    int stop = 0;
    mach_vm_address_t addr = 0;
    for (;;) {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t objp = MACH_PORT_NULL;
        kern_return_t kr = mach_vm_region(task, &addr, &size, VM_REGION_BASIC_INFO_64,
                                         (vm_region_info_t)&info, &cnt, &objp);
        if (kr != KERN_SUCCESS || size == 0) break;
        if (snap_region_ok(&info, size)) {
            uint64_t off = 0;
            while (off + 8 <= (uint64_t)size) {
                if (cancel && *cancel) { stop = 1; break; }
                mach_vm_size_t cur = (mach_vm_size_t)((size - off > CHUNK) ? CHUNK : (size - off));
                cur -= (cur % 8);
                if (cur == 0) break;
                mach_vm_size_t got = 0;
                kr = mach_vm_read_overwrite(task, addr + off, cur,
                                           (mach_vm_address_t)buf, &got);
                if (kr == KERN_SUCCESS && got == cur) {
                    for (mach_vm_size_t o = 0; o + 8 <= cur; o += 8) {
                        uint64_t val;
                        memcpy(&val, buf + o, 8);
                        if (val != vt) continue;        // 不是同类对象头，跳过
                        uint64_t obj = (uint64_t)addr + off + o;
                        float v[3];
                        if (!peer_read_coord(task, obj, root_off, loc_off, v)) continue;
                        if (n >= cap) { stop = 1; break; }
                        out[n].obj = obj;
                        out[n].v[0] = v[0]; out[n].v[1] = v[1]; out[n].v[2] = v[2];
                        out[n].dist = self_ok
                            ? sqrtf((v[0] - selfv[0]) * (v[0] - selfv[0]) +
                                    (v[1] - selfv[1]) * (v[1] - selfv[1]) +
                                    (v[2] - selfv[2]) * (v[2] - selfv[2]))
                            : -1.0f;
                        n++;
                    }
                    if (stop) break;
                }
                off += cur;
            }
        }
        if (stop) break;
        addr += size;
    }
    free(buf);
    mach_port_deallocate(mach_task_self(), task);
    qsort(out, (size_t)n, sizeof(memread_peer_t), peer_cmp);
    if (found) *found = n;
    fprintf(stderr, "同类对象: %d 个（vtable 0x%llX）\n", n, (unsigned long long)vt);
    return 0;
}
