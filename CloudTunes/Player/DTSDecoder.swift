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
/// 输出布局由 libdca 的 downmix 决定：我们请求立体声（`DCA_STEREO`），
/// 5.1 源会被混成 2 声道；但单声道源（amode=0）请求立体声时仍只返回 1 声道，
/// 所以每帧都要读回 `flags` 里的实际输出声道数，不能写死 2。
final class DTSDecoder {
    /// 每个 block 每声道的样本数（libdca 固定 256：8 subsubframe × 32）
    static let samplesPerBlock = 256
    /// 交给 dca_syncinfo 的字节数。头字段加起来约 100 bit，
    /// 但 bitstream 是 4 字节 4 字节读的，给 32 字节留足余量。
    static let headerSize = 32

    /// 下面三个常量来自 libdca 的 dca.h，照抄一份避免 C 宏导入差异
    private static let dcaStereoFlag: Int32 = 2          // DCA_STEREO
    private static let dcaAdjustLevelFlag: Int32 = 0x100 // DCA_ADJUST_LEVEL
    /// dca.h 的 DCA_CHANNEL_MASK
    private static let channelMask = 0x3F
    /// tables.h 里的 dca_channels[]：output 值 → 声道数
    private static let channelCountTable = [1, 2, 2, 2, 2, 3, 3, 4, 4, 5, 6, 6, 6, 7, 8, 8]

    private var state: OpaquePointer?
    /// dca_bitstream_init 会把自己的指针对齐到 4 字节后往前退，可能读 buf 前面的字节。
    /// 用它当「安全垫」：真正的头从 scratch[4] 开始，前面 4 字节随便读。
    private var scratch = [UInt8](repeating: 0, count: 64)

    private(set) var sampleRate: Int = 44100
    private(set) var bitRate: Int = 0
    /// 最近一帧的实际输出声道数（1 或 2；>2 说明 downmix 没生效）
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
        self.frameLength = Int(byteCount)          // 字节数，切帧用这个
        self.samplesPerFrame = Int(samplesPerFrame) // 样本数，只做校验/诊断
        return Int(byteCount)
    }

    /// 解一整帧，返回按声道分开的 float 样本（channel-major，每个声道 256×blocks 个）
    func decode(frame: [UInt8]) -> [[Float]]? {
        guard let state, !frame.isEmpty else { return nil }
        var data = frame
        // 请求立体声输出；ADJUST_LEVEL 让 5.1→2ch 的 downmix 不至于削顶
        var f = Self.dcaStereoFlag | Self.dcaAdjustLevelFlag
        var level: Float = 1.0
        let bias: Float = 0

        let result = data.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            var lvl = level
            let r = dca_frame(state, base, &f, &lvl, bias)
            level = lvl
            return Int32(r)
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
