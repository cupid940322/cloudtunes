import Foundation

/// 在线音乐元数据/封面搜索。
///
/// 关键改动 1：结果不再「取第一条」，而是把候选全部打分，只有超过阈值才采纳。
/// 宁可没有封面，也不要错封面——这是「刮削错误率高」的主要成因。
///
/// 关键改动 2（v1.16）：原来是「网易云优先，网易云不行才查 QQ」。
/// 但网易云丢了大厂版权（周杰伦、部分华语专辑），搜「说走就走」只能搜到陶喆的同名歌，
/// 于是直接判为无结果。现在改为 **网易云 + QQ音乐 + iTunes 三源并发**，
/// 候选合并去重后统一打分选最优——哪个库有就用哪个。
enum MusicSearchService {

    struct SongInfo {
        var title: String?
        var artist: String?
        var album: String?
        var coverURL: String?
        var neteaseID: Int?
        var duration: Double?
        /// 来源标签：网易云 / QQ音乐 / iTunes（手动匹配时展示，方便判断可信度）
        var source: String = ""
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
        req.timeoutInterval = 8
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
                            duration: ms.map { $0 / 1000 },
                            source: "网易云")
        }
    }

    /// 兼容旧调用（标题 + 艺术家拼关键词）
    static func neteaseSearch(title: String, artist: String?, limit: Int = 5) async -> [SongInfo] {
        await search(keyword: keyword(title: title, artist: artist), limit: limit)
    }

    /// 取网易云歌曲详情（封面 + 规范化专辑/艺术家）
    static func neteaseDetail(id: Int) async -> SongInfo? {
        await neteaseDetails(ids: [id])[id]
    }

    /// 解析详情接口的一首歌。
    ///
    /// **坑**：同一个 `/api/song/detail` 接口，单查和批量都返回**老字段名**
    /// `album` / `artists` / `duration`，并不是网易云新版 API 的 `al` / `ar` / `dt`。
    /// 之前只解析 `al`，导致封面 / 专辑 / 时长全部拿到 nil（封面就一直加载不出来）。
    private static func parseDetail(_ s: [String: Any]) -> SongInfo {
        let al = (s["al"] as? [String: Any]) ?? (s["album"] as? [String: Any])
        let ar = (s["ar"] as? [[String: Any]]) ?? (s["artists"] as? [[String: Any]])
        var pic = al?["picUrl"] as? String
        if let p = pic, p.hasPrefix("http://") { pic = "https://" + p.dropFirst(7) }
        let ms = (s["dt"] as? Double) ?? (s["duration"] as? Double)
        return SongInfo(title: s["name"] as? String,
                        artist: ar?.first?["name"] as? String,
                        album: al?["name"] as? String,
                        coverURL: pic,
                        neteaseID: s["id"] as? Int,
                        duration: ms.map { $0 / 1000 },
                        source: "网易云")
    }

    /// 批量取网易云歌曲详情。
    ///
    /// 网易云的**搜索接口不返回封面**（`album.picUrl` 不存在），
    /// 必须拿歌曲 id 再查详情才有。这里一次带多个 id，给手动匹配列表补封面用。
    static func neteaseDetails(ids: [Int]) async -> [Int: SongInfo] {
        let uniq = Array(Set(ids.filter { $0 > 0 })).prefix(20)
        guard !uniq.isEmpty else { return [:] }
        let list = uniq.map(String.init).joined(separator: ",")
        var comps = URLComponents(string: "https://music.163.com/api/song/detail")!
        comps.queryItems = [.init(name: "ids", value: "[\(list)]")]   // 方括号交给 URLComponents 转义
        guard let url = comps.url else { return [:] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let songs = obj["songs"] as? [[String: Any]] else { return [:] }
        var out: [Int: SongInfo] = [:]
        for s in songs {
            let info = parseDetail(s)
            if let id = info.neteaseID { out[id] = info }
        }
        return out
    }

    /// 网易云歌词（LRC 格式）
    static func neteaseLyrics(id: Int) async -> String? {
        guard let url = URL(string: "https://music.163.com/api/song/lyric?id=\(id)&lv=1&kv=1&tv=-1") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
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
        req.timeoutInterval = 8
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
            var duration: Double?
            if let sec = item["interval"] as? Double, sec > 0 {
                duration = sec
            } else if let sec = item["interval"] as? Int, sec > 0 {
                duration = Double(sec)
            }
            return SongInfo(title: title, artist: artistName, album: albumName,
                            coverURL: cover, neteaseID: nil, duration: duration,
                            source: "QQ音乐")
        }
    }

    /// 兼容旧调用
    static func qqCover(title: String, artist: String?) async -> String? {
        await qqSearch(keyword: keyword(title: title, artist: artist), limit: 3).first?.coverURL
    }

    // MARK: - iTunes（欧美 / 外语专辑的封面最全，补网易云与 QQ 的缺口）

    static func itunesSearch(keyword: String, limit: Int = 8) async -> [SongInfo] {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return [] }
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            .init(name: "term", value: kw),
            .init(name: "media", value: "music"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "\(limit)"),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return [] }

        return results.compactMap { r in
            guard let name = r["trackName"] as? String else { return nil }
            var cover: String?
            if let art = r["artworkUrl100"] as? String {
                // 100×100 换成 600×600，直接拿到大图
                cover = art.replacingOccurrences(of: "100x100", with: "600x600")
            }
            var duration: Double?
            if let ms = r["trackTimeMillis"] as? Double, ms > 0 { duration = ms / 1000 }
            return SongInfo(title: name,
                            artist: r["artistName"] as? String,
                            album: r["collectionName"] as? String,
                            coverURL: cover,
                            neteaseID: nil,
                            duration: duration,
                            source: "iTunes")
        }
    }

    // MARK: - 打分匹配

    private static func keyword(title: String, artist: String?) -> String {
        let a = (artist ?? "").trimmingCharacters(in: .whitespaces)
        let t = title.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return t }
        if t.isEmpty { return a }
        return "\(a) \(t)"
    }

    /// 收集候选：网易云 + QQ音乐 + iTunes **三源并发**，合并去重。
    /// 之前只查网易云，周杰伦这类网易云没有版权的歌就永远搜不到。
    static func candidates(title: String, artist: String?, limit: Int = 12) async -> [SongInfo] {
        let kw = keyword(title: title, artist: artist)
        let plain = title.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return [] }

        var pool: [SongInfo] = []
        await withTaskGroup(of: [SongInfo].self) { group in
            group.addTask { await search(keyword: kw, limit: limit) }        // 网易云
            if plain != kw {
                group.addTask { await search(keyword: plain, limit: limit) } // 网易云（只留歌名再试一次）
            }
            group.addTask { await qqSearch(keyword: kw, limit: limit) }      // QQ音乐
            group.addTask { await itunesSearch(keyword: kw, limit: 8) }      // iTunes
            for await list in group { pool.append(contentsOf: list) }
        }

        // 去重：同来源下「歌名 + 歌手」相同的只留一条
        var seen = Set<String>()
        var unique: [SongInfo] = []
        for s in pool {
            guard let t = s.title, !t.isEmpty else { continue }
            let key = "\(s.source)|\(t)|\(s.artist ?? "")".lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(s)
        }

        // 网易云的搜索接口不返回封面（album.picUrl 不存在），批量查一次详情补上。
        // 不补的话「在线重新匹配」列表里网易云候选永远只有灰块，QQ音乐 / iTunes 有图。
        let needIDs = unique
            .filter { $0.source == "网易云" && ($0.coverURL ?? "").isEmpty }
            .compactMap(\.neteaseID)
        if !needIDs.isEmpty {
            let details = await neteaseDetails(ids: needIDs)
            if !details.isEmpty {
                unique = unique.map { s in
                    guard s.source == "网易云", let id = s.neteaseID, let d = details[id] else { return s }
                    var v = s
                    if (v.coverURL ?? "").isEmpty { v.coverURL = d.coverURL }
                    if (v.album ?? "").isEmpty, let a = d.album { v.album = a }
                    if v.duration == nil { v.duration = d.duration }
                    return v
                }
            }
        }
        return unique
    }

    /// 手动匹配用：多源候选按置信度从高到低排序，并丢掉明显不相关的
    static func rankedCandidates(title: String, artist: String?) async -> [SongInfo] {
        let pool = await candidates(title: title, artist: artist)
        guard !pool.isEmpty else { return [] }
        return pool
            .map { (info: $0, s: score(candidate: $0, title: title, artist: artist)) }
            .filter { $0.s >= 0.30 }
            .sorted { $0.s > $1.s }
            .map { $0.info }
    }

    /// 给候选打分：标题占大头，艺术家占小头。没有艺术家信息时略微降权并抬高阈值。
    /// - Parameter artistHint: 文件夹结构推断出的歌手，对得上加分、完全对不上扣分
    static func score(candidate: SongInfo, title: String, artist: String?,
                      artistHint: String? = nil) -> Double {
        let tSim = TextMatch.similarity(title, candidate.title ?? "")
        if tSim < 0.45 { return tSim * 0.5 }

        let base: Double
        if let artist, !artist.isEmpty,
           let cArtist = candidate.artist, !cArtist.isEmpty {
            let aSim = cArtist
                .components(separatedBy: CharacterSet(charactersIn: "/、,&;；"))
                .map { TextMatch.similarity(artist, $0.trimmingCharacters(in: .whitespaces)) }
                .max() ?? 0
            base = tSim * 0.66 + aSim * 0.34
        } else {
            base = tSim * 0.9
        }

        // 同名情况下优先录音室版：Live / 伴奏 / 翻唱 / 网友自制 轻微降权
        var s = isAlternateVersion(candidate.title) ? base * 0.94 : base

        // 目录里的歌手是很强的上下文：对得上就加分，完全对不上就压下去
        // （比如目录写着「周杰伦」，候选里陶喆的同名歌就直接跌到阈值以下）
        if let hint = artistHint?.trimmingCharacters(in: .whitespaces), !hint.isEmpty,
           let cArtist = candidate.artist, !cArtist.isEmpty {
            let hSim = cArtist
                .components(separatedBy: CharacterSet(charactersIn: "/、,&;；"))
                .map { TextMatch.similarity(hint, $0.trimmingCharacters(in: .whitespaces)) }
                .max() ?? 0
            if hSim >= 0.55 {
                s = min(1.0, s + 0.06)
            } else if hSim < 0.20 {
                s = max(0, s - 0.12)
            }
        }
        return s
    }

    /// 是否是 Live / 伴奏 / 翻唱之类的非原版
    private static func isAlternateVersion(_ title: String?) -> Bool {
        let lower = (title ?? "").lowercased()
        for token in ["live", "现场", "演唱会", "伴奏", "翻唱", "cover", "karaoke",
                      "remix", "dj版", "网友自制", "翻自", "纯音乐", "instrumental"] {
            if lower.contains(token) { return true }
        }
        return false
    }

    /// 统一入口：按「主源优先、逐级补充」的顺序取最可信的一条。
    ///
    /// 为什么不把所有源混在一起按分数排：
    /// 网易云和 QQ 同名同歌手的两条都是 1.0 分，混排时谁先到谁赢，
    /// 于是 QQ 的《精选集》封面会把网易云的原版专辑顶掉——重刮整库时错误反而变多。
    /// 现在的顺序是：
    ///   ① 网易云（曲库信息最规范，专辑/封面基本都是原版）
    ///   ② 网易云没有可信结果 → QQ音乐（补大厂版权，如周杰伦）
    ///   ③ 还没有 → iTunes（补欧美/外语专辑封面）
    /// 任何一级达标就收工，次源只在主源确实没有时出场。
    static func bestMatch(title: String, artist: String?, artistHint: String? = nil,
                          minScore: Double? = nil) async -> Match? {
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        guard !cleanTitle.isEmpty else { return nil }

        let kw = keyword(title: cleanTitle, artist: artist)
        let plain = cleanTitle
        let hasArtist = !(artist ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            || !(artistHint ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        // 有歌手信息时阈值 0.70：正好卡住「歌名一模一样但根本不是同一个人」的版本
        // （那种只有 0.66 分），又不至于把 Live / 重新编曲版全部拒掉。
        let threshold = minScore ?? (hasArtist ? 0.70 : 0.78)

        func acceptable(_ m: Match?) -> Bool { (m?.score ?? 0) >= threshold }

        // ① 网易云：先「歌手 + 歌名」，还不行再只用歌名
        var best = pickBest(await search(keyword: kw, limit: 10),
                            title: cleanTitle, artist: artist, artistHint: artistHint)
        if !acceptable(best), plain != kw {
            if let alt = pickBest(await search(keyword: plain, limit: 10),
                                  title: cleanTitle, artist: artist, artistHint: artistHint),
               alt.score > (best?.score ?? 0) {
                best = alt
            }
        }

        // ② QQ 音乐兜底（网易云丢了大厂版权时才走到这里）
        if !acceptable(best) {
            var pool = await qqSearch(keyword: kw, limit: 10)
            if pool.isEmpty, plain != kw {
                pool += await qqSearch(keyword: plain, limit: 10)
            }
            if let alt = pickBest(pool, title: cleanTitle, artist: artist, artistHint: artistHint),
               alt.score > (best?.score ?? 0) {
                best = alt
            }
        }

        // ③ iTunes 最后兜一次（欧美/外语专辑封面最全）
        if !acceptable(best) {
            if let alt = pickBest(await itunesSearch(keyword: kw, limit: 8),
                                  title: cleanTitle, artist: artist, artistHint: artistHint),
               alt.score > (best?.score ?? 0) {
                best = alt
            }
        }

        guard var b = best, b.score >= threshold else { return nil }

        // 网易云命中但字段不全时补全封面 / 专辑 / 时长（搜索接口给的信息比详情少）
        if let id = b.info.neteaseID, (b.info.coverURL ?? "").isEmpty {
            if let detail = await neteaseDetail(id: id) {
                if let c = detail.coverURL, !c.isEmpty { b.info.coverURL = c }
                if (b.info.album ?? "").isEmpty, let a = detail.album, !a.isEmpty { b.info.album = a }
                if (b.info.artist ?? "").isEmpty, let ar = detail.artist, !ar.isEmpty { b.info.artist = ar }
                if b.info.duration == nil { b.info.duration = detail.duration }
            }
        }
        return b
    }

    private static func pickBest(_ pool: [SongInfo], title: String, artist: String?,
                                 artistHint: String? = nil) -> Match? {
        var best: Match?
        for c in pool {
            let s = score(candidate: c, title: title, artist: artist, artistHint: artistHint)
            if s > (best?.score ?? 0) {
                best = Match(info: c, score: s)
            }
        }
        return best
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

