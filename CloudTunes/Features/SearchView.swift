import SwiftUI

/// 搜索页：全库搜歌曲 / 专辑 / 艺术家
struct SearchView: View {
    @ObservedObject private var store = LibraryStore.shared
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [TrackRef] { store.search(query) }

    private var matchedAlbums: [AlbumGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return store.libraries.flatMap { $0.albums() }
            .filter { $0.name.lowercased().contains(q) || ($0.artist?.lowercased().contains(q) ?? false) }
            .prefix(6).map { $0 }
    }

    private var matchedArtists: [ArtistGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return store.libraries.flatMap { $0.artists() }
            .filter { $0.name.lowercased().contains(q) }
            .prefix(6).map { $0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    searchField

                    if query.isEmpty {
                        browseShortcuts
                        if !store.recentTracks.isEmpty { recentSection }
                        if !store.favoriteTracks.isEmpty { favoriteSection }
                    } else if results.isEmpty && matchedAlbums.isEmpty && matchedArtists.isEmpty {
                        EmptyStateView(icon: "magnifyingglass",
                                       title: "没有找到「\(query)」",
                                       message: "试试搜索歌手名、歌曲名或专辑名")
                    } else {
                        if !matchedArtists.isEmpty { artistSection }
                        if !matchedAlbums.isEmpty { albumSection }
                        if !results.isEmpty { songSection }
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 140)
            }
            .background(Theme.background)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private var searchField: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("搜索").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("在 \(store.allTracks().count) 首歌里查找").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, Theme.pagePadding)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("歌曲、歌手、专辑", text: $query)
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
            .padding(.horizontal, Theme.pagePadding)
        }
    }

    private var browseShortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "快捷入口")
            HStack(spacing: 10) {
                shortcut("收藏", "\(store.favoriteIDs.count) 首", "heart.fill", [Color(red: 0.98, green: 0.42, blue: 0.44),
                                                                          Color(red: 0.99, green: 0.58, blue: 0.42)])
                shortcut("最近播放", "\(store.recentIDs.count) 首", "clock.fill", [Color(red: 0.42, green: 0.55, blue: 0.98),
                                                                          Color(red: 0.55, green: 0.45, blue: 0.95)])
                shortcut("音乐库", "\(store.libraries.count) 个", "square.stack.fill", [Color(red: 0.30, green: 0.75, blue: 0.62),
                                                                          Color(red: 0.28, green: 0.62, blue: 0.80)])
            }
            .padding(.horizontal, Theme.pagePadding)
        }
    }

    private func shortcut(_ title: String, _ subtitle: String, _ icon: String, _ colors: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            Spacer(minLength: 12)
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.white)
            Text(subtitle).font(.caption2).foregroundStyle(.white.opacity(0.8))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 92)
        .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var songSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "歌曲", subtitle: "\(results.count) 个结果")
            VStack(spacing: 0) {
                ForEach(results.indices, id: \.self) { idx in
                            let item = results[idx]
                    SongRow(track: item.track, library: item.library) {
                        play(item)
                    }
                    if idx < results.count - 1 {
                        Divider().padding(.leading, 74)
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .padding(.horizontal, Theme.pagePadding)
        }
    }

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "专辑")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(matchedAlbums) { album in
                        VStack(alignment: .leading, spacing: 5) {
                            CoverView(file: album.artwork, size: 108, corner: 12, showsShadow: true)
                            Text(album.name).font(.caption).lineLimit(1).frame(width: 108, alignment: .leading)
                            Text(album.artist ?? "未知").font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).frame(width: 108, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
            }
        }
    }

    private var artistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "艺术家")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(matchedArtists) { artist in
                        VStack(spacing: 6) {
                            CoverView(file: artist.artwork, size: 82, corner: 41, showsShadow: true)
                            Text(artist.name).font(.caption).lineLimit(1).frame(width: 82)
                        }
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "最近播放")
            VStack(spacing: 0) {
                ForEach(store.recentTracks.prefix(4).indices, id: \.self) { idx in
                            let item = store.recentTracks.prefix(4)[idx]
                    SongRow(track: item.track, library: item.library) { play(item) }
                    if idx < min(3, store.recentTracks.count - 1) {
                        Divider().padding(.leading, 74)
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .padding(.horizontal, Theme.pagePadding)
        }
    }

    private var favoriteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "我的收藏", subtitle: "\(store.favoriteIDs.count) 首")
            VStack(spacing: 0) {
                ForEach(store.favoriteTracks.prefix(4).indices, id: \.self) { idx in
                            let item = store.favoriteTracks.prefix(4)[idx]
                    SongRow(track: item.track, library: item.library) { play(item) }
                    if idx < min(3, store.favoriteTracks.count - 1) {
                        Divider().padding(.leading, 74)
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .padding(.horizontal, Theme.pagePadding)
        }
    }

    private func play(_ item: TrackRef) {
        guard let provider = ProviderRegistry.provider(kind: item.library.providerKind) else { return }
        let all = results.isEmpty ? store.search(item.track.title) : results
        let list = all.map { $0.track.toTrack(kind: $0.library.providerKind) }
        let idx = list.firstIndex { $0.id == item.id } ?? 0
        PlayerManager.shared.play(tracks: list, at: idx, provider: provider)
    }
}
