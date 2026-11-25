// memread.c — 命令行形态（SSH / NewTerm 用）
// 目标：让扫描逻辑可以在设备上直接跑、直接打印结果，用于远程迭代
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#include <math.h>
#include "memread_core.h"

#define SAVE_MAGIC 0x4D524344u

typedef struct {
    unsigned int magic;
    unsigned int n;
} save_head_t;

static const char *type_name(int t) {
    switch (t) {
        case MEMREAD_VALTYPE_INT32: return "int32";
        case MEMREAD_VALTYPE_INT64: return "int64";
        case MEMREAD_VALTYPE_FLOAT: return "float";
        case MEMREAD_VALTYPE_DOUBLE: return "double";
        default: return "auto";
    }
}

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int parse_type(const char *s) {
    if (!s) return MEMREAD_VALTYPE_FLOAT;
    if (!strcmp(s, "i") || !strcmp(s, "int32")) return MEMREAD_VALTYPE_INT32;
    if (!strcmp(s, "l") || !strcmp(s, "int64")) return MEMREAD_VALTYPE_INT64;
    if (!strcmp(s, "d") || !strcmp(s, "double")) return MEMREAD_VALTYPE_DOUBLE;
    return MEMREAD_VALTYPE_FLOAT;
}

static int find_pid_by_name(const char *needle) {
    pid_t pids[4096];
    int n = memread_list_procs(pids, 4096);
    char path[MEMREAD_PROC_PATH_MAX];
    for (int i = 0; i < n; i++) {
        if (memread_proc_path(pids[i], path, sizeof(path)) <= 0) continue;
        if (strstr(path, needle)) return (int)pids[i];
    }
    return -1;
}

static void print_coord_hits(const memread_coord_hit_t *h, int n, int limit) {
    if (limit > n) limit = n;
    for (int i = 0; i < limit; i++) {
        printf("%3d  addr=0x%llx  v=(%.4f, %.4f, %.4f)  quat=%d\n",
               i, (unsigned long long)h[i].addr,
               h[i].v[0], h[i].v[1], h[i].v[2], h[i].quat_off);
    }
    if (n > limit) printf("... 共 %d 条，只显示前 %d 条\n", n, limit);
}

static int cmd_procs(int argc, char **argv) {
    pid_t pids[4096];
    int n = memread_list_procs(pids, 4096);
    char path[MEMREAD_PROC_PATH_MAX];
    const char *filter = (argc >= 3) ? argv[2] : NULL;
    int shown = 0;
    for (int i = 0; i < n; i++) {
        if (memread_proc_path(pids[i], path, sizeof(path)) <= 0) continue;
        if (filter && !strstr(path, filter)) continue;
        printf("%5d  %s\n", (int)pids[i], path);
        shown++;
    }
    printf("-- %d 条\n", shown);
    return 0;
}

static int cmd_coordscan(int argc, char **argv) {
    const char *target = argv[2];
    int pid = atoi(target);
    if (pid <= 0 && (pid = find_pid_by_name(target)) < 0) { fprintf(stderr, "找不到进程 %s\n", target); return 2; }
    int limit = (argc >= 4) ? atoi(argv[3]) : 40;

    memread_coord_hit_t *buf = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * MEMREAD_COORD_HIT_CAP);
    if (!buf) { fprintf(stderr, "内存不足\n"); return 3; }
    int found = 0;
    double t0 = now_s();
    int rc = memread_coord_probe(pid, buf, MEMREAD_COORD_HIT_CAP, &found, NULL, NULL, NULL);
    double t1 = now_s();
    printf("pid=%d  rc=%d  命中=%d  用时=%.2fs\n", pid, rc, found, t1 - t0);
    if (found > 0) print_coord_hits(buf, found, limit);
    free(buf);
    return rc == 0 ? 0 : 2;
}

static int cmd_coordsave(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "用法: coordsave <pid> <file>\n"); return 1; }
    int pid = atoi(argv[2]);
    memread_coord_hit_t *buf = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * MEMREAD_COORD_HIT_CAP);
    if (!buf) return 3;
    int found = 0;
    double t0 = now_s();
    int rc = memread_coord_probe(pid, buf, MEMREAD_COORD_HIT_CAP, &found, NULL, NULL, NULL);
    printf("pid=%d rc=%d 命中=%d 用时=%.2fs\n", pid, rc, found, now_s() - t0);
    if (rc == 0 && found > 0) {
        FILE *f = fopen(argv[3], "wb");
        if (!f) { free(buf); return 4; }
        save_head_t h = { SAVE_MAGIC, (unsigned int)found };
        fwrite(&h, sizeof(h), 1, f);
        fwrite(buf, sizeof(memread_coord_hit_t), found, f);
        fclose(f);
        printf("已保存 %d 条 -> %s\n", found, argv[3]);
    }
    free(buf);
    return rc == 0 ? 0 : 2;
}

