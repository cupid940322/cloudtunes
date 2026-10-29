import SwiftUI

/// 音乐库首页：库列表 + 新建
struct LibraryHomeView: View {
    @ObservedObject private var store = LibraryStore.shared
    @State private var showProviderPicker = false
    @State private var pickingKind: CloudKind?
    @State private var pendingLibraryName = ""

    var body: some View {
        NavigationStack {
            List {
                if store.libraries.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 40)).foregroundColor(.secondary)
                            Text("还没有音乐库").font(.headline)
                            Text("选择云盘里的一个文件夹，自动扫描并刮削成音乐库")
                                .font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                }
                ForEach(store.libraries) { lib in
                    NavigationLink {
                        LibraryDetailView(libraryID: lib.id)
                    } label: {
                        libraryRow(lib)
                    }
                }
                .onDelete { idx in
                    idx.map { store.libraries[$0].id }.forEach { store.removeLibrary(id: $0) }
                }
                Section {
                    Button {
                        showProviderPicker = true
                    } label: {
                        Label("添加音乐库", systemImage: "plus.circle.fill")
                    }
                }
            }
            .navigationTitle("音乐库")
            .confirmationDialog("选择网盘", isPresented: $showProviderPicker) {
                ForEach(CloudKind.allCases) { kind in
                    if ProviderRegistry.provider(kind: kind)?.isSignedIn == true {
                        Button(kind.rawValue) { pickingKind = kind }
                    }
                }
            } message: {
                Text("从已登录的网盘中挑选文件夹")
            }
            .sheet(item: $pickingKind) { kind in
                FolderPickerView(kind: kind) { folder in
                    Task {
                        await LibraryStore.shared.addLibrary(name: folder.name,
                                                             providerKind: kind,
                                                             folder: folder)
                    }
                }
            }
        }
    }

    private func libraryRow(_ lib: MusicLibrary) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 46, height: 46)
                .overlay(Image(systemName: "music.note.list").foregroundColor(.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(lib.name).font(.headline)
                Text("\(lib.tracks.count) 首 · \(lib.albumCount) 张专辑 · \(lib.providerKind.rawValue)")
                    .font(.caption).foregroundColor(.secondary)
                if let p = store.progress[lib.id] {
                    Text("\(p.phase)（\(p.scrapedTracks)/\(max(p.totalToScrape, 1))）")
                        .font(.caption2).foregroundColor(.accentColor)
                }
            }
        }
    }
}

/// 库详情：歌曲 / 专辑 / 艺术家
struct LibraryDetailView: View {
    let libraryID: String
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var player = PlayerManager.shared
    @State private var tab = 0

