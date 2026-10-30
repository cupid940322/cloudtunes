import SwiftUI

/// 我的：网盘账号、云盘浏览、数据管理
struct ProfileView: View {
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var auth = AuthState.shared
    @State private var confirmClearRecent = false

    private var signedInKinds: [CloudKind] {
        CloudKind.allCases.filter { ProviderRegistry.provider(kind: $0)?.isSignedIn == true }
    }

    private var totalTracks: Int { store.libraries.reduce(0) { $0 + $1.tracks.count } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                profileHeader
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                ScrollView {
                    VStack(spacing: 20) {
                        statsRow
                        providerSection
                        browseSection
                        dataSection
                        aboutSection
                    }
                    .padding(.bottom, 140)
                }
            }
            .background(Theme.background)
            .scrollIndicators(.hidden)
            .id(auth.tick)
            .confirmationDialog("清空最近播放记录？", isPresented: $confirmClearRecent) {
                Button("清空", role: .destructive) {
                    store.clearRecent()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.accentGradient).frame(width: 62, height: 62)
                Image(systemName: "music.note")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Theme.accent.opacity(0.30), radius: 12, y: 5)

            VStack(alignment: .leading, spacing: 4) {
                Text("汤圆云音盒").font(.title3.weight(.bold))
                Text("云盘直连 · 自动刮削 · \(store.libraries.count) 个音乐库")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.pagePadding)
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            statCell("\(totalTracks)", "首歌曲")
            statCell("\(store.libraries.reduce(0) { $0 + $1.albumCount })", "张专辑")
            statCell("\(store.favoriteIDs.count)", "首收藏")
            statCell("\(signedInKinds.count)", "个网盘")
        }
        .padding(.horizontal, Theme.pagePadding)
    }

    private func statCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.title3.weight(.bold)).foregroundStyle(Theme.accent)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "网盘账号", subtitle: "登录后可把任意文件夹设为音乐库")
            VStack(spacing: 0) {
                ForEach(CloudKind.allCases.indices, id: \.self) { idx in
                            let kind = CloudKind.allCases[idx]
                    NavigationLink {
                        destination(for: kind)
                    } label: {
                        ProviderRow(kind: kind)
                    }
                    .buttonStyle(.plain)
                    if idx < CloudKind.allCases.count - 1 {
                        Divider().padding(.leading, 64)
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .padding(.horizontal, Theme.pagePadding)
        }
    }

    @ViewBuilder
    private func destination(for kind: CloudKind) -> some View {
        switch kind {
        case .guangya: GuangyaLoginView()
        case .baidu: BaiduLoginView()
        case .quark: QuarkLoginView()
        }
    }

    @ViewBuilder
    private var browseSection: some View {
        if !signedInKinds.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "云盘文件", subtitle: "直接浏览、单曲播放")
                VStack(spacing: 0) {
                    ForEach(signedInKinds.indices, id: \.self) { idx in
                            let kind = signedInKinds[idx]
                        NavigationLink {
                            FileBrowserView(kind: kind)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Theme.folderTint)
                                    .frame(width: 26)
                                Text(kind.rawValue).font(.subheadline).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.quaternary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        if idx < signedInKinds.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .padding(.horizontal, Theme.pagePadding)
            }
        }
    }

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "数据")
            VStack(spacing: 0) {
                Button {
                    Task {
                        for lib in store.libraries {
                            await store.rescan(libraryID: lib.id)
                        }
                    }
                } label: {
                    rowLabel("扫描全部音乐库", "arrow.clockwise")
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 52)
                Button {
                    confirmClearRecent = true
                } label: {
                    rowLabel("清空播放记录", "clock.arrow.circlepath")
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 52)
                NavigationLink {
                    CacheManageView()
                } label: {
                    rowLabel("缓存管理", "internaldrive")
                }
                .buttonStyle(.plain)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .padding(.horizontal, Theme.pagePadding)
        }
    }

    private func rowLabel(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
            Text(title).font(.subheadline).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "关于")
            VStack(alignment: .leading, spacing: 6) {
                Text("汤圆云音盒 1.4").font(.subheadline.weight(.medium))
                Text("直连光鸭 / 百度 / 夸克网盘，递归扫描音乐文件，通过网易云音乐与 QQ 音乐匹配封面、专辑与歌词。免费签名 7 天有效，到期用 Sideloadly 覆盖安装即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .padding(.horizontal, Theme.pagePadding)
        }
    }
}

/// 封面 / 播放缓存管理
struct CacheManageView: View {
    @State private var sizeText = "计算中…"
    @State private var count = 0
    @State private var streamText = "计算中…"
    @State private var streamCount = 0
    @State private var lyricsText = "计算中…"
    @State private var lyricsCount = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text(sizeText).font(.title2.weight(.bold))
                    Text("\(count) 张封面").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))

                Button(role: .destructive) {
                    clearCache()
                } label: {
                    Text("清空封面缓存")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)

                Text("清空后重新进入音乐库会重新下载封面。")
                    .font(.caption).foregroundStyle(.tertiary)

                Divider().padding(.vertical, 4)

                VStack(spacing: 6) {
                    Text(streamText).font(.title3.weight(.bold))
                    Text("\(streamCount) 个音频（直链播放失败时的本地兜底缓存）")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))

                Button(role: .destructive) {
                    StreamCache.clear()
                    refresh()
                } label: {
                    Text("清空播放缓存")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)

                Divider().padding(.vertical, 4)

                VStack(spacing: 6) {
                    Text(lyricsText).font(.title3.weight(.bold))
                    Text("\(lyricsCount) 首歌的歌词（命中后切歌秒出）")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))

                Button(role: .destructive) {
                    LyricsCache.clear()
                    refresh()
                } label: {
                    Text("清空歌词缓存")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.pagePadding)
        }
        .background(Theme.background)
        .navigationTitle("缓存管理")
        .navigationBarTitleDisplayMode(.inline)
        .task { refresh() }
    }

    private func refresh() {
        let dir = MetadataScraper.artworkDir
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var total: Int64 = 0
        for f in files {
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        count = files.count
        sizeText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)

        streamCount = StreamCache.count
        streamText = ByteCountFormatter.string(fromByteCount: StreamCache.totalSize, countStyle: .file)

        lyricsCount = LyricsCache.count
        lyricsText = ByteCountFormatter.string(fromByteCount: LyricsCache.totalSize, countStyle: .file)
    }

    private func clearCache() {
        let dir = MetadataScraper.artworkDir
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files { try? FileManager.default.removeItem(at: f) }
        refresh()
    }
}
