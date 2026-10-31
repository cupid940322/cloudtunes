import SwiftUI

// MARK: - 首页

struct HomeTabView: View {
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var player = PlayerManager.shared

    @State private var showProviderPicker = false
    @State private var pickingKind: CloudKind?
    @State private var renameTarget: MusicLibrary?
    @State private var renameText = ""

    private var totalTracks: Int { store.libraries.reduce(0) { $0 + $1.tracks.count } }
    private var recentlyAdded: [TrackRef] {
        Array(store.allTracks()
            .sorted { ($0.track.addedAt ?? .distantPast) > ($1.track.addedAt ?? .distantPast) }
            .prefix(12))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                ScrollView {
                    VStack(spacing: 24) {
                        continueCard
                        librariesSection
                        if !recentlyAdded.isEmpty { recentlyAddedSection }
                        if !store.recentTracks.isEmpty { recentSection }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 140)
                }
            }
            .background(Theme.background)
            .scrollIndicators(.hidden)
            .confirmationDialog("选择网盘", isPresented: $showProviderPicker) {
                ForEach(CloudKind.allCases) { kind in
                    if ProviderRegistry.provider(kind: kind)?.isSignedIn == true {
                        Button(kind.rawValue) { pickingKind = kind }
                    }
                }
                Button("先去登录网盘") { pickingKind = nil }
            } message: {
                Text("从已登录的网盘里挑选文件夹")
            }
            .sheet(item: $pickingKind) { kind in
                FolderPickerView(kind: kind) { folder, includeSub in
                    Task {
                        await store.addLibrary(name: folder.name,
                                               providerKind: kind,
                                               folder: folder,
                                               includeSubfolders: includeSub)
                    }
                }
            }
            .alert("重命名音乐库", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("名称", text: $renameText)
                Button("取消", role: .cancel) { renameTarget = nil }
                Button("保存") {
                    if let t = renameTarget { store.renameLibrary(id: t.id, to: renameText) }
                    renameTarget = nil
                }
            }
        }
    }

    // MARK: 顶部标题

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("汤圆云音盒")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("\(totalTracks) 首音乐 · \(store.libraries.count) 个音乐库 · \(store.favoriteIDs.count) 首收藏")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showProviderPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Theme.accentGradient, in: Circle())
                    .shadow(color: Theme.accent.opacity(0.35), radius: 10, y: 4)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
    }

    // MARK: 继续播放

    @ViewBuilder
    private var continueCard: some View {
        if let now = player.currentTrack {
            NowPlayingHomeCard(track: now)
        } else if let item = store.recentTracks.first {
            Button {
                play(ref: item)
            } label: {
                HStack(spacing: 14) {
                    CoverView(file: item.track.artworkFile, size: 64, corner: 14, showsShadow: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("继续播放")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(item.track.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(item.track.displayArtist)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 40)
                        .background(.white, in: Circle())
                }
                .padding(14)
                .background {
                    LinearGradient(colors: [Color(red: 0.32, green: 0.26, blue: 0.42),
                                            Color(red: 0.20, green: 0.20, blue: 0.30)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay {
                            if let img = ArtworkCache.shared.image(named: item.track.artworkFile, target: 300) {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .blur(radius: 40)
                                    .opacity(0.55)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.pagePadding)
        }
    }

    // MARK: 我的音乐库

    private var librariesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "我的音乐库",
                          subtitle: store.libraries.isEmpty ? nil : "点开查看歌曲、专辑、艺术家",
                          actionTitle: store.libraries.isEmpty ? nil : "添加",
                          action: { showProviderPicker = true })

            if store.libraries.isEmpty {
                VStack(spacing: 6) {
                    EmptyStateView(icon: "square.stack.3d.up",
                                   title: "还没有音乐库",
                                   message: "选一个云盘文件夹，自动递归扫描并刮削封面、专辑、艺术家",
                                   actionTitle: "添加音乐库",
                                   action: { showProviderPicker = true })
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .padding(.horizontal, Theme.pagePadding)
            } else {
                VStack(spacing: 10) {
                    ForEach(store.libraries) { lib in
                        NavigationLink {
                            LibraryDetailView(libraryID: lib.id)
                        } label: {
                            LibraryCard(library: lib, progress: store.progress[lib.id])
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                renameText = lib.name
                                renameTarget = lib
                            } label: { Label("重命名", systemImage: "pencil") }
                            Button {
                                Task { await store.rescan(libraryID: lib.id) }
                            } label: { Label("扫描新文件", systemImage: "arrow.clockwise") }
                            Button(role: .destructive) {
                                store.removeLibrary(id: lib.id)
                            } label: { Label("删除音乐库", systemImage: "trash") }
                        }
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
            }
        }
    }

    // MARK: 最近添加

    private var recentlyAddedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "最近添加")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(recentlyAdded) { item in
                        Button {
                            play(ref: item)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverView(file: item.track.artworkFile, size: 124, corner: 14, showsShadow: true)
                                Text(item.track.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(width: 124, alignment: .leading)
                                Text(item.track.displayArtist)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(width: 124, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
            }
        }
    }

    // MARK: 最近播放

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "最近播放")
            VStack(spacing: 0) {
                ForEach(store.recentTracks.prefix(5).indices, id: \.self) { idx in
                            let item = store.recentTracks.prefix(5)[idx]
                    SongRow(track: item.track, library: item.library) {
                        play(ref: item)
                    }
                    if idx < min(4, store.recentTracks.count - 1) {
                        Divider().padding(.leading, 74)
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .padding(.horizontal, Theme.pagePadding)
        }
    }

    private func play(ref: TrackRef) {
        guard let provider = ProviderRegistry.provider(kind: ref.library.providerKind) else { return }
        PlayerManager.shared.play(tracks: [ref.track.toTrack(kind: ref.library.providerKind)],
                                  at: 0, provider: provider)
    }
}

// MARK: - 首页正在播放卡片（实时同步）

/// 首页顶部的「继续播放」卡片：有歌在播时实时显示当前曲目与进度
struct NowPlayingHomeCard: View {
    let track: Track
    @ObservedObject private var player = PlayerManager.shared

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return max(0, min(1, player.currentTime / player.duration))
    }

    var body: some View {
        Button {
            AppUIState.shared.showPlayer = true
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    ZStack {
                        CoverView(file: track.artworkFile, size: 64, corner: 14, showsShadow: true)
                        if !player.isPlaying {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.black.opacity(0.35))
                                .frame(width: 64, height: 64)
                            Image(systemName: "pause.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(player.isPlaying ? Theme.accent : Color.white.opacity(0.6))
                                .frame(width: 6, height: 6)
                            Text(player.isPlaying ? "正在播放" : "已暂停")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Text(track.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(track.displayArtist)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    Spacer()

                    Button {
                        player.togglePlay()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 40, height: 40)
                            .background(.white, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, player.duration > 0 ? 10 : 14)

                if player.duration > 0 {
                    VStack(alignment: .leading, spacing: 5) {
                        ThinProgressBar(value: progress, height: 3)
                        HStack {
                            Text(player.currentTime.formattedTime)
                            Spacer()
                            Text(player.duration.formattedTime)
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }
            .background {
                LinearGradient(colors: [Color(red: 0.32, green: 0.26, blue: 0.42),
                                        Color(red: 0.20, green: 0.20, blue: 0.30)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        if let img = ArtworkCache.shared.image(named: track.artworkFile, target: 300) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .blur(radius: 40)
                                .opacity(0.55)
                                .animation(.easeInOut(duration: 0.35), value: track.id)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.25), value: track.id)
        .padding(.horizontal, Theme.pagePadding)
    }
}

// MARK: - 音乐库卡片

struct LibraryCard: View {
    let library: MusicLibrary
    var progress: ScanProgress?

    var body: some View {
        HStack(spacing: 14) {
            CoverView(file: library.coverArtwork, size: 62, corner: 14, showsShadow: true)

            VStack(alignment: .leading, spacing: 4) {
                Text(library.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(library.tracks.count) 首 · \(library.albumCount) 张专辑 · \(library.artistCount) 位艺术家")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let progress {
                    VStack(alignment: .leading, spacing: 4) {
                        ThinProgressBar(value: progress.fraction, height: 3)
                        Text(progress.totalToScrape > 0
                             ? "\(progress.phase) · \(progress.scrapedTracks)/\(progress.totalToScrape)"
                             : progress.phase)
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "cloud.fill").font(.system(size: 9))
                        Text(library.providerKind.rawValue).font(.caption2)
                    }
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.quaternary)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
    }
}

// MARK: - 库详情

struct LibraryDetailView: View {
    let libraryID: String
    @ObservedObject private var store = LibraryStore.shared
    @State private var tab = 0
    @State private var confirmRescrape = false

    private var lib: MusicLibrary? { store.library(id: libraryID) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                    if let lib {
                        header(lib)
                        if let p = store.progress[libraryID] {
                            progressCard(p)
                        }
                        switch tab {
                        case 0: songList(lib)
                        case 1: albumGrid(lib)
                        default: artistList(lib)
                        }
                    } else {
                        EmptyStateView(icon: "questionmark.folder", title: "音乐库不存在", message: "可能已被删除")
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 140)
            }
            .background(Theme.background)
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) {
                SegmentedPills(selection: $tab, titles: ["歌曲", "专辑", "艺术家"])
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.vertical, 8)
                    .background(Theme.background)
            }
        .navigationTitle(lib?.name ?? "音乐库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        Task { await store.rescan(libraryID: libraryID) }
                    } label: { Label("扫描新文件", systemImage: "arrow.clockwise") }
                    Button {
                        confirmRescrape = true
                    } label: { Label("重新刮削全部（修正错误）", systemImage: "wand.and.stars") }
                    Divider()
                    Button(role: .destructive) {
                        store.removeLibrary(id: libraryID)
                    } label: { Label("删除音乐库", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("重新刮削会按文件名重新匹配全部歌曲，可能耗时较久", isPresented: $confirmRescrape) {
            Button("开始重新刮削", role: .destructive) {
                Task { await store.rescrapeAll(libraryID: libraryID) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func header(_ lib: MusicLibrary) -> some View {
        VStack(spacing: 14) {
            HStack(alignment: .bottom, spacing: 16) {
                CoverView(file: lib.coverArtwork, size: 110, corner: 16, showsShadow: true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(lib.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                    Text("\(lib.tracks.count) 首 · \(lib.albumCount) 张专辑")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(lib.providerKind.rawValue)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.hairline, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.pagePadding)

            HStack(spacing: 10) {
                Button {
                    playAll(shuffle: false)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    playAll(shuffle: true)
                } label: {
                    Label("随机", systemImage: "shuffle")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 108)
                        .padding(.vertical, 11)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(Theme.hairline, lineWidth: 0.5)
                        )
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.pagePadding)
        }
    }

    private func progressCard(_ p: ScanProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text(p.totalToScrape > 0 ? "刮削 \(p.scrapedTracks)/\(p.totalToScrape)" : p.phase)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ThinProgressBar(value: p.fraction, height: 3)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, Theme.pagePadding)
    }

    private func songList(_ lib: MusicLibrary) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(lib.tracks.indices, id: \.self) { idx in
                            let t = lib.tracks[idx]
                SongRow(track: t, library: lib) {
                    play(lib: lib, tracks: lib.tracks, startAt: t.id)
                }
                if idx < lib.tracks.count - 1 {
                    Divider().padding(.leading, 74)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .padding(.horizontal, Theme.pagePadding)
    }

    private func albumGrid(_ lib: MusicLibrary) -> some View {
        let albums = lib.albums()
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                         spacing: 18) {
            ForEach(albums) { album in
                NavigationLink {
                    AlbumDetailView(libraryID: libraryID, albumID: album.id)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { geo in
                            CoverView(file: album.artwork, size: geo.size.width, corner: 14, showsShadow: true)
                        }
                        .aspectRatio(1, contentMode: .fit)
                        Text(album.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(album.artist ?? "未知艺术家")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
    }

    private func artistList(_ lib: MusicLibrary) -> some View {
        let artists = lib.artists()
        return VStack(spacing: 0) {
            ForEach(artists.indices, id: \.self) { idx in
                let artist = artists[idx]
                NavigationLink {
                    ArtistDetailView(libraryID: libraryID, artistName: artist.name)
                } label: {
                    HStack(spacing: 12) {
                        CoverView(file: artist.artwork, size: 48, corner: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            Text("\(artist.tracks.count) 首 · \(artist.albumCount) 张专辑")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.quaternary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                if idx < artists.count - 1 {
                    Divider().padding(.leading, 74)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .padding(.horizontal, Theme.pagePadding)
    }

    private func playAll(shuffle: Bool) {
        guard let lib,
              let provider = ProviderRegistry.provider(kind: lib.providerKind),
              !lib.tracks.isEmpty else { return }
        var list = lib.tracks.map { $0.toTrack(kind: lib.providerKind) }
        if shuffle { list.shuffle() }
        // 先设模式再起播：play() 会依据当前模式决定是否把「当前曲」放到队首
        PlayerManager.shared.setShuffled(shuffle)
        PlayerManager.shared.play(tracks: list, at: 0, provider: provider)
    }

    private func play(lib: MusicLibrary, tracks: [LibraryTrack], startAt id: String) {
        guard let provider = ProviderRegistry.provider(kind: lib.providerKind) else { return }
        let list = tracks.map { $0.toTrack(kind: lib.providerKind) }
        let idx = list.firstIndex { $0.id == id } ?? 0
        PlayerManager.shared.play(tracks: list, at: idx, provider: provider)
    }
}

// MARK: - 分段控件

struct SegmentedPills: View {
    @Binding var selection: Int
    let titles: [String]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(titles.indices, id: \.self) { i in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selection = i }
                } label: {
                    Text(titles[i])
                        .font(.subheadline.weight(selection == i ? .semibold : .regular))
                        .foregroundStyle(selection == i ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if selection == i {
                                Capsule()
                                    .fill(Theme.surface)
                                    .shadow(color: .black.opacity(0.07), radius: 4, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.hairline.opacity(0.5), in: Capsule())
    }
}

// MARK: - 歌曲行

struct SongRow: View {
    let track: LibraryTrack
    let library: MusicLibrary
    var onPlay: () -> Void

    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var player = PlayerManager.shared
    @State private var showEdit = false

    private var isCurrent: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    ZStack {
                        CoverView(file: track.artworkFile, size: 50, corner: 10)
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.black.opacity(0.42))
                                .frame(width: 50, height: 50)
                            if player.isPlaying {
                                PlayingIndicator(color: .white)
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isCurrent ? Theme.accent : Color.primary)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(track.displayArtist)
                                .lineLimit(1)
                            if track.needsReview {
                                Text("待确认")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 6)

                    if let d = track.duration, !isCurrent {
                        Text(d.formattedTime)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    store.toggleFavorite(track.id)
                } label: {
                    Label(store.isFavorite(track.id) ? "取消收藏" : "收藏",
                          systemImage: store.isFavorite(track.id) ? "heart.fill" : "heart")
                }
                Button {
                    showEdit = true
                } label: { Label("编辑歌曲信息", systemImage: "pencil") }
                Button {
                    Task { await store.rescrapeTrack(libraryID: library.id, trackID: track.id) }
                } label: { Label("重新刮削这首", systemImage: "arrow.triangle.2.circlepath") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 9)
        .sheet(isPresented: $showEdit) {
            EditTrackSheet(libraryID: library.id, track: track)
        }
    }
}

// MARK: - 专辑详情

struct AlbumDetailView: View {
    let libraryID: String
    let albumID: String
    @ObservedObject private var store = LibraryStore.shared

    private var lib: MusicLibrary? { store.library(id: libraryID) }
    private var album: AlbumGroup? { lib?.albums().first { $0.id == albumID } }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 12) {
                    CoverView(file: album?.artwork, size: 170, corner: 18, showsShadow: true)
                    VStack(spacing: 4) {
                        Text(album?.name ?? "未知专辑").font(.title3.weight(.bold))
                        Text(album?.artist ?? "未知艺术家").font(.subheadline).foregroundStyle(.secondary)
                        Text("\(album?.tracks.count ?? 0) 首 · \(Int((album?.duration ?? 0) / 60)) 分钟")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 10) {
                    Button { playAll() } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    Button { playShuffle() } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 52)
                            .padding(.vertical, 11)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Theme.pagePadding)

                if let lib, let album {
                    LazyVStack(spacing: 0) {
                        ForEach(album.tracks.indices, id: \.self) { idx in
                            let t = album.tracks[idx]
                            SongRow(track: t, library: lib) { play(startAt: t.id) }
                            if idx < album.tracks.count - 1 {
                                Divider().padding(.leading, 74)
                            }
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .padding(.horizontal, Theme.pagePadding)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 140)
        }
        .background(Theme.background)
        .scrollIndicators(.hidden)
        .navigationTitle(album?.name ?? "专辑")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func playAll() { play(startAt: album?.tracks.first?.id) }
    private func playShuffle() { play(startAt: album?.tracks.randomElement()?.id) }

    private func play(startAt id: String?) {
        guard let lib, let album,
              let provider = ProviderRegistry.provider(kind: lib.providerKind) else { return }
        let list = album.tracks.map { $0.toTrack(kind: lib.providerKind) }
        let idx = list.firstIndex { $0.id == id } ?? 0
        PlayerManager.shared.play(tracks: list, at: idx, provider: provider)
    }
}

// MARK: - 艺术家详情

struct ArtistDetailView: View {
    let libraryID: String
    let artistName: String
    @ObservedObject private var store = LibraryStore.shared

    private var lib: MusicLibrary? { store.library(id: libraryID) }
    private var artist: ArtistGroup? { lib?.artists().first { $0.name == artistName } }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 12) {
                    CoverView(file: artist?.artwork, size: 120, corner: 60, showsShadow: true)
                    VStack(spacing: 4) {
                        Text(artistName).font(.title3.weight(.bold))
                        Text("\(artist?.tracks.count ?? 0) 首 · \(artist?.albumCount ?? 0) 张专辑")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)

                Button { playAll() } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Theme.pagePadding)

                if let lib, let artist {
                    LazyVStack(spacing: 0) {
                        ForEach(artist.tracks.indices, id: \.self) { idx in
                            let t = artist.tracks[idx]
                            SongRow(track: t, library: lib) { play(startAt: t.id) }
                            if idx < artist.tracks.count - 1 {
                                Divider().padding(.leading, 74)
                            }
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .padding(.horizontal, Theme.pagePadding)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 140)
        }
        .background(Theme.background)
        .scrollIndicators(.hidden)
        .navigationTitle(artistName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func playAll() {
        guard let lib, let artist,
              let provider = ProviderRegistry.provider(kind: lib.providerKind) else { return }
        PlayerManager.shared.play(tracks: artist.tracks.map { $0.toTrack(kind: lib.providerKind) },
                                  at: 0, provider: provider)
    }

    private func play(startAt id: String) {
        guard let lib, let artist,
              let provider = ProviderRegistry.provider(kind: lib.providerKind) else { return }
        let list = artist.tracks.map { $0.toTrack(kind: lib.providerKind) }
        let idx = list.firstIndex { $0.id == id } ?? 0
        PlayerManager.shared.play(tracks: list, at: idx, provider: provider)
    }
}

// MARK: - 编辑歌曲信息

struct EditTrackSheet: View {
    let libraryID: String
    let track: LibraryTrack

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LibraryStore.shared

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var candidates: [MusicSearchService.SongInfo] = []
    @State private var searching = false
    @State private var message = ""

    init(libraryID: String, track: LibraryTrack) {
        self.libraryID = libraryID
        self.track = track
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist ?? "")
        _album = State(initialValue: track.album ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    HStack(spacing: 14) {
                        CoverView(file: track.artworkFile, size: 76, corner: 14, showsShadow: true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.fileName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if let src = track.metaSource {
                                Text(sourceLabel(src) + (track.confidence.map { String(format: " · 置信度 %.0f%%", $0 * 100) } ?? ""))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))

                    VStack(spacing: 0) {
                        field("歌曲名", text: $title)
                        Divider().padding(.leading, 14)
                        field("艺术家", text: $artist)
                        Divider().padding(.leading, 14)
                        field("专辑", text: $album)
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))

                    Button {
                        searchOnline()
                    } label: {
                        HStack {
                            if searching { ProgressView().scaleEffect(0.8).tint(.white) }
                            else { Image(systemName: "wand.and.stars") }
                            Text(searching ? "正在搜索…" : "在线重新匹配")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(searching)

                    if !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }

                    if !candidates.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("选择正确的版本").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            VStack(spacing: 0) {
                                ForEach(candidates.indices, id: \.self) { idx in
                            let c = candidates[idx]
                                    Button {
                                        apply(c)
                                    } label: {
                                        HStack(spacing: 10) {
                                            AsyncImage(url: URL(string: c.coverURL ?? "")) { phase in
                                                if let img = phase.image {
                                                    img.resizable().scaledToFill()
                                                } else {
                                                    Theme.hairline
                                                }
                                            }
                                            .frame(width: 44, height: 44)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(c.title ?? "—").font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                                                Text("\(c.artist ?? "—") · \(c.album ?? "—")")
                                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer()
                                            Image(systemName: "arrow.down.circle")
                                                .foregroundStyle(Theme.accent)
                                        }
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                    }
                                    .buttonStyle(.plain)
                                    if idx < candidates.count - 1 {
                                        Divider().padding(.leading, 66)
                                    }
                                }
                            }
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        }
                    }
                }
                .padding(Theme.pagePadding)
            }
            .background(Theme.background)
            .navigationTitle("歌曲信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.updateMeta(libraryID: libraryID, trackID: track.id,
                                         title: title, artist: artist, album: album)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.subheadline).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            TextField(label, text: text).font(.subheadline)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func sourceLabel(_ src: String) -> String {
        switch src {
        case "embedded": return "来源：文件内嵌标签"
        case "online": return "来源：在线匹配"
        case "manual": return "来源：手动修正"
        default: return "来源：文件名解析"
        }
    }

    private func searchOnline() {
        searching = true
        message = ""
        Task {
            let list = await MetadataScraper.searchCandidates(title: title,
                                                             artist: artist.isEmpty ? nil : artist)
            await MainActor.run {
                candidates = list
                searching = false
                if list.isEmpty { message = "没有找到匹配结果，试试把歌名改短一些" }
            }
        }
    }

    private func apply(_ info: MusicSearchService.SongInfo) {
        Task {
            await store.applyMatch(libraryID: libraryID, trackID: track.id, info: info)
            await MainActor.run {
                if let t = info.title { title = t }
                if let a = info.artist { artist = a }
                if let al = info.album { album = al }
                message = "已应用，封面同步更新"
            }
        }
    }
}
