import AVFoundation
import Foundation

/// DTS 流式播放器：边下边解边播，**完全不落盘**。
///
/// - URLSession data task 收字节（带 Range，拖动时直接从目标字节位置续传）
/// - 后台队列按 DTS 帧切分 → libdca 解码 → float PCM
/// - AVAudioEngine / AVAudioPlayerNode 按 buffer 调度播放
/// - 解码领先播放超过 6 秒就 suspend 下载任务，内存里不会堆整首歌
///
/// 线程约定：
/// - `buf / head / decoder / frameLength / streamEnded` 只在 decodeQueue 上碰
/// - `engine / node / isPlaying / inputEnded / duration` 只在主线程碰
/// - `scheduledSamples / playedSamples / requestedOffset` 用锁保护
final class DTSStreamPlayer: NSObject {
    // MARK: 回调（主线程）

    var onTime: ((TimeInterval) -> Void)?
    var onDuration: ((TimeInterval) -> Void)?
    var onReady: (() -> Void)?
    var onFinish: (() -> Void)?
    var onError: ((String) -> Void)?

    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0

    // MARK: 引擎（主线程）

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var engineReady = false
    private var inputEnded = false
    private var finished = false

    // MARK: 解码（decodeQueue）

    private let decodeQueue = DispatchQueue(label: "cloudtunes.dts.decode", qos: .userInitiated)
    private var decoder: DTSDecoder?
    /// 待解码字节。用「数组 + 游标」而不是 Data.removeFirst，
    /// 否则每丢一个字节都要搬一次剩余内存，44MB 的文件直接卡死。
    private var buf: [UInt8] = []
    private var head = 0
    /// 14bit 打包的码流（DTS-CD 抓轨）。只用于算「每秒字节数」，
    /// 拆位由 libdca 自己做，这里不做任何预处理。
    private var fourteenBit = false
    private var frameLength = 0
    private var accumulatorLeft: [Float] = []
    private var accumulatorRight: [Float] = []
    private var skipRemaining = 0
    private var decodeFailed = false
    private var streamEnded = false
    private var retryScheduled = false
    private var infoCaptured = false

    // MARK: 网络

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private var task: URLSessionDataTask?
    private var suspendedTask: URLSessionDataTask?
    private var streamURL: URL?
    private var streamHeaders: [String: String] = [:]
    private var dataOffset = 0
    private var dataBytes = 0
    private var seekBase: TimeInterval = 0
    /// 从码流里学到的「每秒字节数」，**跨 seek 保留**：拖动时还没解析到帧头，
    /// 全靠它把「秒」换算成字节偏移，否则每次拖动都从文件头重新下。
    private var knownByteRate = 0

    // MARK: 计数（锁）

    private let counterLock = NSLock()
    private var scheduledSamples = 0
    private var playedSamples = 0
    private var requestedOffset = 0

    private var progressTimer: Timer?

    // MARK: - 控制

    func start(url: URL,
               headers: [String: String],
               dataOffset: Int,
               dataBytes: Int,
               startAt: TimeInterval = 0,
               fourteenBit: Bool) {
        stop()

        streamURL = url
        streamHeaders = headers
        self.dataOffset = max(0, dataOffset)
        self.dataBytes = max(0, dataBytes)
        seekBase = max(0, startAt)
        currentTime = seekBase
        isPlaying = true

        let target = byteOffset(for: seekBase)
        counterLock.lock(); requestedOffset = target; counterLock.unlock()

        decodeQueue.async { [weak self] in
            guard let self else { return }
            if let d = DTSDecoder() {
                self.decoder = d
            } else {
                self.decodeFailed = true
                DispatchQueue.main.async { [weak self] in
                    self?.onError?("DTS 解码器初始化失败")
                }
            }
            self.buf = []
            self.head = 0
            self.fourteenBit = fourteenBit
            self.frameLength = 0
            self.accumulatorLeft = []
            self.accumulatorRight = []
            self.skipRemaining = 0
            self.streamEnded = false
            self.retryScheduled = false
            self.infoCaptured = false
        }

        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if target > 0 { req.setValue("bytes=\(target)-", forHTTPHeaderField: "Range") }
        let t = session.dataTask(with: req)
        task = t
        t.resume()

        startProgressTimer()
    }

    func pause() {
        isPlaying = false
        node.pause()
        stopProgressTimer()
    }