static int cmd_coorddiff(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "用法: coorddiff <pid> <file> [mode] [limit]\n"); return 1; }
    int pid = atoi(argv[2]);
    FILE *f = fopen(argv[3], "rb");
    if (!f) { fprintf(stderr, "打不开基准文件\n"); return 4; }
    save_head_t h;
    if (fread(&h, sizeof(h), 1, f) != 1 || h.magic != SAVE_MAGIC) { fclose(f); fprintf(stderr, "基准文件格式不对\n"); return 4; }
    int nbase = (int)h.n;
    memread_coord_hit_t *base = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * nbase);
    if (!base) { fclose(f); return 3; }
    if (fread(base, sizeof(memread_coord_hit_t), nbase, f) != (size_t)nbase) { fclose(f); free(base); return 4; }
    fclose(f);

    memread_coord_hit_t *cur = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * MEMREAD_COORD_HIT_CAP);
    if (!cur) { free(base); return 3; }

    int ncur = 0, found = 0, common = 0, moved = 0;
    float maxdelta = 0, pdelta = 0;
    double t0 = now_s();
    ncur = memread_coord_probe(pid, cur, MEMREAD_COORD_HIT_CAP, &found, NULL, NULL, NULL);
    if (ncur != 0) { printf("重扫失败 rc=%d\n", ncur); }
    printf("基准=%d 本轮命中=%d 用时=%.2fs\n", nbase, found, now_s() - t0);

    memread_coord_hit_t *out = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * MEMREAD_COORD_HIT_CAP);
    if (!out) { free(base); free(cur); return 3; }

    const char *mode = (argc >= 5) ? argv[4] : "0";
    int ndiff = 0;
    if (mode[0] == '1') {
        ndiff = memread_coord_probe_jump(pid, base, nbase, out, MEMREAD_COORD_HIT_CAP, &found, &common, &moved, &pdelta, NULL, NULL, NULL);
        printf("姿态过滤: rc=%d 保留=%d 共同地址=%d 已变动=%d 最大位移=%.2f\n", ndiff, found, common, moved, pdelta);
    } else {
        ndiff = memread_coord_probe_diff(pid, base, nbase, out, MEMREAD_COORD_HIT_CAP, &found, &common, &moved, &maxdelta, 0.001f, 1e9f, NULL, NULL, NULL);
        printf("全量比对: rc=%d 保留=%d 共同地址=%d 已变动=%d 最大位移=%.2f\n", ndiff, found, common, moved, maxdelta);
    }
    (void)ndiff;
    int limit = (argc >= 6) ? atoi(argv[5]) : 40;
    print_coord_hits(out, found, limit);

    free(out); free(base); free(cur);
    return 0;
}

typedef struct {
    float total;
    float first[3];
    float last[3];
    float lo[3];
    float hi[3];
    uint64_t addr;
    int ok;
    int i;
} watch_stat_t;

static int watch_cmp(const void *a, const void *b) {
    const watch_stat_t *x = (const watch_stat_t *)a;
    const watch_stat_t *y = (const watch_stat_t *)b;
    if (x->total < y->total) return 1;
    if (x->total > y->total) return -1;
    return 0;
}

