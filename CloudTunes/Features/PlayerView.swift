import SwiftUI

/// 全屏播放页：封面模糊背景 + 大封面 / 歌词切换 + 随机循环
struct PlayerView: View {
    @ObservedObject private var player = PlayerManager.shared
    @ObservedObject private var store = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showLyrics = false
    @State private var showLyricSearch = false
    @State private var showEdit = false
    @State private var dragValue: Double = 0
    @State private var isDragging = false

    private var track: Track? { player.currentTrack }
    private var artwork: UIImage? {
        ArtworkCache.shared.image(named: track?.artworkFile, target: 700)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 8)
                    if showLyrics {
                        lyricPanel
                            .frame(maxHeight: .infinity)
                    } else {
                        coverPanel(side: min(geo.size.width - 76, 330))
                    }
                    Spacer(minLength: 8)
                    titleRow
                    progressSection
                    controlRow
                    bottomBar
                }
                .padding(.horizontal, 26)
                .padding(.top, 4)
                .padding(.bottom, 18)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLyricSearch) {
            LyricSearchSheet()
        }
        .sheet(isPresented: $showEdit) {
            if let track, let ref = store.track(id: track.id) {
                EditTrackSheet(libraryID: ref.library.id, track: ref.track)
            }
        }
    }

    // MARK: 背景

    private var background: some View {
        ZStack {
            Color.black
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 55)
                    .opacity(0.75)
                    .ignoresSafeArea()
            } else {
                LinearGradient(colors: [Color(red: 0.28, green: 0.20, blue: 0.32),
                                        Color(red: 0.10, green: 0.10, blue: 0.14)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
            LinearGradient(colors: [Color.black.opacity(0.15), Color.black.opacity(0.62)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            Color.black.opacity(0.18).ignoresSafeArea()
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.12), in: Circle())
            }
            Spacer()
            VStack(spacing: 2) {
                Text("正在播放").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.65))
                Text(track?.album ?? "汤圆云音盒")
                    .font(.caption).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
            }
            Spacer()
            Button {
                showEdit = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .disabled(track == nil)
        }
    }

    // MARK: 封面

    private func coverPanel(side: CGFloat) -> some View {
        VStack {
            Spacer(minLength: 0)
            CoverView(file: track?.artworkFile, size: side, corner: 22, showsShadow: true)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                .scaleEffect(player.isPlaying ? 1 : 0.94)
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: player.isPlaying)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.28)) { showLyrics = true }
                }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 歌词

    private var lyricPanel: some View {
        VStack(spacing: 8) {
            HStack {
                Text(player.lyricSourceNote.isEmpty ? "暂无歌词" : player.lyricSourceNote)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer()
                Button {
                    showLyricSearch = true
                } label: {
                    Label("搜歌词", systemImage: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 4)

            LyricScrollView()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.28)) { showLyrics = false }
                }
        }
        .padding(.vertical, 8)
    }

    // MARK: 标题

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.nowPlayingTitle.isEmpty ? "—" : player.nowPlayingTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track?.artist ?? "未知艺术家")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer()
            if let id = track?.id {
                Button {
                    store.toggleFavorite(id)
                } label: {
                    Image(systemName: store.isFavorite(id) ? "heart.fill" : "heart")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(store.isFavorite(id) ? Theme.accent : .white.opacity(0.85))
                        .frame(width: 38, height: 38)
                }
            }
        }
        .padding(.bottom, 14)
    }

    // MARK: 进度

    private var progressSection: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { isDragging ? dragValue : player.currentTime },
                    set: { dragValue = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing { player.seek(to: dragValue) }
                }
            )
            .tint(.white)

            HStack {
                Text((isDragging ? dragValue : player.currentTime).formattedTime)
                Spacer()
                Text(player.duration.formattedTime)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.bottom, 12)
    }

    // MARK: 控制

    private var controlRow: some View {
        HStack(spacing: 0) {
            Button {
                player.setShuffled(!player.isShuffled)
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(player.isShuffled ? Theme.accent : .white.opacity(0.55))
            }
            .frame(maxWidth: .infinity)

            Button {
                player.playPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)

            Button {
                player.togglePlay()
            } label: {
                ZStack {
                    Circle().fill(.white).frame(width: 68, height: 68)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.black)
                        .offset(x: player.isPlaying ? 0 : 2)
                }
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            }
            .frame(maxWidth: .infinity)

            Button {
                player.playNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { player.cycleRepeatMode() }
            } label: {
                Image(systemName: player.repeatMode.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(player.repeatMode.isActive ? Theme.accent : .white.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 18)
    }

    // MARK: 底部工具

    private var bottomBar: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.28)) { showLyrics.toggle() }
            } label: {
                Label(showLyrics ? "封面" : "歌词",
                      systemImage: showLyrics ? "photo" : "text.quote")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity)

            Button {
                showLyricSearch = true
            } label: {
                Label("歌词源", systemImage: "music.note.list")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity)

            Text("\(player.currentIndex + 1)/\(max(player.queue.count, 1))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - 歌词滚动

struct LyricScrollView: View {
    @ObservedObject private var player = PlayerManager.shared
    @State private var autoScroll = true

    var body: some View {
        Group {
            if player.lyricLines.isEmpty {
                emptyView
            } else if player.lyricLines.allSatisfy({ $0.time < 0 }) {
                plainView
            } else {
                syncedView
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.quote")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.white.opacity(0.35))
            Text("暂无歌词")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.45))
            Text("点右上角「搜歌词」可手动匹配")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var plainView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                ForEach(player.lyricLines) { line in
                    Text(line.text)
                        .font(.body)
                        .foregroundStyle(Color.white.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.vertical, 30)
        }
    }

    private var syncedView: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 16) {
                    ForEach(player.lyricLines) { line in
                        lineView(line)
                    }
                }
                .padding(.vertical, 80)
            }
            .mask(fadeMask)
            .onChange(of: player.currentTime) { _ in
                handleTick(proxy: proxy)
            }
        }
    }

    private func lineView(_ line: LyricLine) -> some View {
        let isActive: Bool = active(line)
        return Text(line.text.isEmpty ? " " : line.text)
            .font(isActive ? Font.title3.weight(.semibold) : Font.body)
            .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.38))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .id(line.id)
    }

    private var fadeMask: LinearGradient {
        LinearGradient(colors: [Color.clear, Color.black, Color.black, Color.clear],
                       startPoint: .top, endPoint: .bottom)
    }

    private func handleTick(proxy: ScrollViewProxy) {
        guard autoScroll, let idx = activeIndex() else { return }
        let target = player.lyricLines[idx].id
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(target, anchor: .center)
        }
    }

    private func active(_ line: LyricLine) -> Bool {
        guard let idx = activeIndex() else { return false }
        return player.lyricLines[idx].id == line.id
    }

    private func activeIndex() -> Int? {
        var result: Int?
        for (i, line) in player.lyricLines.enumerated() where line.time <= player.currentTime + 0.25 {
            result = i
        }
        return result
    }
}

