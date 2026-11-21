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
#define MEMREAD_VALTYPE_AUTO  -1   // 四种一起扫，逐条记类型

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
// 若本次会把候选筛成 0，则拒绝执行、原样保留候选，返回 MEMREAD_VALSCAN_ZERO
#define MEMREAD_VALSCAN_ZERO -3
// 快照/候选所属进程已经重启（pid 变了或主模块基址变了），旧快照与旧候选全部作废
#define MEMREAD_PROC_RESTARTED -9
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

// 同上，并回填该候选的类型（auto 扫描时逐条不同）
int memread_valscan_get_ex(unsigned long long index, uint64_t *out_addr,
                           uint64_t *out_prev, int *out_type);

// 读任意地址的当前值（已保存地址刷新用）；返回 0 成功，-1 task_for_pid 失败，-3 地址不可读
int memread_read_scalar(pid_t pid, uint64_t addr, int type, double *out_value);

// ============ 模块基址 + 偏移（跨进程重启定位模块内地址） ============
// 判断 addr 落在哪个 Mach-O 模块里；命中回填模块 UUID / 名字 / 基址 / 偏移
// 返回 0 命中，1 不在任何模块（堆地址），-1 取进程失败
int memread_addr_module_info(pid_t pid, uint64_t addr,
                             char *out_uuid, size_t uuid_cap,
                             char *out_name, size_t name_cap,
                             uint64_t *out_base, uint64_t *out_off);
// 按模块 UUID 找回本次进程里的模块基址；返回 0 找到，1 没加载，-1 取进程失败
int memread_module_base(pid_t pid, const char *uuid,
                        uint64_t *out_base, char *out_name, size_t name_cap);
// 进程身份：主可执行模块的 UUID + 基址（重启后必然变），用于快照/候选的进程校验
int memread_proc_token(pid_t pid, char *out_uuid, size_t uuid_cap, uint64_t *out_base);

// ============ 未知值扫描 / 坐标扫描 ============
// 快照：把进程可写内存整块写到 /var/mobile/Media/memread_snap.bin 再只读 mmap 回来
// （不占常驻内存，上限 2GB；用完调 memread_snapshot_free 删除文件）
int memread_unknown_snapshot(pid_t pid, unsigned long long *pbytes, unsigned long long *pregions);

// 与快照比对，重建候选表；cond 支持 CHANGED / UNCHANGED / INCREASED / DECREASED
// float_only=1 时只保留「当前位能解析成有限 float 且 |v| <= 1e6」的地址（坐标用）
int memread_unknown_diff(pid_t pid, int cond, int float_only,
                         memread_region_cb cb, void *ctx,
                         unsigned long long *phits, volatile int *cancel);

// 坐标锁定：在「走动变化」候选里找三连 float，其中恰好一个分量在最近一次快照后变了，
// 且变化的不是候选自己（走 XZ 不变、跳 Y 变）。命中则把候选表改写成三连 float 地址。
int memread_coord_lock(pid_t pid, int *ptriplets, unsigned long long *pcands,
                       memread_region_cb cb, void *ctx);

// ---- 坐标结构扫描（不依赖知道坐标值）----
// 判据：某处连续 3 个 float 是合理坐标，紧跟（+12 或 +16）4 个 float 构成模长≈1 的四元数
#define MEMREAD_COORD_HIT_CAP 300000
typedef struct {
    uint64_t addr;      // FVector 起始地址（4 字节对齐）
    float v[3];
    int quat_off;       // 12/16 = 后面是四元数；-12/-16 = 平凡四元数；0 = 前面是四元数(FTransform)；100 = 后面是 FRotator
} memread_coord_hit_t;

int memread_coord_probe(pid_t pid, memread_coord_hit_t *out, int cap, int *found,
                        volatile int *cancel, memread_region_cb cb, void *ctx);

// 一次扫描直接与基准比对（基准按地址查找），顺带给出共同地址数 / 位移非零数
int memread_coord_probe_diff(pid_t pid, const memread_coord_hit_t *base, int nbase,
                             memread_coord_hit_t *out, int cap, int *found,
                             int *pcommon, int *pmoved, float *pmaxdelta,
                             float min_len, float max_len,
                             volatile int *cancel, memread_region_cb cb, void *ctx);


// 两次探测按地址求差：位移长度落在 [min_len, max_len] 的留下，按位移大小排序
int memread_coord_diff(const memread_coord_hit_t *a, int na,
                       const memread_coord_hit_t *b, int nb,
                       memread_coord_hit_t *out, int cap, int *found,
                       float min_len, float max_len);

// 用一批地址覆盖候选表（供列表页直接点『链』）
int memread_valscan_set(const uint64_t *addrs, int n, int type);

// 取链上第 hop 跳读出的对象指针（hop 从 0 起，0 = 静态槽里的值）
int memread_chain_hop_object(pid_t pid, const char *uuid, uint64_t static_off,
                             const int64_t *offs, int depth, int hop, uint64_t *out_obj);