    private var lib: MusicLibrary? { store.library(id: libraryID) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("视图", selection: $tab) {
                Text("歌曲").tag(0)
                Text("专辑").tag(1)
                Text("艺术家").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if let p = store.progress[libraryID] {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("\(p.phase)  \(p.scrapedTracks)/\(max(p.totalToScrape, 1))")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.bottom, 6)
            }

            if let lib {
                switch tab {
                case 0: songList(lib)
                case 1: albumGrid(lib)
                default: artistList(lib)
                }
            } else {
                Spacer()
                Text("音乐库不存在").foregroundColor(.secondary)
                Spacer()
            }
        }
        .navigationTitle(lib?.name ?? "音乐库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        Task { await LibraryStore.shared.rescan(libraryID: libraryID) }
                    } label: {
                        Label("重新扫描并刮削", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        LibraryStore.shared.removeLibrary(id: libraryID)
                    } label: {
                        Label("删除音乐库", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func songList(_ lib: MusicLibrary) -> some View {
        List {
            ForEach(lib.tracks) { t in
                Button {
                    play(lib: lib, tracks: lib.tracks, startAt: t.id)
                } label: {
                    HStack(spacing: 10) {
                        ArtworkThumb(file: t.artworkFile, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).lineLimit(1)
                                .foregroundColor(player.currentTrack?.id == t.id ? .accentColor : .primary)
                            Text("\(t.displayArtist) · \(t.displayAlbum)")
                                .font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func albumGrid(_ lib: MusicLibrary) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                ForEach(lib.albums()) { album in
                    NavigationLink {
                        AlbumDetailView(libraryID: libraryID, albumName: album.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkThumb(file: album.artwork, size: 150, corner: 10)
                                .frame(maxWidth: .infinity)
                            Text(album.name).font(.subheadline).lineLimit(1)
                            Text(album.artist ?? "未知艺术家").font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }

    private func artistList(_ lib: MusicLibrary) -> some View {
        List(lib.artists()) { artist in
            NavigationLink {
                ArtistDetailView(libraryID: libraryID, artistName: artist.name)
            } label: {
                HStack(spacing: 10) {
                    ArtworkThumb(file: artist.artwork, size: 44, corner: 22)
                    VStack(alignment: .leading) {
                        Text(artist.name)
                        Text("\(artist.tracks.count) 首").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func play(lib: MusicLibrary, tracks: [LibraryTrack], startAt id: String) {
        guard let provider = ProviderRegistry.provider(kind: lib.providerKind) else { return }
        let list = tracks.map { $0.toTrack(kind: lib.providerKind) }
        let idx = list.firstIndex { $0.id == id } ?? 0
        PlayerManager.shared.play(tracks: list, at: idx, provider: provider)
    }
}

/// 专辑详情
struct AlbumDetailView: View {
    let libraryID: String
    let albumName: String
    @ObservedObject private var store = LibraryStore.shared

    private var lib: MusicLibrary? { store.library(id: libraryID) }
    private var album: AlbumGroup? { lib?.albums().first { $0.name == albumName } }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ArtworkThumb(file: album?.artwork, size: 90, corner: 10)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(albumName).font(.headline)
                        Text(album?.artist ?? "未知艺术家").font(.subheadline).foregroundColor(.secondary)
                        Text("\(album?.tracks.count ?? 0) 首").font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Button {
                    playAll()
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                }
            }
            Section("曲目") {
                ForEach(album?.tracks ?? []) { t in
                    Button {
                        play(startAt: t.id)
                    } label: {
                        HStack {
                            Text(t.title).lineLimit(1)
                            Spacer()
                            if let d = t.duration { Text(d.formattedTime).font(.caption).foregroundColor(.secondary) }
                        }
                    }
                }
            }
        }
        .navigationTitle(albumName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func playAll() {
        guard let lib, let album, let provider = ProviderRegistry.provider(kind: lib.providerKind) else { return }
        let list = album.tracks.map { $0.toTrack(kind: lib.providerKind) }
        PlayerManager.shared.play(tracks: list, at: 0, provider: provider)
    }

    private func play(startAt id: String) {
        guard let lib, let album, let provider = ProviderRegistry.provider(kind: lib.providerKind) else { return }
        let list = album.tracks.map { $0.toTrack(kind: lib.providerKind) }
        let idx = list.firstIndex { $0.id == id } ?? 0
        PlayerManager.shared.play(tracks: list, at: idx, provider: provider)
    }
}

/// 艺术家详情
struct ArtistDetailView: View {
    let libraryID: String
    let artistName: String
    @ObservedObject private var store = LibraryStore.shared

    private var lib: MusicLibrary? { store.library(id: libraryID) }
    private var artist: ArtistGroup? { lib?.artists().first { $0.name == artistName } }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ArtworkThumb(file: artist?.artwork, size: 80, corner: 40)
                    VStack(alignment: .leading) {
                        Text(artistName).font(.headline)
                        Text("\(artist?.tracks.count ?? 0) 首").font(.caption).foregroundColor(.secondary)
                    }
                }
                Button {
                    guard let lib, let artist, let p = ProviderRegistry.provider(kind: lib.providerKind) else { return }
                    PlayerManager.shared.play(tracks: artist.tracks.map { $0.toTrack(kind: lib.providerKind) },
                                              at: 0, provider: p)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                }
            }
            Section("歌曲") {
                ForEach(artist?.tracks ?? []) { t in
                    Button {
                        guard let lib, let artist, let p = ProviderRegistry.provider(kind: lib.providerKind) else { return }
                        let list = artist.tracks.map { $0.toTrack(kind: lib.providerKind) }
                        let idx = list.firstIndex { $0.id == t.id } ?? 0
                        PlayerManager.shared.play(tracks: list, at: idx, provider: p)
                    } label: {
                        Text(t.title).lineLimit(1)
                    }
                }
            }
        }
        .navigationTitle(artistName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 封面缩略图（本地缓存）
struct ArtworkThumb: View {
    let file: String?
    var size: CGFloat = 44
    var corner: CGFloat = 6

    var body: some View {
        Group {
            if let url = MetadataScraper.artworkURL(file: file), let ui = UIImage(contentsOfFile: url.path) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "music.note").foregroundColor(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }
}
