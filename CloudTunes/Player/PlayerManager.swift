import AVFoundation
import Combine
import Foundation

/// 全局播放器：AVPlayer 流媒体播放 + 歌词状态
final class PlayerManager: NSObject, ObservableObject {
    static let shared = PlayerManager()

    @Published var queue: [Track] = []
    @Published var currentIndex: Int = -1
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var lyricLines: [LyricLine] = []
    @Published var lyricSourceNote: String = ""
    @Published var nowPlayingTitle: String = ""

    private var player = AVPlayer()
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    /// 当前曲目的直链请求头（百度需要 UA）
    private var currentHeaders: [String: String] = [:]

    var currentTrack: Track? {
        (0..<queue.count).contains(currentIndex) ? queue[currentIndex] : nil
    }

    override init() {
        super.init()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        addTimeObserver()
    }

    private func addTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            currentTime = time.seconds
            let d = player.currentItem?.duration.seconds ?? 0
            if d.isFinite { duration = d }
        }
    }

    /// 用某网盘的文件列表填充队列并从 index 开始播放
    func play(tracks: [Track], at index: Int, provider: CloudProvider) {
        queue = tracks
        playAt(index, provider: provider)
    }

    func playAt(_ index: Int, provider: CloudProvider) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        let track = queue[index]
        nowPlayingTitle = track.title
        currentTime = 0
        duration = 0
        lyricLines = []
        lyricSourceNote = "歌词加载中…"

        Task {
            do {
                let link = try await provider.streamURL(file: track.file)
                await MainActor.run {
                    self.currentHeaders = link.headers
                    let asset = AVURLAsset(url: link.url, options: [
                        "AVURLAssetHTTPHeaderFieldsKey": link.headers,
                    ])
                    let item = AVPlayerItem(asset: asset)
                    self.player.replaceCurrentItem(with: item)
                    self.player.play()
                    self.isPlaying = true
                }
                await self.loadLyrics(for: track)
            } catch {
                await MainActor.run {
                    self.lyricSourceNote = "播放失败：\(error.localizedDescription)"
                    self.isPlaying = false
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
    }

    func next(provider: CloudProvider) {
        guard currentIndex + 1 < queue.count else { return }
        playAt(currentIndex + 1, provider: provider)
    }

    func previous(provider: CloudProvider) {
        guard currentIndex - 1 >= 0 else { return }
        playAt(currentIndex - 1, provider: provider)
    }

    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    // MARK: - 歌词

    /// 歌词获取优先级：
    /// 1) 云盘目录中同名 .lrc 文件  2) LRCLIB 在线匹配  3) 提示手动搜索
    private func loadLyrics(for track: Track) async {
        // 1. 同目录同名 .lrc
        if let lrcFile = await findSiblingLRC(for: track),
           let provider = ProviderRegistry.provider(kind: track.providerKind),
           let (url, headers) = try? provider.streamURL(file: lrcFile) {
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
        // 2. LRCLIB
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