    func resume() {
        guard engineReady else { return }
        isPlaying = true
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try? engine.start() }
        node.play()
        startProgressTimer()
    }

    func seek(to seconds: TimeInterval) {
        guard let url = streamURL else { return }
        start(url: url,
              headers: streamHeaders,
              dataOffset: dataOffset,
              dataBytes: dataBytes,
              startAt: seconds,
              fourteenBit: fourteenBit)
    }

    func stop() {
        stopProgressTimer()
        task?.cancel()
        task = nil
        if let s = suspendedTask, s.state == .suspended { s.resume() }
        suspendedTask?.cancel()
        suspendedTask = nil
        node.stop()
        inputEnded = false
        finished = false
        isPlaying = false
        duration = 0
        counterLock.lock()
        scheduledSamples = 0
        playedSamples = 0
        requestedOffset = 0
        counterLock.unlock()
        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.decoder = nil
            self.buf = []
            self.head = 0
            self.accumulatorLeft = []
            self.accumulatorRight = []
            self.frameLength = 0
            self.streamEnded = false
            self.decodeFailed = false
        }
    }

    // MARK: - 字节偏移

    private func byteOffset(for seconds: TimeInterval) -> Int {
        guard seconds > 0.5, knownByteRate > 0 else { return dataOffset }
        let bytes = Int(seconds * Double(knownByteRate))
        let maxBytes = max(0, dataBytes - 16 * 1024)
        return dataOffset + min(max(0, bytes), maxBytes)
    }

    // MARK: - 缓冲

    private var remain: Int { buf.count - head }

    private func appendBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        buf.append(contentsOf: bytes)
        compact()
    }

    private func dropBytes(_ n: Int) {
        head = min(buf.count, head + n)
        compact()
    }

    /// 游标推进到一定程度后把前半段丢掉，避免 buf 无限增长
    private func compact() {
        if head == buf.count {
            buf.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 512 * 1024 {
            buf.removeFirst(head)
            head = 0
        }
    }

    // MARK: - 解码（decodeQueue）

    private func ingest(_ chunk: Data) {
        guard !decodeFailed else { return }
        appendBytes([UInt8](chunk))
        pump()
    }

    /// 在已缓冲的字节里找一个合法的 DTS 帧头，找到就把游标挪过去。
    /// 只扫前 4096 个偏移——正常情况下帧边界离当前位置不超过几十字节。
    private func syncAtHead(_ decoder: DTSDecoder) -> Bool {
        let scanMax = min(remain - DTSDecoder.headerSize, 4096)
        guard scanMax >= 0 else { return false }
        for off in 0...scanMax {
            let start = head + off
            let header = Array(buf[start..<(start + DTSDecoder.headerSize)])
            if decoder.syncInfo(header) > 0 {
                dropBytes(off)
                return true
            }
        }
        return false
    }

    private func pump() {
        guard let decoder, !decodeFailed else { return }

        decodeLoop: while true {
            // 1) 没帧头就先对帧头（每解完一帧都重新对一次，帧长偶尔会变）
            if frameLength == 0 {
                if remain >= DTSDecoder.headerSize, syncAtHead(decoder) {
                    frameLength = decoder.frameLength
                    captureInfo(decoder)
                } else if remain > 8192 {
                    // 这段确实没有 DTS 帧，跳过一截继续找
                    dropBytes(4096)
                    continue decodeLoop
                } else {
                    break decodeLoop      // 数据不够，等下一批
                }
            }

            guard frameLength > 0 else { break decodeLoop }

            // 2) 背压：解码领先太多就先攒着，等播放追上来
            let goal = Int(Double(decoder.sampleRate) * 6.0)
            if aheadSamples() > goal {
                scheduleDeferredPump()
                return
            }

            // 3) 手上不够一整帧 → 等数据
            guard remain >= frameLength else { break decodeLoop }

            let frame = Array(buf[head..<(head + frameLength)])
            dropBytes(frameLength)
            frameLength = 0
            if let planar = decoder.decode(frame: frame) {
                accumulate(planar: planar, decoder: decoder)
            }
        }

        checkDrained()
    }

    /// 帧头里只有码率 / 采样率，取一次就够。
    ///
    /// 字节↔时间换算要分两种形态：
    /// - 14bit 打包：每个样本占 1 个 16bit 词 → 每秒字节数 = 采样率 × 声道数 × 2
    ///   （DTS-CD 的 header 里 bit_rate 填的是有效码率，比实际占用的字节少，直接用会 seek 偏前）
    /// - 16bit 直排：每秒字节数 = bit_rate / 8
    private func captureInfo(_ decoder: DTSDecoder) {
        guard !infoCaptured else { return }
        let byteRate: Int
        if fourteenBit {
            byteRate = decoder.sampleRate * 2 * 2
        } else {
            byteRate = decoder.bitRate > 0 ? decoder.bitRate / 8 : 0
        }
        guard byteRate > 0 else { return }
        infoCaptured = true
        if knownByteRate == 0 { knownByteRate = byteRate }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dataBytes > 0, self.duration == 0 else { return }
            let seconds = Double(self.dataBytes) / Double(byteRate)
            self.duration = seconds
            self.onDuration?(seconds)
        }
    }

    /// 数据流结束：pump 已经把能解的帧全解完了，直接收尾
    private func checkDrained() {
        guard streamEnded, !decodeFailed else { return }
        dispatchToMain { [weak self] in self?.finishWhenDrained() }
    }

    private func scheduleDeferredPump() {
        guard !retryScheduled else { return }
        retryScheduled = true
        decodeQueue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.pump()
        }
    }

    private func accumulate(planar: [[Float]], decoder: DTSDecoder) {
        // 单声道源（amode=0）downmix 之后仍只有 1 个声道，复制一份当立体声
        let right = planar.count > 1 ? planar[1] : planar[0]
        accumulatorLeft.append(contentsOf: planar[0])
        accumulatorRight.append(contentsOf: right)

        let sampleRate = Double(decoder.sampleRate)
        let chunkFrames = max(1024, Int(sampleRate / 20))   // ≈50ms 一块
        while accumulatorLeft.count >= chunkFrames {
            let l = Array(accumulatorLeft.prefix(chunkFrames))
            let r = Array(accumulatorRight.prefix(chunkFrames))
            accumulatorLeft.removeFirst(chunkFrames)
            accumulatorRight.removeFirst(chunkFrames)
            dispatchToMain { [weak self] in
                self?.enqueue(left: l, right: r, sampleRate: sampleRate)
            }
        }
    }

    private func dispatchToMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - 调度（主线程）

    private func enqueue(left: [Float], right: [Float], sampleRate: Double) {
        guard let fmt = ensureEngine(sampleRate: sampleRate),
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(left.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(left.count)
        if let ch = buffer.floatChannelData {
            left.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: left.count) }
            right.withUnsafeBufferPointer { ch[1].update(from: $0.baseAddress!, count: right.count) }
        }
        if !engine.isRunning { try? engine.start() }
        if !node.isPlaying, isPlaying { node.play() }
        node.scheduleBuffer(buffer, completionHandler: nil)

        counterLock.lock()
        scheduledSamples += left.count
        let ahead = scheduledSamples - playedSamples
        counterLock.unlock()

        // 领先过多 → 暂停下载；追上来 → 恢复
        if ahead > Int(sampleRate * 8), let t = task, t.state == .running {
            t.suspend()
            suspendedTask = t
        } else if ahead < Int(sampleRate * 3), let t = suspendedTask, t.state == .suspended {
            t.resume()
            suspendedTask = nil
        }
        onReady?()
    }

    private func ensureEngine(sampleRate: Double) -> AVAudioFormat? {
        if let format { return format }
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: sampleRate,
                                      channels: 2,
                                      interleaved: false) else { return nil }
        format = fmt
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try engine.start()
        } catch {
            onError?("音频引擎启动失败：\(error.localizedDescription)")
            return nil
        }
        engineReady = true
        if isPlaying { node.play() }
        return fmt
    }

    // MARK: - 进度

    private func aheadSamples() -> Int {
        counterLock.lock(); defer { counterLock.unlock() }
        return scheduledSamples - playedSamples
    }

    private func startProgressTimer() {
        stopProgressTimer()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        progressTimer = t
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func tick() {
        guard engineReady, let fmt = format else { return }
        var played = 0
        if let renderTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: renderTime) {
            played = Int(playerTime.sampleTime)
        }
        counterLock.lock()
        playedSamples = played
        let scheduled = scheduledSamples
        counterLock.unlock()

        let seconds = seekBase + Double(played) / fmt.sampleRate
        currentTime = seconds
        onTime?(seconds)

        if inputEnded, !finished, scheduled > 0, played >= scheduled - 4096 {
            finished = true
            isPlaying = false
            stopProgressTimer()
            onFinish?()
        }
    }

    /// 数据流结束（主线程）：等排队的 buffer 播完再收尾
    private func finishWhenDrained() {
        guard !inputEnded else { return }
        inputEnded = true
        counterLock.lock()
        let scheduled = scheduledSamples
        counterLock.unlock()
        // 一个 buffer 都没排上（例如全是坏帧）→ 直接报错，别让 UI 干等
        if scheduled == 0 {
            isPlaying = false
            stopProgressTimer()
            onError?("这个 DTS 文件没有可解码的音频帧")
        }
    }
}

