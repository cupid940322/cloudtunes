import SwiftUI

@main
struct CloudTunesApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @ObservedObject private var player = PlayerManager.shared

    var body: some View {
        TabView {
            LibraryHomeView()
                .tabItem { Label("音乐库", systemImage: "square.stack.fill") }
            BrowseTabView()
                .tabItem { Label("浏览", systemImage: "folder.fill") }
            AccountsView()
                .tabItem { Label("网盘", systemImage: "cloud.fill") }
        }
        .overlay(alignment: .bottom) {
            if player.currentTrack != nil {
                MiniPlayerBar()
                    .padding(.bottom, 52)
            }
        }
    }
}

/// 浏览页：已登录网盘的入口
struct BrowseTabView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(CloudKind.allCases) { kind in
                        if ProviderRegistry.provider(kind: kind)?.isSignedIn == true {
                            NavigationLink {
                                FileBrowserView(kind: kind)
                            } label: {
                                Label(kind.rawValue, systemImage: kind.icon)
                            }
                        }
                    }
                } footer: {
                    Text("在「网盘」页登录后，这里会显示可浏览的云盘")
                }
            }
            .navigationTitle("浏览")
        }
    }
}
