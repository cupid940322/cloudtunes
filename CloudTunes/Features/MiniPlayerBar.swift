import SwiftUI

/// 底部迷你播放条（胶囊 + 进度线）
struct MiniPlayerBar: View {
    var onOpen: () -> Void

    @ObservedObject private var player = PlayerManager.shared

    var body: some View {
        if let track = player.currentTrack {
            Button(action: onOpen) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        ZStack {
                            CoverView(file: track.artworkFile, size: 42, corner: 10)
                            if !player.isPlaying {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.black.opacity(0.35))
                                    .frame(width: 42, height: 42)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(track.displayArtist)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        Button {
                            player.togglePlay()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 34, height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            player.playNext()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.8))
                                .frame(width: 34, height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)

                    ThinProgressBar(value: progress, height: 2.5)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 5)
                        .opacity(player.duration > 0 ? 1 : 0)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
            }
            .buttonStyle(.plain)
        }
    }

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return max(0, min(1, player.currentTime / player.duration))
    }
}
