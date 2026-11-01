import SwiftUI

/// 通用歌曲集合页：最近播放 / 全部歌曲共用。
/// 顶部是封面信息 + 播放全部 / 随机播放，下面是可搜索的完整列表。
struct TrackListView: View {
    let title: String
    let icon: String
    let colors: [Color]
    let items: [TrackRef]
    let emptyIcon: String
    let emptyTitle: String
    let emptyMessage: String
    /// 可选：右上角的清理动作（最近播放用「清空记录」）
    var clearActionTitle: String? = nil
    var clearAction: (() -> Void)? = nil

    @ObservedObject private var player = PlayerManager.shared
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [TrackRef] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { item in
            item.track.title.lowercased().contains(q)
                || (item.track.artist?.lowercased().contains(q) ?? false)
                || (item.track.album?.lowercased().contains(q) ?? false)
        }
    }

    private var totalDuration: Double {
        items.reduce(0) { $0 + ($1.track.duration ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                if filtered.isEmpty {
                    EmptyStateView(icon: emptyIcon,
                                   title: query.isEmpty ? emptyTitle : "没找到「\(query)」",
                                   message: query.isEmpty ? emptyMessage : "换个关键词试试")
                } else {
                    list
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 140)
        }
        .background(Theme.background)
        .scrollIndicators(.hidden)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "在\(title)中搜索")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let clearActionTitle, clearAction != nil {
                    Button(clearActionTitle) { confirmClear = true }
                        .font(.footnote)
                }
            }
        }
        .confirmationDialog("\(clearActionTitle ?? "清空")？", isPresented: $confirmClear) {
            Button("确定", role: .destructive) { clearAction?() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 顶部信息

    private var header: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 92, height: 92)
                    if let cover = items.first?.track.artworkFile {
                        CoverView(file: cover, size: 92, corner: 18, showsShadow: true)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.title3.weight(.bold))
                    Text("\(items.count) 首" + (totalDuration > 0 ? " · \(durationText)" : ""))
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
                        .background(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing),
                                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(items.isEmpty)

                Button { playAll(shuffled: true) } label: {
                    Label("随机播放", systemImage: "shuffle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(items.isEmpty)
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
        Set(items.map { $0.library.providerKindRaw }).count
    }

    // MARK: 列表

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(filtered.indices, id: \.self) { idx in
                let item = filtered[idx]
                SongRow(track: item.track, library: item.library) {
                    play(at: idx)
                }
                if idx < filtered.count - 1 {
                    Divider().padding(.leading, 74)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .padding(.horizontal, Theme.pagePadding)
    }

    // MARK: 播放

    private func play(at index: Int) {
        guard filtered.indices.contains(index) else { return }
        let tracks = filtered.map { $0.track.toTrack(kind: $0.library.providerKind) }
        guard let provider = ProviderRegistry.provider(kind: filtered[index].library.providerKind) else { return }
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

// MARK: - 最近播放

struct RecentTracksView: View {
    @ObservedObject private var store = LibraryStore.shared

    var body: some View {
        TrackListView(title: "最近播放",
                      icon: "clock.fill",
                      colors: [Color(red: 0.42, green: 0.55, blue: 0.98),
                               Color(red: 0.55, green: 0.45, blue: 0.95)],
                      items: store.recentTracks,
                      emptyIcon: "clock",
                      emptyTitle: "还没有播放记录",
                      emptyMessage: "放过一首歌之后，这里会按时间倒序列出最近听过的曲子",
                      clearActionTitle: "清空",
                      clearAction: { store.clearRecent() })
    }
}

// MARK: - 全部歌曲

struct AllTracksView: View {
    @ObservedObject private var store = LibraryStore.shared

    var body: some View {
        TrackListView(title: "全部歌曲",
                      icon: "music.note.list",
                      colors: [Color(red: 0.30, green: 0.75, blue: 0.62),
                               Color(red: 0.28, green: 0.62, blue: 0.80)],
                      items: store.allTracks(),
                      emptyIcon: "music.note.list",
                      emptyTitle: "还没有歌曲",
                      emptyMessage: "先添加一个音乐库，扫描完成后所有歌曲都会汇总在这里")
    }
}
