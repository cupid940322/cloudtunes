import SwiftUI

/// 桌面小组件的快捷入口（cloudtunes:// 深链）。
/// 小组件上的「我喜欢的音乐 / 最近播放 / 随机播放 / 继续播放」按钮
/// 本质是 Link，点击后系统拉起 App 并把 URL 送到 RootView.onOpenURL，由这里统一分发。
@MainActor
enum WidgetDeepLink {

    static func handle(_ url: URL) {
        guard url.scheme == "cloudtunes" else { return }
        switch url.host ?? "open" {

        case "player", "open":
            AppUIState.shared.showPlayer = true

        case "favorites":
            play(LibraryStore.shared.favoriteTracks, shuffled: false)

        case "recent":
            play(LibraryStore.shared.recentTracks, shuffled: false)

        case "shuffle":
            play(LibraryStore.shared.allTracks(), shuffled: true)

        case "resume":
            // 有上次的播放列表就整张恢复（接着上次的进度听），
            // 否则退而求其次播最近播放
            if PlayerManager.shared.savedSession != nil {
                PlayerManager.shared.resumeSavedSession()
            } else {
                play(LibraryStore.shared.recentTracks, shuffled: false)
            }

        default:
            break
        }
    }

    /// 与 FavoritesView / LibraryHomeView 相同的播放逻辑：整张列表进队列，跨网盘按曲目自身取直链
    private static func play(_ items: [TrackRef], shuffled: Bool) {
        guard !items.isEmpty else { return }
        let tracks = items.map { $0.track.toTrack(kind: $0.library.providerKind) }
        guard let provider = ProviderRegistry.provider(kind: items[0].library.providerKind) else { return }
        PlayerManager.shared.setShuffled(shuffled)
        let start = shuffled ? Int.random(in: 0..<tracks.count) : 0
        PlayerManager.shared.play(tracks: tracks, at: start, provider: provider)
    }
}
