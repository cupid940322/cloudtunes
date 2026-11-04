import Foundation

/// 读音频文件的头 + 数据特征，判断「这个文件到底是什么」。
///
/// 起因是「wav 放出来是噪声」：噪声只可能来自几种情况：
/// 1. 容器不是 RIFF（文件根本不是 wav，只是后缀叫 wav）；
/// 2. fmt 块声明的编码不是 PCM（AC3 / MP3 / ADPCM …），iOS 没有对应解码器；
/// 3. 头里写的是 PCM，但数据区是 DTS 码流（DTS-CD / 5.1 资源抓轨的标准形态）。
///    DTS 有两种打包：16bit 直排、以及 14bit 打包（每个样本只带 14 位有效数据，
///    同步字被拆进位流，字节级搜索永远找不到）。iOS 没有 DTS 解码器，只能出噪声；
/// 4. 是 PCM，但位深 / 声道 / 采样率是播放器没处理好的变体。
enum AudioProbe {
    struct Info {
        var container: String = "未知"
        var formatTag: UInt16 = 0
        var channels: Int = 0
        var sampleRate: Int = 0
        var bitsPerSample: Int = 0
        var dataOffset: Int = -1
        var dataBytes: Int = 0
        /// 头写 PCM、数据其实是压缩码流时，这里给出 "DTS" / "AC3"
        var disguised: String?
        /// DTS 打包方式
        var dts: DTSVariant = .none

        var codecName: String {
            switch formatTag {
            case 0x0001: return "PCM"
            case 0x0003: return "浮点 PCM"
            case 0x0002: return "MS ADPCM"
            case 0x0011: return "IMA ADPCM"
            case 0x0055: return "MP3"
            case 0x2000: return "AC3"
            case 0xF1AC: return "FLAC"
            case 0x0161: return "WMA"
            case 0x0006: return "A-law"
            case 0x0007: return "μ-law"
            case 0: return "未知"
            default: return String(format: "0x%04X", formatTag)
            }
        }

        /// 能不能用 PCM 通道播（AVAudioPlayer / AudioQueue 走的就是这条路）
        var isPlayablePCM: Bool {
            guard disguised == nil, dts == .none else { return false }
            guard formatTag == 0x0001 || formatTag == 0x0003 else { return false }
            guard channels >= 1, channels <= 8 else { return false }
            guard sampleRate >= 8000, sampleRate <= 384_000 else { return false }
            return [8, 16, 24, 32].contains(bitsPerSample)
        }

        /// 给人看的短描述，例如「WAV · PCM 24bit 96kHz 2ch」
        var summary: String {
            if dts != .none { return "\(container) · DTS 音轨（\(dts.label)）" }
            if let disguised {
                return "\(container) · \(disguised)（头里写的是 \(codecName)，实际是 \(disguised) 码流）"
            }
            let khz = sampleRate > 0 ? String(format: "%.1fk", Double(sampleRate) / 1000) : "?"
            let bit = bitsPerSample > 0 ? "\(bitsPerSample)bit" : "?"
            return "\(container) · \(codecName) \(bit) \(khz)Hz \(channels)ch"
        }
    }

    enum DTSVariant: Equatable {
        case none
        /// 16bit 直排，字节流里能直接找到 7F FE 80 01
        case dts16
        /// 14bit 打包（DTS-CD 常见），同步字在 14bit 位流里
        case dts14

        var label: String {
            switch self {
            case .none: return ""
            case .dts16: return "16bit"
            case .dts14: return "14bit 打包"
            }
        }
    }

    // MARK: - 解析

    /// 从文件头部字节解析（本地文件和远程前缀都走这一套）
    static func parse(_ data: Data) -> Info? {
        guard data.count >= 12 else { return nil }
        let magic = ascii(data, 0, 4)
        if magic == "RIFF" || magic == "RF64" {
            guard ascii(data, 8, 4) == "WAVE" else {
                return Info(container: magic)
            }
            return parseWAVE(data)
        }
        if magic == "FORM" {
            let type = ascii(data, 8, 4)
            if type.hasPrefix("AIF") { return parseAIFF(data, container: type) }
        }
        return Info(container: magic.isEmpty ? "未知" : magic)
    }

