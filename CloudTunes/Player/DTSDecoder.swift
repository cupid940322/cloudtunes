import Foundation

/// libdca（DTS Coherent Acoustics 解码器）的 Swift 封装。
///
/// iOS 系统没有 DTS 解码器，DTS-in-WAV（DTS-CD / 5.1 抓轨）直接当 PCM 播只有噪声。
/// 这里把 DTS 码流按帧解成 float PCM，交给 AVAudioEngine 播。
///
/// **14bit 打包不用自己拆**：libdca 的 bitstream 层已经做了
/// `(w & 0x3FFF) | ((w & 0x3FFF0000) >> 2)` 的还原，
/// `dca_syncinfo` 也认识 `ff 1f 00 e8` 这个 14bit 小端同步模式。
/// 所以原始字节直接喂进来就行，预先展开反而会破坏位流。
///
/// **不再让 libdca 做 5.1→2ch 折下**（见 `decode` 的注释）：0.0.7 的 downmix
/// 把中置/环绕按 0 dB 直接相加，折下后最多高出 9.5 dB，必然削顶，
/// 听感就是「音乐在，但上面糊了一层噪音」。现在按原始布局解出全部声道，
/// 折下交给 `DTSStreamPlayer.foldToStereo`，系数可按标准给。
final class DTSDecoder {
    /// 每个 block 每声道的样本数（libdca 固定 256：8 subsubframe × 32）
    static let samplesPerBlock = 256
    /// 交给 dca_syncinfo 的字节数。头字段加起来约 100 bit，
    /// 但 bitstream 是 4 字节 4 字节读的，给 32 字节留足余量。
    static let headerSize = 32

    /// 帧缓冲前后各留一段垫子：
    /// - 前 8 字节：`dca_bitstream_init` 会把指针向下对齐到 4 字节再读，
    ///   对齐失败时会回读前面的字节。
    /// - 后 32 字节：`bitstream_fill_current` 每次无条件读入一个 32bit 字，
    ///   帧尾那一次可能读过帧边界；越过边界读到的是堆里的垃圾位，
    ///   解出来正是一层高频「嘶嘶」噪声。
    /// Android 的 JNI 包装（dts_jni.c）用的是同样的垫子，两边行为保持一致。
    private static let padHead = 8
    private static let padTail = 32

    /// 下面两个常量来自 libdca 的 dca.h，照抄一份避免 C 宏导入差异
    /// dca.h 的 DCA_CHANNEL_MASK
    private static let channelMask = 0x3F
    /// dca.h 的 DCA_CHANNEL_MAX（0.0.7 只做到 DCA_3F2R = 9）
    private static let channelMax = 9
    /// tables.h 里的 dca_channels[]：output 值 → 声道数
    private static let channelCountTable = [1, 2, 2, 2, 2, 3, 3, 4, 4, 5, 6, 6, 6, 7, 8, 8]

    private var state: OpaquePointer?
    /// 帧头用的小缓冲（同样前面留垫子）
    private var scratch = [UInt8](repeating: 0, count: 64)
    /// 帧数据缓冲（带前后垫子），长度不够时再扩
    private var frameScratch = [UInt8](repeating: 0, count: 0)

    private(set) var sampleRate: Int = 44100
    private(set) var bitRate: Int = 0
    /// 源码流的声道布局（amode，0=单声道 2=立体声 9=5.1 等）
    private(set) var amode: Int = 2
    /// 解出来的**原始**声道数（按 amode 布局，5.1 源就是 5，不含 LFE）
    private(set) var outputChannels: Int = 2
    /// 一帧的**字节数**（切帧用）
    private(set) var frameLength: Int = 0
    /// 一帧的**样本数**（诊断用，正常等于 frameLength 换算出的时长）
    private(set) var samplesPerFrame: Int = 0

    init?() {
        guard let s = dca_init(0) else { return nil }
        state = s
    }

    deinit {
        if let state { dca_free(state) }
    }

