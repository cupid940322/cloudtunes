import Foundation

/// 音乐库（一个云盘文件夹 = 一个库）
struct MusicLibrary: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var providerKindRaw: String
    var folderID: String
    var folderName: String
    var tracks: [LibraryTrack]
    var createdAt: Date
    var lastScanAt: Date?
    var includeSubfolders: Bool?

    var providerKind: CloudKind { CloudKind(rawValue: providerKindRaw) ?? .guangya }
    var scansSubfolders: Bool { includeSubfolders ?? true }

    var artistCount: Int {
        Set(tracks.compactMap { ($0.artist?.isEmpty == false) ? $0.artist! : nil }).count
    }
    var albumCount: Int {
        Set(tracks.compactMap { $0.albumKey }).count
    }
    var totalDuration: Double { tracks.reduce(0) { $0 + ($1.duration ?? 0) } }
    /// 最近添加到库的封面（用于库卡片）
    var coverArtwork: String? {
        let sorted = tracks.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
        return sorted.compactMap { $0.artworkFile }.first
    }

    func albums() -> [AlbumGroup] {
        var map: [String: [LibraryTrack]] = [:]
        for t in tracks {
            let key = t.albumKey ?? "unknown-\(t.id)"
            map[key, default: []].append(t)
        }
        return map.map { key, value in
            let first = value.first
            return AlbumGroup(id: key,
                              name: first?.displayAlbum ?? "未知专辑",
                              artist: value.compactMap { ($0.artist?.isEmpty == false) ? $0.artist : nil }.first,
                              tracks: value.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        }
        .filter { $0.name != "未知专辑" || $0.tracks.count > 0 }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func artists() -> [ArtistGroup] {
        var map: [String: [LibraryTrack]] = [:]
        for t in tracks {
            if let a = t.artist, !a.isEmpty {
                map[a, default: []].append(t)
            }
        }
        return map.map { ArtistGroup(id: $0.key, name: $0.key, tracks: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 按添加时间倒序（最近添加）
    func recentlyAdded(limit: Int = 20) -> [LibraryTrack] {
        tracks
            .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }
}

struct AlbumGroup: Identifiable {
    let id: String
    let name: String
    let artist: String?
    let tracks: [LibraryTrack]
    var artwork: String? { tracks.compactMap { $0.artworkFile }.first }
    var duration: Double { tracks.reduce(0) { $0 + ($1.duration ?? 0) } }
}

struct ArtistGroup: Identifiable {
    let id: String
    let name: String
    let tracks: [LibraryTrack]
    var artwork: String? { tracks.compactMap { $0.artworkFile }.first }
    var albumCount: Int { Set(tracks.compactMap { $0.albumKey }).count }
}

/// 音乐库中的一首歌（持久化用）
struct LibraryTrack: Identifiable, Codable, Hashable {
    var id: String            // provider-kind + fileID
    var fileID: String
    var fileName: String
    var size: Int64
    var parentID: String
    var title: String
    var artist: String?
    var album: String?
    var duration: Double?
    var artworkFile: String?  // Documents/Artwork 下的文件名
    var scraped: Bool         // 是否已刮削元数据
    var neteaseID: Int?       // 网易云歌曲 ID（用于歌词匹配）
    var addedAt: Date?        // 入库时间（最近添加排序用）
    /// 元数据来源：embedded（内嵌标签）/ online（在线匹配）/ filename（文件名解析）
    var metaSource: String?
    /// 在线匹配置信度 0~1，低于 0.7 时 UI 上提示「待确认」
    var confidence: Double?
    /// 所在文件夹名（专辑兜底 / 重新刮削时恢复）
    var parentName: String?

    var displayArtist: String { (artist?.isEmpty == false) ? artist! : "未知艺术家" }
    var displayAlbum: String { (album?.isEmpty == false) ? album! : "未知专辑" }
    /// 分组用的专辑键（专辑名 + 艺术家，避免同名专辑合并）
    var albumKey: String? {
        guard let a = album?.trimmingCharacters(in: .whitespaces), !a.isEmpty else { return nil }
        let artistKey = (artist?.isEmpty == false) ? artist! : "群星"
        return "\(a)|\(artistKey)"
    }
    var needsReview: Bool { (confidence ?? 1) < 0.7 }

    /// 转为播放器可用的 Track
    func toTrack(kind: CloudKind) -> Track {
        Track(id: id,
              file: CloudFile(id: fileID, name: fileName, size: size, isFolder: false,
                              modifiedAt: nil, extra: ["parentID": parentID]),
              providerKind: kind,
              accountID: kind.rawValue,
              titleOverride: title,
              artistOverride: artist,
              album: album,
              artworkFile: artworkFile,
              duration: duration,
              neteaseID: neteaseID)
    }
}

/// 跨库引用：一首歌 + 它所属的库（用于收藏 / 最近播放 / 搜索）
struct TrackRef: Identifiable {
    let track: LibraryTrack
    let library: MusicLibrary
    var id: String { track.id }
}

/// 扫描进度
struct ScanProgress: Equatable {    var phase: String = "扫描目录…"
    var scannedFolders: Int = 0
    var foundTracks: Int = 0
    var scrapedTracks: Int = 0
    var totalToScrape: Int = 0
    var failed: Int = 0

    var fraction: Double {
        guard totalToScrape > 0 else { return 0 }
        return min(1, Double(scrapedTracks) / Double(totalToScrape))
    }
}
