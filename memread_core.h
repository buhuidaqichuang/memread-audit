#ifndef MEMREAD_CORE_H
#define MEMREAD_CORE_H

#include <sys/types.h>
#include <stddef.h>
#include <stdint.h>

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

// 扫描模式：不落全量 dump，只把命中的敏感数据按 A/B/C/D 分级写入 out_path
// label 用于报告头（通常是目标 bundle id）；返回 0 成功，hits 回填各档数量（可为 NULL）
int memread_scan_ex(pid_t pid, const char *out_path, const char *label, int rw_only,
                    memread_region_cb cb, void *ctx,
                    unsigned long long hits[4]);

// 文本提取：只把可打印 ASCII 串连同虚拟地址写进 out_path，体积远小于原始 dump
// min_len 为最短字符串长度（建议 5）；返回 0 成功，无命中返回 -3
int memread_strings_ex(pid_t pid, const char *out_path, int rw_only, int min_len,
                       memread_region_cb cb, void *ctx);

// 关键词精确搜索：把一个值（密钥 / 标记串 / 二进制）在目标进程全部可读区域里按字节找出来
// as_hex=1 时 needle 按十六进制解析（支持 "DE AD BE EF" / "0xdeadbeef"），否则按 UTF-8 文本
// fold=1 表示 ASCII 不区分大小写；rw_only=1 只搜可写区域
// 命中处写 out_path：地址 + 前后 16 字节 hex + 所在行文本；最多 500 处
// 返回 0 成功；phits 回填命中数（可为 NULL）；cancel 指向非 0 时尽快停止（可为 NULL）
int memread_find_ex(pid_t pid, const char *out_path, const char *needle,
                    int as_hex, int fold, int rw_only,
                    memread_region_cb cb, void *ctx, unsigned long long *phits,
                    volatile int *cancel);

// 兼容旧签名：只有累计字节的进度回调
int memread_dump(pid_t pid, const char *out_path, int rw_only,
                 void (*progress)(unsigned long long done, void *ctx), void *ctx);

// 枚举所有进程 pid，返回数量
int memread_list_procs(pid_t *pids, int max);

// 取某 pid 的可执行文件路径，返回写入长度
int memread_proc_path(pid_t pid, char *buf, size_t bufsz);

// ================= 数值扫描 =================
// 用途：找二进制 int/float 这类战斗数值（血量、子弹、坐标等），
//       不走 A/B/C/D 字符串分级，也不落 dump，直接对可写区按类型对齐比对。

// 数值类型
#define MEMREAD_VALTYPE_INT32  0
#define MEMREAD_VALTYPE_INT64  1
#define MEMREAD_VALTYPE_FLOAT  2   // float32
#define MEMREAD_VALTYPE_DOUBLE 3

// 收敛条件
#define MEMREAD_VALCOND_EQUAL     0   // 当前值 == target
#define MEMREAD_VALCOND_NOT_EQUAL 1   // 当前值 != target
#define MEMREAD_VALCOND_GREATER   2   // 当前值 >  target
#define MEMREAD_VALCOND_LESS      3   // 当前值 <  target
#define MEMREAD_VALCOND_INCREASED 4   // 当前值 >  上一轮
#define MEMREAD_VALCOND_DECREASED 5   // 当前值 <  上一轮
#define MEMREAD_VALCOND_CHANGED   6   // 当前值 != 上一轮
#define MEMREAD_VALCOND_UNCHANGED 7   // 当前值 == 上一轮
#define MEMREAD_VALCOND_DELTA     8   // (当前 - 上一轮) == target

// 首扫：枚举可写区，按 type 步进比对，value±tol 内的地址写入候选（进程内保存）
// 返回 0 成功；phits 回填候选数（可为 NULL）；cancel 指向非 0 时尽快停止（可为 NULL）
int memread_valscan_first(pid_t pid, int rw_only, int type, double value, double tol,
                          memread_region_cb cb, void *ctx,
                          unsigned long long *phits, volatile int *cancel);

// 收敛：对现有候选逐个重读当前值，按 cond 过滤（DELTA 用 target 作差值）
// 返回 0 成功；phits 回填剩余候选数
int memread_valscan_refine(pid_t pid, int type, int cond, double target,
                           memread_region_cb cb, void *ctx,
                           unsigned long long *phits, volatile int *cancel);

// 自动收敛：先探测是否有候选变化，无变化则原样保留（后台定时收敛用，避免空跑把候选清空）
// pchanged 回填本次是否检测到变化；pleft 回填剩余候选数
int memread_valscan_autorefine(pid_t pid, int type, int cond, double target,
                               unsigned long long *pleft, int *pchanged);

// 读某个候选的当前值（结果列表点按查看）；返回 0 成功
int memread_valscan_peek(pid_t pid, int type, unsigned long long index,
                         uint64_t *out_addr, double *out_value);

// 取候选的地址与上一轮原始位（列表展示）；返回 0 成功
int memread_valscan_get(unsigned long long index, uint64_t *out_addr, uint64_t *out_prev);

// 读任意地址的当前值（已保存地址刷新用）；返回 0 成功，-1 task_for_pid 失败，-3 地址不可读
int memread_read_scalar(pid_t pid, uint64_t addr, int type, double *out_value);

// 预统计可写区域总量（进度百分比用，不读内存，只枚举 region）；返回 0 成功
int memread_writable_bytes(pid_t pid, int rw_only,
                           unsigned long long *out_bytes, unsigned long long *out_regions);

// 原始位 -> 数值（供 UI 把上一轮原始位显示成可读数字）
double memread_valscan_raw2double(uint64_t raw, int type);

unsigned long long memread_valscan_count(void);
void memread_valscan_reset(void);

#endif
