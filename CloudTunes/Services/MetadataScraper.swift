import AVFoundation
import Foundation
import UIKit

/// 音乐元数据刮削。
///
/// 优先级：
/// 1. 文件内嵌标签（ID3 / FLAC / MP4 的 commonMetadata）——最可信，命中就不覆盖
/// 2. 在线匹配（网易云 → QQ音乐）——必须通过相似度打分，宁缺勿错
/// 3. iTunes 封面兜底——同样要校验歌名/歌手，避免随手贴封面
enum MetadataScraper {

    struct Result {
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var artworkFile: String?
        var neteaseID: Int?
        /// 在线匹配的置信度（0~1），0 表示没走在线或没匹配上
        var confidence: Double = 0
        /// 是否命中在线匹配
        var matched: Bool = false
    }

    /// 刮削单个文件（需要直链）。
    static func scrape(url: URL, headers: [String: String], trackID: String,
                       fallbackTitle: String, fallbackArtist: String?) async -> Result {
        var result = Result()
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])

        // 1. 时长
        if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 {
            result.duration = d.seconds
        }

        // 2. 内嵌标签
        var embeddedTitle: String?
        var embeddedArtist: String?
        var embeddedAlbum: String?
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    embeddedTitle = try? await item.load(.stringValue)
                case .commonKeyArtist:
                    embeddedArtist = try? await item.load(.stringValue)
                case .commonKeyAlbumName:
                    embeddedAlbum = try? await item.load(.stringValue)
                case .commonKeyArtwork:
                    if let data = try? await item.load(.dataValue) {
                        result.artworkFile = saveArtwork(data, key: trackID)
                    }
                default:
                    break
                }
            }
        }

        // 内嵌标签优先
        if let t = embeddedTitle?.trimmingCharacters(in: .whitespaces), !t.isEmpty { result.title = t }
        if let a = embeddedArtist?.trimmingCharacters(in: .whitespaces), !a.isEmpty { result.artist = a }
        if let al = embeddedAlbum?.trimmingCharacters(in: .whitespaces), !al.isEmpty { result.album = al }

        // 3. 在线匹配：缺封面 / 缺专辑 / 缺艺术家时才发起
        let needOnline = result.artworkFile == nil
            || (result.album?.isEmpty ?? true)
            || (result.artist?.isEmpty ?? true)
        let queryTitle = (result.title?.isEmpty == false) ? result.title! : fallbackTitle
        let queryArtist = (result.artist?.isEmpty == false) ? result.artist : fallbackArtist

        if needOnline, !queryTitle.isEmpty {
            var match = await MusicSearchService.bestMatch(title: queryTitle, artist: queryArtist)

            // 「歌名-歌手」倒序文件名：正着匹配不到就反过来再试一次
            var didSwap = false
            if match == nil, let swappedTitle = queryArtist, !swappedTitle.isEmpty {
                if let alt = await MusicSearchService.bestMatch(title: swappedTitle, artist: queryTitle) {
                    match = alt
                    didSwap = true
                }
            }

            if let match {
                let info = match.info
                result.matched = true
                result.confidence = match.score
                result.neteaseID = info.neteaseID

                if (result.album?.isEmpty ?? true), let a = info.album, !a.isEmpty {
                    result.album = a
                }

                if didSwap, match.score >= 0.75 {
                    // 倒序文件名：以在线结果为准，整条纠正过来
                    if let t = info.title, !t.isEmpty { result.title = t }
                    if let a = info.artist, !a.isEmpty { result.artist = a }
                } else {
                    // 艺术家：内嵌有值绝不覆盖
                    if embeddedArtist?.isEmpty ?? true {
                        if let ar = info.artist, !ar.isEmpty {
                            if let local = fallbackArtist?.trimmingCharacters(in: .whitespaces), !local.isEmpty {
                                // 文件名里本来就有艺术家：只有对得上才采纳在线的规范写法
                                if match.score >= 0.80, TextMatch.similarity(local, ar) >= 0.5 {
                                    result.artist = ar
                                }
                            } else if match.score >= 0.75 {
                                result.artist = ar
                            }
                        }
                    }
                    // 标题：内嵌有值绝不覆盖；否则要求与在线标题高度一致才替换
                    if embeddedTitle?.isEmpty ?? true, let t = info.title, !t.isEmpty {
                        if TextMatch.similarity(queryTitle, t) >= 0.80 {
                            result.title = t
                        }
                    }
                }

                if result.artworkFile == nil, let cover = info.coverURL,
                   let data = await MusicSearchService.downloadImage(cover) {
                    result.artworkFile = saveArtwork(data, key: trackID)
                }
            }
        }

        // 4. iTunes 兜底封面（仍要做校验）
        let artworkQueryTitle = result.title ?? fallbackTitle
        if result.artworkFile == nil, !artworkQueryTitle.isEmpty {
            let artist = result.artist ?? fallbackArtist
            if let data = await fetchITunesArtwork(title: artworkQueryTitle, artist: artist) {
                result.artworkFile = saveArtwork(data, key: trackID)
            }
        }
        return result
    }

    /// 手动匹配用：只搜在线，不读文件
    static func searchCandidates(title: String, artist: String?) async -> [MusicSearchService.SongInfo] {
        await MusicSearchService.candidates(title: title, artist: artist, limit: 10)
    }

    // MARK: - 封面缓存

    static var artworkDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func artworkURL(file: String?) -> URL? {
        guard let file, !file.isEmpty else { return nil }
        let url = artworkDir.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    static func saveArtwork(_ data: Data, key: String) -> String? {
        guard let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        let name = key.replacingOccurrences(of: "/", with: "_") + ".jpg"
        let url = artworkDir.appendingPathComponent(name)
        try? jpeg.write(to: url)
        return name
    }

    static func removeArtwork(named: String?) {
        guard let name = named, !name.isEmpty else { return }
        try? FileManager.default.removeItem(at: artworkDir.appendingPathComponent(name))
    }

    // MARK: - iTunes 封面（带校验）

    private static func fetchITunesArtwork(title: String, artist: String?) async -> Data? {
        let term = [artist, title].compactMap { $0 }.joined(separator: " ")
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            .init(name: "term", value: term),
            .init(name: "media", value: "music"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "5"),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return nil }

        // 只有歌名/歌手对得上才用，避免张冠李戴
        var picked: [String: Any]?
        var bestScore = 0.0
        for r in results {
            guard let trackName = r["trackName"] as? String else { continue }
            let tSim = TextMatch.similarity(title, trackName)
            var s = tSim * 0.72
            if let artist, !artist.isEmpty, let aName = r["artistName"] as? String {
                s += TextMatch.similarity(artist, aName) * 0.28
            } else {
                s = tSim * 0.9
            }
            if s > bestScore {
                bestScore = s
                picked = r
            }
        }
        guard bestScore >= 0.72, let art = picked?["artworkUrl100"] as? String else { return nil }

        let big = art.replacingOccurrences(of: "100x100", with: "600x600")
        guard let artURL = URL(string: big) else { return nil }
        return (try? await URLSession.shared.data(for: URLRequest(url: artURL)))?.0
    }
}
