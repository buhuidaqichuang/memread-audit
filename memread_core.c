#include "memread_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
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
                        fwrite(buf, 1, (size_t)cur, f);
                        total += cur;
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