// 时间序列采样：连续读一批地址，跟踪首末值与各轴极值，直接打印「确实动过的地址」
static int cmd_watch(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "用法: watch <pid> <file> <seconds> <interval_ms> [min_delta] [topN]\n"); return 1; }
    int pid = atoi(argv[2]);
    FILE *f = fopen(argv[3], "rb");
    if (!f) { fprintf(stderr, "打不开基准文件 %s\n", argv[3]); return 4; }
    save_head_t h;
    if (fread(&h, sizeof(h), 1, f) != 1 || h.magic != SAVE_MAGIC) { fclose(f); return 4; }
    int n = (int)h.n;
    memread_coord_hit_t *base = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * n);
    if (!base) { fclose(f); return 3; }
    if (fread(base, sizeof(memread_coord_hit_t), n, f) != (size_t)n) { fclose(f); free(base); return 4; }
    fclose(f);

    double secs = atof(argv[4]);
    int interval_ms = atoi(argv[5]);
    float min_delta = (argc >= 6) ? (float)atof(argv[6]) : 2.0f;
    int topn = (argc >= 7) ? atoi(argv[7]) : 60;

    uint64_t *addrs = (uint64_t *)malloc(sizeof(uint64_t) * n);
    float *buf = (float *)malloc(sizeof(float) * 3 * n);
    watch_stat_t *st = (watch_stat_t *)calloc(n, sizeof(watch_stat_t));
    if (!addrs || !buf || !st) { free(base); free(addrs); free(buf); free(st); return 3; }
    for (int i = 0; i < n; i++) { addrs[i] = base[i].addr; st[i].i = i; st[i].addr = base[i].addr; }

    double t0 = now_s();
    int samples = 0, reads = 0;
    while (1) {
        double el = now_s() - t0;
        if (el > secs) break;
        int ok = memread_read_vec3_batch(pid, addrs, n, buf);
        if (ok < 0) { printf("采样失败 rc=%d\n", ok); break; }
        reads += ok;
        for (int i = 0; i < n; i++) {
            if (i >= ok) continue;
            float *v = &buf[i * 3];
            if (st[i].ok == 0) {
                for (int k = 0; k < 3; k++) { st[i].first[k] = v[k]; st[i].lo[k] = v[k]; st[i].hi[k] = v[k]; }
            } else {
                for (int k = 0; k < 3; k++) {
                    if (v[k] < st[i].lo[k]) st[i].lo[k] = v[k];
                    if (v[k] > st[i].hi[k]) st[i].hi[k] = v[k];
                }
            }
            for (int k = 0; k < 3; k++) st[i].last[k] = v[k];
            st[i].ok++;
        }
        samples++;
        usleep(interval_ms * 1000);
    }

    double span = 0;
    for (int i = 0; i < n; i++) {
        float d = 0;
        for (int k = 0; k < 3; k++) {
            float dv = st[i].last[k] - st[i].first[k];
            d += dv * dv;
        }
        st[i].total = (float)d;
        if (st[i].total > span) span = st[i].total;
    }
    span = 0;
    for (int i = 0; i < n; i++) {
        if (st[i].total > span) span = st[i].total;
    }
    float maxdist = (float)sqrt((double)span);

    watch_stat_t *sorted = (watch_stat_t *)malloc(sizeof(watch_stat_t) * n);
    if (!sorted) { free(base); free(addrs); free(buf); free(st); return 3; }
    memcpy(sorted, st, sizeof(watch_stat_t) * n);
    qsort(sorted, n, sizeof(watch_stat_t), watch_cmp);

    int moved = 0;
    for (int i = 0; i < n; i++) if (sqrt((double)sorted[i].total) >= min_delta) moved++;
    printf("采样: %d 帧 / %d 次读，地址 %d 个，位移>=%.2f 的有 %d 个，最大位移 %.2f\n",
           samples, reads, n, min_delta, moved, maxdist);
    int shown = 0;
    for (int i = 0; i < n && shown < topn; i++) {
        float dist = (float)sqrt((double)sorted[i].total);
        if (dist < min_delta) break;
        printf("%3d  0x%-12llx d=%-9.2f  start=(%.2f,%.2f,%.2f)  end=(%.2f,%.2f,%.2f)  range=[%.2f..%.2f / %.2f..%.2f / %.2f..%.2f] n=%d\n",
               shown, (unsigned long long)sorted[i].addr, dist,
               sorted[i].first[0], sorted[i].first[1], sorted[i].first[2],
               sorted[i].last[0], sorted[i].last[1], sorted[i].last[2],
               sorted[i].lo[0], sorted[i].hi[0], sorted[i].lo[1], sorted[i].hi[1],
               sorted[i].lo[2], sorted[i].hi[2], sorted[i].ok);
        shown++;
    }
    printf("-- 显示 %d / %d\n", shown, moved);

    free(sorted); free(base); free(addrs); free(buf); free(st);
    return 0;
}

