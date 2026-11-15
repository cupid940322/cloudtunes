package com.gysbs.cloudtunes.player

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ParsableByteArray
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorInput
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.PositionHolder
import androidx.media3.extractor.SeekMap
import androidx.media3.extractor.SeekPoint
import androidx.media3.extractor.TrackOutput
import com.gysbs.cloudtunes.core.CrashLog

/**
 * DTS-in-WAV 的提取器：把「伪装成 PCM 的 DTS-CD 抓轨」识别出来，
 * 按帧切成 `MimeTypes.AUDIO_DTS` 的样本喂给 [DtsAudioRenderer]。
 *
 * 判定条件（两个都要满足）：
 *   1. 标准的 `RIFF....WAVE` 文件，且能找到 `data` chunk
 *   2. `data` 开头就是 DTS 同步字（libdca 认 4 种：16/14bit × 大小端）
 *
 * 真 PCM 的 WAV 不会命中第 2 条，所以嗅探失败时照旧交给系统的 WavExtractor。
 *
 * 这个文件不解析 `fmt` chunk —— 它的内容对 DTS 抓轨来说全是假的（写着 PCM 16bit），
 * 真实参数一律从 DTS 帧头拿。
 */
class DtsExtractor : Extractor {

    private var extractorOutput: ExtractorOutput? = null
    private var trackOutput: TrackOutput? = null

    private var headerParsed = false
    /** data chunk 数据区在文件里的起始偏移 */
    private var dataStart = 0L
    /** data chunk 结束偏移；0 表示未知（按文件长度算） */
    private var dataEnd = 0L
    /** 每秒字节数，用来算时长/定位 */
    private var bytesPerSecond = 0L
    private var sampleRate = 44100
    private var samplesPerFrame = 0
    private var frameBytes = 0

    /** 下一帧的播放时间戳 */
    private var timeUs = 0L
    private var ended = false

    private var frameBuffer = ByteArray(0)
    private var frameSample = ParsableByteArray()
    private val info = IntArray(3)

    // ── Extractor ──

    override fun sniff(input: ExtractorInput): Boolean {
        if (!DtsNative.available) return false

        // 先只 peek 12 字节：mp3/flac/m4a 全在这里就被否掉，不为它们多读一个字节
        val head = ByteArray(12)
        val hasHead = input.peekFully(head, 0, 12, true)
        input.resetPeekPosition()
        if (!hasHead || !isRiffWave(head)) return false

        // 头部最多扫这么多：正常 WAV 的 data chunk 在 40~100 字节处，
        // 带大块 LIST/INFO 的抓轨也不会超过 64KB
        val scan = ByteArray(MAX_SCAN)
        var have = 0
        while (have < MAX_SCAN) {
            val step = minOf(8192, MAX_SCAN - have)
            if (!input.peekFully(scan, have, step, true)) break
            have += step
            val dataOffset = findDataChunk(scan, have)
            if (dataOffset != null) {
                input.resetPeekPosition()
                return findFirstFrame(scan, dataOffset, have)
            }
            // data chunk 还没出现，继续往后 peek
        }
        input.resetPeekPosition()
        val dataOffset = findDataChunk(scan, have) ?: return false
        return findFirstFrame(scan, dataOffset, have)
    }

    override fun init(output: ExtractorOutput) {
        extractorOutput = output
        trackOutput = output.track(0, C.TRACK_TYPE_AUDIO)
        output.endTracks()
    }

    override fun seek(position: Long, timeUs: Long) {
        // 只有「回到文件头」才需要重新解析 RIFF 头。
        // 注意不能写成 position <= dataStart —— 定位到 data 起点时输入是停在 data 上的，
        // 再从那里解析 RIFF 头必然失败，整首歌会直接变成「播不出」。
        if (position <= 12L) headerParsed = false
        this.timeUs = if (timeUs > 0) timeUs else 0
        ended = false
    }

    override fun read(input: ExtractorInput, seekPosition: PositionHolder): Int {
        if (!headerParsed) {
            if (!parseHeader(input)) {
                ended = true
                return Extractor.RESULT_END_OF_INPUT
            }
            headerParsed = true
        }
        if (ended || frameBytes <= 0) return Extractor.RESULT_END_OF_INPUT

        val len = frameBytes
        if (frameBuffer.size < len) frameBuffer = ByteArray(len)
        var offset = 0
        while (offset < len) {
            val read = input.read(frameBuffer, offset, len - offset)
            if (read == C.RESULT_END_OF_INPUT || read <= 0) {
                // 尾部残留的半帧直接丢掉
                ended = true
                return Extractor.RESULT_END_OF_INPUT
            }
            offset += read
        }

        val track = trackOutput ?: return Extractor.RESULT_END_OF_INPUT
        frameSample.reset(frameBuffer, len)
        track.sampleData(frameSample, len)
        track.sampleMetadata(timeUs, C.BUFFER_FLAG_KEY_FRAME, len, 0, null)

        timeUs += samplesPerFrame * 1_000_000L / sampleRate.coerceAtLeast(1)
        return Extractor.RESULT_CONTINUE
    }

