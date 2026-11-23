// npu.h - NPU 软件驱动头文件（weight stationary 脉动阵列，C = A x B）
//
// 用法：在监控程序 / 测试程序中 include 本头文件并链接 npu.c。
// 要求 CPU 支持 MMIO 访存（总线地址直接映射到 Wishbone，NPU 挂在其上）。
//
// 指令模型（与课程文档一致）：
//   LDTILE（Load Tile）：把 L0B 里一个 4x4 子块载入脉动阵列（B 驻留，
//     weight stationary），按行优先每拍从顶部注入一行，共 4+1 拍。
//   TMUL（Tile Multiply）：C += A x B。A 的行从左侧流入阵列，C 的部分和
//     从底部流出写入 L0C；M=1..M_MAX 行一次算完，MUL 状态为 M + 2N - 1 拍
//     （指令 busy 为 M + 2N 拍，另有 PRE 预取和状态转移各 1 拍）。
//     acc=1 时先读 L0C 累加再写（分块跨 K 维累加，如 C00=A00*B00+A01*B10）。
//
// 片上存储 L0A/L0B/L0C（向 CPU 暴露为 MMIO）：
//   L0A 存 A（TMUL 每拍给阵列一行 4 int8）、L0B 存 B（LDTILE 每拍注入
//   一行 4 int8）、L0C 存 C（TMUL 每拍收 4 个 int32；CPU 读回结果）。
//
// 软件分块：提供课程文档里的 v1/v2 两个简化实现。
//   v1：三层循环，每个 C 子块独立计算；
//   v2：一次 LDTILE 的 B 子块复用到两个 C 行子块。
// 前提：M/N/K 为 4 的倍数；v2 额外要求 M/4 为偶数（M 为 8 的倍数）。
// A/B/C 行优先，A/B 行起始地址 4 字节对齐；不处理尾块和 padding。

#ifndef NPU_H
#define NPU_H

#include <stdint.h>

// NPU 基地址（与课程实验工程中 wbs3 的地址一致）
#define NPU_BASE 0x20000000ul

// 寄存器
#define NPU_REG_CMD     (NPU_BASE + 0x00)  // [0] LDTILE；[1] TMUL；[2] acc
#define NPU_REG_STATUS  (NPU_BASE + 0x04)  // [0] busy；[1] done（W1C）
#define NPU_REG_A_BASE  (NPU_BASE + 0x08)  // TMUL 的 A 行块基址（L0A 字偏移）
#define NPU_REG_B_BASE  (NPU_BASE + 0x0C)  // LDTILE/TMUL 的 B 子块基址（L0B 字偏移）
#define NPU_REG_C_BASE  (NPU_BASE + 0x10)  // TMUL 的 C 行块基址（L0C 字偏移）
#define NPU_REG_M_ROWS  (NPU_BASE + 0x14)  // TMUL 的 A/C 行数 M-1（默认 0..63 -> M=1..64）

// L0 暂存（各段独立固定基址，全行优先）
#define NPU_L0A_DATA(w) (NPU_BASE + 0x100 + (w) * 4)  // A：64 字，字 = A 的一行 4 int8
#define NPU_L0B_DATA(w) (NPU_BASE + 0x200 + (w) * 4)  // B：4 字，字 = B 的一行 4 int8
#define NPU_L0C_DATA(w) (NPU_BASE + 0x300 + (w) * 4)  // C：w = 128 位字号 * 4 + lane（int32）

#define NPU_CMD_LDTILE   (1u << 0)
#define NPU_CMD_TMUL   (1u << 1)
#define NPU_CMD_ACC      (1u << 2)

#define NPU_STATUS_BUSY  (1u << 0)
#define NPU_STATUS_DONE  (1u << 1)

// L0 容量（参数化；默认与 npu_top 的 L0A_DEPTH/L0C_DEPTH 一致）
#define NPU_L0A_DEPTH  64     // A 行缓冲（字 = 一行 4 int8）
#define NPU_L0B_DEPTH  4      // B 4×4 子块
#define NPU_L0C_DEPTH  64     // C 行缓冲（字 = 一行 4 int32）

#define NPU_M_TILE_MAX 64     // 一次 TMUL 最多 64 行（默认 L0A/L0C 深度）
#define NPU_N_TILE     4      // 一次 TMUL 算 4 列（B 的列数 = 阵列宽度）
#define NPU_K_TILE     4      // 一次 TMUL 的收缩宽度

// 矩阵乘 C[M][N] = A[M][K] × B[K][N]
//  - A, B: int8，行优先；C: int32，行优先
//  - M/N/K 为 4 的倍数，A/B 行起始地址 4 字节对齐
//  - 返回 LDTILE / TMUL 次数
typedef struct {
  int ldtile;
  int tmul;
} npu_counts_t;

// v1：简单三层循环（M/N/K 为 4 的倍数）
npu_counts_t npu_matmul_v1(const int8_t *A, const int8_t *B, int32_t *C,
                           int m, int n, int k);
// v2：一次 LDTILE 复用到两个 C 行子块（M/4 为偶数）
npu_counts_t npu_matmul_v2(const int8_t *A, const int8_t *B, int32_t *C,
                           int m, int n, int k);

// 指令级接口
void npu_fill_l0a(const int8_t *A, int stride, int a_base);  // 4x4 A 子块 -> L0A
void npu_fill_l0b(const int8_t *B, int stride);              // 4x4 B 子块 -> L0B
void npu_ldtile(void);                                       // LDTILE：B 子块载入阵列
void npu_tmul(int a_base, int c_base, int m_rows, int acc);  // TMUL：C += A x B
void npu_read_l0c(int32_t *C, int stride, int c_base);       // 4x4 C 子块 <- L0C
int  npu_busy(void);
int  npu_done(void);
void npu_clear_done(void);

// 软件对照实现（标量三重循环，用于验证 NPU 结果的正确性）
void npu_matmul_sw(const int8_t *A, const int8_t *B, int32_t *C, int m, int n, int k);

#endif
