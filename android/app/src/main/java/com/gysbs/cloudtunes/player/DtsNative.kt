package com.gysbs.cloudtunes.player

import com.gysbs.cloudtunes.core.CrashLog

/**
 * libdca（DTS Coherent Acoustics 解码器）的 JNI 门面。
 *
 * 为什么需要它：DTS-CD 抓轨出来的 WAV，RIFF 头是教科书级的
 * `fmt tag=1 PCM 16bit/44100/2ch`，`data` 里其实是大端/小端的 DTS 码流。
 * Android 系统没有 DTS 解码器，按 PCM 直接播就是一片噪音。
 *
 * 方法都是 public（不是 internal）：Kotlin 会给 **internal 成员** 的名字加
 * `$模块名` 后缀，那样 JNI 就找不到 `Java_..._nativeInit` 这个符号了。
 */
object DtsNative {

    /** so 是否加载成功；设备 ABI 不在打包列表里时为 false（此时退回原行为，只是 DTS 仍会是噪音） */
    val available: Boolean = try {
        System.loadLibrary("dtsjni")
        true
    } catch (t: Throwable) {
        CrashLog.record("加载 libdtsjni", t)
        false
    }

    /** 建解码器，返回句柄（0 = 失败） */
    external fun nativeInit(): Long

    external fun nativeFree(handle: Long)

    /**
     * 解析帧头。
     * @param header 至少 16 字节的帧头
     * @param out 出参 [采样率, 位率, 帧内样本数]
     * @return 整帧**字节数**（0 = 不是有效 DTS 帧）
     */
    external fun nativeSyncInfo(handle: Long, header: ByteArray, out: IntArray): Int

    /**
     * 解一整帧。
     * @param out 交织 int16 的落点
     * @param info 出参 [实际输出声道数, 采样率]
     * @return 写入 out 的 short 个数（0 = 失败）
     */
    external fun nativeDecode(handle: Long, frame: ByteArray, out: ShortArray, info: IntArray): Int

    /** 只探测同步字，不建解码器；返回整帧字节数（0 = 不是 DTS） */
    external fun nativeProbeFrameLength(header: ByteArray): Int
}