// 同类对象枚举：self_obj 是自己的角色对象，vtable 相同的都是同类单位
// root_off = RootComponent 在角色对象内的偏移；loc_off = 坐标在 RootComponent 内的偏移
typedef struct {
    uint64_t obj;
    float v[3];
    float dist;     // 与自己的距离（游戏单位），自己为 0
} memread_peer_t;

int memread_peers_scan(pid_t pid, uint64_t self_obj, int64_t root_off, int64_t loc_off,
                       memread_peer_t *out, int cap, int *found, uint64_t *out_vtable,
                       volatile int *cancel);

void memread_snapshot_free(void);

// 预统计可写区域总量（进度百分比用，不读内存，只枚举 region）；返回 0 成功
int memread_writable_bytes(pid_t pid, int rw_only,
                           unsigned long long *out_bytes, unsigned long long *out_regions);

// 原始位 -> 数值（供 UI 把上一轮原始位显示成可读数字）
double memread_valscan_raw2double(uint64_t raw, int type);

unsigned long long memread_valscan_count(void);
void memread_valscan_reset(void);

#pragma mark - 指针链扫描

#define MEMREAD_CHAIN_MAX_DEPTH 6
#define MEMREAD_CHAIN_OFF_WIN   0x10000   // 每跳偏移搜索窗口：0 ~ +64KB（UE 的 UObject 字段偏移常上万）

#define MEMREAD_CHAIN_FLAG_VEC3QUAT 0x1   // 末跳地址形如「FVector + 模长≈1 的四元数」（场景坐标）

typedef struct {
    char uuid[40];              // 模块 UUID（跨重启不变）
    char name[64];
    uint64_t static_off;        // 静态槽相对模块头的偏移
    int depth;                  // 解引用层数 1..6
    int valid_hops;             // 有多少跳通过了「对象头是模块内 vtable」校验
    int flags;                  // MEMREAD_CHAIN_FLAG_*
    int64_t offs[MEMREAD_CHAIN_MAX_DEPTH];   // 每一跳偏移，offs[0] 最先加
} memread_chain_t;

// 从 target（数值地址）反推能跨重启复原的链；max_depth=4 时按 1→4 层依次试，
// 哪层先命中就返回哪层（3 层找不到才用 4 层）。返回条数，负数=错误。
int memread_chain_scan(pid_t pid, uint64_t target, int max_depth,
                       memread_chain_t *out, int cap, int *found_depth,
                       volatile int *cancel);

// 用保存的链算出本轮目标地址：0 成功，2 模块未加载，-3 链断
int memread_chain_resolve(pid_t pid, const char *uuid, uint64_t static_off,
                          const int64_t *offs, int depth, uint64_t *out_addr);

// 同上，额外给出失败跳数（1 起）与那一跳槽里的原值，用于区分「模块没了 / 链在第几跳断」
int memread_chain_resolve_ex(pid_t pid, const char *uuid, uint64_t static_off,
                             const int64_t *offs, int depth, uint64_t *out_addr,
                             int *fail_hop, uint64_t *fail_val);

// 扫描进度（扫描线程写、UI 定时读）：当前层、本层已扫字节、本层总量、候选槽数、已命中链数
void memread_chain_progress(int *level, unsigned long long *done, unsigned long long *total,
                            int *nodes, int *results);

#pragma mark - 值签名重定位

#define MEMREAD_SIG_LEN         128
#define MEMREAD_SIG_MAX_STABLE  128
#define MEMREAD_SIG_PRE         32   // 窗口起点在目标地址前多少字节

typedef struct {
    int win;                 // 窗口长度（字节）
    int target_off;          // 数值在窗口内的偏移
    int stable_n;            // 稳定字节数
    unsigned char offs[MEMREAD_SIG_MAX_STABLE];
    unsigned char vals[MEMREAD_SIG_MAX_STABLE];
} memread_sig_t;

// 采样指纹：连读 4 次，只留不变字节；value_size 是目标数值占用字节（4/8），会被排除
// 返回 0 成功（稳定字节 >= 12），-4 稳定字节不足，-3 读失败，-1 取进程失败
int memread_sig_capture(pid_t pid, uint64_t addr, int value_size, memread_sig_t *out);
// 单帧采样：读 [addr-pre, addr-pre+len) 共 len 字节（分帧手动采样用，App 侧比较多帧）
int memread_sig_read_frame(pid_t pid, uint64_t addr, unsigned char *out, int len, int pre);
// 扫可写内存找指纹（允许 25% 稳定字节已变，按匹配度降序返回），
// 返回候选条数；-5 = 已取消且无结果，-1 取进程失败，-2 参数错，-4 内存不足
int memread_sig_scan(pid_t pid, const memread_sig_t *sig, uint64_t *out, int cap,
                     volatile int *cancel);
// 采样/扫描进度（后台线程写、UI 定时读）：phase 0=空闲 1=采样(共 4 次) 2=扫描
void memread_sig_progress(int *phase, unsigned long long *done, unsigned long long *total,
                          int *hits);

#endif
