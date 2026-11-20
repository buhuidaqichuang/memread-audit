#ifndef MEMREAD_CORE_H
#define MEMREAD_CORE_H

#include <sys/types.h>
#include <stddef.h>

// libproc 是 iOS 私有头，但符号在 libSystem 里，手动声明
extern int proc_pidpath(int pid, void *buffer, unsigned int buffersize);
extern int proc_name(int pid, void *buffer, unsigned int buffersize);

#define MEMREAD_PROC_PATH_MAX (4 * 1024)

// 每读一块（chunk）回调一次，用于 UI 实时显示
// addr      当前 chunk 的目标地址
// chunk     chunk 大小（字节）
// total     已写入文件的累计字节
// skipped   该 chunk 是否因全零被跳过
typedef void (*memread_region_cb)(unsigned long long addr,
                                  unsigned long long chunk,
                                  unsigned long long total,
                                  int skipped,
                                  void *ctx);

// 读取目标进程内存（无注入、无 ptrace，目标不可感知）
// rw_only=1 只读可写区域；全零块跳过不写
// 返回 0 成功；cb 可为 NULL
int memread_dump_ex(pid_t pid, const char *out_path, int rw_only,
                    memread_region_cb cb, void *ctx);

// 兼容旧签名：只有累计字节的进度回调
int memread_dump(pid_t pid, const char *out_path, int rw_only,
                 void (*progress)(unsigned long long done, void *ctx), void *ctx);

// 枚举所有进程 pid，返回数量
int memread_list_procs(pid_t *pids, int max);

// 取某 pid 的可执行文件路径，返回写入长度
int memread_proc_path(pid_t pid, char *buf, size_t bufsz);

#endif
