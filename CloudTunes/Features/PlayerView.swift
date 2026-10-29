import SwiftUI

/// 播放页：当前曲目 + 控制条 + 歌词（滚动/手动搜索）
struct LibraryView: View {
    @ObservedObject private var player = PlayerManager.shared

    var body: some View {
        NavigationStack {
            Group {
                if player.currentTrack == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note").font(.system(size: 48)).foregroundColor(.secondary)
                        Text("还没有在播放").font(.title3)
                        Text("到「网盘」标签页浏览云盘，选择文件夹即可播放")
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                } else {
                    NowPlayingView()
                }
            }
            .navigationTitle("播放")
        }
    }
}

struct NowPlayingView: View {
    @ObservedObject private var player = PlayerManager.shared
    @State private var manualQuery = ""
    @State private var searchResults: [LyricsService.Candidate] = []
    @State private var showSearch = false

    var body: some View {
        VStack(spacing: 16) {
            trackInfo
            controls
            progressBar
            lyricHeader
            LyricsListView()
        }
        .padding()
        .sheet(isPresented: $showSearch) { manualSearchSheet }
    }

    private var trackInfo: some View {
        VStack(spacing: 10) {
            ArtworkThumb(file: player.currentTrack?.artworkFile, size: 220, corner: 14)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .padding(.top, 8)
            VStack(spacing: 4) {
                Text(player.nowPlayingTitle.isEmpty ? "—" : player.nowPlayingTitle)
                    .font(.title2).fontWeight(.semibold).lineLimit(1)
                Text(player.currentTrack?.artist ?? "未知艺术家")
                    .font(.subheadline).foregroundColor(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 40) {
            Button { prevAction() } label: { Image(systemName: "backward.fill").font(.title2) }
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
            }
            Button { nextAction() } label: { Image(systemName: "forward.fill").font(.title2) }
        }
        .tint(.primary)
    }

    private var progressBar: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 1))
            HStack {
                Text(player.currentTime.formattedTime)
                Spacer()
                Text(player.duration.formattedTime)
            }
            .font(.caption2).foregroundColor(.secondary)
        }
    }

    private var lyricHeader: some View {
        HStack {
            Text(player.lyricSourceNote.isEmpty ? " " : player.lyricSourceNote)
                .font(.caption).foregroundColor(.secondary)
            Spacer()
            Button {
                showSearch = true
            } label: {
                Label("搜歌词", systemImage: "magnifyingglass").font(.caption)
            }
        }
    }

    private var manualSearchSheet: some View {
        NavigationStack {
            List {
                Section("关键词（默认填入当前曲目）") {
                    TextField("歌名 歌手", text: $manualQuery)
                        .onAppear { if manualQuery.isEmpty {
                            manualQuery = [player.currentTrack?.artist, player.currentTrack?.title]
                                .compactMap { $0 }.joined(separator: " ")
                        } }
                    Button("搜索 LRCLIB") { doSearch() }
                }
                ForEach(searchResults) { c in
                    Button {
                        apply(candidate: c)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("\(c.artistName) - \(c.trackName)")
                            Text(c.synced ? "带时间轴 ✓" : "纯文本")
                                .font(.caption)
                                .foregroundColor(c.synced ? .green : .secondary)
                        }
                    }
                }
            }
            .navigationTitle("在线歌词搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") { showSearch = false }
            }
        }
    }

    private func prevAction() {
        guard let t = player.currentTrack,
              let p = ProviderRegistry.provider(kind: t.providerKind) else { return }
        player.previous(provider: p)
    }

    private func nextAction() {
        guard let t = player.currentTrack,
              let p = ProviderRegistry.provider(kind: t.providerKind) else { return }
        player.next(provider: p)
    }

    private func doSearch() {
        let q = manualQuery
        Task {
            let parts = q.components(separatedBy: " ")
            let results = (try? await LyricsService.search(
                title: parts.count > 1 ? parts.dropFirst().joined(separator: " ") : q,
                artist: parts.count > 1 ? parts.first : nil)) ?? []
            searchResults = results
        }
    }

    private func apply(candidate: LyricsService.Candidate) {
        let parsed = candidate.syncedLyrics.map { LRCParser.parse($0) } ?? []
        player.lyricLines = parsed
        player.lyricSourceNote = "歌词来源：手动搜索（\(candidate.artistName)）"
        if parsed.isEmpty, let plain = candidate.plain {
            player.lyricLines = plain.components(separatedBy: .newlines)
                .enumerated().map { LyricLine(id: $0.offset, time: -1, text: $0.element) }
        }
        showSearch = false
    }
}

/// 歌词滚动列表：跟随播放进度高亮
struct LyricsListView: View {
    @ObservedObject private var player = PlayerManager.shared
    @State private var autoScroll = true

    var body: some View {
        if player.lyricLines.isEmpty {
            Spacer()
            Text("暂无歌词").foregroundColor(.secondary)
            Spacer()
        } else if player.lyricLines.allSatisfy({ $0.time < 0 }) {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(player.lyricLines) { line in
                        Text(line.text).frame(maxWidth: .infinity)
                    }
                }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(player.lyricLines) { line in
                            Text(line.text)
                                .foregroundColor(highlight(line) ? .primary : .secondary)
                                .font(highlight(line) ? .body.weight(.semibold) : .body)
                                .id(line.id)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .padding(.vertical, 40)
                }
                .onChange(of: player.currentTime) { t in
                    guard autoScroll else { return }
                    if let idx = activeIndex(at: t) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(player.lyricLines[idx].id, anchor: .center)
                        }
                    }
                }
                .onTapGesture { autoScroll.toggle() }
            }
        }
    }

    private func highlight(_ line: LyricLine) -> Bool {
        guard let idx = player.lyricLines.firstIndex(where: { $0.id == line.id }) else { return false }
        return activeIndex(at: player.currentTime) == idx
    }

    private func activeIndex(at time: TimeInterval) -> Int? {
        var result: Int?
        for (i, line) in player.lyricLines.enumerated() where line.time <= time + 0.2 {
            result = i
        }
        return result
    }
}

extension TimeInterval {
    var formattedTime: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let m = Int(self) / 60
        let s = Int(self) % 60
        return String(format: "%d:%02d", m, s)
    }
}
