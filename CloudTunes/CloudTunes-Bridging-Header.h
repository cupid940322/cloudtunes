//
//  CloudTunes-Bridging-Header.h
//  给 Swift 暴露 libdca（DTS 解码库）的 C 接口。
//
//  libdca 是 CI 里现编的静态库（见 .github/workflows/build.yml 的
//  "Build libdca" 步骤），产物放在 Libraries/libdca/{libdca.a, include/dca.h}。
//  本地没有这个库时用下面的 fallback 声明顶上，保证 Swift 侧还能编译
//  （能编译、但跑到 DTS 解码会在链接期缺符号——只能在 CI 环境验证）。
//
//  这里刻意**不**引入 dca.h 里的宏和 static inline 函数：
//  C 宏/内联函数在 Swift 侧的导入形态不稳定（Int32 / Int 混杂），
//  用到的常量（DCA_STEREO 等）与声道表都在 DTSDecoder.swift 里另写一份，
//  数值与 dca.h 保持一致即可。
//

#ifndef CLOUDTUNES_BRIDGING_HEADER_H
#define CLOUDTUNES_BRIDGING_HEADER_H

#include <stdint.h>

#if __has_include(<dca.h>)
#include <dca.h>
#else
typedef struct dca_state_s dca_state_t;
typedef float sample_t;
typedef float level_t;

dca_state_t *dca_init(uint32_t mm_accel);
int dca_syncinfo(dca_state_t *state, uint8_t *buf, int *flags,
                 int *sample_rate, int *bit_rate, int *frame_length);
int dca_frame(dca_state_t *state, uint8_t *buf, int *flags,
              level_t *level, sample_t bias);
int dca_blocks_num(dca_state_t *state);
int dca_block(dca_state_t *state);
sample_t *dca_samples(dca_state_t *state);
void dca_free(dca_state_t *state);
#endif

#endif /* CLOUDTUNES_BRIDGING_HEADER_H */
