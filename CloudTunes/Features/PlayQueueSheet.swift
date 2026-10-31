import SwiftUI

/// 播放队列：查看当前队列、点选跳转
struct PlayQueueSheet: View {
    @ObservedObject private var player = PlayerManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if player.queue.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("播放列表是空的")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(player.queue.indices, id: \.self) { idx in
                                    queueRow(idx: idx, track: player.queue[idx])
                                    if idx < player.queue.count - 1 {
                                        Divider().padding(.leading, 70)
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .scrollIndicators(.hidden)
                        .onAppear {
                            guard player.queue.indices.contains(player.currentIndex) else { return }
                            proxy.scrollTo(player.currentIndex, anchor: .center)
                        }
                    }
                }
            }
            .background(Theme.background)
            .navigationTitle("播放列表 · \(player.queue.count) 首")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func queueRow(idx: Int, track: Track) -> some View {
        let isCurrent = idx == player.currentIndex
        return Button {
            guard let provider = ProviderRegistry.provider(kind: track.providerKind) else { return }
            player.playAt(idx, provider: provider)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    CoverView(file: track.artworkFile, size: 46, corner: 9)
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(.black.opacity(0.42))
                            .frame(width: 46, height: 46)
                        if player.isPlaying {
                            PlayingIndicator(color: .white)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Theme.accent : Color.primary)
                        .lineLimit(1)
                    Text(track.displayArtist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if isCurrent {
                    Text("正在播放")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                } else if let d = track.duration {
                    Text(d.formattedTime)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
