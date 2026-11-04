import Foundation

/// 读本地音频文件的头，判断它到底是不是「标准 PCM」。
///
/// 这解决的问题是「wav 放出来是噪声」，噪声只可能来自三种情况：
/// 1. 容器不是 RIFF（文件根本不是 wav，只是后缀叫 wav）；
/// 2. fmt 块声明的编码不是 PCM（AC3 / MP3 / ADPCM / DTS …），iOS 没有对应解码器；
/// 3. 头里写的是 PCM，但数据区开头是 DTS / AC3 的同步字——即「DTS-in-WAV」，
///    这种文件任何只认 PCM 的播放器都会放出噪声，属于文件本身的问题；
/// 4. 是 PCM，但位深 / 声道 / 采样率是播放器没处理好的变体（24bit、32bit float、
///    WAVE_FORMAT_EXTENSIBLE），这属于播放通道选错了，可以修。
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
            guard disguised == nil else { return false }
            guard formatTag == 0x0001 || formatTag == 0x0003 else { return false }
            guard channels >= 1, channels <= 8 else { return false }
            guard sampleRate >= 8000, sampleRate <= 384_000 else { return false }
            return [8, 16, 24, 32].contains(bitsPerSample)
        }

        /// 给人看的短描述，例如「WAV · PCM 24bit 96kHz 2ch」
        var summary: String {
            if let disguised {
                return "\(container) · \(disguised)（头里写的是 \(codecName)，实际是 \(disguised) 码流）"
            }
            let khz = sampleRate > 0 ? String(format: "%.1fk", Double(sampleRate) / 1000) : "?"
            let bit = bitsPerSample > 0 ? "\(bitsPerSample)bit" : "?"
            return "\(container) · \(codecName) \(bit) \(khz)Hz \(channels)ch"
        }
    }

    static func probe(_ url: URL) -> Info? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16 * 1024), head.count >= 12 else { return nil }

        let magic = ascii(head, 0, 4)
        if magic == "RIFF" || magic == "RF64" {
            guard ascii(head, 8, 4) == "WAVE" else {
                return Info(container: magic, formatTag: 0, channels: 0, sampleRate: 0, bitsPerSample: 0)
            }
            return parseWAVE(head, handle: handle, container: "WAV")
        }
        if magic == "FORM" {
            let type = ascii(head, 8, 4)
            if type.hasPrefix("AIF") {
                return parseAIFF(head, container: type)
            }
        }
        return Info(container: magic.isEmpty ? "未知" : magic, formatTag: 0,
                    channels: 0, sampleRate: 0, bitsPerSample: 0)
    }

    // MARK: - WAVE

    private static func parseWAVE(_ head: Data, handle: FileHandle, container: String) -> Info {
        var info = Info(container: container)
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

            guard size >= 0 else { break }
            offset = payload + size + (size % 2)   // chunk 按偶数字节对齐
        }

        // 头写 PCM、数据却是 DTS/AC3 码流：这种「假 wav」播出来必然是白噪声
        if info.dataOffset > 0 {
            var prefix = Data()
            if info.dataOffset + 8 <= head.count {
                prefix = head.subdata(in: info.dataOffset..<min(info.dataOffset + 8, head.count))
            } else if (try? handle.seek(toOffset: UInt64(info.dataOffset))) != nil {
                prefix = (try? handle.read(upToCount: 8)) ?? Data()
            }
            if prefix.count >= 4 {
                let b = [UInt8](prefix.prefix(4))
                if b[0] == 0x7F, b[1] == 0xFE, b[2] == 0x80, b[3] == 0x01 {
                    info.disguised = "DTS"
                } else if b[0] == 0x0B, b[1] == 0x77 {
                    info.disguised = "AC3"
                }
            }
        }
        return info
    }

    // MARK: - AIFF

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
                // 80 位扩展浮点采样率，这里只取指数与最高位尾数，精度够用
                info.sampleRate = extendedSampleRate(head, payload + 8)
                break
            }
            guard size >= 0 else { break }
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

    // MARK: - 噪声判定

    /// 数据段看起来是白噪声吗？
    ///
    /// 判断依据（只看前 1.5 秒，代价很小）：16bit PCM 正常音乐相邻采样的相关性
    /// 一般在 0.9 以上、过零率远低于 0.5；而「头对但数据是随机数」的文件
    /// （损坏、加密、下载乱序）相关性接近 0、过零率接近 0.5，各频点能量也均匀。
    /// 这种情况任何播放器都只能放出噪声，与解码器无关。
    static func looksLikeNoise(_ url: URL, info: Info) -> Bool {
        guard info.bitsPerSample == 16,
              info.channels >= 1, info.channels <= 2,
              info.dataOffset > 0 else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(info.dataOffset))) != nil,
              let block = try? handle.read(upToCount: 96 * 1024),
              block.count >= 16 * 1024 else { return false }

        var samples = [Double]()
        samples.reserveCapacity(block.count / 2)
        var i = 0
        while i + 1 < block.count {
            let lo = UInt16(block[block.startIndex + i])
            let hi = UInt16(block[block.startIndex + i + 1])
            samples.append(Double(Int16(bitPattern: lo | (hi << 8))))
            i += 2
        }
        guard samples.count > 4096 else { return false }

        var mean = 0.0
        for v in samples { mean += v }
        mean /= Double(samples.count)

        var num = 0.0, d1 = 0.0, d2 = 0.0, power = 0.0, zeroCross = 0
        for idx in samples.indices {
            let x = samples[idx] - mean
            power += x * x
            if idx > 0 {
                let y = samples[idx - 1] - mean
                num += x * y
                d1 += y * y
                d2 += x * x
                if (samples[idx - 1] < 0) != (samples[idx] < 0) { zeroCross += 1 }
            }
        }
        let corr = (d1 > 0 && d2 > 0) ? num / (d1 * d2).squareRoot() : 0
        let zcr = Double(zeroCross) / Double(samples.count)
        let rms = (power / Double(samples.count)).squareRoot()

        return rms > 300 && corr < 0.12 && zcr > 0.40
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
