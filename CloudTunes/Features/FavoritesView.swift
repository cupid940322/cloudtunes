import SwiftUI

/// 我的收藏：完整列表 + 播放全部 / 随机播放。
/// 收藏可以跨多个网盘，播放时由 PlayerManager 按每首歌自己的网盘取直链。
struct FavoritesView: View {
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var player = PlayerManager.shared
    @State private var query = ""

    private var allItems: [TrackRef] { store.favoriteTracks }

    private var items: [TrackRef] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allItems }
        return allItems.filter { item in
            item.track.title.lowercased().contains(q)
                || (item.track.artist?.lowercased().contains(q) ?? false)
                || (item.track.album?.lowercased().contains(q) ?? false)
        }
    }

    private var totalDuration: Double {
        allItems.reduce(0) { $0 + ($1.track.duration ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                if items.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 140)
        }
        .background(Theme.background)
        .scrollIndicators(.hidden)
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索收藏的歌曲")
    }

    // MARK: 顶部信息

    private var header: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.accentGradient)
                        .frame(width: 92, height: 92)
                    if let cover = allItems.first?.track.artworkFile {
                        CoverView(file: cover, size: 92, corner: 18, showsShadow: true)
                    } else {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("我的收藏").font(.title3.weight(.bold))
                    Text("\(allItems.count) 首" + (totalDuration > 0 ? " · \(durationText)" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("来自 \(providerCount) 个网盘")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.pagePadding)

            HStack(spacing: 10) {
                Button { playAll(shuffled: false) } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(allItems.isEmpty)

                Button { playAll(shuffled: true) } label: {
                    Label("随机播放", systemImage: "shuffle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(allItems.isEmpty)
            }
            .padding(.horizontal, Theme.pagePadding)
        }
    }

    private var durationText: String {
        let seconds = Int(totalDuration)
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h) 小时 \(m) 分钟" }
        return "\(max(m, 1)) 分钟"
    }

    private var providerCount: Int {
        Set(allItems.map { $0.library.providerKindRaw }).count
    }

    // MARK: 列表

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { idx in
                let item = items[idx]
                SongRow(track: item.track, library: item.library) {
                    play(at: idx)
                }
                if idx < items.count - 1 {
                    Divider().padding(.leading, 74)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .padding(.horizontal, Theme.pagePadding)
    }

    private var emptyState: some View {
        EmptyStateView(icon: "heart",
                       title: query.isEmpty ? "还没有收藏" : "没找到「\(query)」",
                       message: query.isEmpty
                        ? "在歌曲右侧的 ⋯ 菜单里，或播放页点小心形，就能把歌加到收藏"
                        : "换个关键词试试")
    }

    // MARK: 播放

    private func play(at index: Int) {
        guard items.indices.contains(index) else { return }
        let tracks = items.map { $0.track.toTrack(kind: $0.library.providerKind) }
        guard let provider = ProviderRegistry.provider(kind: items[index].library.providerKind) else { return }
        player.play(tracks: tracks, at: index, provider: provider)
    }

    private func playAll(shuffled: Bool) {
        guard !items.isEmpty else { return }
        let tracks = items.map { $0.track.toTrack(kind: $0.library.providerKind) }
        guard let provider = ProviderRegistry.provider(kind: items[0].library.providerKind) else { return }
        player.setShuffled(shuffled)
        let start = shuffled ? Int.random(in: 0..<tracks.count) : 0
        player.play(tracks: tracks, at: start, provider: provider)
    }
}
