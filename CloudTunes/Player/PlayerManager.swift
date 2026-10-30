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
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var lyricLines: [LyricLine] = []
    @Published var lyricSourceNote: String = ""
    @Published var nowPlayingTitle: String = ""
    @Published var repeatMode: RepeatMode = .off
    @Published var isShuffled = false
    /// 播放状态提示（缓存中 / 直链被拒绝等），播放页顶部横幅展示
    @Published var playNote: String = ""

    private var player = AVPlayer()
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
    /// 锁屏进度每秒同步用
    private var lastSyncedSecond: Int = -1
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
            guard let self else { return }
            guard let t = self.currentTrack,
                  let p = ProviderRegistry.provider(kind: t.providerKind) else { return }

            // 单曲循环：回到开头继续放
            if self.repeatMode == .one {
                self.player.seek(to: .zero)
                self.player.play()
                self.isPlaying = true
                self.currentTime = 0
                self.updateNowPlaying()
                return
            }
            if self.currentIndex + 1 < self.queue.count {
                self.playAt(self.currentIndex + 1, provider: p)
            } else if self.repeatMode == .all, !self.queue.isEmpty {
                // 列表循环：回到第一首
                self.playAt(0, provider: p)
            } else {
                self.isPlaying = false
                self.currentTime = 0
                self.player.seek(to: .zero)
                self.updateNowPlaying()
            }
        }
    }

    var currentTrack: Track? {
        (0..<queue.count).contains(currentIndex) ? queue[currentIndex] : nil
    }

    override init() {
        super.init()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        addTimeObserver()
        setupRemoteCommands()
    }

    // MARK: - 锁屏 / 耳机控制

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.player.play(); self?.isPlaying = true; return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.player.pause(); self?.isPlaying = false; return .success
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
            }
        }
        if let npArtwork { info[MPMediaItemPropertyArtwork] = npArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func addTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            let d = self.player.currentItem?.duration.seconds ?? 0
            if d.isFinite, d > 0 {
                let rounded = (d * 100).rounded() / 100
                if abs(self.duration - rounded) > 0.05 {
                    // 时长刚解析出来（之前是 0），立刻刷锁屏，否则锁屏没有总时长
                    self.duration = rounded
                    self.updateNowPlaying()
                }
            }
            // 每秒同步一次锁屏的已播时间
            let second = Int(time.seconds)
            if second != self.lastSyncedSecond {
                self.lastSyncedSecond = second
                self.updateNowPlaying()
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
        currentIndex = index
        let track = queue[index]
        nowPlayingTitle = track.title
        currentTime = 0
        duration = 0
        lastSyncedSecond = -1
        npArtworkKey = nil
        lyricLines = []
        playNote = ""
        lyricSourceNote = "歌词加载中…"
        updateNowPlaying()

        loadTask = Task {
            do {
                let link = try await provider.streamURL(file: track.file)
                try Task.checkCancellation()
                await MainActor.run {
                    // 在取直链期间用户又切了别的歌
                    guard self.currentIndex == index, !Task.isCancelled else { return }
                    self.startStreaming(track: track, index: index, link: link)
                    LibraryStore.shared.markPlayed(track.id)
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
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        updateNowPlaying()
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
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
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
