import SwiftUI

/// 云盘文件浏览：目录导航 + 单曲播放 + 一键设为音乐库
struct FileBrowserView: View {
    let kind: CloudKind

    @State private var path: [CloudFile] = []
    @State private var files: [CloudFile] = []
    @State private var isLoading = false
    @State private var errorText = ""
    @State private var isAdding = false
    @State private var toast = ""
    @ObservedObject private var store = LibraryStore.shared

    private var currentFolderID: String {
        path.last?.id ?? ProviderRegistry.rootID(of: kind)
    }
    private var currentName: String { path.last?.name ?? kind.rawValue }
    private var currentFolder: CloudFile {
        path.last ?? CloudFile(id: ProviderRegistry.rootID(of: kind), name: kind.rawValue, size: 0, isFolder: true)
    }
    private var audioFiles: [CloudFile] { MusicScanner.filterAudio(files) }
    private var audioCount: Int { audioFiles.count }

    /// 这个网盘里已入库的文件夹 ID：音乐库根 + 已经扫进库里的歌曲所在目录
    private var inLibraryFolderIDs: Set<String> {
        var ids = Set<String>()
        for lib in store.libraries where lib.providerKind == kind {
            // 空串是光鸭的根目录 id，塞进集合也匹配不到任何一行，单独用 coversWholeDrive 处理
            if !lib.folderID.isEmpty { ids.insert(lib.folderID) }
            for t in lib.tracks where !t.parentID.isEmpty { ids.insert(t.parentID) }
        }
        return ids
    }

    /// 这个网盘里是否有「直接以网盘根目录为根」的库。
    /// 有的话整个网盘都在库里，每一层文件夹都该带标记——原来只往集合里塞了个空串，
    /// 结果一行都匹配不上，看起来就像「标记功能坏了」。
    private var coversWholeDrive: Bool {
        let root = ProviderRegistry.rootID(of: kind)
        return store.libraries.contains {
            $0.providerKind == kind && ($0.folderID == root || ($0.folderID.isEmpty && root.isEmpty))
        }
    }

    /// 当前浏览路径已经落在某个库里面（库根是路径上的某一层，或整个网盘就是一个库）。
    /// 库内的文件夹即便自己没直接装歌（歌在更深的子目录里），也属于这个库，同样该有标记——
    /// 原来只认「直接装歌的目录」，中间层一律没标记，看着就像标记丢了。
    private var insideLibrary: Bool {
        if coversWholeDrive { return true }
        let roots = Set(store.libraries.filter { $0.providerKind == kind }.map { $0.folderID })
        guard !roots.isEmpty else { return false }
        return path.contains { roots.contains($0.id) }
    }

    /// 诊断：这个网盘其实有库，但一个都对不上 → 多半是库里的网盘字段与当前页面不一致
    private var libraryMismatchHint: String? {
        guard !store.libraries.isEmpty else { return nil }
        guard !store.libraries.contains(where: { $0.providerKind == kind }) else { return nil }
        let raws = Set(store.libraries.map { $0.providerKindRaw }).sorted().joined(separator: "、")
        return "已入库标记不可用：库里记的网盘类型是「\(raws)」，与当前页面（\(kind.rawValue)）不一致"
    }

    /// 当前所在文件夹是否已是某个音乐库的根
    private var isCurrentFolderALibrary: Bool {
        if coversWholeDrive { return true }
        return store.libraries.contains { $0.providerKind == kind && $0.folderID == currentFolderID }
    }

