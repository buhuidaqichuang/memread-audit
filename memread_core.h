#ifndef MEMREAD_CORE_H
#define MEMREAD_CORE_H

#include <sys/types.h>

// 读取目标进程内存（无注入、无 ptrace，目标不可感知）
// 返回 0 成功；progress 可为 NULL
int memread_dump(pid_t pid, const char *out_path, int rw_only,
                 void (*progress)(unsigned long long done, void *ctx), void *ctx);

// 枚举所有进程 pid，返回数量
int memread_list_procs(pid_t *pids, int max);

// 取某 pid 的可执行文件路径，返回写入长度
int memread_proc_path(pid_t pid, char *buf, size_t bufsz);

#endif