// live：自己扫一遍拿地址，然后连续采样并打印「动过」的地址（不落文件）
static int cmd_live(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "用法: live <pid> <seconds> <interval_ms> [min_delta] [topN]\n"); return 1; }
    int pid = atoi(argv[2]);
    double secs = atof(argv[3]);
    int interval_ms = atoi(argv[4]);
    float min_delta = (argc >= 6) ? (float)atof(argv[5]) : 2.0f;
    int topn = (argc >= 7) ? atoi(argv[6]) : 60;

    memread_coord_hit_t *hits = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * MEMREAD_COORD_HIT_CAP);
    if (!hits) return 3;
    int found = 0;
    double ts = now_s();
    int rc = memread_coord_probe(pid, hits, MEMREAD_COORD_HIT_CAP, &found, NULL, NULL, NULL);
    printf("扫描: rc=%d 候选=%d 用时=%.2fs\n", rc, found, now_s() - ts);
    if (rc != 0 || found <= 0) { free(hits); return 2; }

    int n = found;
    uint64_t *addrs = (uint64_t *)malloc(sizeof(uint64_t) * n);
    float *buf = (float *)malloc(sizeof(float) * 3 * n);
    watch_stat_t *st = (watch_stat_t *)calloc(n, sizeof(watch_stat_t));
    if (!addrs || !buf || !st) { free(hits); free(addrs); free(buf); free(st); return 3; }
    for (int i = 0; i < n; i++) { addrs[i] = hits[i].addr; st[i].addr = hits[i].addr; st[i].i = i; }
    free(hits);

    double t0 = now_s();
    int samples = 0, reads = 0;
    while (1) {
        double el = now_s() - t0;
        if (el > secs) break;
        int ok = memread_read_vec3_batch(pid, addrs, n, buf);
        if (ok < 0) { printf("采样失败 rc=%d\n", ok); break; }
        reads += ok;
        for (int i = 0; i < ok; i++) {
            float *v = &buf[i * 3];
            if (st[i].ok == 0) {
                for (int k = 0; k < 3; k++) { st[i].first[k] = v[k]; st[i].lo[k] = v[k]; st[i].hi[k] = v[k]; }
            } else {
                for (int k = 0; k < 3; k++) {
                    if (v[k] < st[i].lo[k]) st[i].lo[k] = v[k];
                    if (v[k] > st[i].hi[k]) st[i].hi[k] = v[k];
                }
            }
            for (int k = 0; k < 3; k++) st[i].last[k] = v[k];
            st[i].ok++;
        }
        samples++;
        usleep(interval_ms * 1000);
    }

    float maxsq = 0;
    for (int i = 0; i < n; i++) {
        float d = 0;
        for (int k = 0; k < 3; k++) { float dv = st[i].last[k] - st[i].first[k]; d += dv * dv; }
        st[i].total = d;
        if (d > maxsq) maxsq = d;
    }

    watch_stat_t *sorted = (watch_stat_t *)malloc(sizeof(watch_stat_t) * n);
    if (!sorted) { free(addrs); free(buf); free(st); return 3; }
    memcpy(sorted, st, sizeof(watch_stat_t) * n);
    qsort(sorted, n, sizeof(watch_stat_t), watch_cmp);

    int moved = 0;
    for (int i = 0; i < n; i++) if (sqrt((double)sorted[i].total) >= min_delta) moved++;
    printf("采样: %d 帧 / %d 次读，地址 %d 个，位移>=%.2f 的有 %d 个，最大位移 %.2f\n",
           samples, reads, n, min_delta, moved, sqrt((double)maxsq));
    int shown = 0;
    for (int i = 0; i < n && shown < topn; i++) {
        float dist = (float)sqrt((double)sorted[i].total);
        if (dist < min_delta) break;
        printf("%3d  0x%-12llx d=%-8.2f  start=(%.2f,%.2f,%.2f)  end=(%.2f,%.2f,%.2f)  range=[%.1f..%.1f / %.1f..%.1f / %.1f..%.1f] n=%d\n",
               shown, (unsigned long long)sorted[i].addr, dist,
               sorted[i].first[0], sorted[i].first[1], sorted[i].first[2],
               sorted[i].last[0], sorted[i].last[1], sorted[i].last[2],
               sorted[i].lo[0], sorted[i].hi[0], sorted[i].lo[1], sorted[i].hi[1],
               sorted[i].lo[2], sorted[i].hi[2], sorted[i].ok);
        shown++;
    }
    printf("-- 显示 %d / %d\n", shown, moved);
    free(sorted); free(addrs); free(buf); free(st);
    return 0;
}

typedef struct { uint64_t addr; float v[3]; } ent_t;
typedef struct { float d; float dv[3]; float a[3]; float b[3]; uint64_t addr; } cmp_t;

static int ent_cmp_addr(const void *x, const void *y) {
    const ent_t *a = (const ent_t *)x, *b = (const ent_t *)y;
    if (a->addr < b->addr) return -1;
    if (a->addr > b->addr) return 1;
    return 0;
}