// MARK: - 手动搜歌词

struct LyricSearchSheet: View {
    @ObservedObject private var player = PlayerManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [LyricsService.Candidate] = []
    @State private var neteaseResults: [MusicSearchService.SongInfo] = []
    @State private var searching = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("歌名 歌手", text: $query)
                            .submitLabel(.search)
                            .onSubmit { doSearch() }
                        Button("搜索") { doSearch() }.font(.footnote.weight(.semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if searching {
                        ProgressView("搜索中…").padding()
                    }
                    if !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }

                    if !neteaseResults.isEmpty {
                        group(title: "网易云候选") {
                            ForEach(neteaseResults.indices, id: \.self) { idx in
                            let s = neteaseResults[idx]
                                Button {
                                    applyNetease(s)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.title ?? "—").font(.subheadline).foregroundStyle(.primary)
                                        Text("\(s.artist ?? "—") · \(s.album ?? "—")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                                if idx < neteaseResults.count - 1 { Divider().padding(.leading, 14) }
                            }
                        }
                    }

                    if !results.isEmpty {
                        group(title: "LRCLIB") {
                            ForEach(results.indices, id: \.self) { idx in
                            let c = results[idx]
                                Button {
                                    applyLRCLIB(c)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(c.artistName) - \(c.trackName)")
                                            .font(.subheadline).foregroundStyle(.primary)
                                        Text(c.synced ? "带时间轴 ✓" : "纯文本")
                                            .font(.caption)
                                            .foregroundStyle(c.synced ? .green : .secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                                if idx < results.count - 1 { Divider().padding(.leading, 14) }
                            }
                        }
                    }
                }
                .padding(Theme.pagePadding)
            }
            .background(Theme.background)
            .navigationTitle("歌词来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                if query.isEmpty {
                    query = [player.currentTrack?.artist, player.currentTrack?.title]
                        .compactMap { $0 }.joined(separator: " ")
                }
            }
        }
    }

    @ViewBuilder
    private func group<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 0) { content() }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func doSearch() {
        let parts = query.components(separatedBy: " ")
        let title = parts.count > 1 ? parts.dropFirst().joined(separator: " ") : query
        let artist = parts.count > 1 ? parts.first : nil
        searching = true
        message = ""
        Task {
            let lrcList = try? await LyricsService.search(title: title, artist: artist)
            let neList = await MusicSearchService.candidates(title: title, artist: artist, limit: 6)
            await MainActor.run {
                results = lrcList ?? []
                neteaseResults = neList.filter { $0.neteaseID != nil }
                searching = false
                if results.isEmpty && neteaseResults.isEmpty { message = "没有找到，换个关键词试试" }
            }
        }
    }

    private func applyLRCLIB(_ c: LyricsService.Candidate) {
        let parsed = c.syncedLyrics.map { LRCParser.parse($0) } ?? []
        if parsed.isEmpty, let plain = c.plain {
            player.lyricLines = plain.components(separatedBy: .newlines)
                .enumerated().map { LyricLine(id: $0.offset, time: -1, text: $0.element) }
        } else {
            player.lyricLines = parsed
        }
        player.lyricSourceNote = "歌词来源：LRCLIB（\(c.artistName)）"
        dismiss()
    }

    private func applyNetease(_ s: MusicSearchService.SongInfo) {
        guard let id = s.neteaseID else { return }
        Task {
            let text = await MusicSearchService.neteaseLyrics(id: id)
            await MainActor.run {
                if let text {
                    let parsed = LRCParser.parse(text)
                    player.lyricLines = parsed
                    player.lyricSourceNote = "歌词来源：网易云（\(s.artist ?? "")）"
                } else {
                    message = "这首歌在网易云没有歌词"
                }
                dismiss()
            }
        }
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
