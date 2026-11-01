import Foundation

/// 上次的播放队列快照。
/// 用途：App 被系统回收 / 很久没听之后再打开，首页「继续播放」能把**整个播放列表**恢复回来，
/// 而不是只播最后那一首。
struct PlaybackSession: Codable {
    var tracks: [Track]
    var index: Int
    /// 上次停下的播放进度（秒）
    var position: Double
    var updatedAt: Date

    static var storageURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("playback-session.json")
    }

    static func load() -> PlaybackSession? {
        guard let data = try? Data(contentsOf: storageURL),
              let session = try? JSONDecoder().decode(PlaybackSession.self, from: data),
              !session.tracks.isEmpty,
              session.tracks.indices.contains(session.index) else { return nil }
        return session
    }

    func save() {
        guard !tracks.isEmpty, tracks.indices.contains(index) else { return }
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.storageURL, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: storageURL)
    }
}
