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

    var providerKind: CloudKind { CloudKind(rawValue: providerKindRaw) ?? .guangya }

    var artistCount: Int { Set(tracks.compactMap { $0.artist }).count }
    var albumCount: Int { Set(tracks.compactMap { $0.album }).count }

    func albums() -> [AlbumGroup] {
        var map: [String: [LibraryTrack]] = [:]
        for t in tracks {
            let key = (t.album?.isEmpty == false) ? t.album! : "未知专辑"
            map[key, default: []].append(t)
        }
        return map.map { AlbumGroup(id: $0.key, name: $0.key,
                                    artist: $0.value.compactMap { $0.artist }.first,
                                    tracks: $0.value) }
            .sorted { $0.name < $1.name }
    }

    func artists() -> [ArtistGroup] {
        var map: [String: [LibraryTrack]] = [:]
        for t in tracks {
            let key = (t.artist?.isEmpty == false) ? t.artist! : "未知艺术家"
            map[key, default: []].append(t)
        }
        return map.map { ArtistGroup(id: $0.key, name: $0.key, tracks: $0.value) }
            .sorted { $0.name < $1.name }
    }
}

struct AlbumGroup: Identifiable {
    let id: String
    let name: String
    let artist: String?
    let tracks: [LibraryTrack]
    var artwork: String? { tracks.compactMap { $0.artworkFile }.first }
}

struct ArtistGroup: Identifiable {
    let id: String
    let name: String
    let tracks: [LibraryTrack]
    var artwork: String? { tracks.compactMap { $0.artworkFile }.first }
}

/// 音乐库中的一首歌（持久化用，与 Track 区分）
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

    var displayArtist: String { artist?.isEmpty == false ? artist! : "未知艺术家" }
    var displayAlbum: String { album?.isEmpty == false ? album! : "未知专辑" }

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
              duration: duration)
    }
}

/// 扫描进度
struct ScanProgress: Equatable {
    var phase: String = "扫描目录…"
    var scannedFolders: Int = 0
    var foundTracks: Int = 0
    var scrapedTracks: Int = 0
    var totalToScrape: Int = 0
}
