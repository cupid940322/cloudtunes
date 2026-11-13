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

    /// 同步墓碑：删除必须留痕，否则另一台设备会把删掉的歌「同步复活」
    private var deletedLibraries: [String: Date] = [:]
    private var deletedTracks: [String: [String: Date]] = [:]
    private let deletedLibsKey = "cloudtunes.sync.deletedLibraries"
    private let deletedTracksKey = "cloudtunes.sync.deletedTracks"
    private let localChangedKey = "cloudtunes.sync.localChangedAt"

    /// 本机数据最后一次真实改动的时间。
    /// 用它而不是「现在」当快照时间戳，否则每次同步都会让云端看起来更新，
    /// 另一台设备就会一直拿远端覆盖本地。
    private var localChangedAt: Date {
        get { UserDefaults.standard.object(forKey: localChangedKey) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: localChangedKey) }
    }

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

    private func save(touch: Bool = true) {
        if touch { localChangedAt = Date() }
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
        if let data = defaults.data(forKey: deletedLibsKey),
           let v = try? SyncService.decoder().decode([String: Date].self, from: data) {
            deletedLibraries = v
        }
        if let data = defaults.data(forKey: deletedTracksKey),
           let v = try? SyncService.decoder().decode([String: [String: Date]].self, from: data) {
            deletedTracks = v
        }
    }

    private func savePrefs(touch: Bool = true) {
        if touch { localChangedAt = Date() }
        let defaults = UserDefaults.standard
        defaults.set(Array(favoriteIDs), forKey: favoritesKey)
        defaults.set(recentIDs, forKey: recentKey)
        if let data = try? SyncService.encoder().encode(deletedLibraries) {
            defaults.set(data, forKey: deletedLibsKey)
        }
        if let data = try? SyncService.encoder().encode(deletedTracks) {
            defaults.set(data, forKey: deletedTracksKey)
        }
    }

    // MARK: - 跨设备同步

    /// 生成传给 SyncService 的本地快照。
    /// 曲目不放在这里（每个库单独一个文件上传），只带库的轻量描述。
    func syncSnapshot(deviceName: String) -> SyncAccount {
        let metas = libraries.map { lib in
            LibraryMeta(id: lib.id,
                        name: lib.name,
                        providerKindRaw: lib.providerKindRaw,
                        folderID: lib.folderID,
                        folderName: lib.folderName,
                        includeSubfolders: lib.scansSubfolders,
                        createdAt: lib.createdAt,
                        lastScanAt: lib.lastScanAt,
                        updatedAt: lib.updatedAt ?? lib.lastScanAt ?? lib.createdAt)
        }
        // 本机数据的真实最新改动时间（取库和收藏/记录里较新的那个）
        let newestLibrary = metas.map(\.updatedAt).max() ?? .distantPast
        let stamp = max(newestLibrary, localChangedAt)
        return SyncAccount(schemaVersion: 1,
                           updatedAt: stamp,
                           deviceName: deviceName,
                           libraries: metas,
                           favorites: Array(favoriteIDs),
                           recent: recentIDs,
                           session: PlaybackSession.load(),
                           deletedLibraries: deletedLibraries,
                           deletedTracks: deletedTracks)
    }

    /// 把合并结果落到本地。同步过程本身不该再反过来触发一轮上传，
    /// 所以这里不调 scheduleSync。
    func applySync(libraries newLibs: [MusicLibrary],
                   favorites: Set<String>,
                   recent: [String],
                   session: PlaybackSession?,
                   deletedLibraries libTombstones: [String: Date] = [:],
                   deletedTracks trackTombstones: [String: [String: Date]] = [:]) {
        libraries = newLibs
        favoriteIDs = favorites
        recentIDs = recent
        if !libTombstones.isEmpty {
            // 墓碑取最新删除时间：min 会让最早的删除永远压不过恢复后的 updatedAt，
            // 之后怎么删都删不掉（「删库复活」的帮凶之一）
            deletedLibraries.merge(libTombstones) { old, new in max(old, new) }
        }
        for (libID, marks) in trackTombstones {
            var existing = deletedTracks[libID] ?? [:]
            for (tid, at) in marks {
                existing[tid] = max(existing[tid] ?? at, at)
            }
            deletedTracks[libID] = existing
        }
        // 同步下来不算「本机改动」，否则会立刻反过来再推一轮
        save(touch: false)
        savePrefs(touch: false)

        // 合并下来的「继续播放」只在本机还没有更新的会话时才采用，
        // 否则正在听的时候同步一下会把播放队列换掉。
        // 只写文件不换当前队列：下次启动生效，不打断正在播的歌。
        if let session {
            if let local = PlaybackSession.load() {
                if session.updatedAt > local.updatedAt { session.save() }
            } else {
                session.save()
            }
        }
    }

    /// 同步下来的曲目只有封面 URL，本地图要补。
    /// 边补边落盘，界面上的封面会分批逐个出现。
    private var backfilling = false
    /// 本次启动里「在线搜封面也没找到」的曲目，避免每个同步周期都白搜一轮
    private var rescueFailedIDs = Set<String>()

    func backfillArtwork(libraryIDs: [String]) {
        guard !backfilling else { return }
        backfilling = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.backfilling = false }

            for libID in libraryIDs {
                // 第一步：老数据（这个字段还没诞生的年代刮的）没有封面 URL，
                // 但存了网易云 ID，可以拿它把封面地址反查回来。
                await self.resolveMissingArtworkURLs(libraryID: libID)

                // 第二步：按 URL 把图下载到本地缓存
                guard let lib = self.library(id: libID) else { continue }
                let pending = lib.tracks.filter { t in
                    guard let url = t.artworkURL, !url.isEmpty else { return false }
                    guard let file = t.artworkFile, !file.isEmpty else { return true }
                    return MetadataScraper.artworkURL(file: file) == nil
                }
                // 注意这里不能用 continue：后面还有第三步（连 URL 都没有的在线兜底）
                if !pending.isEmpty {
                    let batchSize = 4
                    var cursor = 0
                    while cursor < pending.count {
                        let slice = Array(pending[cursor..<min(cursor + batchSize, pending.count)])
                        let results = await withTaskGroup(of: (String, String?).self) { group in
                            for t in slice {
                                group.addTask {
                                    guard let url = t.artworkURL,
                                          let data = await MusicSearchService.downloadImage(url) else {
                                        return (t.id, nil)
                                    }
                                    return (t.id, MetadataScraper.saveArtwork(data, key: t.id))
                                }
                            }
                            var out: [(String, String?)] = []
                            for await item in group { out.append(item) }
                            return out
                        }
                        if let li = libraries.firstIndex(where: { $0.id == libID }) {
                            var changed = false
                            for (trackID, name) in results {
                                guard let name,
                                      let ti = libraries[li].tracks.firstIndex(where: { $0.id == trackID }) else { continue }
                                libraries[li].tracks[ti].artworkFile = name
                                changed = true
                            }
                            // 补封面属于本机缓存行为，不该被当成「用户改了数据」推回云端
                            if changed { save(touch: false) }
                        }
                        cursor += batchSize
                    }
                }

                // 第三步：连 URL 都没有的（artworkURL 字段诞生前刮的老数据、
                // 且非网易云来源），按「歌名 + 歌手」做一次仅封面的在线查找
                await self.rescueMissingCovers(libraryID: libID)
            }
        }
    }

    /// 仅封面的在线兜底：老数据在云端只有歌名歌手，没有封面地址，
    /// neteaseID 也没有的（QQ / iTunes 来源）连反查都无从下手，新设备上就是空白。
    /// 这里按「歌名 + 歌手」在线匹配，命中即下载落盘并记下 artworkURL——
    /// URL 会随下次同步传回云端，等于顺手把云端数据也修好，其它设备同样受益。
    private func rescueMissingCovers(libraryID: String) async {
        guard let lib = library(id: libraryID) else { return }
        let pending = lib.tracks.filter { t in
            guard t.scraped, !t.title.isEmpty else { return false }
            // 本地已经有能用的封面文件就不动
            if let f = t.artworkFile, !f.isEmpty, MetadataScraper.artworkURL(file: f) != nil { return false }
            // 本次启动里已经试过且没找到的不再重复搜（每个同步周期省一轮请求）
            if rescueFailedIDs.contains(t.id) { return false }
            return true
        }
        guard !pending.isEmpty else { return }

        let batchSize = 3
        var cursor = 0
        while cursor < pending.count {
            let slice = Array(pending[cursor..<min(cursor + batchSize, pending.count)])
            let results = await withTaskGroup(of: (String, String?, String?).self) { group in
                for t in slice {
                    group.addTask {
                        guard let cover = await MetadataScraper.coverHit(title: t.title, artist: t.artist),
                              let data = await MusicSearchService.downloadImage(cover) else {
                            return (t.id, nil, nil)
                        }
                        return (t.id, MetadataScraper.saveArtwork(data, key: t.id), cover)
                    }
                }
                var out: [(String, String?, String?)] = []
                for await item in group { out.append(item) }
                return out
            }
            if let li = libraries.firstIndex(where: { $0.id == libraryID }) {
                var changed = false
                for (trackID, name, url) in results {
                    guard let name, let url,
                          let ti = libraries[li].tracks.firstIndex(where: { $0.id == trackID }) else { continue }
                    libraries[li].tracks[ti].artworkFile = name
                    libraries[li].tracks[ti].artworkURL = url
                    changed = true
                }
                // 补封面属于本机缓存行为，不该被当成「用户改了数据」推回云端；
                // 但 artworkURL 的变化会在下次同步时自然传上去（needsUpload 比较它）
                if changed { save(touch: false) }
            }
            // 没找到的记下来，这个启动周期内不再重试
            for (trackID, name, _) in results where name == nil {
                rescueFailedIDs.insert(trackID)
            }
            cursor += batchSize
            // 每批里有搜索请求，批间歇一下，别把在线源打疼了
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    /// 用 neteaseID 反查封面地址，补进 artworkURL。
    /// 接口一次最多接受 20 个 id，所以分批走。
    private func resolveMissingArtworkURLs(libraryID: String) async {
        guard let lib = library(id: libraryID) else { return }
        let needed = Set(lib.tracks.filter {
            ($0.artworkURL ?? "").isEmpty && ($0.neteaseID ?? 0) > 0
        }.compactMap { $0.neteaseID })
        guard !needed.isEmpty else { return }

        var resolved: [Int: String] = [:]
        let ids = Array(needed)
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 20, ids.count)])
            let detail = await MusicSearchService.neteaseDetails(ids: chunk)
            for (k, v) in detail where !(v.coverURL ?? "").isEmpty {
                resolved[k] = v.coverURL
            }
            start += 20
        }
        guard !resolved.isEmpty,
              let li = libraries.firstIndex(where: { $0.id == libraryID }) else { return }

        var changed = false
        for i in libraries[li].tracks.indices {
            guard (libraries[li].tracks[i].artworkURL ?? "").isEmpty,
                  let nid = libraries[li].tracks[i].neteaseID,
                  let url = resolved[nid] else { continue }
            libraries[li].tracks[i].artworkURL = url
            changed = true
        }
        if changed { save(touch: false) }
    }

    /// 新设备扫描前先问问云端有没有已经刮好的结果。
    /// 有的话直接填进去并标记 scraped，整首歌就完全跳过刮削——
    /// 这是「换设备不用重新刮」的核心。
    func reuseCloudMetadata(_ tracks: inout [LibraryTrack], kind: CloudKind) {
        guard GitHubAccount.isSignedIn else { return }
        // 从所有本地库里找同 provider 的已刮削记录（同步下来的库也在其中）
        var index: [String: LibraryTrack] = [:]
        for lib in libraries where lib.providerKindRaw == kind.rawValue {
            for t in lib.tracks where t.scraped {
                index[t.fileID] = t
            }
        }
        guard !index.isEmpty else { return }
        for i in tracks.indices {
            guard let hit = index[tracks[i].fileID] else { continue }
            tracks[i].title = hit.title
            tracks[i].artist = hit.artist ?? tracks[i].artist
            tracks[i].album = hit.album ?? tracks[i].album
            tracks[i].duration = hit.duration ?? tracks[i].duration
            tracks[i].artworkFile = hit.artworkFile
            tracks[i].artworkURL = hit.artworkURL
            tracks[i].neteaseID = hit.neteaseID
            tracks[i].confidence = hit.confidence
            tracks[i].metaSource = hit.metaSource
            tracks[i].scraped = true
        }
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
        SyncService.shared.scheduleSync(reason: "收藏变化")
    }

    func markPlayed(_ trackID: String) {
        recentIDs.removeAll { $0 == trackID }
        recentIDs.insert(trackID, at: 0)
        if recentIDs.count > maxRecent { recentIDs = Array(recentIDs.prefix(maxRecent)) }
        savePrefs()
        // 切歌很频繁，给一个更长的延迟，等停下来再推
        SyncService.shared.scheduleSync(reason: "播放记录", delay: 25)
    }

    func clearRecent() {
        recentIDs = []
        savePrefs()
        SyncService.shared.scheduleSync(reason: "清空播放记录")
    }

    // MARK: - 库管理

    func removeLibrary(id: String) {
        libraries.removeAll { $0.id == id }
        // 留墓碑：不然同步时另一台设备还留着这个库，会被"合并"回来
        deletedLibraries[id] = Date()
        save()
        savePrefs()
        SyncService.shared.scheduleSync(reason: "删除音乐库")
    }

    func renameLibrary(id: String, to name: String) {
        guard let idx = libraries.firstIndex(where: { $0.id == id }) else { return }
        libraries[idx].name = name
        libraries[idx].updatedAt = Date()
        save()
        SyncService.shared.scheduleSync(reason: "重命名音乐库")
    }

    // MARK: - 扫描

    /// 新建音乐库并扫描。folder 可以是任意层级的文件夹；includeSubfolders 决定是否递归。
    func addLibrary(name: String,
                    providerKind: CloudKind,
                    folder: CloudFile,
                    includeSubfolders: Bool = true) async {
        guard let provider = ProviderRegistry.provider(kind: providerKind) else { return }

        // 已经有同一个云盘文件夹的库（多半是别的设备同步过来的）就不新建，
        // 直接在它身上重新扫描：刮削结果全都还在，这次扫描只补新增的歌。
        if let existing = libraries.first(where: {
            $0.providerKindRaw == providerKind.rawValue && $0.folderID == folder.id
        }) {
            if let idx = libraries.firstIndex(where: { $0.id == existing.id }) {
                libraries[idx].updatedAt = Date()
            }
            save()
            await rescan(libraryID: existing.id)
            return
        }

        let libID = UUID().uuidString
        progress[libID] = ScanProgress(phase: includeSubfolders ? "扫描目录…" : "读取目录…")
        // 扫描 + 刮削可能持续很久，熄屏/切后台时保活，避免被系统挂起
        BackgroundKeepAlive.shared.begin()
        defer { BackgroundKeepAlive.shared.end() }

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

        var found = await collect(provider: provider, kind: providerKind, root: folder,
                                  includeSubfolders: includeSubfolders, libID: libID)
        // 别的设备已经刮过的，直接沿用，一首都不重刮
        let pendingBefore = found.filter { !$0.scraped }.count
        reuseCloudMetadata(&found, kind: providerKind)
        let hit = pendingBefore - found.filter { !$0.scraped }.count

        if let idx = libraries.firstIndex(where: { $0.id == libID }) {
            libraries[idx].tracks = found
            libraries[idx].lastScanAt = Date()
            libraries[idx].updatedAt = Date()
        }
        save()

        progress[libID]?.phase = hit > 0
            ? "沿用云端刮削 \(hit) 首，其余开始刮削…"
            : (found.isEmpty ? "没有找到音乐文件" : "入库完成，开始刮削…")
        progress[libID]?.totalToScrape = found.count

        await scrapeAll(libraryID: libID, providerKind: providerKind)
        progress[libID] = nil
        SyncService.shared.scheduleSync(reason: "扫描完成")
    }

    /// 重新扫描已有库（只补新增文件，随后补刮未刮过的）
    func rescan(libraryID: String) async {
        guard let lib = library(id: libraryID),
              let provider = ProviderRegistry.provider(kind: lib.providerKind) else { return }
        progress[libraryID] = ScanProgress(phase: "重新扫描…")
        BackgroundKeepAlive.shared.begin()
        defer { BackgroundKeepAlive.shared.end() }
        let root = CloudFile(id: lib.folderID, name: lib.folderName, size: 0, isFolder: true)
        var found = await collect(provider: provider, kind: lib.providerKind, root: root,
                                  includeSubfolders: lib.scansSubfolders, libID: libraryID)
        // 新增的文件先在云端找有没有刮好的记录；刚换设备时这一条能省掉整库重刮
        reuseCloudMetadata(&found, kind: lib.providerKind)

        var known = Set(lib.tracks.map { $0.fileID })
        var added = 0
        if let idx = libraries.firstIndex(where: { $0.id == libraryID }) {
            for t in found where !known.contains(t.fileID) {
                libraries[idx].tracks.append(t)
                known.insert(t.fileID)
                added += 1
            }
            // 老库补文件夹路径（旧版本扫描时没记录），只补路径不动元数据
            var pathMap: [String: [String]] = [:]
            for f in found { if let p = f.folderPath, !p.isEmpty { pathMap[f.fileID] = p } }
            for i in libraries[idx].tracks.indices where libraries[idx].tracks[i].folderPath == nil {
                if let p = pathMap[libraries[idx].tracks[i].fileID] {
                    libraries[idx].tracks[i].folderPath = p
                }
            }
            libraries[idx].lastScanAt = Date()
            libraries[idx].updatedAt = Date()
        }
        save()
        progress[libraryID]?.phase = "新增 \(added) 首，开始刮削…"
        await scrapeAll(libraryID: libraryID, providerKind: lib.providerKind)
        progress[libraryID] = nil
        SyncService.shared.scheduleSync(reason: "扫描完成")
    }

    /// 老库补文件夹路径（旧版本扫描时没记录 folderPath）。
    /// 有了「歌手/专辑」目录结构，刮削才能拿目录名当上下文去约束匹配。
    private func backfillFolderPaths(libraryID: String) async {
        guard let lib = library(id: libraryID),
              lib.tracks.contains(where: { $0.folderPath == nil }),
              let provider = ProviderRegistry.provider(kind: lib.providerKind) else { return }
        progress[libraryID]?.phase = "整理目录结构…"
        let root = CloudFile(id: lib.folderID, name: lib.folderName, size: 0, isFolder: true)
        let found = await collect(provider: provider, kind: lib.providerKind, root: root,
                                  includeSubfolders: lib.scansSubfolders, libID: libraryID)
        var pathMap: [String: [String]] = [:]
        for f in found { if let p = f.folderPath, !p.isEmpty { pathMap[f.fileID] = p } }
        guard let idx = libraries.firstIndex(where: { $0.id == libraryID }) else { return }
        for i in libraries[idx].tracks.indices where libraries[idx].tracks[i].folderPath == nil {
            if let p = pathMap[libraries[idx].tracks[i].fileID] {
                libraries[idx].tracks[i].folderPath = p
            }
        }
        save()
    }

    /// 强制重刮全部：把元数据回滚成文件名解析结果，再重新匹配（用于修正以前的错误）
    func rescrapeAll(libraryID: String) async {
        guard let lib = library(id: libraryID) else { return }
        progress[libraryID] = ScanProgress(phase: "重置元数据…")
        BackgroundKeepAlive.shared.begin()
        defer { BackgroundKeepAlive.shared.end() }

        // 先把「歌手/专辑」目录结构补齐，否则老库没有上下文可用
        await backfillFolderPaths(libraryID: libraryID)

        if let idx = libraries.firstIndex(where: { $0.id == libraryID }) {
            for i in libraries[idx].tracks.indices {
                // 手动改过/手动匹配过的歌不动：用户的选择优先于自动匹配，
                // 否则重新刮削会把辛苦修好的信息又冲掉。
                if libraries[idx].tracks[i].metaSource == "manual" { continue }
                let t = libraries[idx].tracks[i]
                let parsed = MusicScanner.parse(t.fileName)
                let hint = scrapeHints(for: t)
                libraries[idx].tracks[i].title = parsed.title
                libraries[idx].tracks[i].artist = parsed.artist ?? hint.artist
                // 专辑优先用「歌手 - 专辑」/「歌手/专辑」结构推断，其次才退回目录名
                libraries[idx].tracks[i].album = hint.album
                    ?? (t.parentID != lib.folderID ? t.parentName : nil)
                libraries[idx].tracks[i].scraped = false
                libraries[idx].tracks[i].confidence = nil
                libraries[idx].tracks[i].metaSource = "filename"
                libraries[idx].tracks[i].neteaseID = nil
            }
        }
        save()

        // 纯在线修正先跑一轮：只靠文件名解析 + 搜索 API 把歌名/歌手摆正，
        // 完全不碰文件直链。WAV 分轨这类无标签文件如果直链读取失败（限流/超时），
        // 后面的 scrapeAll 只会把错误的文件名解析固化下来——文字元数据必须先正确。
        await onlineFixPass(libraryID: libraryID)

        await scrapeAll(libraryID: libraryID, providerKind: lib.providerKind)
        progress[libraryID] = nil
        SyncService.shared.scheduleSync(reason: "重新刮削完成")
    }

    /// 纯在线识别：不取文件直链、不读内嵌标签，只靠文件名重新解析 + 搜索 API
    /// 修正歌名/歌手（两方向匹配在 MusicSearchService.bestMatch 里）。
    /// 用于「歌名--歌手」倒序命名、以及直链读取失败导致错误被固化的场景。
    /// 手动改过（metaSource=manual）的曲目不动；封面/时长等仍由后续完整刮削补齐。
    func onlineFixPass(libraryID: String) async {
        guard let lib = library(id: libraryID) else { return }
        progress[libraryID] = ScanProgress(phase: "在线识别修正…")
        let targets = lib.tracks.filter { $0.metaSource != "manual" }
        progress[libraryID]?.totalToScrape = targets.count
        var done = 0
        let batchSize = 4
        var cursor = 0
        while cursor < targets.count {
            let batch = Array(targets[cursor..<min(cursor + batchSize, targets.count)])
            // 目录提示在主线程先算好，别在并发任务里再回头读 self
            let batchHints = batch.map { scrapeHints(for: $0) }
            let fixed: [(String, SongInfo, Double)] = await withTaskGroup(
                of: (String, SongInfo?, Double).self) { group in
                for (i, t) in batch.enumerated() {
                    let hint = batchHints[i]
                    group.addTask {
                        // 匹配输入用文件名重新解析：库里可能存着旧解析的错位结果
                        let parsed = MusicScanner.parse(t.fileName)
                        let title = parsed.title.isEmpty ? t.title : parsed.title
                        let artist = parsed.artist ?? hint.artist ?? t.artist
                        guard !title.isEmpty else { return (t.id, nil, 0) }
                        let m = await MusicSearchService.bestMatch(title: title,
                                                                   artist: artist,
                                                                   artistHint: hint.artist)
                        return (t.id, m?.info, m?.score ?? 0)
                    }
                }
                var out: [(String, SongInfo?, Double)] = []
                for await r in group { out.append(r) }
                return out.compactMap { id, info, score in
                    info.map { (id, $0, score) }
                }
            }

            if let li = libraries.firstIndex(where: { $0.id == libraryID }) {
                var tracks = libraries[li].tracks
                for (id, info, score) in fixed {
                    guard let ti = tracks.firstIndex(where: { $0.id == id }) else { continue }
                    if let v = info.title, !v.isEmpty { tracks[ti].title = v }
                    if let v = info.artist, !v.isEmpty { tracks[ti].artist = v }
                    if let v = info.album, !v.isEmpty { tracks[ti].album = v }
                    if let v = info.duration { tracks[ti].duration = v }
                    if let v = info.neteaseID { tracks[ti].neteaseID = v }
                    tracks[ti].confidence = score
                    tracks[ti].metaSource = "online"
                    // scraped 保持 false：让后面的完整刮削继续补封面/内嵌标签
                    tracks[ti].updatedAt = Date()
                }
                libraries[li].tracks = tracks
            }
            done += fixed.count
            progress[libraryID]?.scrapedTracks = done
            if let total = progress[libraryID]?.totalToScrape {
                progress[libraryID]?.phase = "在线识别 \(done)/\(total)"
            }
            cursor += batchSize
        }
        save()
    }

    /// 只补缺失：不动已有的歌名/歌手，只处理和在线补齐「没封面 / 没专辑 / 之前只有文件名」的歌。
    /// 比整库重刮安全得多——重刮会按文件名把现有信息全部重置，一次不理想的匹配就会把对的改错。
    func fillMissing(libraryID: String) async {
        guard let lib = library(id: libraryID) else { return }
        progress[libraryID] = ScanProgress(phase: "检查缺失信息…")
        BackgroundKeepAlive.shared.begin()
        defer { BackgroundKeepAlive.shared.end() }

        await backfillFolderPaths(libraryID: libraryID)

        if let idx = libraries.firstIndex(where: { $0.id == libraryID }) {
            for i in libraries[idx].tracks.indices {
                let t = libraries[idx].tracks[i]
                // 手动改过的绝不碰
                if t.metaSource == "manual" { continue }
                let needy = (t.artworkFile ?? "").isEmpty
                    || (t.album ?? "").isEmpty
                    || (t.artist ?? "").isEmpty
                    || t.metaSource == "filename"
                libraries[idx].tracks[i].scraped = !needy
            }
        }
        save()
        await scrapeAll(libraryID: libraryID, providerKind: lib.providerKind)
        progress[libraryID] = nil
        SyncService.shared.scheduleSync(reason: "重新刮削完成")
    }

    /// 只重刮单曲（不动其他）
    func rescrapeTrack(libraryID: String, trackID: String) async {
        guard let lib = library(id: libraryID),
              let item = lib.tracks.first(where: { $0.id == trackID }),
              let provider = ProviderRegistry.provider(kind: lib.providerKind) else { return }
        let file = CloudFile(id: item.fileID, name: item.fileName, size: item.size,
                             isFolder: false, modifiedAt: nil, extra: ["parentID": item.parentID])
        guard let link = try? await provider.streamURL(file: file) else {
            // 直链失败也要做纯在线修正：只靠文件名解析 + 搜索 API。
            // 原来直接 return，错误元数据原地不动，用户点「重新刮削这首」毫无效果
            let parsed = MusicScanner.parse(item.fileName)
            let title = parsed.title.isEmpty ? item.title : parsed.title
            let artist = parsed.artist ?? hint.artist ?? item.artist
            guard !title.isEmpty,
                  let m = await MusicSearchService.bestMatch(title: title, artist: artist,
                                                             artistHint: hint.artist) else { return }
            updateTrack(libraryID: libraryID, trackID: trackID) { t in
                if let v = m.info.title, !v.isEmpty { t.title = v }
                if let v = m.info.artist, !v.isEmpty { t.artist = v }
                if let v = m.info.album, !v.isEmpty { t.album = v }
                if let v = m.info.duration { t.duration = v }
                if let v = m.info.neteaseID { t.neteaseID = v }
                t.artworkURL = m.info.coverURL ?? t.artworkURL
                t.confidence = m.score
                t.metaSource = "online"
                t.scraped = true
            }
            save()
            return
        }
        let hint = scrapeHints(for: item)
        // 匹配输入用文件名重新解析的结果：库里可能存着旧版本解析出的「-陈鸿宇」
        // 这类残渣，拿残渣去搜永远搜不对；文件名才是干净的原始信息
        let parsed = MusicScanner.parse(item.fileName)
        let fallbackTitle = parsed.title.isEmpty ? item.title : parsed.title
        let fallbackArtist = parsed.artist ?? item.artist
        let meta = await MetadataScraper.scrape(url: link.url, headers: link.headers, trackID: item.id,
                                                fallbackTitle: fallbackTitle, fallbackArtist: fallbackArtist,
                                                hintArtist: hint.artist, hintAlbum: hint.album,
                                                forceOnline: true)
        updateTrack(libraryID: libraryID, trackID: trackID) { t in
            if let v = meta.title, !v.isEmpty { t.title = v }
            if let v = meta.artist, !v.isEmpty { t.artist = v }
            if let v = meta.album, !v.isEmpty { t.album = v }
            if let v = meta.duration { t.duration = v }
            if let v = meta.artworkFile { t.artworkFile = v }
            if let v = meta.artworkURL { t.artworkURL = v }
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
            t.artworkURL = info.coverURL
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
        // path = 从库根到当前目录的目录名（不含库根），用于推断歌手/专辑
        var queue: [(id: String, name: String, path: [String])] = [(root.id, root.name, [])]
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
                    if includeSubfolders {
                        queue.append((item.id, item.name, current.path + [item.name]))
                    }
                    continue
                }
                guard MusicScanner.isAudioFile(item.name) else { continue }
                let parsed = MusicScanner.parse(item.name)
                let isRoot = current.id == root.id
                // 用目录名推断歌手/专辑：比文件名可靠得多（人整理目录时是认真写的）
                let hint = FolderHints.hint(for: current.path, filenameArtist: parsed.artist)
                let hintedArtist = hint.artistConfidence >= 0.80 ? hint.artist : nil
                found.append(LibraryTrack(
                    id: "\(kind.rawValue)-\(item.id)",
                    fileID: item.id,
                    fileName: item.name,
                    size: item.size,
                    parentID: current.id,
                    title: parsed.title,
                    artist: parsed.artist ?? hintedArtist,
                    album: hint.album ?? (isRoot ? nil : current.name),
                    duration: nil,
                    artworkFile: nil,
                    scraped: false,
                    neteaseID: nil,
                    addedAt: now,
                    metaSource: "filename",
                    confidence: nil,
                    parentName: isRoot ? nil : current.name,
                    folderPath: current.path.isEmpty ? nil : current.path,
                    updatedAt: now))
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

    /// 用「目录结构 + 文件名」推算歌手/专辑提示。
    /// 老库没有 folderPath 时退化成父目录名（单层），仍能靠文件名交叉验证判断是不是歌手目录。
    private func folderHints(for t: LibraryTrack) -> FolderHints.Hint {
        let path = t.folderPath ?? (t.parentName.map { [$0] } ?? [])
        let fileArtist = MusicScanner.parse(t.fileName).artist
        return FolderHints.hint(for: path, filenameArtist: fileArtist)
    }

    /// 刮削时真正拿去用的提示：只取可信度够高的，
    /// 避免把「新建文件夹」「合集」猜成歌手/专辑反而制造错误。
    private func scrapeHints(for t: LibraryTrack) -> (artist: String?, album: String?) {
        let h = folderHints(for: t)
        return (h.artistConfidence >= 0.80 ? h.artist : nil,
                h.albumConfidence >= 0.50 ? h.album : nil)
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
            // 目录提示在主线程先算好，别在并发任务里再回头读 self
            let batchHints = batch.map { scrapeHints(for: $0) }

            let results = await withTaskGroup(of: ScrapeOutcome.self) { group in
                for (i, track) in batch.enumerated() {
                    let hint = batchHints[i]
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
                                                                fallbackArtist: track.artist,
                                                                hintArtist: hint.artist,
                                                                hintAlbum: hint.album)
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
                        if let v = meta.artworkURL { tracks[ti].artworkURL = v }
                        if let v = meta.neteaseID { tracks[ti].neteaseID = v }
                        if meta.matched { tracks[ti].confidence = meta.confidence }
                        tracks[ti].metaSource = meta.matched ? "online" : "filename"
                        tracks[ti].scraped = true
                        tracks[ti].updatedAt = Date()
                    } else {
                        tracks[ti].scraped = true
                        tracks[ti].updatedAt = Date()
                    }
                }
                libraries[li].tracks = tracks

                // 正在播放的那首如果刚被重刮，同步刷新播放队列（否则播放页/锁屏还是旧信息）
                if let cur = PlayerManager.shared.currentTrack,
                   let fresh = tracks.first(where: { $0.id == cur.id }) {
                    PlayerManager.shared.refreshTrackMetadata(fresh.toTrack(kind: providerKind))
                }
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
        libraries[li].tracks[ti].updatedAt = Date()
        libraries[li].updatedAt = Date()
        // 元数据变了就把新信息同步给正在播放的队列，
        // 播放页 / 锁屏 / 小组件才会跟着更新（否则一直显示旧歌手）
        let kind = libraries[li].providerKind
        PlayerManager.shared.refreshTrackMetadata(libraries[li].tracks[ti].toTrack(kind: kind))
        SyncService.shared.scheduleSync(reason: "元数据更新")
    }
}
