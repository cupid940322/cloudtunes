import SwiftUI

/// 选择云盘文件夹作为音乐库（只显示文件夹）
struct FolderPickerView: View {
    let kind: CloudKind
    var onPick: (CloudFile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [CloudFile] = []
    @State private var folders: [CloudFile] = []
    @State private var audioCount = 0
    @State private var isLoading = false
    @State private var errorText = ""

    private var currentID: String { path.last?.id ?? ProviderRegistry.rootID(of: kind) }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("读取中…")
                } else if !errorText.isEmpty {
                    VStack(spacing: 10) {
                        Text(errorText).foregroundColor(.red).multilineTextAlignment(.center).padding()
                        Button("重试") { load() }
                    }
                } else {
                    List {
                        if audioCount > 0 {
                            Section {
                                Button {
                                    pickCurrent()
                                } label: {
                                    Label("把此文件夹设为音乐库（含 \(audioCount) 首音乐）",
                                          systemImage: "plus.circle.fill")
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                        if !path.isEmpty {
                            Button("⬆️ 返回上级") {
                                path.removeLast()
                                load()
                            }
                        }
                        Section("子文件夹") {
                            ForEach(folders) { f in
                                Button {
                                    path.append(f)
                                    load()
                                } label: {
                                    HStack {
                                        Image(systemName: "folder.fill").foregroundColor(.blue)
                                        Text(f.name)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                            if folders.isEmpty {
                                Text("此文件夹下没有子文件夹").foregroundColor(.secondary).font(.footnote)
                            }
                        }
                    }
                }
            }
            .navigationTitle(path.last?.name ?? kind.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task { if folders.isEmpty { load() } }
        }
    }

    private func load() {
        isLoading = true
        errorText = ""
        Task {
            do {
                guard let p = ProviderRegistry.provider(kind: kind) else { return }
                let all = try await ProviderRegistry.listWithParent(p, folderID: currentID)
                folders = all.filter { $0.isFolder }.sorted { $0.name < $1.name }
                audioCount = all.filter { !$0.isFolder && MusicScanner.isAudioFile($0.name) }.count
            } catch {
                errorText = "读取失败：\(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    private func pickCurrent() {
        let folder: CloudFile
        if let last = path.last {
            folder = last
        } else {
            folder = CloudFile(id: ProviderRegistry.rootID(of: kind),
                               name: kind.rawValue, size: 0, isFolder: true)
        }
        onPick(folder)
        dismiss()
    }
}
