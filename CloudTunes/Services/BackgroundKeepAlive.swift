import AVFoundation
import UIKit

/// 熄屏 / 切后台时保持 App 继续运行，供「扫描目录 + 刮削」这类长任务使用。
///
/// iOS 退到后台几十秒后就会挂起 App（网络请求全部暂停），这就是
/// 「熄屏后刮削停了」的原因。这里用两层手段续命：
/// 1. `beginBackgroundTask` —— 系统给的约 30 秒宽限期；
/// 2. 循环播放一段静音音频 —— 音频会话处于播放状态时系统不会挂起 App
///    （和正常听歌同等待遇）。
///
/// 用法：任务开头 `begin()`，用 `defer` 或任务结束时 `end()`。
/// 静音音频音量 0.01 × 静音数据 = 完全无声，但会让系统认为 App 在播音频。
@MainActor
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var silentPlayer: AVAudioPlayer?
    private var refCount = 0

    private init() {}

    func begin() {
        refCount += 1
        guard refCount == 1 else { return }
        start()
    }

    func end() {
        refCount = max(0, refCount - 1)
        guard refCount == 0 else { return }
        stop()
    }

    private func start() {
        // 静音循环播放（内存合成 WAV，无需打包资源文件）
        if silentPlayer == nil, let data = Self.silenceWAV(seconds: 4) {
            let p = try? AVAudioPlayer(data: data)
            p?.numberOfLoops = -1        // 无限循环
            p?.volume = 0.01             // 数据本身是静音，这层是双保险
            p?.prepareToPlay()
            p?.play()
            silentPlayer = p
        } else {
            // 已有别的音频在播（正常听歌），确保会话激活即可
            try? AVAudioSession.sharedInstance().setActive(true)
        }

        if bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "cloudtunes.background-work") {
                // 宽限期到期。静音音频仍会让系统保持 App 活跃，
                // 这里只做兜底标记，真正的清理统一放在 end()
            }
        }
    }

    private func stop() {
        silentPlayer?.stop()
        silentPlayer = nil
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    /// 现场合成一段静音 WAV（4 秒 8kHz 16bit 单声道，约 64KB）
    private static func silenceWAV(seconds: Double) -> Data? {
        let sampleRate = 8000
        let dataSize = Int(Double(sampleRate) * seconds) * 2
        var data = Data()

        func appendASCII(_ s: String) { data.append(s.data(using: .ascii)!) }
        func append32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }

        appendASCII("RIFF"); append32(UInt32(36 + dataSize)); appendASCII("WAVE")
        appendASCII("fmt "); append32(16)          // fmt 块长度
        append16(1)                                 // PCM
        append16(1)                                 // 单声道
        append32(UInt32(sampleRate))                // 采样率
        append32(UInt32(sampleRate * 2))            // 字节率 = 采样率 × 块对齐
        append16(2)                                 // 块对齐（16bit 单声道）
        append16(16)                                // 位深
        appendASCII("data"); append32(UInt32(dataSize))
        data.append(Data(count: dataSize))          // 全零采样 = 静音
        return data
    }
}
