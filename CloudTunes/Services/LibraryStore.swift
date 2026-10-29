import Foundation

/// 音乐库管理：扫描云盘文件夹、递归收集音频、持久化、后台刮削
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var libraries: [MusicLibrary] = []
    @Published private(set) var progress: [String: ScanProgress] = [:]

    private let storageURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("libraries.json")
    }()

    init() { load() }

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

    func library(id: String) -> MusicLibrary? { libraries.first { $0.id == id } }

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

    /// 新建音乐库并扫描。folder 为云端文件夹。
    func addLibrary(name: String, providerKind: CloudKind, folder: CloudFile) async {
        guard let provider = ProviderRegistry.provider(kind: providerKind) else { return }
        let libID = UUID().uuidString
        progress[libID] = ScanProgress(phase: "扫描目录…")

        var lib = MusicLibrary(id: libID,
                               name: name.isEmpty ? folder.name : name,
                               providerKindRaw: providerKind.rawValue,
                               folderID: folder.id,
                               folderName: folder.name,
                               tracks: [],
                               createdAt: Date(),
                               lastScanAt: nil)
        libraries.append(lib)
        save()

        // 1) 递归收集音频文件
        var queue: [(id: String, name: String)] = [(folder.id, folder.name)]
        var visited = Set<String>()
        var found: [LibraryTrack] = []
        let maxFolders = 500
        let maxTracks = 5000

        while !queue.isEmpty, visited.count < maxFolders, found.count < maxTracks {
            let current = queue.removeFirst()
            if visited.contains(current.id) { continue }
            visited.insert(current.id)
            progress[libID]?.scannedFolders = visited.count
            progress[libID]?.phase = "扫描：\(current.name)"

            guard let items = try? await ProviderRegistry.listWithParent(provider, folderID: current.id) else { continue }
            for item in items {
                if item.isFolder {
                    queue.append((item.id, item.name))
                } else if MusicScanner.isAudioFile(item.name) {
                    let parsedTitle = MusicScanner.parseTitle(item.name)
                    let parsedArtist = MusicScanner.parseArtist(item.name)
                    found.append(LibraryTrack(
                        id: "\(providerKind.rawValue)-\(item.id)",
                        fileID: item.id,
                        fileName: item.name,
                        size: item.size,
                        parentID: current.id,
                        title: parsedTitle,
                        artist: parsedArtist,
                        // 专辑名先用所在文件夹名兜底
                        album: current.id == folder.id ? nil : current.name,
                        duration: nil,
                        artworkFile: nil,
                        scraped: false))
                }
            }
            progress[libID]?.foundTracks = found.count
        }

        // 2) 立即入库（先用文件名信息，UI 马上可用）
        if let idx = libraries.firstIndex(where: { $0.id == libID }) {
            libraries[idx].tracks = found
            libraries[idx].lastScanAt = Date()
            lib = libraries[idx]
        }
        save()
        progress[libID]?.phase = "入库完成，开始刮削封面/标签…"
        progress[libID]?.totalToScrape = found.count

        // 3) 后台逐个刮削元数据与封面
        await scrapeAll(libraryID: libID, providerKind: providerKind)

        progress[libID] = nil
    }

    /// 重新扫描已有库（新增文件 / 补刮元数据）
    func rescan(libraryID: String) async {
        guard let lib = library(id: libraryID),
              let provider = ProviderRegistry.provider(kind: lib.providerKind) else { return }
        progress[libraryID] = ScanProgress(phase: "重新扫描…")
        var known = Set(lib.tracks.map { $0.fileID })
        var queue: [(id: String, name: String)] = [(lib.folderID, lib.folderName)]
        var visited = Set<String>()
        var added = 0

        while !queue.isEmpty, visited.count < 500 {
            let current = queue.removeFirst()
            if visited.contains(current.id) { continue }
            visited.insert(current.id)
            progress[libraryID]?.scannedFolders = visited.count
            guard let items = try? await ProviderRegistry.listWithParent(provider, folderID: current.id) else { continue }
            for item in items {
                if item.isFolder { queue.append((item.id, item.name)); continue }
                guard MusicScanner.isAudioFile(item.name), !known.contains(item.id) else { continue }
                known.insert(item.id)
                let t = LibraryTrack(id: "\(lib.providerKind.rawValue)-\(item.id)",
                                     fileID: item.id, fileName: item.name, size: item.size,
                                     parentID: current.id,
                                     title: MusicScanner.parseTitle(item.name),
                                     artist: MusicScanner.parseArtist(item.name),
                                     album: current.name, duration: nil, artworkFile: nil, scraped: false)
                if let idx = libraries.firstIndex(where: { $0.id == libraryID }) {
                    libraries[idx].tracks.append(t)
                }
                added += 1
            }
        }
        save()
        progress[libraryID]?.phase = "新增 \(added) 首，开始刮削…"
        await scrapeAll(libraryID: libraryID, providerKind: lib.providerKind)
        progress[libraryID] = nil
    }

    // MARK: - 刮削

    private func scrapeAll(libraryID: String, providerKind: CloudKind) async {
        guard let provider = ProviderRegistry.provider(kind: providerKind),
              let lib = library(id: libraryID) else { return }
        let pending = lib.tracks.filter { !$0.scraped }
        progress[libraryID]?.totalToScrape = lib.tracks.count
        var done = lib.tracks.count - pending.count

        for track in pending {
            if Task.isCancelled { break }
            progress[libraryID]?.scrapedTracks = done
            progress[libraryID]?.phase = "刮削：\(track.title)"
            let file = CloudFile(id: track.fileID, name: track.fileName, size: track.size,
                                 isFolder: false, modifiedAt: nil, extra: ["parentID": track.parentID])
            if let link = try? await provider.streamURL(file: file) {
                let meta = await MetadataScraper.scrape(url: link.url, headers: link.headers, trackID: track.id)
                updateTrack(libraryID: libraryID, trackID: track.id) { t in
                    if let v = meta.title, !v.isEmpty { t.title = v }
                    if let v = meta.artist, !v.isEmpty { t.artist = v }
                    if let v = meta.album, !v.isEmpty { t.album = v }
                    if let v = meta.duration { t.duration = v }
                    if let v = meta.artworkFile { t.artworkFile = v }
                    t.scraped = true
                }
            } else {
                updateTrack(libraryID: libraryID, trackID: track.id) { $0.scraped = true }
            }
            done += 1
            progress[libraryID]?.scrapedTracks = done
            if done % 8 == 0 { save() }
        }
        save()
    }

    private func updateTrack(libraryID: String, trackID: String, _ mutate: (inout LibraryTrack) -> Void) {
        guard let li = libraries.firstIndex(where: { $0.id == libraryID }),
              let ti = libraries[li].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        mutate(&libraries[li].tracks[ti])
    }
}
