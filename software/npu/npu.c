// npu.c - NPU 软件驱动（weight stationary 脉动阵列，C = A x B）
//
// 简化实现，对应课程文档中的 v1/v2：
//   - 只支持 M、N、K 是 4 的倍数；
//   - A/B/C 都按行优先存放，A/B 行起始地址 4 字节对齐；
//   - 不处理 K/N/M 尾块，不做 padding，不处理非对齐指针；
//   - v2 额外要求 M/4 是偶数（即 M 是 8 的倍数）。
//
// LDTILE：把 L0B 里的 4x4 B 子块载入阵列（B 驻留）。
// TMUL  ：C(Mx4) += A(Mx4) x B(4x4)，这里每次固定做 M=4。

#include "npu.h"

// ---- MMIO 访问 ----
#include <stdint.h>
static inline uint32_t npu_read(uint32_t addr) {
  return *(volatile uint32_t *)(uintptr_t)addr;
}
static inline void npu_write(uint32_t addr, uint32_t val) {
  *(volatile uint32_t *)(uintptr_t)addr = val;
}

// ---- 从 4 字节对齐的 int8 行读出一个 32 位字（4 个 int8） ----
static inline uint32_t load4(const int8_t *p) {
  return *(const uint32_t *)p;
}

// ---- 把一个 4x4 A 子块写入 L0A ----
// A 指向子块左上角，stride 是 A 的行宽（K）；a_base 是 L0A 字地址。
void npu_fill_l0a(const int8_t *A, int stride, int a_base) {
  for (int r = 0; r < 4; r++)
    npu_write(NPU_L0A_DATA(a_base + r), load4(A + r * stride));
}

// ---- 把一个 4x4 B 子块写入 L0B（固定写到 L0B 字 0..3） ----
// B 指向子块左上角，stride 是 B 的行宽（N）。
void npu_fill_l0b(const int8_t *B, int stride) {
  for (int r = 0; r < 4; r++)
    npu_write(NPU_L0B_DATA(r), load4(B + r * stride));
}

// ---- 从 L0C 读回一个 4x4 C 子块 ----
// C 指向目的子块左上角，stride 是 C 的行宽（N）；
// c_base 是 L0C 的 128 位字地址（每个字存 C 的一行 4 个 int32）。
void npu_read_l0c(int32_t *C, int stride, int c_base) {
  for (int r = 0; r < 4; r++)
    for (int j = 0; j < 4; j++)
      C[r * stride + j] =
          (int32_t)npu_read(NPU_L0C_DATA((c_base + r) * 4 + j));
}

// ---- 指令级接口 ----
void npu_ldtile(void) {
  npu_write(NPU_REG_CMD, NPU_CMD_LDTILE);
}

void npu_tmul(int a_base, int c_base, int m_rows, int acc) {
  npu_write(NPU_REG_A_BASE, a_base);
  npu_write(NPU_REG_C_BASE, c_base);
  npu_write(NPU_REG_M_ROWS, m_rows - 1);
  npu_write(NPU_REG_CMD, NPU_CMD_TMUL | (acc ? NPU_CMD_ACC : 0));
}

int npu_busy(void) {
  return npu_read(NPU_REG_STATUS) & NPU_STATUS_BUSY;
}

int npu_done(void) {
  return npu_read(NPU_REG_STATUS) & NPU_STATUS_DONE;
}

void npu_clear_done(void) {
  npu_write(NPU_REG_STATUS, NPU_STATUS_DONE);
}

static void npu_wait(void) {
  while (npu_busy())
    ;
}

// ==================== v1：三层循环，每个 C 子块独立计算 ====================
// 返回 LDTILE / TMUL 次数。
npu_counts_t npu_matmul_v1(const int8_t *A, const int8_t *B, int32_t *C,
                           int M, int N, int K) {
  npu_write(NPU_REG_B_BASE, 0);
  int ld_cnt = 0, tmul_cnt = 0;

  for (int i = 0; i < M / 4; i++) {
    for (int j = 0; j < N / 4; j++) {
      for (int k = 0; k < K / 4; k++) {
        // B 子块
        npu_fill_l0b(B + (k * N + j) * 4, N);
        npu_ldtile();
        npu_wait();
        ld_cnt++;

        // A 子块 + TMUL
        npu_fill_l0a(A + (i * K + k) * 4, K, 0);
        npu_tmul(0, 0, 4, k > 0);
        npu_wait();
        tmul_cnt++;
      }

      // 读回 C 子块
      npu_read_l0c(C + (i * N + j) * 4, N, 0);
    }
  }

  npu_clear_done();
  npu_counts_t ret = {ld_cnt, tmul_cnt};
  return ret;
}

// ==================== v2：一次 LDTILE，复用到两个 C 行子块 ====================
// 要求 M/4 是偶数。返回 LDTILE / TMUL 次数。
npu_counts_t npu_matmul_v2(const int8_t *A, const int8_t *B, int32_t *C,
                           int M, int N, int K) {
  npu_write(NPU_REG_B_BASE, 0);
  int ld_cnt = 0, tmul_cnt = 0;

  for (int i = 0; i < M / 4; i += 2) {
    for (int j = 0; j < N / 4; j++) {
      for (int k = 0; k < K / 4; k++) {
        // 一次 LDTILE 加载 B 子块
        npu_fill_l0b(B + (k * N + j) * 4, N);
        npu_ldtile();
        npu_wait();
        ld_cnt++;

        int acc = k > 0;

        // Cij = Aik * Bkj
        npu_fill_l0a(A + (i * K + k) * 4, K, 0);
        npu_tmul(0, 0, 4, acc);
        npu_wait();

        // C(i+1)j += A(i+1)k * Bkj
        npu_fill_l0a(A + ((i + 1) * K + k) * 4, K, 4);
        npu_tmul(4, 4, 4, acc);
        npu_wait();
        tmul_cnt += 2;
      }

      // 读回两个 C 子块
      npu_read_l0c(C + (i * N + j) * 4, N, 0);
      npu_read_l0c(C + ((i + 1) * N + j) * 4, N, 4);
    }
  }

  npu_clear_done();
  npu_counts_t ret = {ld_cnt, tmul_cnt};
  return ret;
}

// ---- 软件对照（标量三重循环，int8 输入 int32 累加） ----
void npu_matmul_sw(const int8_t *A, const int8_t *B, int32_t *C,
                   int M, int N, int K) {
  for (int i = 0; i < M; i++)
    for (int j = 0; j < N; j++) {
      int32_t sum = 0;
      for (int k = 0; k < K; k++)
        sum += (int32_t)A[i * K + k] * (int32_t)B[k * N + j];
      C[i * N + j] = sum;
    }
}
