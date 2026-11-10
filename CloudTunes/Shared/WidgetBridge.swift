import Foundation
import UIKit
import WidgetKit

/// App 与桌面小组件共享的「正在播放」数据（通过 App Group 容器交换）
enum WidgetBridge {
    static let appGroupID = "group.com.gysbs.cloudtunes"

    struct Snapshot: Codable {
        var title: String
        var artist: String
        var isPlaying: Bool
        /// 写入时刻的播放进度（秒）
        var position: TimeInterval
        var duration: TimeInterval
        /// 1-based 队列位置
        var index: Int
        var total: Int
        var updatedAt: Date
        /// 当前曲目 ID：锁屏心形小组件靠它知道该收藏哪首歌。
        /// 旧版本写入的快照没有这个字段，容错解码成空串。
        var trackID: String = ""

        private enum CodingKeys: String, CodingKey {
            case title, artist, isPlaying, position, duration, index, total, updatedAt, trackID
        }

        init(title: String, artist: String, isPlaying: Bool, position: TimeInterval,
             duration: TimeInterval, index: Int, total: Int, updatedAt: Date, trackID: String = "") {
            self.title = title
            self.artist = artist
            self.isPlaying = isPlaying
            self.position = position
            self.duration = duration
            self.index = index
            self.total = total
            self.updatedAt = updatedAt
            self.trackID = trackID
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            artist = try c.decode(String.self, forKey: .artist)
            isPlaying = try c.decode(Bool.self, forKey: .isPlaying)
            position = try c.decode(TimeInterval.self, forKey: .position)
            duration = try c.decode(TimeInterval.self, forKey: .duration)
            index = try c.decode(Int.self, forKey: .index)
            total = try c.decode(Int.self, forKey: .total)
            updatedAt = try c.decode(Date.self, forKey: .updatedAt)
            trackID = try c.decodeIfPresent(String.self, forKey: .trackID) ?? ""
        }
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// App 端调用：写入快照与封面
    /// - Parameter replaceCover: 换歌时为 true。此时若这首歌没有封面，
    ///   会把上一首的封面文件删掉，避免小组件一直显示上一首的图。
    static func save(_ snapshot: Snapshot, cover: UIImage?, replaceCover: Bool = false) {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: "nowplaying.snapshot")
        }
        guard let target = containerURL?.appendingPathComponent("widget-cover.png") else { return }
        if let cover,
           let data = cover.jpegData(compressionQuality: 0.88) ?? cover.pngData() {
            try? data.write(to: target, options: .atomic)
        } else if replaceCover {
            try? FileManager.default.removeItem(at: target)
        }
    }

    /// 清空（App 被手动停播且无曲目时调用）
    static func clear() {
        defaults?.removeObject(forKey: "nowplaying.snapshot")
    }

    /// 小组件端调用：读取快照
    static func load() -> Snapshot? {
        guard let defaults, let data = defaults.data(forKey: "nowplaying.snapshot") else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func coverURL() -> URL? {
        containerURL?.appendingPathComponent("widget-cover.png")
    }

    static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - 收藏桥（锁屏心形小组件 ↔ App）

    /// 收藏在 App Group 里放一份镜像：
    /// 心形小组件运行在扩展进程里，读不到 App 的 UserDefaults.standard，
    /// 双方都以这份镜像为准，谁改了另一方跟着走。
    private static let favoritesKey = "bridge.favorites"

    static var hasFavoritesMirror: Bool {
        defaults?.object(forKey: favoritesKey) != nil
    }

    static func pushFavorites(_ ids: Set<String>) {
        defaults?.set(Array(ids), forKey: favoritesKey)
    }

    static func currentFavorites() -> Set<String> {
        Set(defaults?.stringArray(forKey: favoritesKey) ?? [])
    }

    /// 小组件端调用：切换一首歌的收藏，返回切换后的状态
    @discardableResult
    static func toggleFavorite(trackID: String) -> Bool {
        var favs = currentFavorites()
        if favs.contains(trackID) {
            favs.remove(trackID)
        } else {
            favs.insert(trackID)
        }
        pushFavorites(favs)
        return favs.contains(trackID)
    }

    /// 小组件改完收藏后「喊一嗓子」：往 App Group 容器里写一个 ping 文件。
    ///
    /// 为什么不用 Darwin 通知：`CFNotificationCenterGetDarwinNotificationCenter`
    /// 在 iOS 的 Swift 里不导出（ObjC 才能用）。改用文件系统通知——
    /// App 端用 DispatchSource 盯着这个文件，内容一变就知道收藏被小组件改了。
    /// 注意这里**不能**用 atomic 写（会换 inode，App 盯着的还是旧文件），
    /// 必须复用同一个文件 truncate + write。
    static func notifyFavoritesChanged() {
        guard let url = favoritesPingURL else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let fh = try? FileHandle(forWritingTo: url) else { return }
        let stamp = Data("\(Date().timeIntervalSince1970)".utf8)
        try? fh.truncate(atOffset: 0)
        try? fh.write(contentsOf: stamp)
        try? fh.close()
    }

    static var favoritesPingURL: URL? {
        containerURL?.appendingPathComponent("favorites.ping")
    }
}
