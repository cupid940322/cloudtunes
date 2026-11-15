/*
 * dts_jni.c —— libdca 的 JNI 包装
 *
 * 只做三件事：
 *   1. 把 Java 传进来的帧头交给 dca_syncinfo，拿到整帧字节数 / 采样率 / 位率
 *   2. 把整帧字节交给 dca_frame + dca_block 解成 float PCM
 *   3. 转成 Android AudioSink 要的 **交织 int16**（channel-major → interleaved）
 *
 * 两个坑（iOS 版踩过，这里照抄结论）：
 *   - dca_syncinfo 的**返回值是帧的字节数**，出参 frame_length 是帧内样本数。
 *     拿 1024 当字节数去切帧，等于每帧只喂进四分之一，结果是「能听出旋律但全是杂音」。
 *   - dca_bitstream_init 会把指针按 4 字节向下对齐，可能读到 buf 前面的字节，
 *     所以真正的帧数据前面必须留几个字节的垫子（PAD_HEAD）。
 */

#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "dca.h"

/* libdca 输出 float（config.h 没定义 LIBDCA_FIXED / LIBDCA_DOUBLE） */
typedef float dts_sample_t;

/* 帧数据前面的安全垫：bitstream_init 会向下对齐到 4 字节后回退读 */
#define PAD_HEAD 8
#define PAD_TAIL 32

/* 首帧按这个大小起步，不够再翻倍 */
#define INITIAL_FRAME_CAP 8192

/* 一个 block 每声道固定 256 个样本；DTS 最多 16 个 block，声道最多 8 */
#define MAX_BLOCKS 16
#define SAMPLES_PER_BLOCK 256
#define MAX_CHANNELS 8

/* tables.h 里的 dca_channels[]：flags 低 6 位 → 实际输出声道数 */
static const int channel_count_table[16] =
    { 1, 2, 2, 2, 2, 3, 3, 4, 4, 5, 6, 6, 6, 7, 8, 8 };

typedef struct {
    dca_state_t *state;
    uint8_t *raw;      /* realloc 拿到的原始指针 */
    uint8_t *base;     /* base[0..PAD_HEAD) 是垫子，帧数据从 base 开始写 */
    int capacity;
    /* 交织 int16 的落点 */
    int16_t *pcm;
    int pcm_capacity;
} dts_ctx;

static int ensure_frame_capacity(dts_ctx *c, int need)
{
    if (c->capacity >= need) return 1;

    int cap = c->capacity > 0 ? c->capacity : INITIAL_FRAME_CAP;
    while (cap < need) cap *= 2;

    uint8_t *raw = (uint8_t *) realloc(c->raw,
                                       (size_t) cap + PAD_HEAD + PAD_TAIL + 8);
    if (raw == NULL) return 0;

    c->raw = raw;
    /* 先把起点对齐到 4 字节，再留 PAD_HEAD 字节垫子；PAD_HEAD 是 8 的倍数，仍然 4 字节对齐 */
    uintptr_t aligned = ((uintptr_t) raw + 4) & ~(uintptr_t) 3;
    c->base = (uint8_t *) (aligned + PAD_HEAD);
    c->capacity = cap;
    return 1;
}

static int ensure_pcm_capacity(dts_ctx *c, int need)
{
    if (c->pcm_capacity >= need) return 1;
    int cap = c->pcm_capacity > 0 ? c->pcm_capacity : 8192;
    while (cap < need) cap *= 2;
    int16_t *p = (int16_t *) realloc(c->pcm, (size_t) cap * sizeof(int16_t));
    if (p == NULL) return 0;
    c->pcm = p;
    c->pcm_capacity = cap;
    return 1;
}

JNIEXPORT jlong JNICALL
Java_com_gysbs_cloudtunes_player_DtsNative_nativeInit(JNIEnv *env, jobject thiz)
{
    (void) env; (void) thiz;

    dts_ctx *c = (dts_ctx *) calloc(1, sizeof(dts_ctx));
    if (c == NULL) return 0;

    c->state = dca_init(0);
    if (c->state == NULL) {
        free(c);
        return 0;
    }
    if (!ensure_frame_capacity(c, INITIAL_FRAME_CAP)) {
        dca_free(c->state);
        free(c);
        return 0;
    }
    return (jlong) (intptr_t) c;
}

JNIEXPORT void JNICALL
Java_com_gysbs_cloudtunes_player_DtsNative_nativeFree(JNIEnv *env, jobject thiz, jlong handle)
{
    (void) env; (void) thiz;

    dts_ctx *c = (dts_ctx *) (intptr_t) handle;
    if (c == NULL) return;
    if (c->state) dca_free(c->state);
    free(c->raw);
    free(c->pcm);
    free(c);
}

/*
 * 解析帧头。
 * 返回：整帧**字节数**（0 = 这段不是有效 DTS 帧）
 * out：  [0]=采样率  [1]=位率  [2]=帧内样本数（每声道）
 */
JNIEXPORT jint JNICALL
Java_com_gysbs_cloudtunes_player_DtsNative_nativeSyncInfo(
        JNIEnv *env, jobject thiz, jlong handle, jbyteArray header, jintArray out)
{
    (void) thiz;

    dts_ctx *c = (dts_ctx *) (intptr_t) handle;
    if (c == NULL || header == NULL) return 0;

    jsize n = (*env)->GetArrayLength(env, header);
    if (n < 16) return 0;
    if (!ensure_frame_capacity(c, n)) return 0;

    (*env)->GetByteArrayRegion(env, header, 0, n, (jbyte *) c->base);

    int flags = 0, sample_rate = 0, bit_rate = 0, frame_length = 0;
    int frame_bytes = dca_syncinfo(c->state, c->base, &flags,
                                   &sample_rate, &bit_rate, &frame_length);
    if (frame_bytes <= 0) return 0;

    if (out != NULL && (*env)->GetArrayLength(env, out) >= 3) {
        jint vals[3];
        vals[0] = sample_rate;
        vals[1] = bit_rate;
        vals[2] = frame_length;
        (*env)->SetIntArrayRegion(env, out, 0, 3, vals);
    }
    return frame_bytes;
}

