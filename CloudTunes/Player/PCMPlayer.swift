import AVFoundation

/// 无压缩 PCM（WAV / AIFF / CAF）专用的本地播放通道。
///
/// 为什么不用 AVPlayer：AVPlayer 播 PCM 时走的是 AudioFileStream / 解码器那条路，
/// 24bit 打包、32bit 浮点、WAVE_FORMAT_EXTENSIBLE 这些常见变体它不一定按 fmt 块解释，
/// 结果是「能播、有声音、全是噪声」。AVAudioPlayer 底下是 AudioFile + AudioQueue，
/// 所有 PCM 变体都由 CoreAudio 统一转成设备格式，输出一定是对的。
///
/// 代价是整个文件进内存（一首 24bit/96k 的 wav 大概几十 MB），换取稳定。
final class PCMPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// 0.25 秒一次，回调当前秒数（主线程）
    var onTick: ((TimeInterval) -> Void)?
    var onFinish: (() -> Void)?
    var onError: ((String) -> Void)?

    private(set) var duration: TimeInterval = 0

    var isPlaying: Bool { player?.isPlaying ?? false }

    var currentTime: TimeInterval {
        get { player?.currentTime ?? 0 }
        set {
            guard let player else { return }
            player.currentTime = max(0, min(newValue, max(0, duration - 0.05)))
        }
    }

    /// 载入文件，返回时长；失败抛出（例如多声道布局设备不支持）
    @discardableResult
    func load(url: URL, startAt: TimeInterval = 0) throws -> TimeInterval {
        stop()
        let p = try AVAudioPlayer(contentsOf: url)
        p.delegate = self
        p.numberOfLoops = 0
        p.prepareToPlay()
        player = p
        duration = p.duration
        if startAt > 0.5 {
            p.currentTime = max(0, min(startAt, max(0, p.duration - 0.3)))
        }
        return p.duration
    }

    func play() {
        guard let player else { return }
        // AVPlayer 会自己激活会话，AVAudioPlayer 不会，不激活会「点了没声」
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        startTimer()
    }

    func pause() {
        player?.pause()
        stopTimer()
    }

    func stop() {
        stopTimer()
        player?.stop()
        player = nil
        duration = 0
    }

    // MARK: - 进度

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            self.onTick?(p.currentTime)
        }
        // .common 模式：拖动界面时进度也不会停
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopTimer()
        onFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        stopTimer()
        onError?(error?.localizedDescription ?? "解码中断")
    }
}
