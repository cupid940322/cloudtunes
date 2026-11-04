import AVFoundation
import Combine
import Foundation
import MediaPlayer
import UIKit

/// 全局播放器：AVPlayer 流媒体播放 + 歌词状态
final class PlayerManager: NSObject, ObservableObject {
    static let shared = PlayerManager()

    enum RepeatMode: Int {
        case off = 0, all = 1, one = 2

        var icon: String {
            switch self {
            case .off, .all: return "repeat"
            case .one: return "repeat.1"
            }
        }
        var isActive: Bool { self != .off }
    }

    @Published var queue: [Track] = []
    @Published var currentIndex: Int = -1
    @Published var isPlaying = false
    /// 高频进度时钟：0.25 秒一跳，**独立**发布。
    /// 不能放在 PlayerManager 的 @Published 里，否则每秒 4 次触发所有观察者重建整个界面。
    let clock = PlaybackClock()
    @Published var lyricLines: [LyricLine] = []
    @Published var lyricSourceNote: String = ""
    @Published var nowPlayingTitle: String = ""
    @Published var repeatMode: RepeatMode = .off
    @Published var isShuffled = false
    /// 播放状态提示（缓存中 / 直链被拒绝等），播放页顶部横幅展示
    @Published var playNote: String = ""
    /// 当前曲目的音频格式说明（wav / aiff 这类无压缩文件才有），播放页顶部一行小字
    @Published var audioInfo: String = ""
    /// 上次的播放队列（App 重启 / 很久没听后，首页「继续播放」用它恢复整个列表）
    @Published private(set) var savedSession: PlaybackSession?
    /// 恢复会话时要跳到的位置
    private var pendingSeek: Double = 0
    private var lastPersistSignature = ""

    private var player = AVPlayer()
    /// DTS 内置解码通道（边下边解，不落盘）
    private var dtsPlayer: DTSStreamPlayer?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    /// 当前曲目的直链请求头（百度/夸克需要 UA + Cookie + Referer）
    private var currentHeaders: [String: String] = [:]
    /// 随机播放前的原始顺序
    private var originalQueue: [Track] = []
    /// 取直链的任务（新请求会取消旧请求，避免旧结果覆盖新歌）
    private var loadTask: Task<Void, Never>?
    /// 直链播放失败 → 本地缓存兜底
    private var fallbackTask: Task<Void, Never>?
    @Published private(set) var isFallingBack = false
    /// 9 秒还没出声就直接走缓存兜底
    private var watchdogTask: Task<Void, Never>?
    private var itemStatusObservation: NSKeyValueObservation?
    /// 锁屏封面缓存（避免每秒读盘）
    private var npArtworkKey: String?
    private var npArtwork: MPMediaItemArtwork?
    /// 歌词预取任务
    private var prefetchTask: Task<Void, Never>?
    /// 云盘目录缓存（同名 .lrc 查找用，避免每首歌都重新列目录）
    private var listingCache: [String: (files: [CloudFile], at: Date)] = [:]
    private let listingLock = NSLock()

    // MARK: - 播放结束自动下一首（含后台/熄屏）

