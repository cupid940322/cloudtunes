import SwiftUI

@main
struct CloudTunesApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

enum AppTab: Int, CaseIterable, Identifiable {
    case home, search, profile

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: return "音乐"
        case .search: return "搜索"
        case .profile: return "我的"
        }
    }

    var icon: String {
        switch self {
        case .home: return "music.note.house"
        case .search: return "magnifyingglass"
        case .profile: return "person.crop.circle"
        }
    }

    var selectedIcon: String {
        switch self {
        case .home: return "music.note.house.fill"
        case .search: return "magnifyingglass"
        case .profile: return "person.crop.circle.fill"
        }
    }
}

/// 全局 UI 状态（供任意页面打开播放页）
@MainActor
final class AppUIState: ObservableObject {
    static let shared = AppUIState()
    @Published var showPlayer = false
}

struct RootView: View {
    @ObservedObject private var ui = AppUIState.shared
    @State private var tab: AppTab = .home

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()

            ZStack {
                HomeTabView()
                    .opacity(tab == .home ? 1 : 0)
                    .allowsHitTesting(tab == .home)
                SearchView()
                    .opacity(tab == .search ? 1 : 0)
                    .allowsHitTesting(tab == .search)
                ProfileView()
                    .opacity(tab == .profile ? 1 : 0)
                    .allowsHitTesting(tab == .profile)
            }

            PlayerDock(selection: $tab)
        }
        .fullScreenCover(isPresented: $ui.showPlayer) {
            PlayerView()
        }
        .onOpenURL { url in
            // 小组件点击进入播放页
            if url.scheme == "cloudtunes" {
                ui.showPlayer = true
            }
        }
        .tint(Theme.accent)
    }
}

/// 底部「迷你播放条 + 标签栏」。
/// 单独拆出来，只让它观察 PlayerManager：换歌、暂停时不会把上面三个 Tab 的整棵视图树一起重建。
struct PlayerDock: View {
    @Binding var selection: AppTab

    @ObservedObject private var player = PlayerManager.shared
    @ObservedObject private var ui = AppUIState.shared

    var body: some View {
        VStack(spacing: 8) {
            if player.currentTrack != nil {
                MiniPlayerBar { ui.showPlayer = true }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            CustomTabBar(selection: $selection)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        // 封闭式底栏：不透明背景一直铺到屏幕最底，
        // 主界面内容从下面滚过时被完全挡住
        .background(
            Theme.background
                .overlay(alignment: .top) { Theme.hairline.frame(height: 0.5) }
                .ignoresSafeArea(edges: .bottom)
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: player.currentTrack?.id)
    }
}

/// 悬浮胶囊标签栏
struct CustomTabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { item in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        selection = item
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selection == item ? item.selectedIcon : item.icon)
                            .font(.system(size: 15, weight: .semibold))
                        if selection == item {
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(selection == item ? Color.white : Color.secondary)
                    .padding(.horizontal, selection == item ? 16 : 14)
                    .padding(.vertical, 10)
                    .background {
                        if selection == item {
                            Capsule().fill(Theme.accentGradient)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
    }
}
