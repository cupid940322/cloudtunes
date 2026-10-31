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
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// App 端调用：写入快照与封面
    static func save(_ snapshot: Snapshot, cover: UIImage?) {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: "nowplaying.snapshot")
        }
        if let cover {
            let target = containerURL?.appendingPathComponent("widget-cover.png")
            if let url = target,
               let data = cover.jpegData(compressionQuality: 0.88) ?? cover.pngData() {
                try? data.write(to: url, options: .atomic)
            }
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