    override fun release() {
        // 没有需要释放的资源
    }

    // ── 解析 ──

    /** 读 RIFF 头 + 找到 data chunk + 探测首帧，成功返回 true */
    private fun parseHeader(input: ExtractorInput): Boolean {
        val fixed = ByteArray(12)
        if (!input.readFully(fixed, 0, 12, true)) return false
        if (!isRiffWave(fixed)) return false

        while (true) {
            val chunk = ByteArray(8)
            if (!input.readFully(chunk, 0, 8, true)) return false
            val id = String(chunk, 0, 4, Charsets.US_ASCII)
            val size = readU32LE(chunk, 4)
            if (id == "data") {
                dataStart = input.position
                val total = input.length
                dataEnd = when {
                    size > 0 && (total <= 0 || dataStart + size <= total) -> dataStart + size
                    total > dataStart -> total
                    else -> 0L
                }
                break
            }
            // 未知 chunk：整块跳过（chunk 长度按偶数对齐）
            val skip = size + (size and 1L)
            if (skip <= 0 || skip > Int.MAX_VALUE) return false
            try {
                input.skipFully(skip.toInt())
            } catch (t: Throwable) {
                return false
            }
        }

        val window = scanWindow(input)
        if (window < 32) return false
        val scan = ByteArray(window)
        val peeked = input.peekFully(scan, 0, window, true)
        // peek 不满就只信前 32 字节（正常抓轨 sync 就在 data 起点）
        val usable = if (peeked) window else 32

        val handle = DtsNative.nativeInit()
        if (handle == 0L) return false
        var frameOffset = -1
        var detected = 0
        try {
            var k = 0
            while (k + 32 <= usable) {
                if (looksLikeSyncHeader(scan, k)) {
                    val head = scan.copyOfRange(k, k + 32)
                    val bytes = DtsNative.nativeSyncInfo(handle, head, info)
                    if (bytes > 0) {
                        frameOffset = k
                        detected = bytes
                        break
                    }
                }
                k++
            }
        } finally {
            DtsNative.nativeFree(handle)
        }
        if (frameOffset < 0) return false

        // 首帧不在 data 起点（个别抓轨前面有零头）：跳过零头，并把 dataStart 挪到帧边界上
        if (frameOffset > 0) {
            try {
                input.skipFully(frameOffset)
            } catch (t: Throwable) {
                return false
            }
            dataStart += frameOffset
        }

        frameBytes = detected
        sampleRate = if (info[0] > 0) info[0] else 44100
        samplesPerFrame = if (info[2] > 0) info[2] else 1024
        // 用「帧字节数 × 帧率」算真实字节率，比帧头里的标称位率更可靠
        bytesPerSecond = frameBytes.toLong() * sampleRate / samplesPerFrame

        timeUs = 0
        ended = false

        trackOutput?.format(
            Format.Builder()
                .setSampleMimeType(MimeTypes.AUDIO_DTS)
                .setSampleRate(sampleRate)
                .setMaxInputSize(frameBytes)
                .setAverageBitrate((bytesPerSecond * 8).coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
                .build()
        )
        extractorOutput?.seekMap(DtsSeekMap())
        return true
    }

    /** 在已 peek 到的数据里找 data chunk 的位置；找不到（或还没读够）返回 null */
    private fun findDataChunk(buf: ByteArray, limit: Int): Int? {
        if (limit < 20) return null
        if (!isRiffWave(buf)) return null
        var offset = 12
        while (offset + 8 <= limit) {
            val id = String(buf, offset, 4, Charsets.US_ASCII)
            if (id == "data") return offset
            val size = readU32LE(buf, offset + 4)
            val next = offset.toLong() + 8 + size + (size and 1L)
            if (next <= offset || next + 8 > limit) return null
            offset = next.toInt()
        }
        return null
    }

    /**
     * data 起点往后找第一帧。
     * 正常抓轨的 sync 就在 data 起点，但个别文件前面有几个字节零头，所以往后扫最多 [SCAN_WINDOW]。
     */
    private fun findFirstFrame(buf: ByteArray, dataOffset: Int, limit: Int): Boolean {
        val start = dataOffset + 8
        if (start + 32 > limit) return false
        val end = minOf(limit, start + SCAN_WINDOW)
        var k = start
        while (k + 32 <= end) {
            if (looksLikeSyncHeader(buf, k)) {
                return try {
                    DtsNative.nativeProbeFrameLength(buf.copyOfRange(k, k + 32)) > 0
                } catch (t: Throwable) {
                    CrashLog.record("探测 DTS 同步字", t)
                    false
                }
            }
            k++
        }
        return false
    }

    /** 从当前位置往后最多能看多少字节 */
    private fun scanWindow(input: ExtractorInput): Int {
        val total = input.length
        if (total <= 0) return SCAN_WINDOW
        val remain = total - input.position
        if (remain <= 0) return 0
        return remain.coerceAtMost(SCAN_WINDOW.toLong()).toInt()
    }

    /** libdca 认识的四种字节级同步模式（便宜的前置过滤，命中才调 native 校验） */
    private fun looksLikeSyncHeader(b: ByteArray, o: Int): Boolean {
        if (o < 0 || o + 6 > b.size) return false
        val b0 = b[o].toInt() and 0xFF
        val b1 = b[o + 1].toInt() and 0xFF
        val b2 = b[o + 2].toInt() and 0xFF
        val b3 = b[o + 3].toInt() and 0xFF
        // 14bit 小端（DTS-CD 抓轨最常见）
        if (b0 == 0xFF && b1 == 0x1F && b2 == 0x00 && b3 == 0xE8 &&
            (b[o + 4].toInt() and 0xF0) == 0xF0 && b[o + 5].toInt() == 0x07
        ) return true
        // 14bit 大端
        if (b0 == 0x1F && b1 == 0xFF && b2 == 0xE8 && b3 == 0x00 &&
            b[o + 4].toInt() == 0x07 && (b[o + 5].toInt() and 0xF0) == 0xF0
        ) return true
        // 16bit 小端 / 大端
        if (b0 == 0xFE && b1 == 0x7F && b2 == 0x01 && b3 == 0x80) return true
        if (b0 == 0x7F && b1 == 0xFE && b2 == 0x80 && b3 == 0x01) return true
        return false
    }

    private fun isRiffWave(buf: ByteArray): Boolean {
        if (buf.size < 12) return false
        return buf[0] == 'R'.code.toByte() && buf[1] == 'I'.code.toByte() &&
            buf[2] == 'F'.code.toByte() && buf[3] == 'F'.code.toByte() &&
            buf[8] == 'W'.code.toByte() && buf[9] == 'A'.code.toByte() &&
            buf[10] == 'V'.code.toByte() && buf[11] == 'E'.code.toByte()
    }

    private fun readU32LE(buf: ByteArray, offset: Int): Long =
        (buf[offset].toLong() and 0xFF) or
            ((buf[offset + 1].toLong() and 0xFF) shl 8) or
            ((buf[offset + 2].toLong() and 0xFF) shl 16) or
            ((buf[offset + 3].toLong() and 0xFF) shl 24)

    /**
     * 定长码流，按字节线性映射即可定位。
     * 对齐到帧边界，避免解码器吃到半帧。
     */
    private inner class DtsSeekMap : SeekMap {

        override fun isSeekable(): Boolean = dataEnd > dataStart && bytesPerSecond > 0

        override fun getDurationUs(): Long =
            if (isSeekable()) (dataEnd - dataStart) * 1_000_000L / bytesPerSecond
            else C.TIME_UNSET

        override fun getSeekPoints(timeUs: Long): SeekMap.SeekPoints {
            if (!isSeekable()) return SeekMap.SeekPoints(SeekPoint(0L, 0L))
            val raw = dataStart + timeUs.coerceAtLeast(0) * bytesPerSecond / 1_000_000L
            val clamped = raw.coerceIn(dataStart, dataEnd)
            val aligned = if (frameBytes > 0)
                dataStart + (clamped - dataStart) / frameBytes * frameBytes
            else clamped
            val position = aligned.coerceIn(dataStart, dataEnd)
            val actualUs = (position - dataStart) * 1_000_000L / bytesPerSecond
            return SeekMap.SeekPoints(SeekPoint(actualUs, position))
        }
    }

    private companion object {
        const val MAX_SCAN = 64 * 1024
        /** 找首帧时往后扫的最大字节数 */
        const val SCAN_WINDOW = 4096
    }
}