    var body: some View {
        Group {
            if isLoading && files.isEmpty {
                ProgressView("正在读取目录…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !errorText.isEmpty {
                EmptyStateView(icon: "wifi.exclamationmark",
                               title: "读取失败",
                               message: errorText,
                               actionTitle: "重试",
                               action: { load() })
            } else {
                content
            }
        }
        .background(Theme.background)
        .navigationTitle(currentName)
        .navigationBarTitleDisplayMode(.inline)
        .task { if files.isEmpty { load() } }
        .overlay(alignment: .top) {
            if !toast.isEmpty {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var content: some View {
        // 一次性算好已入库集合，别每行都重算（大库有几千首）
        let inLibrary = inLibraryFolderIDs
        return ScrollView {
            VStack(spacing: 14) {
                if let hint = libraryMismatchHint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.pagePadding)
                }
                if !path.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Button {
                                path.removeAll(); load()
                            } label: {
                                Text(kind.rawValue).font(.caption).foregroundStyle(Theme.accent)
                            }
                            ForEach(path.indices, id: \.self) { idx in
                            let folder = path[idx]
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8)).foregroundStyle(.secondary)
                                Button {
                                    path.removeSubrange((idx + 1)...); load()
                                } label: {
                                    Text(folder.name).font(.caption)
                                        .foregroundStyle(idx == path.count - 1 ? Color.secondary : Theme.accent)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.horizontal, Theme.pagePadding)
                    }
                    .padding(.top, 8)
                }

                VStack(spacing: 0) {
                    ForEach(files.indices, id: \.self) { idx in
                            let file = files[idx]
                        row(file, inLibrary: inLibrary)
                        if idx < files.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                    if files.isEmpty {
                        Text("这个文件夹是空的").font(.footnote).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .padding(.horizontal, Theme.pagePadding)
            }
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            if audioCount > 0 || !files.isEmpty {
                actionBar
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                playAll()
            } label: {
                Label("播放全部\(audioCount > 0 ? " \(audioCount)" : "")", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(audioCount == 0)
            .opacity(audioCount == 0 ? 0.5 : 1)

            Button {
                addAsLibrary()
            } label: {
                HStack(spacing: 6) {
                    if isAdding {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: isCurrentFolderALibrary ? "checkmark.circle.fill" : "plus.square.on.square")
                    }
                    Text(isAdding ? "添加中…" : (isCurrentFolderALibrary ? "已在音乐库" : "设为音乐库"))
                }
                .font(.subheadline.weight(.semibold))
                .frame(width: 132)
                .padding(.vertical, 11)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                )
                .foregroundStyle(isCurrentFolderALibrary ? Theme.accent : .primary)
            }
            .buttonStyle(.plain)
            .disabled(isAdding || isCurrentFolderALibrary)
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func row(_ file: CloudFile, inLibrary: Set<String>) -> some View {
        Group {
            if file.isFolder {
                Button {
                    path.append(file)
                    load()
                } label: { rowContent(file, inLibrary: inLibrary) }
                    .buttonStyle(.plain)
            } else if MusicScanner.isAudioFile(file.name) {
                Button {
                    play(file)
                } label: { rowContent(file, inLibrary: inLibrary) }
                    .buttonStyle(.plain)
            } else {
                rowContent(file, inLibrary: inLibrary)
            }
        }
    }

    private func rowContent(_ file: CloudFile, inLibrary: Set<String>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.isFolder ? "folder.fill"
                    : (MusicScanner.isAudioFile(file.name) ? "music.note" : "doc"))
                .font(.system(size: 15))
                .foregroundStyle(file.isFolder ? Theme.folderTint
                                 : (MusicScanner.isAudioFile(file.name) ? Theme.accent : Color.secondary))
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !file.isFolder {
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if file.isFolder {
                // 已入库标记：这个文件夹是音乐库根，或里面的歌已经扫进库
                if insideLibrary || inLibrary.contains(file.id) {
                    Label("已入库", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.quaternary)
            } else if MusicScanner.isAudioFile(file.name) {
                Image(systemName: "play.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.accent.opacity(0.8))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func load() {
        isLoading = true
        errorText = ""
        Task {
            do {
                guard let p = ProviderRegistry.provider(kind: kind) else { return }
                let list = try await ProviderRegistry.listWithParent(p, folderID: currentFolderID)
                files = list.sorted { (a: CloudFile, b: CloudFile) -> Bool in
                    if a.isFolder != b.isFolder { return a.isFolder }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            } catch {
                errorText = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func makeTracks() -> [Track] {
        audioFiles.map {
            Track(id: "\(kind.rawValue)-\($0.id)", file: $0, providerKind: kind, accountID: kind.rawValue)
        }
    }

    private func playAll() {
        guard let p = ProviderRegistry.provider(kind: kind) else { return }
        let tracks = makeTracks()
        guard !tracks.isEmpty else { return }
        PlayerManager.shared.play(tracks: tracks, at: 0, provider: p)
    }

    private func play(_ file: CloudFile) {
        guard let p = ProviderRegistry.provider(kind: kind) else { return }
        var tracks = makeTracks()
        if let idx = tracks.firstIndex(where: { $0.file.id == file.id }) {
            PlayerManager.shared.play(tracks: tracks, at: idx, provider: p)
        } else {
            tracks = [Track(id: "\(kind.rawValue)-\(file.id)", file: file, providerKind: kind, accountID: kind.rawValue)]
            PlayerManager.shared.play(tracks: tracks, at: 0, provider: p)
        }
    }

    private func addAsLibrary() {
        isAdding = true
        Task {
            await LibraryStore.shared.addLibrary(name: currentName,
                                                providerKind: kind,
                                                folder: currentFolder,
                                                includeSubfolders: true)
            await MainActor.run {
                isAdding = false
                withAnimation { toast = "已添加为音乐库：\(currentName)" }
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { withAnimation { toast = "" } }
        }
    }
}
