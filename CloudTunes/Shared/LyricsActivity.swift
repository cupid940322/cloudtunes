import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// 锁屏 / 灵动岛歌词卡片的共享定义。
///
/// 放在 `Shared` 目录：主 App 和 Widget extension **各编译一份**，
/// 两边的类型必须完全一致，否则 ActivityKit 在做跨进程编解码时会解析失败，
/// 表现就是卡片一直显示占位内容或者干脆不出现。
@available(iOS 16.1, *)
struct LyricsActivityAttributes: ActivityAttributes {

    /// 会随每次刷新变化的部分，所以歌名歌手也放这里——
    /// 切歌时只要 update 同一个 Activity，不必销毁重建（重建会让卡片闪一下）。
    struct ContentState: Codable, Hashable {
        var trackID: String
        var title: String
        var artist: String
        /// 当前这一句歌词
        var line: String
        /// 下一句，给个预告，只显示单行会显得很空
        var nextLine: String
        var isPlaying: Bool
        var position: Double
        var duration: Double
    }

    /// 固定传 "lyrics"，保证同一时刻只有一个歌词卡片
    var slot: String
}

#endif