    static func probe(_ url: URL) -> Info? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 128 * 1024) else { return nil }
        guard var info = parse(head) else { return nil }
        // 本地文件可以顺便确认 DTS
        if info.dataOffset > 0, info.dataOffset < head.count {
            let payload = head.subdata(in: info.dataOffset..<head.count)
            info.dts = detectDTS(in: payload, bitsPerSample: info.bitsPerSample)
        }
        return info
    }

    /// 取远程文件的前缀（128KB）用来探测，不落盘、不用等整个文件
    static func probeRemote(url: URL, headers: [String: String], maxBytes: Int = 128 * 1024) async -> (Data, Info?)? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        do {
            let (bytes, _) = try await session.bytes(for: req)
            var data = Data()
            data.reserveCapacity(maxBytes)
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maxBytes { break }
            }
            guard data.count >= 12 else { return nil }
            var info = parse(data)
            if let i = info, i.dataOffset > 0, i.dataOffset < data.count {
                let payload = data.subdata(in: i.dataOffset..<data.count)
                info?.dts = detectDTS(in: payload, bitsPerSample: i.bitsPerSample)
            }
            return (data, info)
        } catch {
            return nil
        }
    }

    // MARK: - WAVE / AIFF

    private static func parseWAVE(_ head: Data) -> Info {
        var info = Info(container: "WAV")
        var offset = 12
        while offset + 8 <= head.count {
            let id = ascii(head, offset, 4)
            let size = Int(u32(head, offset + 4))
            let payload = offset + 8

            if id == "fmt " || id == "fmt" {
                var tag = u16(head, payload)
                info.channels = Int(u16(head, payload + 2))
                info.sampleRate = Int(u32(head, payload + 4))
                info.bitsPerSample = Int(u16(head, payload + 14))
                // WAVE_FORMAT_EXTENSIBLE：真正的编码在 SubFormat GUID 的头两个字节
                if tag == 0xFFFE, payload + 26 <= head.count {
                    tag = u16(head, payload + 24)
                }
                info.formatTag = tag
            } else if id == "data" {
                info.dataOffset = payload
                info.dataBytes = size
                break
            }

            guard size > 0 else { break }
            offset = payload + size + (size % 2)   // chunk 按偶数字节对齐
        }

        // 头写 PCM、数据却是 AC3 码流
        if info.dataOffset > 0, info.dataOffset + 2 <= head.count,
           u16(head, info.dataOffset) == 0x770B {
            info.disguised = "AC3"
        }
        return info
    }

    private static func parseAIFF(_ head: Data, container: String) -> Info {
        var info = Info(container: container.isEmpty ? "AIFF" : container)
        info.formatTag = 0x0001
        var offset = 12
        while offset + 8 <= head.count {
            let id = ascii(head, offset, 4)
            let size = Int(u32(head, offset + 4))
            let payload = offset + 8
            if id == "COMM", payload + 18 <= head.count {
                info.channels = Int(u16(head, payload))
                info.bitsPerSample = Int(u16(head, payload + 6))
                info.sampleRate = extendedSampleRate(head, payload + 8)
                break
            }
            guard size > 0 else { break }
            offset = payload + size + (size % 2)
        }
        return info
    }

    private static func extendedSampleRate(_ d: Data, _ o: Int) -> Int {
        guard o + 10 <= d.count else { return 0 }
        let exponent = Int(u16(d, o)) & 0x7FFF
        let mantissa = u64(d, o + 2)
        guard exponent > 16383, mantissa > 0 else { return 0 }
        let value = Double(mantissa) * pow(2.0, Double(exponent - 16383 - 63))
        return Int(value.rounded())
    }

    // MARK: - DTS 检测

    /// 在 data 区字节里找 DTS 同步字。
    ///
    /// 优先按 libdca 认识的四种字节级同步模式判（快、且和真正的解码器一致）：
    /// - `ff 1f 00 e8` + 后续校验 = 14bit 小端（DTS-CD 抓轨最常见）
    /// - `1f ff e8 00` = 14bit 大端
    /// - `fe 7f 01 80` = 16bit 小端
    /// - `7f fe 80 01` = 16bit 大端
    ///
    /// 都没有时再退回「取每个 16bit 词低 14 位拼位流搜 0x7FFE8001」的暴力扫描，
    /// 兜住那些帧头不在数据最前面、偏移了一点的文件。
    static func detectDTS(in payload: Data, bitsPerSample: Int) -> DTSVariant {
        let bytes = [UInt8](payload.prefix(256 * 1024))
        var i = 0
        while i + 6 <= bytes.count {
            let b0 = bytes[i], b1 = bytes[i + 1], b2 = bytes[i + 2], b3 = bytes[i + 3]
            if b0 == 0xFF, b1 == 0x1F, b2 == 0x00, b3 == 0xE8,
               bytes[i + 4] & 0xF0 == 0xF0, bytes[i + 5] == 0x07 {
                return .dts14
            }
            if b0 == 0x1F, b1 == 0xFF, b2 == 0xE8, b3 == 0x00,
               bytes[i + 4] == 0x07, bytes[i + 5] & 0xF0 == 0xF0 {
                return .dts14
            }
            if b0 == 0xFE, b1 == 0x7F, b2 == 0x01, b3 == 0x80 {
                return .dts16
            }
            if b0 == 0x7F, b1 == 0xFE, b2 == 0x80, b3 == 0x01 {
                return .dts16
            }
            i += 1
        }

        // 兜底：14bit 打包时同步字被拆在位流里，字节级搜不到
        guard bitsPerSample == 16 else { return .none }
        var acc: UInt32 = 0
        var bitCount = 0
        var j = 0
        while j + 1 < bytes.count {
            let word = Int(bytes[j]) | (Int(bytes[j + 1]) << 8)
            let low = UInt32(word & 0x3FFF)
            for shift in stride(from: 13, through: 0, by: -1) {
                acc = (acc << 1) | ((low >> UInt32(shift)) & 1)
                bitCount += 1
                if bitCount >= 32, acc == 0x7FFE_8001 { return .dts14 }
            }
            j += 2
        }
        return .none
    }

    // MARK: - 字节读取（小端）

    private static func ascii(_ d: Data, _ o: Int, _ n: Int) -> String {
        guard o >= 0, o + n <= d.count else { return "" }
        return String(data: d.subdata(in: o..<(o + n)), encoding: .ascii) ?? ""
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 {
        guard o >= 0, o + 2 <= d.count else { return 0 }
        let b = [UInt8](d.subdata(in: o..<(o + 2)))
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= d.count else { return 0 }
        let b = [UInt8](d.subdata(in: o..<(o + 4)))
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    private static func u64(_ d: Data, _ o: Int) -> UInt64 {
        let hi = UInt64(u32(d, o)) << 32
        return hi | UInt64(u32(d, o + 4))
    }
}
