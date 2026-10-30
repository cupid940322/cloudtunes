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
            await MainActor.run {
                guard let self, self.currentIndex == index, self.isPlaying, !self.isFallingBack else { return }
                guard self.currentTime < 0.5 else { return }
                self.fallbackToCache(track: track, index: index, link: link, reason: "连接超时")
            }
        }
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

    func next(provider: CloudProvider) {
        if currentIndex + 1 < queue.count {
            playAt(currentIndex + 1, provider: provider)
        } else if repeatMode == .all, !queue.isEmpty {
            playAt(0, provider: provider)
        }
    }

    func previous(provider: CloudProvider) {
        if currentIndex - 1 >= 0 {
            playAt(currentIndex - 1, provider: provider)
        } else if repeatMode == .all, !queue.isEmpty {
            playAt(queue.count - 1, provider: provider)
        }
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

    /// 歌词获取优先级：
    /// 1) 云盘目录中同名 .lrc 文件  2) LRCLIB 在线匹配  3) 提示手动搜索
    private func loadLyrics(for track: Track) async {
        // 1. 同目录同名 .lrc
        if let lrcFile = await findSiblingLRC(for: track),
           let provider = ProviderRegistry.provider(kind: track.providerKind),
           let (url, headers) = try? await provider.streamURL(file: lrcFile) {
            var req = URLRequest(url: url)
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let text = String(data: data, encoding: .utf8) {
                let lines = LRCParser.parse(text)
                if !lines.isEmpty {
                    await MainActor.run {
                        lyricLines = lines
                        lyricSourceNote = "歌词来源：云盘同名 .lrc"
                    }
                    return
                }
            }
        }
        // 2. 网易云歌词（中文歌命中率最高）
        if let text = await LyricsService.neteaseLyrics(title: track.title,
                                                        artist: track.artist,
                                                        neteaseID: track.neteaseID) {
            let lines = LRCParser.parse(text)
            if !lines.isEmpty {
                await MainActor.run {
                    lyricLines = lines
                    lyricSourceNote = "歌词来源：网易云音乐"
                }
                return
            }
        }
        // 3. LRCLIB
        if let candidates = try? await LyricsService.search(title: track.title, artist: track.artist),
           let first = candidates.first(where: { $0.synced }) ?? candidates.first {
            let parsed = first.syncedLyrics.map { LRCParser.parse($0) } ?? []
            await MainActor.run {
                lyricLines = parsed
                lyricSourceNote = first.synced
                    ? "歌词来源：LRCLIB（\(first.artistName) - \(first.trackName)）"
                    : "歌词来源：LRCLIB（纯文本，无逐行时间轴）"
                if parsed.isEmpty, let plain = first.plain {
                    lyricLines = plain.components(separatedBy: .newlines)
                        .enumerated()
                        .map { LyricLine(id: $0.offset, time: -1, text: $0.element) }
                }
            }
            return
        }
        await MainActor.run { lyricSourceNote = "未匹配到歌词，可在播放页手动搜索" }
    }

    private func findSiblingLRC(for track: Track) async -> CloudFile? {
        guard let provider = ProviderRegistry.provider(kind: track.providerKind) else { return nil }
        // 各网盘父目录 id 存放在 CloudFile.extra["parentID"]
        guard let parent = track.file.extra["parentID"] else { return nil }
        guard let siblings = try? await provider.list(folderID: parent) else { return nil }
        let base = (track.file.name as NSString).deletingPathExtension
        return siblings.first {
            !$0.isFolder && (($0.name as NSString).deletingPathExtension == base)
                && $0.name.lowercased().hasSuffix(".lrc")
        }
    }
}
