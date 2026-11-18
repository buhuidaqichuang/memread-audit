// memread.c — 越狱设备上的“纯读”内存读取器 / 自审工具
// 边界：仅用于自己开发、自己设备上的 App。
//
// 两种运行形态：
//
// 1) 命令行（NewTerm + sudo）
//      sudo memread <pid> <out.bin> [rw-only]
//
// 2) 作为 App（.ipa，安装后用 ldid 重签 platform-application）
//      无参数启动时自动：
//        - 从 /var/mobile/Media/memread_target.txt 读目标 pid
//        - dump 到 /var/mobile/Media/memread_dump.bin
//        - 结果写 /var/mobile/Media/memread_result.txt
//        - 找不到 pid 时把进程列表写到 /var/mobile/Media/memread_proclist.txt
//
// 原理：task_for_pid + mach_vm_read_overwrite
//       不使用 ptrace、不注入镜像、不改目标页权限
//       => 目标进程侧无 P_TRACED、无新增 dyld image，不可感知

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_region.h>
#include <mach/vm_prot.h>

#define MEDIA_DIR      "/var/mobile/Media"
#define APP_PID_FILE   MEDIA_DIR "/memread_target.txt"
#define APP_OUT_FILE   MEDIA_DIR "/memread_dump.bin"
#define APP_LOG_FILE   MEDIA_DIR "/memread_result.txt"
#define APP_PROC_FILE  MEDIA_DIR "/memread_proclist.txt"

static void usage(const char *prog) {
    fprintf(stderr,
        "用法: %s <pid> <out.bin> [rw-only]\n"
        "  pid      目标进程 pid\n"
        "  out.bin  输出文件\n"
        "  rw-only  只 dump 可写数据区（堆/栈/__DATA）\n", prog);
}

static pid_t read_pid_from_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char buf[64] = {0};
    if (fgets(buf, sizeof(buf) - 1, f) == NULL) { fclose(f); return 0; }
    fclose(f);
    return (pid_t)atoi(buf);
}

static int dump(pid_t pid, const char *out, int rw_only, FILE *log) {
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "task_for_pid 失败: (%d) %s\n", kr, mach_error_string(kr));
        if (log) fprintf(log, "RESULT=FAIL task_for_pid kr=%d %s\n", kr, mach_error_string(kr));
        return 2;
    }

    FILE *f = fopen(out, "wb");
    if (!f) {
        perror("fopen out");
        if (log) fprintf(log, "RESULT=FAIL fopen %s\n", out);
        return 3;
    }

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
        int shared = 0;
#ifdef SM_SHARED
        shared = (info.share_mode == SM_SHARED || info.share_mode == SM_SHARED_ALIASED);
#elif defined(SM_COW)
        shared = (info.share_mode == SM_COW || info.share_mode == SM_PRIVATE_ALIASED);
#endif

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
    fprintf(stderr, "读取完成: %llu 字节, %d 个区域 -> %s\n", total, regions, out);
    fprintf(stderr, "本次读取未使用 ptrace / 未注入镜像, 目标进程不可感知\n");
    if (log) fprintf(log, "RESULT=OK pid=%d bytes=%llu regions=%d out=%s\n",
                     (int)pid, total, regions, out);
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 3) {
        pid_t pid = (pid_t)atoi(argv[1]);
        if (pid <= 0) { fprintf(stderr, "非法 pid\n"); return 1; }
        int rw_only = (argc >= 4 && strcmp(argv[3], "rw-only") == 0);
        return dump(pid, argv[2], rw_only, NULL);
    }

    // App 形态（无参数启动）
    FILE *log = fopen(APP_LOG_FILE, "w");
    if (log) fprintf(log, "START app-mode\n");

    pid_t pid = read_pid_from_file(APP_PID_FILE);
    if (pid <= 0) {
        fprintf(stderr, "未找到目标 pid，请先把 pid 写入 %s\n", APP_PID_FILE);
        FILE *pl = fopen(APP_PROC_FILE, "w");
        if (pl) {
            for (int p = 1; p < 99999; p++) {
                char name[256] = {0};
                if (proc_name(p, name, sizeof(name)) > 0) fprintf(pl, "%d\t%s\n", p, name);
            }
            fclose(pl);
        }
        if (log) { fprintf(log, "RESULT=FAIL no target pid file\n"); fclose(log); }
        return 1;
    }

    int rc = dump(pid, APP_OUT_FILE, 1, log);
    if (log) { fprintf(log, "EXIT=%d\n", rc); fclose(log); }
    return rc;
}
