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
}
