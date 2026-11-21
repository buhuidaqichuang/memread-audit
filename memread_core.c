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
    if (type < MEMREAD_VALTYPE_INT32 || type > MEMREAD_VALTYPE_DOUBLE) return -2;
    if (tol < 0) tol = -tol;

    memread_valscan_reset();
    size_t sz = valsize(type);

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
                    if (sz == 4) {
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
    if (type < MEMREAD_VALTYPE_INT32 || type > MEMREAD_VALTYPE_DOUBLE) return -2;
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
        if (val_read_raw(task, g_valents[i].addr, type, &raw) != 0) {
            continue;  // 地址已不可读（内存被回收/释放），丢弃
        }
        double cur = memread_valscan_raw2double(raw, type);
        double prev = memread_valscan_raw2double(g_valents[i].prev, type);
        int match = 0;
        switch (cond) {
            case MEMREAD_VALCOND_EQUAL:     match = val_eq(cur, target, type); break;
            case MEMREAD_VALCOND_NOT_EQUAL: match = !val_eq(cur, target, type); break;
            case MEMREAD_VALCOND_GREATER:   match = cur > target; break;
            case MEMREAD_VALCOND_LESS:      match = cur < target; break;
            case MEMREAD_VALCOND_INCREASED: match = cur > prev; break;
            case MEMREAD_VALCOND_DECREASED: match = cur < prev; break;
            case MEMREAD_VALCOND_CHANGED:   match = !val_eq(cur, prev, type); break;
            case MEMREAD_VALCOND_UNCHANGED: match = val_eq(cur, prev, type); break;
            case MEMREAD_VALCOND_DELTA:     match = val_eq(cur - prev, target, type); break;
            default: break;
        }
        if (match) {
            g_valents[kept].addr = g_valents[i].addr;
            g_valents[kept].prev = raw;
            kept++;
        }
        if (cb && ((i & 0x3FFF) == 0)) {
            cb((unsigned long long)i, n, i, 0, ctx);
        }
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
    if (type < MEMREAD_VALTYPE_INT32 || type > MEMREAD_VALTYPE_DOUBLE) return -2;
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
        if (val_read_raw(task, g_valents[i].addr, type, &raw) != 0) continue;
        double cur = memread_valscan_raw2double(raw, type);
        double prev = memread_valscan_raw2double(g_valents[i].prev, type);
        if (!val_eq(cur, prev, type)) { changed = 1; break; }
    }
    mach_port_deallocate(mach_task_self(), task);

    if (pchanged) *pchanged = changed;
    if (!changed) {
        if (pleft) *pleft = n;
        return 0;
    }
    return memread_valscan_refine(pid, type, cond, target, NULL, NULL, pleft, NULL);
}

int memread_valscan_peek(pid_t pid, int type, unsigned long long index,
                         uint64_t *out_addr, double *out_value) {
    if (!g_valents || index >= g_valcount) return -1;
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return -2;
    uint64_t raw = 0;
    int rc = val_read_raw(task, g_valents[index].addr, type, &raw);
    mach_port_deallocate(mach_task_self(), task);
    if (rc != 0) return -3;
    if (out_addr) *out_addr = g_valents[index].addr;
    if (out_value) *out_value = memread_valscan_raw2double(raw, type);
    return 0;
}

int memread_valscan_get(unsigned long long index, uint64_t *out_addr, uint64_t *out_prev) {
    if (!g_valents || index >= g_valcount) return -1;
    if (out_addr) *out_addr = g_valents[index].addr;
    if (out_prev) *out_prev = g_valents[index].prev;
    return 0;
}
