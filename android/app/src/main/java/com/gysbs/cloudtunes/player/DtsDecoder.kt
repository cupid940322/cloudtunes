package com.gysbs.cloudtunes.player

import androidx.media3.decoder.DecoderException
import androidx.media3.decoder.DecoderInputBuffer
import androidx.media3.decoder.SimpleDecoder
import androidx.media3.decoder.SimpleDecoderOutputBuffer

/** DTS 解码过程中的错误 */
class DtsDecoderException(message: String, cause: Throwable? = null) :
    DecoderException(message, cause)

/**
 * libdca 的 media3 解码器：一帧 DTS 码流进，交织 int16 PCM 出。
 *
 * 两个必须注意的点（都是 iOS 版踩过坑后确认的）：
 *  - 声道数是**每帧回读**的：请求立体声时 5.1 源会被 downmix 成 2 声道，
 *    但单声道源仍然只回 1 声道，写死 2 会让时间轴和声道错位。
 *  - 采样率/声道数只在真正解出数据后才知道，所以 [getOutputFormat][DtsAudioRenderer.getOutputFormat]
 *    要等到第一个输出 buffer 出队后才被读 —— media3 本来就是这么设计的。
 */
class DtsDecoder : SimpleDecoder<DecoderInputBuffer, SimpleDecoderOutputBuffer, DtsDecoderException>(
    inputBufferArray(INPUT_BUFFER_COUNT),
    outputBufferArray(OUTPUT_BUFFER_COUNT),
) {

    private val handle: Long
    private val pcm = ShortArray(MAX_PCM_SHORTS)
    private val info = IntArray(2)
    private var frame = ByteArray(0)
    private var silence = ShortArray(0)

    /** 最近一帧的采样率 */
    var sampleRate: Int = 44100
        private set

    /** 最近一帧的实际输出声道数 */
    var channelCount: Int = 2
        private set

    /** 最近一帧每声道的样本数，坏帧补静音时用它保持时间轴 */
    private var framesPerBuffer = 1024

    init {
        if (!DtsNative.available) throw DtsDecoderException("libdtsjni 未加载")
        val h = DtsNative.nativeInit()
        if (h == 0L) throw DtsDecoderException("libdca 初始化失败")
        handle = h
        // 一帧 4KB 左右，给 16KB 余量，避免边界上反复扩容
        setInitialInputBufferSize(16384)
    }

    override fun createInputBuffer(): DecoderInputBuffer =
        DecoderInputBuffer(DecoderInputBuffer.BUFFER_REPLACEMENT_MODE_NORMAL)

    override fun createOutputBuffer(): SimpleDecoderOutputBuffer =
        // 注意：不能写成 buffer.release() —— SimpleDecoderOutputBuffer.release() 本身
        // 就是回调这个 owner，会无限递归。必须调父类的 releaseOutputBuffer（把 buffer 还回池子）
        SimpleDecoderOutputBuffer { buffer -> this@DtsDecoder.releaseOutputBuffer(buffer) }

    override fun createUnexpectedDecodeException(error: Throwable): DtsDecoderException =
        DtsDecoderException("DTS 解码异常", error)

    override fun decode(
        inputBuffer: DecoderInputBuffer,
        outputBuffer: SimpleDecoderOutputBuffer,
        reset: Boolean,
    ): DtsDecoderException? {
        val data = inputBuffer.data ?: return DtsDecoderException("输入缓冲为空")
        val size = data.remaining()
        if (size <= 0) return DtsDecoderException("空样本")

        if (frame.size < size) frame = ByteArray(size)
        data.get(frame, 0, size)

        val count = DtsNative.nativeDecode(handle, frame, pcm, info)
        if (count <= 0) return writeSilence(outputBuffer, inputBuffer.timeUs)

        if (info[0] in 1..8) channelCount = info[0]
        if (info[1] > 0) sampleRate = info[1]
        framesPerBuffer = count / channelCount

        val buffer = outputBuffer.init(inputBuffer.timeUs, count * 2)
        // init 已经 position(0)/limit(size)，asShortBuffer 的写入不会移动 position，
        // 这正是 AudioSink 期望的「position=0、limit=有效字节数」布局
        buffer.position(0)
        buffer.asShortBuffer().put(pcm, 0, count)
        return null
    }

    override fun release() {
        super.release()
        DtsNative.nativeFree(handle)
    }

    /** 坏帧补等长静音：不中断整首歌，也不会让时间轴塌掉 */
    private fun writeSilence(
        outputBuffer: SimpleDecoderOutputBuffer,
        timeUs: Long,
    ): DtsDecoderException? {
        val shorts = framesPerBuffer.coerceAtLeast(256) * channelCount
        val buffer = outputBuffer.init(timeUs, shorts * 2)
        buffer.position(0)
        if (silence.size < shorts) {
            silence = ShortArray(shorts)
        } else {
            java.util.Arrays.fill(silence, 0, shorts, 0.toShort())
        }
        buffer.asShortBuffer().put(silence, 0, shorts)
        return null
    }

    private companion object {
        const val INPUT_BUFFER_COUNT = 4
        const val OUTPUT_BUFFER_COUNT = 4
        /** 16 block × 256 样本 × 8 声道 的上限，留足余量 */
        const val MAX_PCM_SHORTS = 32768

        @Suppress("UNCHECKED_CAST")
        fun inputBufferArray(n: Int): Array<DecoderInputBuffer> =
            arrayOfNulls<DecoderInputBuffer>(n) as Array<DecoderInputBuffer>

        @Suppress("UNCHECKED_CAST")
        fun outputBufferArray(n: Int): Array<SimpleDecoderOutputBuffer> =
            arrayOfNulls<SimpleDecoderOutputBuffer>(n) as Array<SimpleDecoderOutputBuffer>
    }
}