    private func observeEnd(of item: AVPlayerItem) {
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleItemEnded(_:)),
                                               name: .AVPlayerItemDidPlayToEndTime, object: item)
        NotificationCenter.default.addObserver(self, selector: #selector(handleItemEnded(_:)),
                                               name: .AVPlayerItemFailedToPlayToEndTime, object: item)
    }

    @objc private func handleItemEnded(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.advanceAfterFinish()
        }
    }

    /// 一首放完：单曲循环 → 下一首 → 列表循环 → 停
    private func advanceAfterFinish() {
        guard let t = currentTrack,
              let p = ProviderRegistry.provider(kind: t.providerKind) else { return }

        // 单曲循环：回到开头继续放
        if repeatMode == .one {
            seek(to: 0)
            resumePlayback()
            return
        }
        if currentIndex + 1 < queue.count {
            playAt(currentIndex + 1, provider: p)
        } else if repeatMode == .all, !queue.isEmpty {
            // 列表循环：回到第一首
            playAt(0, provider: p)
        } else {
            isPlaying = false
            currentTime = 0
            dtsPlayer?.pause()
            player.seek(to: .zero)
            updateNowPlaying()
        }
    }

    var currentTrack: Track? {
        (0..<queue.count).contains(currentIndex) ? queue[currentIndex] : nil
    }

    /// 已播秒数（读写都走 clock，读不会触发本对象刷新）
    var currentTime: TimeInterval {
        get { clock.time }
        set { clock.setTime(newValue) }
    }

    /// 当前曲目时长
    var duration: TimeInterval {
        get { clock.duration }
        set { clock.setDuration(newValue) }
    }

    override init() {
        super.init()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        savedSession = PlaybackSession.load()
        addTimeObserver()
        setupRemoteCommands()
        // 退到后台 / 锁屏时记下进度，下次「继续播放」能接着听
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.persistSession()
        }
        // 即将进入后台（锁屏 / 切走）时补写一次锁屏信息，
        // 保证锁屏上的已播时间是准的；前台播放期间交给系统按播放速率外推。
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateNowPlaying()
            self?.persistSession()
        }
    }

    // MARK: - 锁屏 / 耳机控制

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.resumePlayback(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pausePlayback(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlay(); return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, let t = self.currentTrack,
                  let p = ProviderRegistry.provider(kind: t.providerKind) else { return .commandFailed }
            self.next(provider: p); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, let t = self.currentTrack,
                  let p = ProviderRegistry.provider(kind: t.providerKind) else { return .commandFailed }
            self.previous(provider: p); return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: e.positionTime); return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist ?? "未知艺术家",
        ]
        if let album = track.album, !album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        // 封面只在换歌时读一次盘
        if npArtworkKey != track.id {
            npArtworkKey = track.id
            npArtwork = nil
            if let url = MetadataScraper.artworkURL(file: track.artworkFile),
               let image = UIImage(contentsOfFile: url.path) {
                npArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            } else if let placeholder = Self.placeholderArtwork {
                // 没封面时给一张品牌占位图：投送到 Apple TV / 锁屏时不会一片空白
                npArtwork = MPMediaItemArtwork(boundsSize: placeholder.size) { _ in placeholder }
            }
        }
        if let npArtwork { info[MPMediaItemPropertyArtwork] = npArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        pushWidgetSnapshot(track: track)
    }

    /// 没有刮削到封面时的占位图（600×600，品牌渐变 + 音符）
    private static let placeholderArtwork: UIImage? = {
        let size = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let colors = [UIColor(red: 1.00, green: 0.50, blue: 0.46, alpha: 1).cgColor,
                          UIColor(red: 1.00, green: 0.68, blue: 0.38, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero,
                                                 end: CGPoint(x: size.width, y: size.height),
                                                 options: [])
            }
            if let symbol = UIImage(systemName: "music.note")?
                .withTintColor(.white.withAlphaComponent(0.92), renderingMode: .alwaysOriginal) {
                let side: CGFloat = 260
                symbol.draw(in: CGRect(x: (size.width - side) / 2,
                                       y: (size.height - side) / 2,
                                       width: side, height: side))
            }
        }
    }()

    // MARK: - 播放列表快照（首页「继续播放」用）

    /// 把「整个队列 + 当前第几首 + 进度」写盘。
    /// 换歌、暂停、退到后台时都会调用，所以下次点「继续播放」能接着整张列表听。
    func persistSession() {
        guard !queue.isEmpty, queue.indices.contains(currentIndex) else { return }
        let signature = "\(queue.first?.id ?? "")|\(queue.count)|\(currentIndex)|\(Int(currentTime / 10))"
        guard signature != lastPersistSignature else { return }
        lastPersistSignature = signature

        let session = PlaybackSession(tracks: queue,
                                      index: currentIndex,
                                      position: currentTime,
                                      updatedAt: Date())
        session.save()
        savedSession = session
    }

    /// 恢复上次的整个播放列表，并从停下的位置继续
    func resumeSavedSession() {
        guard let session = savedSession,
              !session.tracks.isEmpty,
              session.tracks.indices.contains(session.index),
              let provider = ProviderRegistry.provider(kind: session.tracks[session.index].providerKind)
        else { return }
        isShuffled = false
        queue = session.tracks
        originalQueue = session.tracks
        playAt(session.index, provider: provider)
        // playAt 内部会清零，所以在它之后设置
        pendingSeek = session.position
    }

    /// 资料库里的歌曲信息被修改（手动匹配 / 手动修正 / 重新刮削）后，同步刷新播放队列里的旧拷贝。
    /// 否则播放页、锁屏、小组件会一直显示旧歌手——封面反而会变（封面文件按歌曲 ID 覆盖写入），
    /// 造成「封面更新了、歌手没更新」的怪现象。
    func refreshTrackMetadata(_ updated: Track) {
        var changed = false
        for i in queue.indices where queue[i].id == updated.id {
            if queue[i] != updated { queue[i] = updated; changed = true }
        }
        for i in originalQueue.indices where originalQueue[i].id == updated.id {
            if originalQueue[i] != updated { originalQueue[i] = updated; changed = true }
        }
        // 「继续播放」的会话快照也要跟着换，否则下次恢复又是旧信息
        if let session = savedSession, session.tracks.contains(where: { $0.id == updated.id }) {
            var s = session
            for i in s.tracks.indices where s.tracks[i].id == updated.id { s.tracks[i] = updated }
            savedSession = s
            changed = true
        }
        guard changed else { return }

        if currentTrack?.id == updated.id {
            nowPlayingTitle = updated.title
            // 封面文件是按歌曲 ID 覆盖写的，路径没变内容变了，旧缓存图要清掉
            ArtworkCache.shared.evict(named: updated.artworkFile)
            // 封面内容变了，让下次推送重新读盘写进 App Group
            widgetCoverKey = nil
            // 强制重写锁屏与小组件：快照签名里没有歌名/歌手，不清签名会被节流直接跳过
            widgetLastSignature = ""
            updateNowPlaying()
        }
    }

    // MARK: - 桌面小组件同步
    private var widgetCoverKey: String?
    private var widgetLastSignature = ""

    /// 每 20 秒（或换歌/暂停时）把正在播放的快照写给小组件。
    /// 小组件上的进度是用 Text(timerInterval:) 自己走的，不需要频繁重写，
    /// 而 reloadTimelines 是有成本的系统调用，调太勤会拖慢主线程。
    private func pushWidgetSnapshot(track: Track) {
        let signature = "\(track.id)|\(isPlaying)|\(Int(currentTime / 20))"
        guard signature != widgetLastSignature else { return }
        widgetLastSignature = signature

        var cover: UIImage?
        var replaceCover = false
        if widgetCoverKey != track.id {
            widgetCoverKey = track.id
            replaceCover = true
            cover = MetadataScraper.artworkURL(file: track.artworkFile)
                .flatMap { UIImage(contentsOfFile: $0.path) }
        }
        let snapshot = WidgetBridge.Snapshot(
            title: track.title,
            artist: track.displayArtist,
            isPlaying: isPlaying,
            position: currentTime,
            duration: duration,
            index: currentIndex + 1,
            total: queue.count,
            updatedAt: Date()
        )
        WidgetBridge.save(snapshot, cover: cover, replaceCover: replaceCover)
        WidgetBridge.reload()
    }

    private func addTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            // DTS 通道自己推进度，别让 AVPlayer 的旧时间覆盖掉
            if self.dtsPlayer != nil { return }
            // 只写时钟：PlayerManager 本身不再发通知，列表 / 首页因此不会每秒重建 4 次
            self.currentTime = time.seconds

            // 时长只在还没解析出来时去问一次 AVPlayerItem，解析好之后就不再碰
            if self.duration <= 0, let item = self.player.currentItem {
                let d = item.duration.seconds
                if d.isFinite, d > 0 {
                    self.duration = (d * 100).rounded() / 100
                    // 时长刚解析出来（之前是 0），立刻刷锁屏，否则锁屏没有总时长
                    self.updateNowPlaying()
                    return
                }
            }
            // 锁屏 / 控制中心的进度不再每秒重写：
            // 只要 nowPlayingInfo 里带播放速率，系统会自己外推进度条。
            // 之前每秒一次跨进程写 MPNowPlayingInfoCenter，滑动界面时会周期性地顿一下。

            // 桌面小组件每 20 秒补一次快照（内部有节流，绝大多数调用会立刻返回）
            if let track = self.currentTrack, self.isPlaying, Int(time.seconds) % 20 == 0 {
                self.pushWidgetSnapshot(track: track)
            }
        }
    }

    /// 用某网盘的文件列表填充队列并从 index 开始播放
    func play(tracks: [Track], at index: Int, provider: CloudProvider) {
        originalQueue = tracks
        if isShuffled, tracks.indices.contains(index) {
            let current = tracks[index]
            let rest = tracks.enumerated()
                .filter { $0.offset != index }
                .map { $0.element }
                .shuffled()
            queue = [current] + rest
            playAt(0, provider: provider)
        } else {
            queue = tracks
            playAt(index, provider: provider)
        }
    }

    /// 随机播放开关
    func setShuffled(_ on: Bool) {
        isShuffled = on
        guard let current = currentTrack else { return }
        if on {
            if originalQueue.isEmpty { originalQueue = queue }
            let rest = queue.filter { $0.id != current.id }.shuffled()
            queue = [current] + rest
            currentIndex = 0
        } else if !originalQueue.isEmpty {
            queue = originalQueue
            currentIndex = queue.firstIndex(where: { $0.id == current.id }) ?? 0
        }
    }

    func cycleRepeatMode() {
        repeatMode = RepeatMode(rawValue: (repeatMode.rawValue + 1) % 3) ?? .off
    }

    func playNext() {
        guard let t = currentTrack,
              let p = ProviderRegistry.provider(kind: t.providerKind) else { return }
        next(provider: p)
    }

    func playPrevious() {
        guard let t = currentTrack,
              let p = ProviderRegistry.provider(kind: t.providerKind) else { return }
        previous(provider: p)
    }

    /// 重试当前曲目（重新取直链）
    func retryCurrent() {
        guard let t = currentTrack,
              let p = ProviderRegistry.provider(kind: t.providerKind) else { return }
        playAt(currentIndex, provider: p)
    }
    func playAt(_ index: Int, provider: CloudProvider) {
        guard queue.indices.contains(index) else { return }
        // 取消还在路上的旧请求，避免快速切歌时旧结果把新歌顶掉
        loadTask?.cancel()
        fallbackTask?.cancel()
        watchdogTask?.cancel()
        itemStatusObservation = nil
        isFallingBack = false
        // 切歌时先掐掉 DTS 通道，避免上一首继续响
        dtsPlayer?.stop()
        dtsPlayer = nil
        audioInfo = ""
        player.pause()
        currentIndex = index
        pendingSeek = 0
        let track = queue[index]
        nowPlayingTitle = track.title
        currentTime = 0
        duration = 0
        npArtworkKey = nil
        lyricLines = []
        playNote = ""
        lyricSourceNote = "歌词加载中…"
        updateNowPlaying()
        persistSession()

        // 队列可能跨多个网盘（收藏 / 最近播放），按曲目自己所属的网盘取直链，
        // 取不到再退回调用方传进来的 provider
        let trackProvider = ProviderRegistry.provider(kind: track.providerKind) ?? provider
        loadTask = Task {
            do {
                let link = try await trackProvider.streamURL(file: track.file)
                try Task.checkCancellation()

                // wav / aiff / caf 这类 PCM 容器先取 128KB 前缀探一下：
                // 里面是 DTS 码流就走内置解码，否则直接直链播放（不占存储）。
                var info: AudioProbe.Info?
                if MusicScanner.isPCMContainer(track.file.name),
                   let probe = await AudioProbe.probeRemote(url: link.url, headers: link.headers) {
                    info = probe.1
                }
                try Task.checkCancellation()

                if let info, info.dts != .none {
                    await self.startDTSPlayback(track: track, index: index, link: link, info: info)
                } else {
                    await MainActor.run {
                        // 在取直链期间用户又切了别的歌
                        guard self.currentIndex == index, !Task.isCancelled else { return }
                        // 普通 PCM 也把格式显示出来，方便确认「这到底是 DTS 还是真 PCM」
                        self.audioInfo = info?.summary ?? ""
                        self.startStreaming(track: track, index: index, link: link)
                        LibraryStore.shared.markPlayed(track.id)
                    }
                }
                try Task.checkCancellation()
                await self.loadLyrics(for: track)
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard self.currentIndex == index else { return }
                    // 明确暂停，避免旧歌继续响造成「按了没反应」的错觉
                    self.player.pause()
                    self.isPlaying = false
                    self.playNote = "播放失败：\(error.localizedDescription)"
                    self.lyricSourceNote = "播放失败：\(error.localizedDescription)，请重试或重新登录网盘"
                    self.updateNowPlaying()
                }
            }
        }
    }

    /// 用直链起播，并挂上「失败 / 久不出声」监听，随时准备本地缓存兜底
    private func startStreaming(track: Track, index: Int, link: (url: URL, headers: [String: String])) {
        currentHeaders = link.headers
        let asset = AVURLAsset(url: link.url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": link.headers,
        ])
        let item = AVPlayerItem(asset: asset)
        observeEnd(of: item)
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        // 恢复会话时跳到上次停下的位置
        if pendingSeek > 3 {
            let target = CMTime(seconds: pendingSeek, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        pendingSeek = 0
        updateNowPlaying()

        // AVPlayer 对请求头极敏感（夸克少一个 Referer 就 403），失败就直接转本地缓存
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let reason = item.error?.localizedDescription ?? "无法读取音频流"
            Task { @MainActor in
                self?.fallbackToCache(track: track, index: index, link: link, reason: reason)
            }
        }

        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            await self?.watchdogFired(index: index, track: track, link: link)
        }
    }

    @MainActor
    private func watchdogFired(index: Int, track: Track, link: (url: URL, headers: [String: String])) {
        guard currentIndex == index, isPlaying, !isFallingBack, currentTime < 0.5 else { return }
        fallbackToCache(track: track, index: index, link: link, reason: "连接超时")
    }

    /// DTS 音轨（DTS-CD / 5.1 资源抓轨的标准形态）：iOS 原生没有 DTS 解码器，
    /// 走内置 libdca 边下边解边播，不落盘、不占手机存储。
    @MainActor
    private func startDTSPlayback(track: Track,
                                  index: Int,
                                  link: (url: URL, headers: [String: String]),
                                  info: AudioProbe.Info) async {
        guard currentIndex == index else { return }
        audioInfo = info.summary
        player.replaceCurrentItem(with: nil)
        player.pause()

        let dts = DTSStreamPlayer()
        dts.onTime = { [weak self] t in self?.currentTime = t }
        dts.onDuration = { [weak self] d in self?.duration = d }
        dts.onReady = { [weak self] in
            guard let self, self.playNote.hasPrefix("DTS") else { return }
            self.playNote = ""
        }
        dts.onFinish = { [weak self] in self?.advanceAfterFinish() }
        dts.onError = { [weak self] message in
            guard let self else { return }
            self.isPlaying = false
            self.playNote = "DTS 播放失败：\(message)"
            self.updateNowPlaying()
        }
        dtsPlayer = dts
        isPlaying = true
        playNote = "DTS 音轨：正在解码播放（边下边解，不占存储）"

        dts.start(url: link.url,
                  headers: link.headers,
                  dataOffset: max(0, info.dataOffset),
                  dataBytes: info.dataBytes,
                  startAt: pendingSeek,
                  fourteenBit: info.dts == .dts14)
        pendingSeek = 0
        updateNowPlaying()
        LibraryStore.shared.markPlayed(track.id)
    }

    /// 直链被拒绝 → 用带完整请求头的 URLSession 把文件拉到本地缓存再播
    private func fallbackToCache(track: Track,
                                 index: Int,
                                 link: (url: URL, headers: [String: String]),
                                 reason: String) {
        guard currentIndex == index, !isFallingBack else { return }
        isFallingBack = true
        watchdogTask?.cancel()
        playNote = "直链无法播放（\(reason)），正在缓存到本地…"
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                let local = try await StreamCache.localCopy(of: link.url,
                                                            headers: link.headers,
                                                            key: track.id,
                                                            source: track.file.name)
                await MainActor.run {
                    guard self.currentIndex == index else { return }
                    self.isFallingBack = false
                    self.playNote = "已缓存到本地播放（原直链被拒绝，若频繁出现请重新导入 Cookie）"
                    let item = AVPlayerItem(url: local)
                    self.observeEnd(of: item)
                    self.player.replaceCurrentItem(with: item)
                    self.player.play()
                    self.isPlaying = true
                    self.duration = 0
                    self.updateNowPlaying()
                }
            } catch {
                await MainActor.run {
                    guard self.currentIndex == index else { return }
                    self.isFallingBack = false
                    self.player.pause()
                    self.isPlaying = false
                    self.playNote = "播放失败：\(error.localizedDescription)"
                    self.lyricSourceNote = "播放失败：\(error.localizedDescription)"
                    self.updateNowPlaying()
                }
            }
        }
    }

    func togglePlay() {
        if isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    /// 播放 / 暂停：DTS 与 AVPlayer 两个通道分别处理
    func resumePlayback() {
        if let dts = dtsPlayer {
            dts.resume()
        } else {
            player.play()
        }
        isPlaying = true
        updateNowPlaying()
        persistSession()
    }

    func pausePlayback() {
        if let dts = dtsPlayer {
            dts.pause()
        } else {
            player.pause()
        }
        isPlaying = false
        updateNowPlaying()
        persistSession()
    }

    /// 下一首：**永远会往前走**（到末尾就回绕），不再依赖「列表循环」开关。
    /// 之前只有在 repeatMode == .all 时才回绕，导致随机模式下停到列表末尾后按下一首毫无反应。
    func next(provider: CloudProvider) {
        guard !queue.isEmpty else { return }
        guard queue.count > 1 else { playAt(0, provider: provider); return }

        var nextIndex = currentIndex + 1
        if nextIndex >= queue.count {
            if isShuffled {
                reshuffleAndRestart(provider: provider)
                return
            }
            nextIndex = 0
        }
        playAt(nextIndex, provider: provider)
    }

    /// 上一首：同样会回绕（在第 1 首按上一首 → 跳到最后一首）
    func previous(provider: CloudProvider) {
        guard !queue.isEmpty else { return }
        guard queue.count > 1 else { playAt(0, provider: provider); return }

        var index = currentIndex - 1
        if index < 0 { index = queue.count - 1 }
        playAt(index, provider: provider)
    }

    /// 随机模式播到末尾：重新洗一轮，且保证第一首不是刚播完的那首
    private func reshuffleAndRestart(provider: CloudProvider) {
        guard queue.count > 1 else { playAt(0, provider: provider); return }
        let currentID = currentTrack?.id
        queue = queue.shuffled()
        if queue.first?.id == currentID { queue.swapAt(0, 1) }
        playAt(0, provider: provider)
    }

    func seek(to seconds: TimeInterval) {
        if let dts = dtsPlayer {
            dts.seek(to: seconds)
        } else {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        currentTime = seconds
        updateNowPlaying()
    }

    /// 当前曲目封面（本地缓存），供 UI 使用
    var currentArtwork: UIImage? {
        guard let file = currentTrack?.artworkFile,
              let url = MetadataScraper.artworkURL(file: file) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - 歌词

    /// 一次歌词查询的结果
    struct LyricHit {
        var lines: [LyricLine]
        var note: String
    }

    /// 歌词加载：先查缓存（切歌瞬间出歌词），未命中再「云盘同名 .lrc / 网易云 / LRCLIB」三路并发抢答。
    /// 之前是串行三连（还要先列一次云盘目录），国内网络下 3~8 秒，所以总是"加载中"。
    private func loadLyrics(for track: Track) async {
        let key = LyricsCache.key(title: track.title, artist: track.artist)

        if let hit = LyricsCache.get(key) {
            await MainActor.run {
                lyricLines = hit.lines
                lyricSourceNote = hit.note
            }
            await prefetchNextLyrics()
            return
        }

        let hit = await withTaskGroup(of: LyricHit?.self) { group -> LyricHit? in
            group.addTask { await self.siblingLRC(for: track) }
            group.addTask { await self.neteaseLyrics(for: track) }
            group.addTask { await self.qqLyrics(for: track) }
            group.addTask { await self.kugouLyrics(for: track) }
            group.addTask { await self.lrclibLyrics(for: track) }
            var winner: LyricHit?
            for await r in group {
                if let r, !r.lines.isEmpty { winner = r; break }
            }
            group.cancelAll()
            return winner
        }

        if let hit {
            LyricsCache.store(hit.lines, note: hit.note, for: key)
            await MainActor.run {
                lyricLines = hit.lines
                lyricSourceNote = hit.note
            }
        } else {
            await MainActor.run { lyricSourceNote = "未匹配到歌词，可在播放页手动搜索" }
        }
        await prefetchNextLyrics()
    }

    /// 云盘同目录同名 .lrc
    private func siblingLRC(for track: Track) async -> LyricHit? {
        await withTimeout(5) {
            guard let provider = ProviderRegistry.provider(kind: track.providerKind) else { return nil }
            guard let parent = track.file.extra["parentID"],
                  let siblings = await self.cachedListing(provider: provider, folderID: parent) else { return nil }
            let base = (track.file.name as NSString).deletingPathExtension
            guard let lrc = siblings.first(where: {
                !$0.isFolder
                    && $0.name.lowercased().hasSuffix(".lrc")
                    && ($0.name as NSString).deletingPathExtension == base
            }) else { return nil }

            guard let (url, headers) = try? await provider.streamURL(file: lrc) else { return nil }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let text = Self.decodeText(data) else { return nil }
            let lines = LRCParser.parse(text)
            return lines.isEmpty ? nil : LyricHit(lines: lines, note: "歌词来源：云盘同名 .lrc")
        }
    }

    /// 网易云歌词（中文歌命中率最高）
    private func neteaseLyrics(for track: Track) async -> LyricHit? {
        await withTimeout(7) {
            guard let text = await LyricsService.neteaseLyrics(title: track.title,
                                                               artist: track.artist,
                                                               neteaseID: track.neteaseID) else { return nil }
            let lines = LRCParser.parse(text)
            return lines.isEmpty ? nil : LyricHit(lines: lines, note: "歌词来源：网易云音乐")
        }
    }

    /// QQ 音乐：搜到候选后取第一条的歌词（QQ 歌词库补网易云的缺口）
    private func qqLyrics(for track: Track) async -> LyricHit? {
        await withTimeout(7) {
            let keyword = [track.artist, track.title].compactMap { $0 }.joined(separator: " ")
            guard let song = await LyricsService.qqSearchSongs(keyword: keyword, limit: 5).first,
                  let text = await LyricsService.qqLyric(songmid: song.mid) else { return nil }
            let lines = LyricsService.lines(from: text)
            guard !lines.isEmpty else { return nil }
            let synced = lines.contains { $0.time >= 0 }
            return LyricHit(lines: lines,
                            note: "歌词来源：QQ音乐（\(song.artist) - \(song.title)）" + (synced ? "" : " · 纯文本"))
        }
    }

    /// 酷狗音乐
    private func kugouLyrics(for track: Track) async -> LyricHit? {
        await withTimeout(7) {
            let candidates = await LyricsService.kugouCandidates(title: track.title, artist: track.artist)
            guard let first = candidates.first,
                  case let .kugou(id, key) = first.lookup,
                  let text = await LyricsService.kugouLyric(id: id, accessKey: key) else { return nil }
            let lines = LyricsService.lines(from: text)
            guard !lines.isEmpty else { return nil }
            let synced = lines.contains { $0.time >= 0 }
            return LyricHit(lines: lines,
                            note: "歌词来源：酷狗音乐（\(first.artist) - \(first.title)）" + (synced ? "" : " · 纯文本"))
        }
    }

    /// LRCLIB（外网，国内可能较慢，超时就让位给网易云）
    private func lrclibLyrics(for track: Track) async -> LyricHit? {
        await withTimeout(6) {
            guard let candidates = try? await LyricsService.search(title: track.title, artist: track.artist),
                  let first = candidates.first(where: { $0.synced }) ?? candidates.first else { return nil }
            var lines = first.syncedLyrics.map { LRCParser.parse($0) } ?? []
            if lines.isEmpty, let plain = first.plain {
                lines = plain.components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .enumerated()
                    .map { LyricLine(id: $0.offset, time: -1, text: $0.element) }
            }
            guard !lines.isEmpty else { return nil }
            let note = first.synced
                ? "歌词来源：LRCLIB（\(first.artistName) - \(first.trackName)）"
                : "歌词来源：LRCLIB（纯文本，无逐行时间轴）"
            return LyricHit(lines: lines, note: note)
        }
    }

    /// 提前把下一首的歌词抓好，切歌时直接命中缓存
    @MainActor
    private func prefetchNextLyrics() {
        let nextIndex = currentIndex + 1
        guard queue.indices.contains(nextIndex) else { return }
        let next = queue[nextIndex]
        guard next.id != currentTrack?.id else { return }
        let key = LyricsCache.key(title: next.title, artist: next.artist)
        guard LyricsCache.get(key) == nil else { return }

        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            var hit = await self.neteaseLyrics(for: next)
            if hit == nil { hit = await self.lrclibLyrics(for: next) }
            if let hit {
                LyricsCache.store(hit.lines, note: hit.note, for: key)
            }
        }
    }

    /// 云盘目录缓存：同名 .lrc 查找不必每首歌都重新列一次目录（夸克目录还是分页的，很慢）
    private func cachedListing(provider: CloudProvider, folderID: String) async -> [CloudFile]? {
        let key = "\(provider.kind.rawValue)|\(folderID)"
        listingLock.lock()
        let cached = listingCache[key]
        listingLock.unlock()
        if let cached, Date().timeIntervalSince(cached.at) < 600 { return cached.files }

        guard let files = try? await provider.list(folderID: folderID) else { return nil }
        listingLock.lock()
        if listingCache.count > 12 { listingCache.removeAll() }
        listingCache[key] = (files, Date())
        listingLock.unlock()
        return files
    }

    /// 超时保护：在线服务偶尔会挂很久，不能让歌词一直"加载中"
    private func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// LRC 文件编码兜底：不少中文歌词是 GB18030/GBK
    private static func decodeText(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8), !s.isEmpty { return s }
        if let s = String(data: data, encoding: String.Encoding(rawValue: 0x8000_0632)), !s.isEmpty { return s }
        return nil
    }
}