/*
 * 解一整帧，输出**交织 int16**。
 * 返回：写入 out 的 short 个数（>0 成功；0 = 解码失败/静音帧）
 * info： [0]=实际输出声道数  [1]=采样率
 */
JNIEXPORT jint JNICALL
Java_com_gysbs_cloudtunes_player_DtsNative_nativeDecode(
        JNIEnv *env, jobject thiz, jlong handle, jbyteArray frame,
        jshortArray out, jintArray info)
{
    (void) thiz;

    dts_ctx *c = (dts_ctx *) (intptr_t) handle;
    if (c == NULL || frame == NULL || out == NULL) return 0;

    jsize n = (*env)->GetArrayLength(env, frame);
    if (n <= 0) return 0;
    if (!ensure_frame_capacity(c, n)) return 0;

    (*env)->GetByteArrayRegion(env, frame, 0, n, (jbyte *) c->base);

    /* 先过一遍 syncinfo：既校验帧头，又顺手拿到采样率（dca_frame 不回传采样率） */
    int hflags = 0, sample_rate = 0, bit_rate = 0, frame_length = 0;
    if (dca_syncinfo(c->state, c->base, &hflags, &sample_rate,
                     &bit_rate, &frame_length) <= 0) {
        return 0;
    }

    /* 请求立体声：5.1 源会被 downmix 成 2 声道；ADJUST_LEVEL 避免混音削顶 */
    int flags = DCA_STEREO | DCA_ADJUST_LEVEL;
    dts_sample_t level = 1.0f;
    dts_sample_t bias = 0.0f;

    int ret = dca_frame(c->state, c->base, &flags, &level, bias);
    if (ret != 0) return 0; /* 1 = 失败（例如 amode 超出 downmix 表范围） */

    /* 调用之后 flags 被写回成真实输出布局 */
    int idx = flags & DCA_CHANNEL_MASK;
    if (idx < 0 || idx >= 16) idx = 1;
    int channels = channel_count_table[idx];
    if (channels < 1) return 0;
    if (channels > MAX_CHANNELS) channels = MAX_CHANNELS;

    int blocks = dca_blocks_num(c->state);
    if (blocks <= 0) return 0;
    if (blocks > MAX_BLOCKS) blocks = MAX_BLOCKS;

    int total = blocks * SAMPLES_PER_BLOCK * channels;
    if (total > (*env)->GetArrayLength(env, out)) return 0;
    if (!ensure_pcm_capacity(c, total)) return 0;

    int written = 0; /* 已完成的总样本数（含所有声道） */
    for (int b = 0; b < blocks; b++) {
        if (dca_block(c->state) != 0) break;
        dts_sample_t *raw = dca_samples(c->state);
        if (raw == NULL) break;

        /* libdca 每个 block 是 channel-major：ch0 的 256 个，再 ch1 的 256 个……
           这里就地转成交织，顺便 float → int16 */
        int base = written;
        for (int ch = 0; ch < channels; ch++) {
            const dts_sample_t *src = raw + ch * SAMPLES_PER_BLOCK;
            int16_t *dst = c->pcm + base + ch;
            for (int i = 0; i < SAMPLES_PER_BLOCK; i++) {
                float v = src[i];
                if (v > 1.0f) v = 1.0f;
                else if (v < -1.0f) v = -1.0f;
                dst[i * channels] = (int16_t) lrintf(v * 32767.0f);
            }
        }
        written += SAMPLES_PER_BLOCK * channels;
    }

    if (written <= 0) return 0;

    if (info != NULL && (*env)->GetArrayLength(env, info) >= 2) {
        jint vals[2];
        vals[0] = channels;
        vals[1] = sample_rate;
        (*env)->SetIntArrayRegion(env, info, 0, 2, vals);
    }

    (*env)->SetShortArrayRegion(env, out, 0, written, c->pcm);
    return written;
}

/* 只做同步字探测，不建 state、不分配大缓冲 —— 供 Extractor 嗅探用 */
JNIEXPORT jint JNICALL
Java_com_gysbs_cloudtunes_player_DtsNative_nativeProbeFrameLength(
        JNIEnv *env, jobject thiz, jbyteArray header)
{
    (void) thiz;

    if (header == NULL) return 0;
    jsize n = (*env)->GetArrayLength(env, header);
    if (n < 16) return 0;

    uint8_t buf[PAD_HEAD + 64];
    memset(buf, 0, sizeof(buf));
    int copy = n < 64 ? (int) n : 64;
    (*env)->GetByteArrayRegion(env, header, 0, copy, (jbyte *) (buf + PAD_HEAD));

    dca_state_t *state = dca_init(0);
    if (state == NULL) return 0;
    int flags = 0, sample_rate = 0, bit_rate = 0, frame_length = 0;
    int frame_bytes = dca_syncinfo(state, buf + PAD_HEAD, &flags,
                                   &sample_rate, &bit_rate, &frame_length);
    dca_free(state);
    return frame_bytes > 0 ? frame_bytes : 0;
}
