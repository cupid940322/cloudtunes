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
    var body: some View {
        TabView {
            AccountsView()
                .tabItem { Label("网盘", systemImage: "cloud.fill") }
            LibraryView()
                .tabItem { Label("播放", systemImage: "music.note") }
        }
    }
}
