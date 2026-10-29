import Foundation

/// 音乐库管理：扫描云盘文件夹、递归收集音频、持久化、后台并发刮削，
/// 另外负责收藏与最近播放（跨库）。
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var libraries: [MusicLibrary] = []
    @Published private(set) var progress: [String: ScanProgress] = [:]
    @Published private(set) var favoriteIDs: Set<String> = []
    @Published private(set) var recentIDs: [String] = []

    private let storageURL: URL
    private let favoritesKey = "cloudtunes.favorites"
    private let recentKey = "cloudtunes.recent"
    private let maxRecent = 60

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storageURL = dir.appendingPathComponent("libraries.json")
        load()
        loadPrefs()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let libs = try? JSONDecoder().decode([MusicLibrary].self, from: data) else { return }
        libraries = libs
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(libraries) else { return }
        try? data.write(to: storageURL)
    }

    /// 刮削过程中用：整库 JSON 可能有几 MB，主线程编码写盘会把 UI 卡死，
    /// 所以拷贝一份数据丢到后台线程编码，且最多每 3 秒落一次盘。
    private var lastDeferredSaveAt = Date.distantPast

    private func saveDeferred() {
        guard Date().timeIntervalSince(lastDeferredSaveAt) > 3 else { return }
        lastDeferredSaveAt = Date()
        let libs = libraries
        let url = storageURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(libs) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func loadPrefs() {
        let defaults = UserDefaults.standard
        if let favs = defaults.array(forKey: favoritesKey) as? [String] {
            favoriteIDs = Set(favs)
        }
        if let recent = defaults.array(forKey: recentKey) as? [String] {
            recentIDs = recent
        }
    }

    private func savePrefs() {
        let defaults = UserDefaults.standard
        defaults.set(Array(favoriteIDs), forKey: favoritesKey)
        defaults.set(recentIDs, forKey: recentKey)
    }

    // MARK: - 查询

    func library(id: String) -> MusicLibrary? { libraries.first { $0.id == id } }

    func allTracks() -> [TrackRef] {
        libraries.flatMap { lib in lib.tracks.map { TrackRef(track: $0, library: lib) } }
    }

    func track(id: String) -> TrackRef? {
        allTracks().first { $0.id == id }
    }

    var favoriteTracks: [TrackRef] {
        allTracks().filter { favoriteIDs.contains($0.id) }
    }

    var recentTracks: [TrackRef] {
        let index = Dictionary(uniqueKeysWithValues: allTracks().map { ($0.id, $0) })
        return recentIDs.compactMap { index[$0] }
    }

    func search(_ query: String) -> [TrackRef] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return allTracks().filter { item in
            item.track.title.lowercased().contains(q)
                || (item.track.artist?.lowercased().contains(q) ?? false)
                || (item.track.album?.lowercased().contains(q) ?? false)
        }
    }

    // MARK: - 收藏 / 最近播放

    func isFavorite(_ trackID: String) -> Bool { favoriteIDs.contains(trackID) }

    func toggleFavorite(_ trackID: String) {
        if favoriteIDs.contains(trackID) {
            favoriteIDs.remove(trackID)
        } else {
            favoriteIDs.insert(trackID)
        }
        savePrefs()
    }

    func markPlayed(_ trackID: String) {
        recentIDs.removeAll { $0 == trackID }
        recentIDs.insert(trackID, at: 0)
        if recentIDs.count > maxRecent { recentIDs = Array(recentIDs.prefix(maxRecent)) }
        savePrefs()
    }

    func clearRecent() {
        recentIDs = []
        savePrefs()
    }

    // MARK: - 库管理

    func removeLibrary(id: String) {
        libraries.removeAll { $0.id == id }
        save()
    }

    func renameLibrary(id: String, to name: String) {
        guard let idx = libraries.firstIndex(where: { $0.id == id }) else { return }
        libraries[idx].name = name
        save()
    }

    // MARK: - 扫描

    /// 新建音乐库并扫描。folder 可以是任意层级的文件夹；includeSubfolders 决定是否递归。
    func addLibrary(name: String,
                    providerKind: CloudKind,
                    folder: CloudFile,
                    includeSubfolders: Bool = true) async {
        guard let provider = ProviderRegistry.provider(kind: providerKind) else { return }
        let libID = UUID().uuidString
        progress[libID] = ScanProgress(phase: includeSubfolders ? "扫描目录…" : "读取目录…")

        let lib = MusicLibrary(id: libID,
                               name: name.isEmpty ? (folder.name.isEmpty ? providerKind.rawValue : folder.name) : name,
                               providerKindRaw: providerKind.rawValue,
                               folderID: folder.id,
                               folderName: folder.name,
                               tracks: [],
                               createdAt: Date(),
                               lastScanAt: nil,
                               includeSubfolders: includeSubfolders)
        libraries.append(lib)
        save()

        let found = await collect(provider: provider, kind: providerKind, root: folder,
                                  includeSubfolders: includeSubfolders, libID: libID)

        if let idx = libraries.firstIndex(where: { $0.id == libID }) {
            libraries[idx].tracks = found
            libraries[idx].lastScanAt = Date()
        }
        save()

        progress[libID]?.phase = found.isEmpty ? "没有找到音乐文件" : "入库完成，开始刮削…"
        progress[libID]?.totalToScrape = found.count

        await scrapeAll(libraryID: libID, providerKind: providerKind)
        progress[libID] = nil
    }

    /// 重新扫描已有库（只补新增文件，随后补刮未刮过的）
    func rescan(libraryID: String) async {
        guard let lib = library(id: libraryID),
              let provider = ProviderRegistry.provider(kind: lib.providerKind) else { return }
        progress[libraryID] = ScanProgress(phase: "重新扫描…")
        let root = CloudFile(id: lib.folderID, name: lib.folderName, size: 0, isFolder: true)
        let found = await collect(provider: provider, kind: lib.providerKind, root: root,
                                  includeSubfolders: lib.scansSubfolders, libID: libraryID)

        var known = Set(lib.tracks.map { $0.fileID })
        var added = 0
        if let idx = libraries.firstIndex(where: { $0.id == libraryID }) {
            for t in found where !known.contains(t.fileID) {
                libraries[idx].tracks.append(t)
                known.insert(t.fileID)
                added += 1
            }
            libraries[idx].lastScanAt = Date()
        }
        save()
        progress[libraryID]?.phase = "新增 \(added) 首，开始刮削…"
        await scrapeAll(libraryID: libraryID, providerKind: lib.providerKind)
        progress[libraryID] = nil
    }

    /// 强制重刮全部：把元数据回滚成文件名解析结果，再重新匹配（用于修正以前的错误）
    func rescrapeAll(libraryID: String) async {
        guard let lib = library(id: libraryID) else { return }
        progress[libraryID] = ScanProgress(phase: "重置元数据…")

        if let idx = libraries.firstIndex(where: { $0.id == libraryID }) {
            for i in libraries[idx].tracks.indices {
                let t = libraries[idx].tracks[i]
                let parsed = MusicScanner.parse(t.fileName)
                libraries[idx].tracks[i].title = parsed.title
                libraries[idx].tracks[i].artist = parsed.artist
                // 专辑回退到所在文件夹名
                if let parent = t.parentName, t.parentID != lib.folderID {
                    libraries[idx].tracks[i].album = parent
                } else {
                    libraries[idx].tracks[i].album = nil
                }
                libraries[idx].tracks[i].scraped = false
                libraries[idx].tracks[i].confidence = nil
                libraries[idx].tracks[i].metaSource = "filename"
                libraries[idx].tracks[i].neteaseID = nil
            }
        }
        save()
        await scrapeAll(libraryID: libraryID, providerKind: lib.providerKind)
        progress[libraryID] = nil
    }

    /// 只重刮单曲（不动其他）
    func rescrapeTrack(libraryID: String, trackID: String) async {
        guard let lib = library(id: libraryID),
              let item = lib.tracks.first(where: { $0.id == trackID }),
              let provider = ProviderRegistry.provider(kind: lib.providerKind) else { return }
        let file = CloudFile(id: item.fileID, name: item.fileName, size: item.size,
                             isFolder: false, modifiedAt: nil, extra: ["parentID": item.parentID])
        guard let link = try? await provider.streamURL(file: file) else { return }
        let meta = await MetadataScraper.scrape(url: link.url, headers: link.headers, trackID: item.id,
                                                fallbackTitle: item.title, fallbackArtist: item.artist)
        updateTrack(libraryID: libraryID, trackID: trackID) { t in
            if let v = meta.title, !v.isEmpty { t.title = v }
            if let v = meta.artist, !v.isEmpty { t.artist = v }
            if let v = meta.album, !v.isEmpty { t.album = v }
            if let v = meta.duration { t.duration = v }
            if let v = meta.artworkFile { t.artworkFile = v }
            if let v = meta.neteaseID { t.neteaseID = v }
            t.confidence = meta.matched ? meta.confidence : (t.confidence ?? 1)
            t.metaSource = meta.matched ? "online" : "filename"
            t.scraped = true
        }
        save()
    }

    // MARK: - 手动修正

    func updateMeta(libraryID: String, trackID: String, title: String, artist: String?, album: String?) {
        updateTrack(libraryID: libraryID, trackID: trackID) { t in
            if !title.isEmpty { t.title = title }
            t.artist = (artist?.isEmpty == false) ? artist : nil
            t.album = (album?.isEmpty == false) ? album : nil
            t.confidence = 1.0
            t.metaSource = "manual"
            t.scraped = true
        }
        save()
    }

    /// 用在线候选结果替换元数据与封面
    func applyMatch(libraryID: String, trackID: String, info: MusicSearchService.SongInfo) async {
        var artworkName: String?
        if let cover = info.coverURL, let data = await MusicSearchService.downloadImage(cover) {
            artworkName = MetadataScraper.saveArtwork(data, key: trackID)
        }
        updateTrack(libraryID: libraryID, trackID: trackID) { t in
            if let v = info.title, !v.isEmpty { t.title = v }
            if let v = info.artist, !v.isEmpty { t.artist = v }
            if let v = info.album, !v.isEmpty { t.album = v }
            if let v = info.duration { t.duration = v }
            t.neteaseID = info.neteaseID
            if let a = artworkName { t.artworkFile = a }
            t.confidence = 1.0
            t.metaSource = "manual"
            t.scraped = true
        }
        save()
    }

    // MARK: - 内部：目录收集

    private func collect(provider: CloudProvider, kind: CloudKind, root: CloudFile,
                         includeSubfolders: Bool, libID: String) async -> [LibraryTrack] {
        var found: [LibraryTrack] = []
        var queue: [(id: String, name: String)] = [(root.id, root.name)]
        var visited = Set<String>()
        let maxFolders = 800
        let maxTracks = 8000
        let now = Date()

        while !queue.isEmpty, visited.count < maxFolders, found.count < maxTracks {
            if Task.isCancelled { break }
            let current = queue.removeFirst()
            if visited.contains(current.id) { continue }
            visited.insert(current.id)
            progress[libID]?.scannedFolders = visited.count
            progress[libID]?.phase = "扫描：\(current.name)"

            guard let items = try? await ProviderRegistry.listWithParent(provider, folderID: current.id) else { continue }
            for item in items {
                if item.isFolder {
                    if includeSubfolders { queue.append((item.id, item.name)) }
                    continue
                }
                guard MusicScanner.isAudioFile(item.name) else { continue }
                let parsed = MusicScanner.parse(item.name)
                let isRoot = current.id == root.id
                found.append(LibraryTrack(
                    id: "\(kind.rawValue)-\(item.id)",
                    fileID: item.id,
                    fileName: item.name,
                    size: item.size,
                    parentID: current.id,
                    title: parsed.title,
                    artist: parsed.artist,
                    album: isRoot ? nil : current.name,
                    duration: nil,
                    artworkFile: nil,
                    scraped: false,
                    neteaseID: nil,
                    addedAt: now,
                    metaSource: "filename",
                    confidence: nil,
                    parentName: isRoot ? nil : current.name))
            }
            progress[libID]?.foundTracks = found.count
        }
        return found
    }

    // MARK: - 内部：并发刮削

    private struct ScrapeOutcome: Sendable {
        let trackID: String
        let result: MetadataScraper.Result?
    }

    private func scrapeAll(libraryID: String, providerKind: CloudKind) async {
        guard let provider = ProviderRegistry.provider(kind: providerKind),
              let lib = library(id: libraryID) else { return }
        let pending = lib.tracks.filter { !$0.scraped }
        progress[libraryID]?.totalToScrape = lib.tracks.count
        var done = lib.tracks.count - pending.count
        progress[libraryID]?.scrapedTracks = done

        let batchSize = 4
        var cursor = 0
        while cursor < pending.count {
            if Task.isCancelled { break }
            let upper = min(cursor + batchSize, pending.count)
            let batch = Array(pending[cursor..<upper])

            let results = await withTaskGroup(of: ScrapeOutcome.self) { group in
                for track in batch {
                    group.addTask {
                        let file = CloudFile(id: track.fileID, name: track.fileName, size: track.size,
                                             isFolder: false, modifiedAt: nil,
                                             extra: ["parentID": track.parentID])
                        guard let link = try? await provider.streamURL(file: file) else {
                            return ScrapeOutcome(trackID: track.id, result: nil)
                        }
                        let meta = await MetadataScraper.scrape(url: link.url,
                                                                headers: link.headers,
                                                                trackID: track.id,
                                                                fallbackTitle: track.title,
                                                                fallbackArtist: track.artist)
                        return ScrapeOutcome(trackID: track.id, result: meta)
                    }
                }
                var collected: [ScrapeOutcome] = []
                for await item in group { collected.append(item) }
                return collected
            }

            // 整批结果一次性写回，只触发一次 UI 刷新（逐首 update 会把大库的列表卡死）
            if let li = libraries.firstIndex(where: { $0.id == libraryID }) {
                var tracks = libraries[li].tracks
                for item in results {
                    guard let ti = tracks.firstIndex(where: { $0.id == item.trackID }) else { continue }
                    if let meta = item.result {
                        if let v = meta.title, !v.isEmpty { tracks[ti].title = v }
                        if let v = meta.artist, !v.isEmpty { tracks[ti].artist = v }
                        if let v = meta.album, !v.isEmpty { tracks[ti].album = v }
                        if let v = meta.duration { tracks[ti].duration = v }
                        if let v = meta.artworkFile { tracks[ti].artworkFile = v }
                        if let v = meta.neteaseID { tracks[ti].neteaseID = v }
                        if meta.matched { tracks[ti].confidence = meta.confidence }
                        tracks[ti].metaSource = meta.matched ? "online" : "filename"
                        tracks[ti].scraped = true
                    } else {
                        tracks[ti].scraped = true
                    }
                }
                libraries[li].tracks = tracks
            }

            done += results.count
            progress[libraryID]?.scrapedTracks = done
            if let total = progress[libraryID]?.totalToScrape {
                progress[libraryID]?.phase = "刮削 \(done)/\(total)"
            }
            saveDeferred()
            cursor += batchSize
        }
        save()
    }

    private func updateTrack(libraryID: String, trackID: String, _ mutate: (inout LibraryTrack) -> Void) {
        guard let li = libraries.firstIndex(where: { $0.id == libraryID }),
              let ti = libraries[li].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        mutate(&libraries[li].tracks[ti])
    }
}
