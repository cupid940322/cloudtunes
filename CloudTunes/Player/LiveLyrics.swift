import ActivityKit
import Foundation

/// 锁屏 / 灵动岛歌词卡片的生命周期管理。
///
/// 只做三件事：按需开卡片、随歌词滚动推内容、不需要时收掉。
/// 卡片内容由 App 主动 `update` 推送——**不走 APNs**，所以免费 Apple ID
/// 签的包也能用（推送式的实时活动才需要开发者账号的推送能力）。
@available(iOS 16.1, *)
@MainActor
final class LiveLyrics {

    static let shared = LiveLyrics()

    private var activity: Activity<LyricsActivityAttributes>?
    /// 上一次推送的内容指纹，用来避免同一条内容反复推送（系统会对高频更新限流）
    private var lastKey = ""

    private static let enabledKey = "cloudtunes.liveLyrics.enabled"

    /// 用户可在「我的 → 锁屏歌词」里关掉
    var isEnabled: Bool {
        // 默认开启：这个功能就是用户主动要的，第一次装好就该有
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
        if !value { stop() }
    }

    private init() {
        // App 被系统杀掉重开后，上一次的卡片可能还挂在锁屏上，
        // 这里接管它继续更新，避免出现「一张停在旧歌词的死卡片」
        activity = Activity<LyricsActivityAttributes>.activities.first
    }

    /// 由播放器在进度跳动时调用，内部自己去重。
    /// - Parameter lines: 当前曲目的歌词（没有时间轴时传空，卡片会显示占位文案）
    func sync(track: Track?,
              lines: [LyricLine],
              time: TimeInterval,
              duration: TimeInterval,
              isPlaying: Bool) {
        guard isEnabled else { return }
        guard let track, track.id.isEmpty == false else { stop(); return }
        // 用户关了系统的实时活动开关时直接不折腾
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let index = Self.activeIndex(lines, at: time)
        let line = index.flatMap { lines.indices.contains($0) ? lines[$0].text : nil } ?? ""
        let next = index.flatMap { lines.indices.contains($0 + 1) ? lines[$0 + 1].text : nil } ?? ""

        // 指纹：换歌 / 换句 / 播放状态变化 / 每 20 秒补一次进度条
        let key = "\(track.id)|\(index ?? -1)|\(isPlaying)|\(Int(time / 20))"
        guard key != lastKey else { return }
        lastKey = key

        let state = LyricsActivityAttributes.ContentState(
            trackID: track.id,
            title: track.title,
            artist: track.artist ?? "",
            line: line,
            nextLine: next,
            isPlaying: isPlaying,
            position: max(0, time),
            duration: max(0, duration))

        Task { await push(state) }
    }

    /// 停止播放 / 清空队列时收卡片
    func stop() {
        guard let current = activity else { return }
        activity = nil
        lastKey = ""
        Task {
            await current.end(using: nil, dismissalPolicy: .immediate)
        }
    }

    private func push(_ state: LyricsActivityAttributes.ContentState) async {
        if let current = activity {
            await current.update(using: state)
            return
        }
        do {
            activity = try Activity.request(
                attributes: LyricsActivityAttributes(slot: "lyrics"),
                contentState: state,
                pushType: nil)
        } catch {
            // 用户关了实时活动、或卡片数量到上限时会失败。
            // 这属于可选功能，静默降级就好，不要弹错误打扰听歌。
            activity = nil
            lastKey = ""
        }
    }

    // MARK: - 歌词定位

    /// 找出某个播放位置对应的歌词行。
    /// 与播放页用的是同一套判断（允许 0.25 秒提前量），两处显示才会一致。
    static func activeIndex(_ lines: [LyricLine], at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        let limit = time + 0.25
        var result: Int?
        for (i, line) in lines.enumerated() where line.time >= 0 && line.time <= limit {
            result = i
        }
        return result
    }
}
