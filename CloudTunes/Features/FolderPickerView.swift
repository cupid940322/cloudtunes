import SwiftUI

/// 选择云盘文件夹作为音乐库。
/// 任意层级都可以添加：顶部固定的「添加此文件夹」按钮始终可用，
/// 想扫全部子目录就打开「包含子文件夹」。
struct FolderPickerView: View {
    let kind: CloudKind
    /// (选中的文件夹, 是否包含子文件夹)
    var onPick: (CloudFile, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [CloudFile] = []
    @State private var folders: [CloudFile] = []
    @State private var audioCount = 0
    @State private var isLoading = false
    @State private var errorText = ""
    @State private var includeSubfolders = true

    private var currentID: String { path.last?.id ?? ProviderRegistry.rootID(of: kind) }
    private var currentName: String {
        if let last = path.last { return last.name }
        return "\(kind.rawValue)根目录"
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && folders.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在读取目录…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !errorText.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle).foregroundStyle(.orange)
                        Text(errorText).font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal)
                        Button("重试") { load() }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(currentName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                addBar
            }
            .task { if folders.isEmpty { load() } }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 路径面包屑
                if !path.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Button {
                                path.removeAll()
                                load()
                            } label: {
                                Text(kind.rawValue).font(.caption).foregroundStyle(Theme.accent)
                            }
                            ForEach(path.indices, id: \.self) { idx in
                            let folder = path[idx]
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8)).foregroundStyle(.secondary)
                                Button {
                                    path.removeSubrange((idx + 1)...)
                                    load()
                                } label: {
                                    Text(folder.name).font(.caption)
                                        .foregroundStyle(idx == path.count - 1 ? Color.secondary : Theme.accent)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.top, 8)
                }

                // 当前目录信息
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.accentGradient)
                            .frame(width: 54, height: 54)
                            .opacity(0.16)
                        Image(systemName: path.isEmpty ? "externaldrive.fill" : "folder.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.accentGradient)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(currentName).font(.headline).lineLimit(1)
                        Text("本层 \(audioCount) 首音乐 · \(folders.count) 个子文件夹")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .padding(.horizontal, 16)

                // 子文件夹
                VStack(alignment: .leading, spacing: 8) {
                    Text("子文件夹").font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)

                    if folders.isEmpty {
                        Text("这一层没有子文件夹")
                            .font(.footnote).foregroundStyle(.tertiary)
                            .padding(.horizontal, 20).padding(.bottom, 6)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(folders.indices, id: \.self) { idx in
                            let folder = folders[idx]
                                Button {
                                    path.append(folder)
                                    load()
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "folder.fill")
                                            .foregroundStyle(Theme.folderTint)
                                            .frame(width: 26)
                                        Text(folder.name)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 11)
                                }
                                .buttonStyle(.plain)
                                if idx < folders.count - 1 {
                                    Divider().padding(.leading, 54)
                                }
                            }
                        }
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 8)
            }
            .padding(.bottom, 12)
        }
    }

    private var addBar: some View {
        VStack(spacing: 10) {
            Toggle(isOn: $includeSubfolders) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("包含所有子文件夹").font(.subheadline)
                    Text("自动递归搜索这一层的全部音乐，适合「我的音乐」这种大目录")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(Theme.accent)

            Button {
                pickCurrent()
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text(audioCount == 0 && folders.isEmpty ? "添加为空音乐库" : "添加此文件夹")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func load() {
        isLoading = true
        errorText = ""
        Task {
            do {
                guard let p = ProviderRegistry.provider(kind: kind) else { return }
                let all = try await ProviderRegistry.listWithParent(p, folderID: currentID)
                folders = all.filter { $0.isFolder }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
        onPick(folder, includeSubfolders)
        dismiss()
    }
}