    /// 解析帧头，返回整帧**字节数**（0 表示这段不是有效的 DTS 帧，需要往后挪再试）
    ///
    /// 注意别混淆两个数：`dca_syncinfo` 的返回值是帧的字节数（这个文件是 4096），
    /// 而出参 `frame_length` 是帧内**样本数**（= sample_blocks × 32 = 1024）。
    /// 之前把 1024 当字节数去切帧，等于每帧只喂进四分之一，于是「能听出旋律但全是杂音」。
    func syncInfo(_ header: [UInt8]) -> Int {
        guard let state, header.count >= Self.headerSize else { return 0 }
        for i in 0..<Self.headerSize { scratch[4 + i] = header[i] }
        var f: Int32 = 0
        var sampleRate: Int32 = 0
        var bitRate: Int32 = 0
        var samplesPerFrame: Int32 = 0
        let byteCount = scratch.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return 0 }
            return Int32(dca_syncinfo(state, base + 4, &f, &sampleRate, &bitRate, &samplesPerFrame))
        }
        guard byteCount > 0 else { return 0 }
        self.sampleRate = Int(sampleRate)
        self.bitRate = Int(bitRate)
        self.amode = Int(f) & Self.channelMask
        self.frameLength = Int(byteCount)          // 字节数，切帧用这个
        self.samplesPerFrame = Int(samplesPerFrame) // 样本数，只做校验/诊断
        return Int(byteCount)
    }

    /// 解一整帧，返回按声道分开的 float 样本（channel-major，每个声道 256×blocks 个）。
    ///
    /// 请求的是**源码流自己的布局**（`flags = amode`），libdca 就不会插手 downmix，
    /// 5.1 源直接给出 C/L/R/Ls/Rs 五个声道，折下由上层按标准系数做。
    func decode(frame: [UInt8]) -> [[Float]]? {
        guard let state, !frame.isEmpty else { return nil }

        // 拷进带垫子的缓冲：libdca 会无条件按 4 字节读，帧尾可能读过一个字
        let need = frame.count + Self.padHead + Self.padTail
        if frameScratch.count < need {
            frameScratch = [UInt8](repeating: 0, count: need)
        }
        frameScratch.withUnsafeMutableBufferPointer { dst -> Void in
            guard let base = dst.baseAddress else { return }
            frame.withUnsafeBufferPointer { src -> Void in
                guard let s = src.baseAddress else { return }
                (base + Self.padHead).update(from: s, count: frame.count)
            }
            // 垫子清零（正常不该被读到，读到也只是 0）
            for k in 0..<Self.padTail {
                base[Self.padHead + frame.count + k] = 0
            }
        }

        // amode 超出 0.0.7 支持范围（>9）就退回立体声，否则 dca_frame 会直接失败
        let wanted = (0...Self.channelMax).contains(amode) ? amode : 2
        var f = Int32(wanted)
        var level: Float = 1.0
        let bias: Float = 0

        let result = frameScratch.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            let buf = base + Self.padHead
            // 先过一次 syncinfo：`dca_frame` 用的是 state 里**上次解析留下的**
            // word_mode / bigendian_mode，这里保证和当前这一帧一致
            // （Android 的 JNI 也是这么做的，两边行为对齐）
            var hf: Int32 = 0, sr: Int32 = 0, br: Int32 = 0, fl: Int32 = 0
            guard dca_syncinfo(state, buf, &hf, &sr, &br, &fl) > 0 else { return -2 }
            return Int32(dca_frame(state, buf, &f, &level, bias))
        }
        // dca_frame 返回 1 表示失败（例如 amode 超出 downmix 表范围）
        guard result == 0 else { return nil }

        // 调用之后 f 被写回成真实的输出布局
        let idx = Int(f) & Self.channelMask
        let channels = Self.channelCountTable[min(max(idx, 0), Self.channelCountTable.count - 1)]
        guard channels >= 1 else { return nil }
        outputChannels = channels

        var planar = [[Float]](repeating: [], count: channels)
        let blocks = Int(dca_blocks_num(state))
        guard blocks > 0 else { return nil }

        for _ in 0..<blocks {
            guard dca_block(state) == 0 else { break }
            guard let raw = dca_samples(state) else { break }
            // libdca 每个 block 的输出是 channel-major：ch0 的 256 个样本，再 ch1 的 256 个……
            let total = Self.samplesPerBlock * channels
            let buf = UnsafeBufferPointer(start: raw, count: total)
            for ch in 0..<channels {
                let base = ch * Self.samplesPerBlock
                planar[ch].append(contentsOf: buf[base..<(base + Self.samplesPerBlock)])
            }
        }
        guard !planar[0].isEmpty else { return nil }
        return planar
    }
}
