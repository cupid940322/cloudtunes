import AppIntents
import SwiftUI
import WidgetKit

/// 锁屏心形收藏按钮。
///
/// 为什么不是系统媒体控件里的那颗「心」：`MPRemoteCommandCenter.likeCommand`
/// 在系统锁屏播放器里的默认图形是**五角星**，而且图标是系统画的，
/// 第三方 App 没有任何 API 能改。所以把五角星撤掉，改用**锁屏小组件**：
/// iOS 17 起小组件可以内嵌 App Intent 直接执行动作，
/// 在锁屏上点一下就切换当前这首歌的收藏——不用解锁、不用打开 App。
///
/// 数据链路（见 WidgetBridge）：
///   App 把「当前曲目 ID + 收藏集合」镜像进 App Group
///   → 小组件读镜像渲染心形（实心 = 已收藏）
///   → 点按后小组件进程切换收藏、重绘时间线
///   → 发 Darwin 通知，正在运行的 App 立刻重读镜像，界面上的小心脏也同步
@available(iOSApplicationExtension 17.0, *)
struct ToggleFavoriteIntent: AppIntent {
    static var title: LocalizedStringResource = "收藏当前歌曲"
    static var description = IntentDescription("把正在播放的这首加进 / 移出「我喜欢的音乐」")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snap = WidgetBridge.load(), !snap.trackID.isEmpty else {
            return .result(dialog: IntentDialog("当前没有正在播放的歌曲"))
        }
        let liked = WidgetBridge.toggleFavorite(trackID: snap.trackID)
        WidgetCenter.shared.reloadAllTimelines()
        WidgetBridge.notifyFavoritesChanged()
        let dialog: IntentDialog = liked
            ? IntentDialog("已收藏《\(snap.title)》")
            : IntentDialog("已取消收藏《\(snap.title)》")
        return .result(dialog: dialog)
    }
}

@available(iOSApplicationExtension 17.0, *)
struct FavoriteEntry: TimelineEntry {
    let date: Date
    let hasTrack: Bool
    let favorited: Bool
}

@available(iOSApplicationExtension 17.0, *)
struct FavoriteProvider: TimelineProvider {
    func placeholder(in context: Context) -> FavoriteEntry {
        entry()
    }

    func getSnapshot(in context: Context, completion: @escaping (FavoriteEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FavoriteEntry>) -> Void) {
        let e = entry()
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [e], policy: .after(next)))
    }

    private func entry() -> FavoriteEntry {
        let snap = WidgetBridge.load()
        let hasTrack = !(snap?.trackID.isEmpty ?? true)
        let favorited = hasTrack && WidgetBridge.currentFavorites().contains(snap!.trackID)
        return FavoriteEntry(date: Date(), hasTrack: hasTrack, favorited: favorited)
    }
}

@available(iOSApplicationExtension 17.0, *)
struct FavoriteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FavoriteWidget", provider: FavoriteProvider()) { entry in
            FavoriteWidgetView(entry: entry)
        }
        .configurationDisplayName("收藏")
        .description("点一下收藏正在播放的歌曲（锁屏 / 桌面圆形按钮）")
        .supportedFamilies([.accessoryCircular])
    }
}

@available(iOSApplicationExtension 17.0, *)
private struct FavoriteWidgetView: View {
    let entry: FavoriteEntry

    private var heart: String { entry.favorited ? "heart.fill" : "heart" }
    private var tint: Color {
        entry.hasTrack
            ? (entry.favorited ? Color(red: 0.95, green: 0.44, blue: 0.40) : Color.primary.opacity(0.85))
            : .secondary
    }

    var body: some View {
        Button(intent: ToggleFavoriteIntent()) {
            ZStack {
                if entry.favorited {
                    Circle()
                        .fill(Color(red: 0.95, green: 0.44, blue: 0.40).opacity(0.22))
                }
                Image(systemName: heart)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .containerBackground(for: .widget) { Color.clear }
    }
}
