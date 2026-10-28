import SwiftUI

/// 云盘文件浏览 + 音乐搜刮
struct FileBrowserView: View {
    let kind: CloudKind

    @State private var path: [CloudFile] = []          // 目录面包屑栈
    @State private var files: [CloudFile] = []
    @State private var isLoading = false
    @State private var errorText = ""

    private var currentFolderID: String {
        path.last?.id ?? ProviderRegistry.rootID(of: kind)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在读取目录…")
            } else if !errorText.isEmpty {
                VStack(spacing: 8) {
                    Text(errorText).foregroundColor(.red).multilineTextAlignment(.center)
                    Button("重试") { load() }
                }
            } else {
                fileListView
            }
        }
        .navigationTitle(path.last?.name ?? kind.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .task { if files.isEmpty { load() } }
    }

    private var audioCount: Int { MusicScanner.filterAudio(files).count }

    private var fileListView: some View {
        List {
            if !path.isEmpty {
                Button("⬆️ 返回上级") {
                    path.removeLast()
                    load()
                }
            }
            if audioCount > 0 {
                Button("▶️ 播放本文件夹全部 \(audioCount) 首音乐") { playAll() }
                    .fontWeight(.semibold)
            }
            ForEach(files) { file in
                if file.isFolder {
                    Button {
                        path.append(file)
                        load()
                    } label: {
                        row(file)
                    }
                } else if MusicScanner.isAudioFile(file.name) {
                    Button {
                        play(file)
                    } label: {
                        row(file)
                    }
                } else {
                    row(file).foregroundColor(.secondary)
                }
            }
        }
    }

    private func row(_ file: CloudFile) -> some View {
        HStack {
            Image(systemName: file.isFolder ? "folder.fill" :
                    (MusicScanner.isAudioFile(file.name) ? "music.note" : "doc"))
                .foregroundColor(file.isFolder ? .blue : .pink)
            VStack(alignment: .leading) {
                Text(file.name).lineLimit(1)
                if !file.isFolder {
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func load() {
        isLoading = true
        errorText = ""
        Task {
            do {
                guard let p = ProviderRegistry.provider(kind: kind) else { return }
                files = try await ProviderRegistry.listWithParent(p, folderID: currentFolderID)
            } catch {
                errorText = "读取失败：\(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    private func makeTracks() -> [Track] {
        MusicScanner.filterAudio(files).map {
            Track(id: "\(kind.rawValue)-\($0.id)", file: $0, providerKind: kind, accountID: kind.rawValue)
        }
    }

    private func playAll() {
        let tracks = makeTracks()
        guard let p = ProviderRegistry.provider(kind: kind) else { return }
        PlayerManager.shared.play(tracks: tracks, at: 0, provider: p)
    }

    private func play(_ file: CloudFile) {
        var tracks = makeTracks()
        guard let p = ProviderRegistry.provider(kind: kind) else { return }
        if let idx = tracks.firstIndex(where: { $0.file.id == file.id }) {
            PlayerManager.shared.play(tracks: tracks, at: idx, provider: p)
        } else {
            tracks = [Track(id: "\(kind.rawValue)-\(file.id)", file: file, providerKind: kind, accountID: kind.rawValue)]
            PlayerManager.shared.play(tracks: tracks, at: 0, provider: p)
        }
    }
}
