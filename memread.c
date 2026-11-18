// memread.c — 越狱设备上的“纯读”内存读取器
// 用途：审计自有 App 在无注入、无 ptrace 条件下是否可被读取。
// 边界：仅用于自己开发、自己设备上的 App。
//
// 构建（arm64）：
//   clang -arch arm64 -O2 -o memread memread.c
// 签名：
//   ldid -Sent.plist memread
// 运行：
//   sudo ./memread <pid> <out.bin> [rw-only]
//
// 说明：
//   本工具通过 task_for_pid + mach_vm_read_overwrite 读取目标地址空间，
//   不使用 ptrace、不注入任何镜像、不修改目标页权限，
//   因此目标进程侧不会出现 P_TRACED 标志，也不会新增 dyld image。

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_region.h>
#include <mach/vm_prot.h>
#include <mach/shared_region.h>

static void usage(const char *prog) {
    fprintf(stderr,
        "用法: %s <pid> <out.bin> [rw-only]\n"
        "  pid      目标进程 pid\n"
        "  out.bin  输出文件\n"
        "  rw-only  只 dump 可写数据区（堆/栈/__DATA），体积小得多\n", prog);
}

int main(int argc, char **argv) {
    if (argc < 3) { usage(argv[0]); return 1; }

    pid_t pid = (pid_t)atoi(argv[1]);
    if (pid <= 0) { fprintf(stderr, "非法 pid\n"); return 1; }

    int rw_only = (argc >= 4 && strcmp(argv[3], "rw-only") == 0);

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "task_for_pid 失败: (%d) %s\n", kr, mach_error_string(kr));
        fprintf(stderr, "提示: 需要 platform-application 权限，且以 root 运行\n");
        return 2;
    }

    FILE *f = fopen(argv[2], "wb");
    if (!f) { perror("fopen"); return 3; }

    mach_vm_address_t addr = 0;
    unsigned long long total = 0;
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
        int shared   = (info.share_mode == SM_SHARED || info.share_mode == SM_SHARED_ALIASED);

        int want = readable && !shared && (!rw_only || writable);

        if (want && size <= (mach_vm_size_t)(512ULL * 1024 * 1024)) {
            void *buf = malloc((size_t)size);
            if (buf) {
                mach_vm_size_t got = 0;
                kr = mach_vm_read_overwrite(task, addr, size,
                                            (mach_vm_address_t)buf, &got);
                if (kr == KERN_SUCCESS && got == size) {
                    fwrite(buf, 1, (size_t)size, f);
                    total += size;
                    regions++;
                }
                free(buf);
            }
        }
        addr += size;
    }

    fclose(f);
    fprintf(stderr, "读取完成: %llu 字节, %d 个区域 -> %s\n", total, regions, argv[2]);
    fprintf(stderr, "注意: 本次读取全程未使用 ptrace / 未注入镜像, 目标进程不可感知\n");
    return 0;
}