static int cmp_cmp_desc(const void *x, const void *y) {
    const cmp_t *a = (const cmp_t *)x, *b = (const cmp_t *)y;
    if (a->d < b->d) return 1;
    if (a->d > b->d) return -1;
    return 0;
}

// 两份快照直接比对（纯 CPU，不再扫内存）
static int cmd_coordcmp(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "用法: coordcmp <fileA> <fileB> [min_delta] [topN]\n"); return 1; }
    float min_delta = (argc >= 5) ? (float)atof(argv[4]) : 1.0f;
    int topn = (argc >= 6) ? atoi(argv[5]) : 60;

    ent_t *ea = NULL, *eb = NULL;
    int na = 0, nb = 0;
    for (int pass = 0; pass < 2; pass++) {
        FILE *f = fopen(argv[2 + pass], "rb");
        if (!f) { fprintf(stderr, "打不开 %s\n", argv[2 + pass]); free(ea); free(eb); return 4; }
        save_head_t h;
        if (fread(&h, sizeof(h), 1, f) != 1 || h.magic != SAVE_MAGIC) { fclose(f); free(ea); free(eb); return 4; }
        int n = (int)h.n;
        memread_coord_hit_t *tmp = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * (n > 0 ? n : 1));
        if (!tmp) { fclose(f); free(ea); free(eb); return 3; }
        if (fread(tmp, sizeof(memread_coord_hit_t), n, f) != (size_t)n) { fclose(f); free(tmp); free(ea); free(eb); return 4; }
        fclose(f);
        ent_t *e = (ent_t *)malloc(sizeof(ent_t) * (n > 0 ? n : 1));
        if (!e) { free(tmp); free(ea); free(eb); return 3; }
        for (int i = 0; i < n; i++) { e[i].addr = tmp[i].addr; e[i].v[0] = tmp[i].v[0]; e[i].v[1] = tmp[i].v[1]; e[i].v[2] = tmp[i].v[2]; }
        free(tmp);
        qsort(e, n, sizeof(ent_t), ent_cmp_addr);
        if (pass == 0) { e ? (ea = e) : (ea = NULL); na = n; } else { eb = e; nb = n; }
    }

    int cap = na < nb ? na : nb;
    cmp_t *out = (cmp_t *)malloc(sizeof(cmp_t) * (cap > 0 ? cap : 1));
    if (!out) { free(ea); free(eb); return 3; }
    int i = 0, j = 0, ncommon = 0, nmoved = 0;
    while (i < na && j < nb) {
        if (ea[i].addr < eb[j].addr) { i++; continue; }
        if (ea[i].addr > eb[j].addr) { j++; continue; }
        ncommon++;
        float d0 = eb[j].v[0] - ea[i].v[0], d1 = eb[j].v[1] - ea[i].v[1], d2 = eb[j].v[2] - ea[i].v[2];
        float d = (float)sqrt((double)(d0 * d0 + d1 * d1 + d2 * d2));
        if (d >= min_delta) {
            out[nmoved].addr = ea[i].addr;
            out[nmoved].d = d;
            out[nmoved].dv[0] = d0; out[nmoved].dv[1] = d1; out[nmoved].dv[2] = d2;
            out[nmoved].a[0] = ea[i].v[0]; out[nmoved].a[1] = ea[i].v[1]; out[nmoved].a[2] = ea[i].v[2];
            out[nmoved].b[0] = eb[j].v[0]; out[nmoved].b[1] = eb[j].v[1]; out[nmoved].b[2] = eb[j].v[2];
            nmoved++;
        }
        i++; j++;
    }
    qsort(out, nmoved, sizeof(cmp_t), cmp_cmp_desc);
    printf("A=%d B=%d 共同地址=%d 位移>=%.2f 的有 %d\n", na, nb, ncommon, min_delta, nmoved);
    int shown = nmoved < topn ? nmoved : topn;
    for (int k = 0; k < shown; k++) {
        printf("%3d  0x%-12llx d=%-8.2f dv=(%+.2f,%+.2f,%+.2f)  A=(%.2f,%.2f,%.2f) -> B=(%.2f,%.2f,%.2f)\n",
               k, (unsigned long long)out[k].addr, out[k].d, out[k].dv[0], out[k].dv[1], out[k].dv[2],
               out[k].a[0], out[k].a[1], out[k].a[2], out[k].b[0], out[k].b[1], out[k].b[2]);
    }
    printf("-- 显示 %d / %d\n", shown, nmoved);
    free(out); free(ea); free(eb);
    return 0;
}

