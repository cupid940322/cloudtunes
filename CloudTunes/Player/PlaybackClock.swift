import Combine
import Foundation

/// 播放进度时钟（高频、独立发布）。
///
/// 为什么要单独拆出来：
/// 以前 `currentTime` / `duration` 是 `PlayerManager` 的 `@Published`，播放器每 0.25 秒写一次。
/// 而首页、搜索结果、音乐库列表里的每一行 `SongRow`、底部迷你播放条、根视图全都
/// `@ObservedObject` 了整个 `PlayerManager` —— 于是**只要在放歌，整棵界面树每秒被重建 4 次**，
/// 滑动列表时就会明显掉帧（尤其是封面还有圆角裁剪 + 阴影的行）。
///
/// 现在只有真正显示「时间 / 进度」的几个小视图订阅这里，其余页面只在换歌、暂停时才刷新。
final class PlaybackClock: ObservableObject {
    /// 已播秒数（0.25 秒粒度）
    @Published private(set) var time: TimeInterval = 0
    /// 当前曲目总时长（解析出来后会更新一次）
    @Published private(set) var duration: TimeInterval = 0

    /// 只在变化足够大时才发布，避免同一时刻被重复赋值触发无谓刷新
    func setTime(_ value: TimeInterval) {
        let v = value.isFinite ? max(0, value) : 0
        guard abs(v - time) >= 0.04 else { return }
        time = v
    }

    func setDuration(_ value: TimeInterval) {
        let v = value.isFinite ? max(0, value) : 0
        guard abs(v - duration) >= 0.05 else { return }
        duration = v
    }

    /// 换歌 / 停止时一次性归零
    func reset() {
        if time != 0 { time = 0 }
        if duration != 0 { duration = 0 }
    }

    /// 播放进度 0…1
    var fraction: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, time / duration))
    }
}
