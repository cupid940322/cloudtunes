package com.gysbs.cloudtunes.player

import android.os.Handler
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.decoder.CryptoConfig
import androidx.media3.exoplayer.audio.AudioRendererEventListener
import androidx.media3.exoplayer.audio.DecoderAudioRenderer

/**
 * 把 [DtsDecoder] 接到 ExoPlayer 的音频渲染链上。
 *
 * 只认 `MimeTypes.AUDIO_DTS`（由 [DtsExtractor] 产出），输出交给系统音频设备播。
 * 真正的输出格式（采样率 / 声道数）要等第一帧解出来才知道，所以走 [getOutputFormat]。
 */
class DtsAudioRenderer(
    eventHandler: Handler?,
    eventListener: AudioRendererEventListener?,
) : DecoderAudioRenderer<DtsDecoder>(eventHandler, eventListener) {

    override fun getName(): String = "DtsAudioRenderer"

    override fun supportsFormatInternal(format: Format): Int {
        if (!DtsNative.available) return C.FORMAT_UNSUPPORTED_TYPE
        if (format.sampleMimeType != MimeTypes.AUDIO_DTS) return C.FORMAT_UNSUPPORTED_TYPE

        // 输出是裸 PCM16，得先确认本机音频设备吃得下这个采样率/声道数
        val pcm = Format.Builder()
            .setSampleMimeType(MimeTypes.AUDIO_RAW)
            .setPcmEncoding(C.ENCODING_PCM_16BIT)
            .setSampleRate(if (format.sampleRate > 0) format.sampleRate else 44100)
            .setChannelCount(if (format.channelCount > 0) format.channelCount else 2)
            .build()
        return if (sinkSupportsFormat(pcm)) C.FORMAT_HANDLED else C.FORMAT_UNSUPPORTED_SUBTYPE
    }

    override fun createDecoder(format: Format, cryptoConfig: CryptoConfig?): DtsDecoder =
        DtsDecoder()

    override fun getOutputFormat(decoder: DtsDecoder): Format =
        Format.Builder()
            .setSampleMimeType(MimeTypes.AUDIO_RAW)
            .setPcmEncoding(C.ENCODING_PCM_16BIT)
            .setSampleRate(decoder.sampleRate)
            .setChannelCount(decoder.channelCount)
            .build()
}