// 按「模块基址+静态偏移+逐跳偏移」直接解析并读三元组（跨重启复原用）
static int cmd_chainval(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "用法: chainval <pid> <static_off_hex> <depth> <off1> [off2] [off3]...\n"); return 1; }
    int pid = atoi(argv[2]);
    uint64_t off = strtoull(argv[3], NULL, 0);
    int depth = atoi(argv[4]);
    if (depth < 1 || depth > MEMREAD_CHAIN_MAX_DEPTH) { fprintf(stderr, "depth 1..%d\n", MEMREAD_CHAIN_MAX_DEPTH); return 1; }
    if (argc < 5 + depth) { fprintf(stderr, "偏移个数要等于 depth\n"); return 1; }
    int64_t offs[MEMREAD_CHAIN_MAX_DEPTH] = {0};
    for (int i = 0; i < depth; i++) offs[i] = (int64_t)strtoll(argv[5 + i], NULL, 0);

    char uuid[64] = {0};
    uint64_t base = 0;
    int trc = memread_proc_token(pid, uuid, sizeof(uuid), &base);
    printf("进程 uuid=%s 主模块基址=0x%llx (rc=%d)\n", uuid, (unsigned long long)base, trc);
    if (trc != 0 || base == 0) return 2;

    uint64_t a = base + off;
    printf("起跳: 0x%llx (base+0x%llx)\n", (unsigned long long)a, (unsigned long long)off);
    for (int i = 0; i < depth; i++) {
        double pv = 0;
        int rc = memread_read_scalar(pid, a, MEMREAD_VALTYPE_INT64, &pv);
        if (rc != 0) { printf("第 %d 跳读失败 rc=%d @0x%llx\n", i + 1, rc, (unsigned long long)a); return 3; }
        uint64_t v = (uint64_t)pv;
        printf("第 %d 跳: 槽 0x%llx -> 0x%llx  (+0x%llx)\n", i + 1,
               (unsigned long long)a, (unsigned long long)v, (unsigned long long)offs[i]);
        if (v < 0x100000000ULL) { printf("槽值异常，链断\n"); return 3; }
        a = (uint64_t)((int64_t)v + offs[i]);
    }
    float v3[3] = {0};
    int rc = memread_read_vec3(pid, a, v3);
    printf("坐标地址 0x%llx rc=%d  v=(%.4f, %.4f, %.4f)\n",
           (unsigned long long)a, rc, v3[0], v3[1], v3[2]);
    return rc == 0 ? 0 : 4;
}

// 按「XY 相同、Z 不同」聚类：同一角色的多个挂点会共享 XY
typedef struct { float x, y, z; uint64_t addr; } cpt_t;
static int cpt_cmp_xy(const void *a, const void *b) {
    const cpt_t *p = (const cpt_t *)a, *q = (const cpt_t *)b;
    long px = lroundf(p->x * 100.0f), py = lroundf(p->y * 100.0f);
    long qx = lroundf(q->x * 100.0f), qy = lroundf(q->y * 100.0f);
    if (px != qx) return px < qx ? -1 : 1;
    if (py != qy) return py < qy ? -1 : 1;
    return 0;
}

static int cmd_cluster(int argc, char **argv) {
    int pid = atoi(argv[2]);
    int minn = (argc >= 4) ? atoi(argv[3]) : 4;
    int topn = (argc >= 5) ? atoi(argv[4]) : 25;
    memread_coord_hit_t *hits = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * MEMREAD_COORD_HIT_CAP);
    if (!hits) return 3;
    int found = 0;
    int rc = memread_coord_probe(pid, hits, MEMREAD_COORD_HIT_CAP, &found, NULL, NULL, NULL);
    printf("扫描: rc=%d 命中=%d\n", rc, found);
    if (rc != 0 || found <= 0) { free(hits); return 2; }

    cpt_t *pts = (cpt_t *)malloc(sizeof(cpt_t) * found);
    if (!pts) { free(hits); return 3; }
    for (int i = 0; i < found; i++) {
        pts[i].x = hits[i].v[0]; pts[i].y = hits[i].v[1]; pts[i].z = hits[i].v[2];
        pts[i].addr = hits[i].addr;
    }
    qsort(pts, found, sizeof(cpt_t), cpt_cmp_xy);

    int shown = 0;
    int i = 0;
    while (i < found && shown < topn) {
        int j = i + 1;
        while (j < found && cpt_cmp_xy(&pts[i], &pts[j]) == 0) j++;
        int cnt = j - i;
        if (cnt >= minn) {
            float lo = pts[i].z, hi = pts[i].z;
            for (int k = i; k < j; k++) { if (pts[k].z < lo) lo = pts[k].z; if (pts[k].z > hi) hi = pts[k].z; }
            printf("%2d  xy=(%.2f, %.2f)  n=%-3d z=[%.2f .. %.2f]\n", shown, pts[i].x, pts[i].y, cnt, lo, hi);
            int sl = 0;
            for (int k = i; k < j && sl < 8; k++) {
                printf("      0x%-12llx z=%.2f\n", (unsigned long long)pts[k].addr, pts[k].z);
                sl++;
            }
            shown++;
        }
        i = j;
    }
    printf("-- 聚类 %d 组（>=%d 个同 XY）\n", shown, minn);
    free(pts); free(hits);
    return 0;
}