// MARK: - URLSessionDataDelegate

extension DTSStreamPlayer: URLSessionDataDelegate {
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        counterLock.lock()
        let offset = requestedOffset
        counterLock.unlock()
        // 服务器不支持 Range，会把整个文件从头发过来 → 自己跳过前面的字节
        if offset > 0, status != 206 {
            decodeQueue.async { [weak self] in
                guard let self else { return }
                self.skipRemaining = offset
                DispatchQueue.main.async { [weak self] in self?.seekBase = 0 }
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        decodeQueue.async { [weak self] in
            guard let self, !self.decodeFailed else { return }
            // 拖动 / 切歌后旧请求可能还有尾巴在路上，别把它的字节混进新流
            guard dataTask === self.task else { return }
            var chunk = data
            if self.skipRemaining > 0 {
                if chunk.count <= self.skipRemaining {
                    self.skipRemaining -= chunk.count
                    return
                }
                chunk = chunk.dropFirst(self.skipRemaining)
                self.skipRemaining = 0
            }
            self.ingest(chunk)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            decodeQueue.async { [weak self] in
                guard let self, task === self.task else { return }
                self.decodeFailed = true
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, task === self.task else { return }
                self.onError?("DTS 数据流中断：\(error.localizedDescription)")
            }
            return
        }
        decodeQueue.async { [weak self] in
            guard let self, task === self.task else { return }
            self.streamEnded = true
            // 把残留的完整帧全部解完（背压期间可能还压着一些）
            self.pump()
        }
    }
}
