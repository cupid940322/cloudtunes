package com.gysbs.cloudtunes.player

import android.content.Context
import android.os.Handler
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.RenderersFactory
import androidx.media3.exoplayer.audio.AudioRendererEventListener
import androidx.media3.exoplayer.metadata.MetadataOutput
import androidx.media3.exoplayer.text.TextOutput
import androidx.media3.exoplayer.video.VideoRendererEventListener

/**
 * 在默认渲染器前面插一个 [DtsAudioRenderer]。
 *
 * 系统的 MediaCodecAudioRenderer 遇到 `MimeTypes.AUDIO_DTS` 会去找硬件/软件
 * DTS 解码器，绝大多数手机没有 → 直接报不支持的格式。
 * 自己的渲染器排在前面先接住，剩下的格式照旧走默认那套。
 */
class DtsRenderersFactory(context: Context) : RenderersFactory {

    private val delegate = DefaultRenderersFactory(context)

    override fun createRenderers(
        eventHandler: Handler,
        videoRendererEventListener: VideoRendererEventListener,
        audioRendererEventListener: AudioRendererEventListener,
        textRendererOutput: TextOutput,
        metadataRendererOutput: MetadataOutput,
    ): Array<Renderer> {
        val base = delegate.createRenderers(
            eventHandler,
            videoRendererEventListener,
            audioRendererEventListener,
            textRendererOutput,
            metadataRendererOutput,
        )
        // so 没打进来（ABI 不匹配）时保持原样，DTS 仍会是噪音但别的文件不受影响
        if (!DtsNative.available) return base

        return Array<Renderer>(base.size + 1) { index ->
            if (index == 0) {
                DtsAudioRenderer(eventHandler, audioRendererEventListener)
            } else {
                base[index - 1]
            }
        }
    }
}
