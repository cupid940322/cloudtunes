import Foundation

/// 在线音乐元数据/封面搜索。
///
/// 关键改动：结果不再「取第一条」，而是把候选全部打分，只有超过阈值才采纳。
/// 宁可没有封面，也不要错封面——这是「刮削错误率高」的主要成因。
enum MusicSearchService {

    struct SongInfo {
        var title: String?
        var artist: String?
        var album: String?
        var coverURL: String?
        var neteaseID: Int?
        var duration: Double?
    }

    /// 带置信度的匹配结果
    struct Match {
        var info: SongInfo
        var score: Double
    }

    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    // MARK: - 网易云搜索

    /// 原始关键词搜索
    static func search(keyword: String, limit: Int = 8) async -> [SongInfo] {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var comps = URLComponents(string: "https://music.163.com/api/search/get/web")!
        comps.queryItems = [
            .init(name: "s", value: trimmed),
            .init(name: "type", value: "1"),
            .init(name: "limit", value: "\(limit)"),
            .init(name: "offset", value: "0"),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else { return [] }

        return songs.map { s in
            let album = s["album"] as? [String: Any]
            let artists = s["artists"] as? [[String: Any]]
            var pic = album?["picUrl"] as? String
            if let p = pic, p.hasPrefix("http://") { pic = "https://" + p.dropFirst(7) }
            let ms = s["duration"] as? Double
            return SongInfo(title: s["name"] as? String,
                            artist: artists?.first?["name"] as? String,
                            album: album?["name"] as? String,
                            coverURL: pic,
                            neteaseID: s["id"] as? Int,
                            duration: ms.map { $0 / 1000 })
        }
    }

    /// 兼容旧调用（标题 + 艺术家拼关键词）
    static func neteaseSearch(title: String, artist: String?, limit: Int = 5) async -> [SongInfo] {
        await search(keyword: keyword(title: title, artist: artist), limit: limit)
    }

    /// 取网易云歌曲详情（封面 + 规范化专辑/艺术家）
    static func neteaseDetail(id: Int) async -> SongInfo? {
        guard let url = URL(string: "https://music.163.com/api/song/detail?ids=[\(id)]") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let songs = obj["songs"] as? [[String: Any]],
              let s = songs.first else { return nil }
        let al = s["al"] as? [String: Any]
        let ar = s["ar"] as? [[String: Any]]
        var pic = al?["picUrl"] as? String
        if let p = pic, p.hasPrefix("http://") { pic = "https://" + p.dropFirst(7) }
        let ms = s["dt"] as? Double
        return SongInfo(title: s["name"] as? String,
                        artist: ar?.first?["name"] as? String,
                        album: al?["name"] as? String,
                        coverURL: pic,
                        neteaseID: id,
                        duration: ms.map { $0 / 1000 })
    }

    /// 网易云歌词（LRC 格式）
    static func neteaseLyrics(id: Int) async -> String? {
        guard let url = URL(string: "https://music.163.com/api/song/lyric?id=\(id)&lv=1&kv=1&tv=-1") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lrc = obj["lrc"] as? [String: Any],
              let text = lrc["lyric"] as? String, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - QQ音乐

    /// QQ 音乐歌曲搜索（带歌名/歌手，可用于校验），封面走 albummid 拼装
    static func qqSearch(keyword: String, limit: Int = 5) async -> [SongInfo] {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return [] }
        var comps = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")!
        comps.queryItems = [
            .init(name: "p", value: "1"),
            .init(name: "n", value: "\(limit)"),
            .init(name: "w", value: kw),
            .init(name: "format", value: "json"),
            .init(name: "cr", value: "1"),
            .init(name: "new_json", value: "1"),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let song = d["song"] as? [String: Any],
              let list = song["list"] as? [[String: Any]] else { return [] }

        return list.compactMap { item in
            guard let title = (item["title"] as? String) ?? (item["songname"] as? String) else { return nil }
            var artistName: String?
            if let singers = item["singer"] as? [[String: Any]] {
                artistName = singers.compactMap { $0["name"] as? String }.first
            }
            var albumName: String?
            var albumMid: String?
            if let album = item["album"] as? [String: Any] {
                albumName = album["name"] as? String
                albumMid = album["mid"] as? String
            }
            var cover: String?
            if let mid = albumMid, !mid.isEmpty {
                cover = "https://y.qq.com/music/photo_new/T002R500x500M000\(mid).jpg"
            }
            return SongInfo(title: title, artist: artistName, album: albumName,
                            coverURL: cover, neteaseID: nil, duration: nil)
        }
    }

    /// 兼容旧调用
    static func qqCover(title: String, artist: String?) async -> String? {
        await qqSearch(keyword: keyword(title: title, artist: artist), limit: 3).first?.coverURL
    }

    // MARK: - 打分匹配

    private static func keyword(title: String, artist: String?) -> String {
        let a = (artist ?? "").trimmingCharacters(in: .whitespaces)
        let t = title.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return t }
        if t.isEmpty { return a }
        return "\(a) \(t)"
    }

    /// 组装多个搜索词（先用「歌手 + 歌名」，不够再只用歌名）
    private static func queryVariants(title: String, artist: String?) -> [String] {
        var list: [String] = []
        let kw = keyword(title: title, artist: artist)
        if !kw.isEmpty { list.append(kw) }
        let plain = title.trimmingCharacters(in: .whitespaces)
        if !plain.isEmpty, !list.contains(plain) { list.append(plain) }
        return list
    }

    /// 收集候选（去重）
    static func candidates(title: String, artist: String?, limit: Int = 8) async -> [SongInfo] {
        var pool: [SongInfo] = []
        var seen = Set<Int>()
        for q in queryVariants(title: title, artist: artist) {
            for s in await search(keyword: q, limit: limit) {
                guard let id = s.neteaseID, !seen.contains(id) else { continue }
                seen.insert(id)
                pool.append(s)
            }
            if pool.count >= limit { break }
        }
        return pool
    }

    /// 给候选打分：标题占大头，艺术家占小头。没有艺术家信息时略微降权并抬高阈值。
    static func score(candidate: SongInfo, title: String, artist: String?) -> Double {
        let tSim = TextMatch.similarity(title, candidate.title ?? "")
        if tSim < 0.45 { return tSim * 0.5 }

        guard let artist, !artist.isEmpty,
              let cArtist = candidate.artist, !cArtist.isEmpty else {
            return tSim * 0.9
        }
        let aSim = cArtist
            .components(separatedBy: CharacterSet(charactersIn: "/、,&;；"))
            .map { TextMatch.similarity(artist, $0.trimmingCharacters(in: .whitespaces)) }
            .max() ?? 0
        return tSim * 0.66 + aSim * 0.34
    }

    /// 统一入口：返回分数最高且过阈值的一条；没有可信结果时返回 nil
    static func bestMatch(title: String, artist: String?, minScore: Double? = nil) async -> Match? {
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        guard !cleanTitle.isEmpty else { return nil }

        let pool = await candidates(title: cleanTitle, artist: artist)
        let hasArtist = !(artist ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let threshold = minScore ?? (hasArtist ? 0.66 : 0.78)

        var best: Match?
        for c in pool {
            let s = score(candidate: c, title: cleanTitle, artist: artist)
            if s > (best?.score ?? 0) {
                best = Match(info: c, score: s)
            }
        }

        if var b = best, b.score >= threshold, let id = b.info.neteaseID {
            // 补全封面/专辑（搜索接口给的字段不全）
            if let detail = await neteaseDetail(id: id) {
                if let c = detail.coverURL, !c.isEmpty { b.info.coverURL = c }
                if let a = detail.album, !a.isEmpty { b.info.album = a }
                if let ar = detail.artist, !ar.isEmpty { b.info.artist = ar }
                if let d = detail.duration { b.info.duration = d }
            }
            return b
        }

        // 网易云没有可信结果时，再用 QQ 音乐候选打一次分（同样要过阈值）
        var qqBest: Match?
        for c in await qqSearch(keyword: keyword(title: cleanTitle, artist: artist), limit: 6) {
            let s = score(candidate: c, title: cleanTitle, artist: artist)
            if s > (qqBest?.score ?? 0) { qqBest = Match(info: c, score: s) }
        }
        if let q = qqBest, q.score >= threshold { return q }
        return nil
    }

    /// 直接下载封面图片数据
    static func downloadImage(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return data
    }
}
