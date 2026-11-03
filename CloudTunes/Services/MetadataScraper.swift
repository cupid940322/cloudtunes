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
    /// - Parameters:
    ///   - hintArtist/hintAlbum: 从文件夹结构推断出的歌手/专辑，比文件名可靠，用来约束在线匹配
    static func scrape(url: URL, headers: [String: String], trackID: String,
                       fallbackTitle: String, fallbackArtist: String?,
                       hintArtist: String? = nil, hintAlbum: String? = nil) async -> Result {
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

        // 专辑顺序：内嵌标签 > 文件夹名 > 在线。人整理目录时是认真写的，比在线结果更贴近这张碟
        if (result.album?.isEmpty ?? true), let ha = hintAlbum?.trimmingCharacters(in: .whitespaces), !ha.isEmpty {
            result.album = ha
        }

        // 3. 在线匹配：缺封面 / 缺专辑 / 缺艺术家时才发起
        let needOnline = result.artworkFile == nil
            || (result.album?.isEmpty ?? true)
            || (result.artist?.isEmpty ?? true)
        let queryTitle = (result.title?.isEmpty == false) ? result.title! : fallbackTitle
        // 歌手顺序：内嵌标签 > 文件夹名 > 文件名
        let queryArtist = (result.artist?.isEmpty == false)
            ? result.artist
            : (hintArtist?.isEmpty == false ? hintArtist : fallbackArtist)
        // 目录推断出的歌手作为「约束」：候选歌手对不上就扣分，压掉同名不同人
        let artistHint = hintArtist?.trimmingCharacters(in: .whitespaces)

        if needOnline, !queryTitle.isEmpty {
            var match = await MusicSearchService.bestMatch(title: queryTitle,
                                                           artist: queryArtist,
                                                           artistHint: artistHint)

            // 「歌名-歌手」倒序文件名：正着匹配不到就反过来再试一次
            var didSwap = false
            if match == nil, let swappedTitle = queryArtist, !swappedTitle.isEmpty {
                if let alt = await MusicSearchService.bestMatch(title: swappedTitle,
                                                                artist: queryTitle,
                                                                artistHint: artistHint) {
                    match = alt
                    didSwap = true
                }
            }

            if let match {
                let info = match.info
                // iTunes 只信它的封面：它的中文库里同名翻唱/改编太多，
                // 拿它改歌名歌手反而会把对的改错。
                let coverOnly = (info.source == "iTunes")
                if !coverOnly {
                    result.matched = true
                    result.confidence = match.score
                    result.neteaseID = info.neteaseID
                }

                if coverOnly {
                    // nothing：文字信息一律不动
                } else if (result.album?.isEmpty ?? true), let a = info.album, !a.isEmpty {
                    result.album = a
                }

                if didSwap, match.score >= 0.75 {
                    // 倒序文件名：以在线结果为准，整条纠正过来
                    if !coverOnly, let t = info.title, !t.isEmpty { result.title = t }
                    if !coverOnly, let a = info.artist, !a.isEmpty { result.artist = a }
                } else if !coverOnly {
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

    /// 手动匹配用：多源（网易云 / QQ音乐 / iTunes）聚合，按置信度排序
    static func searchCandidates(title: String, artist: String?) async -> [MusicSearchService.SongInfo] {
        await MusicSearchService.rankedCandidates(title: title, artist: artist)
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
        // 新封面已落盘：「这首没有封面」的负缓存要作废，否则界面会一直显示占位图
        ArtworkCache.shared.clearMissing()
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