static int cmd_anchor(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "用法: anchor <pid> <anchor_hex> [depth] [cap]\n"); return 1; }
    int pid = atoi(argv[2]);
    unsigned long long anchor = strtoull(argv[3], NULL, 0);
    int depth = (argc >= 5) ? atoi(argv[4]) : 4;
    int cap = (argc >= 6) ? atoi(argv[5]) : 200;
    memread_anchor_coord_t *out = (memread_anchor_coord_t *)malloc(sizeof(memread_anchor_coord_t) * cap);
    if (!out) return 3;
    int found = 0, objects = 0;
    double t0 = now_s();
    int rc = memread_coord_from_anchor(pid, anchor, depth, out, cap, &found, &objects);
    printf("rc=%d 对象数=%d 坐标命中=%d 用时=%.2fs\n", rc, objects, found, now_s() - t0);
    for (int i = 0; i < found && i < cap; i++) {
        printf("%3d  coord=0x%llx  object=0x%llx  depth=%d  v=(%.3f, %.3f, %.3f)\n",
               i, (unsigned long long)out[i].coord_addr, (unsigned long long)out[i].object,
               out[i].depth, out[i].v[0], out[i].v[1], out[i].v[2]);
    }
    free(out);
    return 0;
}

static int cmd_read(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "用法: read <pid> <addr_hex> [f|i|l|d]\n"); return 1; }
    int pid = atoi(argv[2]);
    unsigned long long addr = strtoull(argv[3], NULL, 0);
    int t = parse_type(argc >= 5 ? argv[4] : "f");
    double val = 0;
    int rc = memread_read_scalar(pid, addr, t, &val);
    printf("rc=%d addr=0x%llx type=%s value=%.6f\n", rc, addr, type_name(t), val);
    if (t == MEMREAD_VALTYPE_FLOAT) {
        float v3[3] = {0};
        if (memread_read_vec3(pid, addr, v3) == 0) printf("vec3=(%.4f, %.4f, %.4f)\n", v3[0], v3[1], v3[2]);
    }
    return rc == 0 ? 0 : 2;
}

static int cmd_chain(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "用法: chain <pid> <addr_hex> [depth] [cap]\n"); return 1; }
    int pid = atoi(argv[2]);
    unsigned long long addr = strtoull(argv[3], NULL, 0);
    int depth = (argc >= 5) ? atoi(argv[4]) : 4;
    int cap = (argc >= 6) ? atoi(argv[5]) : 50;
    memread_chain_t *out = (memread_chain_t *)malloc(sizeof(memread_chain_t) * cap);
    if (!out) return 3;
    int found = 0;
    int rc = memread_chain_scan(pid, addr, depth, out, cap, &found, NULL);
    printf("正向: rc=%d 链数=%d\n", rc, found);
    for (int i = 0; i < found && i < cap; i++) {
        printf("  [%d] %s+0x%llx depth=%d valid=%d flags=0x%x offs=", i, out[i].name,
               (unsigned long long)out[i].static_off, out[i].depth, out[i].valid_hops, out[i].flags);
        for (int k = 0; k < out[i].depth; k++) printf("%s%lld", k ? "," : "", (long long)out[i].offs[k]);
        printf("\n");
    }
    if (found == 0) {
        int r2 = memread_chain_scan_reverse(pid, addr, depth, out, cap);
        printf("反向: rc=%d 链数=%d\n", r2, r2 > 0 ? r2 : 0);
        for (int i = 0; i < r2 && i < cap; i++) {
            printf("  [%d] %s+0x%llx depth=%d valid=%d offs=", i, out[i].name,
                   (unsigned long long)out[i].static_off, out[i].depth, out[i].valid_hops);
            for (int k = 0; k < out[i].depth; k++) printf("%s%lld", k ? "," : "", (long long)out[i].offs[k]);
            printf("\n");
        }
    }
    free(out);
    return 0;
}

