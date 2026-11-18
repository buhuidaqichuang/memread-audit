// memread.c — 命令行形态
// 用法: memread <pid> <out.bin> [rw-only]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include "memread_core.h"

static void usage(const char *prog) {
    fprintf(stderr,
        "用法: %s <pid> <out.bin> [rw-only]\n"
        "  pid      目标进程 pid\n"
        "  out.bin  输出文件\n"
        "  rw-only  只 dump 可写数据区（堆/栈/__DATA）\n", prog);
}

int main(int argc, char **argv) {
    if (argc < 3) { usage(argv[0]); return 1; }
    pid_t pid = (pid_t)atoi(argv[1]);
    if (pid <= 0) { fprintf(stderr, "非法 pid\n"); return 1; }
    int rw_only = (argc >= 4 && strcmp(argv[3], "rw-only") == 0);
    int rc = memread_dump(pid, argv[2], rw_only, NULL, NULL);
    fprintf(stderr, "本次读取未使用 ptrace / 未注入镜像, 目标进程不可感知\n");
    return rc == 0 ? 0 : 2;
}
