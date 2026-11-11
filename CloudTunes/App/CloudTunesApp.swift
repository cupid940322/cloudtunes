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

/// iPad 侧栏条目。分栏模式下左栏列这些，右栏显示对应内容。
enum SidebarItem: Hashable, CaseIterable, Identifiable {
    case home, search, favorites, recent, profile

    var id: Self { self }

    var title: String {
        switch self {
        case .home: return "音乐库"
        case .search: return "搜索"
        case .favorites: return "我喜欢的音乐"
        case .recent: return "最近播放"
        case .profile: return "我的"
        }
    }

    var icon: String {
        switch self {
        case .home: return "music.note.house.fill"
        case .search: return "magnifyingglass"
        case .favorites: return "heart.fill"
        case .recent: return "clock.fill"
        case .profile: return "person.crop.circle.fill"
        }
    }

    static let groups: [(title: String, items: [SidebarItem])] = [
        ("浏览", [.home, .search]),
        ("资料库", [.favorites, .recent]),
        ("设置", [.profile]),
    ]
}

struct RootView: View {
    @ObservedObject private var ui = AppUIState.shared
    @State private var tab: AppTab = .home
    @State private var sidebar: SidebarItem? = .home
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// iPad + 常规宽度（未分屏成窄窗口）→ 用分栏布局
    private var usesSplitLayout: Bool {
        Adaptive.isPad && sizeClass == .regular
    }

    var body: some View {
        Group {
            if usesSplitLayout {
                splitLayout
            } else {
                phoneLayout
            }
        }
        .fullScreenCover(isPresented: $ui.showPlayer) {
            PlayerView()
        }
        .onOpenURL { url in
            // 小组件点击：cloudtunes://player|favorites|recent|shuffle|resume
            WidgetDeepLink.handle(url)
        }
        .task {
            // 冷启动先跟云端对一次账：另一台设备加的歌、改的元数据直接出现
            await SyncService.shared.syncIfStale()
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await SyncService.shared.syncIfStale() }
        }
        .tint(Theme.accent)
    }

    // MARK: - 手机形态（原来的悬浮标签栏）

    private var phoneLayout: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()

            tabContent
                .readableWidth()

            PlayerDock(selection: $tab)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
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
    }

    // MARK: - iPad 形态（侧栏 + 内容区，底部只留迷你播放条）

    private var splitLayout: some View {
        NavigationSplitView {
            List(selection: $sidebar) {
                ForEach(SidebarItem.groups, id: \.title) { group in
                    Section(header: Text(group.title)) {
                        ForEach(group.items) { item in
                            Label(item.title, systemImage: item.icon)
                                .tag(Optional(item))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("汤圆云音盒")
        } detail: {
            ZStack(alignment: .bottom) {
                Theme.background.ignoresSafeArea()

                detailContent
                    .readableWidth()

                PlayerDock(selection: $tab, showsTabBar: false)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch sidebar ?? .home {
        case .home:
            HomeTabView()
        case .search:
            SearchView()
        case .favorites:
            NavigationStack { FavoritesView() }
        case .recent:
            NavigationStack { RecentTracksView() }
        case .profile:
            ProfileView()
        }
    }
}

/// 底部「迷你播放条 + 标签栏」。
/// 单独拆出来，只让它观察 PlayerManager：换歌、暂停时不会把上面三个 Tab 的整棵视图树一起重建。
struct PlayerDock: View {
    @Binding var selection: AppTab
    /// iPad 分栏模式下用侧栏导航，就不再画悬浮标签栏，只留迷你播放条
    var showsTabBar: Bool = true

    @ObservedObject private var player = PlayerManager.shared
    @ObservedObject private var ui = AppUIState.shared

    var body: some View {
        VStack(spacing: 8) {
            if player.currentTrack != nil {
                MiniPlayerBar { ui.showPlayer = true }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showsTabBar {
                CustomTabBar(selection: $selection)
            }
        }
        .readableWidth(600)
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