static int cmd_modinfo(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "用法: modinfo <pid> <addr_hex>\n"); return 1; }
    int pid = atoi(argv[2]);
    unsigned long long addr = strtoull(argv[3], NULL, 0);
    char uuid[64] = {0}, name[128] = {0};
    unsigned long long base = 0, off = 0;
    int rc = memread_addr_module_info(pid, addr, uuid, sizeof(uuid), name, sizeof(name), &base, &off);
    printf("rc=%d uuid=%s name=%s base=0x%llx off=0x%llx\n", rc, uuid, name, base, off);
    return 0;
}

static int cmd_token(int argc, char **argv) {
    if (argc < 3) return 1;
    int pid = atoi(argv[2]);
    char uuid[64] = {0};
    unsigned long long base = 0;
    int rc = memread_proc_token(pid, uuid, sizeof(uuid), &base);
    printf("rc=%d uuid=%s mainbase=0x%llx\n", rc, uuid, base);
    return 0;
}

static int cmd_dump(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "用法: dump <pid> <out.bin> [rw-only]\n"); return 1; }
    int pid = atoi(argv[2]);
    int rw_only = (argc >= 5 && strcmp(argv[4], "rw-only") == 0);
    int rc = memread_dump(pid, argv[3], rw_only, NULL, NULL);
    printf("rc=%d -> %s\n", rc, argv[3]);
    return rc == 0 ? 0 : 2;
}

static void usage(const char *prog) {
    fprintf(stderr,
        "用法:\n"
        "  %s procs [过滤串]\n"
        "  %s coordscan <pid|进程名> [显示条数]\n"
        "  %s coordsave <pid> <file>\n"
        "  %s coorddiff <pid> <file> [0=全量|1=姿态] [显示条数]\n"
        "  %s anchor <pid> <anchor_hex> [depth] [cap]\n"
        "  %s cluster <pid> [minN] [topN]\n"
        "  %s chainval <pid> <static_off_hex> <depth> <off1> [off2] ...\n"
        "  %s coordcmp <fileA> <fileB> [min_delta] [topN]\n"
        "  %s live <pid> <seconds> <interval_ms> [min_delta] [topN]\n"
        "  %s watch <pid> <file> <seconds> <interval_ms> [min_delta] [topN]\n"
        "  %s read <pid> <addr_hex> [f|i|l|d]\n"
        "  %s chain <pid> <addr_hex> [depth] [cap]\n"
        "  %s modinfo <pid> <addr_hex>\n"
        "  %s token <pid>\n"
        "  %s dump <pid> <out.bin> [rw-only]\n", prog, prog, prog, prog, prog, prog, prog, prog, prog, prog, prog, prog, prog, prog, prog);
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(argv[0]); return 1; }
    const char *cmd = argv[1];
    if (!strcmp(cmd, "procs"))     return cmd_procs(argc, argv);
    if (!strcmp(cmd, "coordscan")) return cmd_coordscan(argc, argv);
    if (!strcmp(cmd, "coordsave")) return cmd_coordsave(argc, argv);
    if (!strcmp(cmd, "coorddiff")) return cmd_coorddiff(argc, argv);
    if (!strcmp(cmd, "anchor"))    return cmd_anchor(argc, argv);
    if (!strcmp(cmd, "watch"))     return cmd_watch(argc, argv);
    if (!strcmp(cmd, "live"))      return cmd_live(argc, argv);
    if (!strcmp(cmd, "coordcmp"))  return cmd_coordcmp(argc, argv);
    if (!strcmp(cmd, "chainval"))  return cmd_chainval(argc, argv);
    if (!strcmp(cmd, "cluster"))   return cmd_cluster(argc, argv);
    if (!strcmp(cmd, "read"))      return cmd_read(argc, argv);
    if (!strcmp(cmd, "chain"))     return cmd_chain(argc, argv);
    if (!strcmp(cmd, "modinfo"))   return cmd_modinfo(argc, argv);
    if (!strcmp(cmd, "token"))     return cmd_token(argc, argv);
    if (!strcmp(cmd, "dump"))      return cmd_dump(argc, argv);
    usage(argv[0]);
    return 1;
}
