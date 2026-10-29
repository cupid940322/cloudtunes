import SwiftUI

/// 底部迷你播放条
struct MiniPlayerBar: View {
    @ObservedObject private var player = PlayerManager.shared
    @State private var showFull = false

    var body: some View {
        if let track = player.currentTrack {
            HStack(spacing: 10) {
                ArtworkThumb(file: track.artworkFile, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.subheadline).lineLimit(1)
                    Text(track.artist ?? "未知艺术家").font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                Button {
                    playNext()
                } label: {
                    Image(systemName: "forward.fill").font(.body)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            .padding(.horizontal, 8)
            .onTapGesture { showFull = true }
            .sheet(isPresented: $showFull) {
                NavigationStack {
                    NowPlayingView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("收起") { showFull = false }
                            }
                        }
                }
            }
        }
    }

    private func playNext() {
        guard let t = player.currentTrack,
              let p = ProviderRegistry.provider(kind: t.providerKind) else { return }
        player.next(provider: p)
    }
}
