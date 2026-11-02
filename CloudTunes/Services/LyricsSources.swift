import Foundation

/// 统一的歌词候选（网易云 / QQ音乐 / 酷狗 / LRCLIB）
struct LyricCandidate: Identifiable {
    enum Source: String, CaseIterable {
        case netease = "网易云音乐"
        case qq = "QQ音乐"
        case kugou = "酷狗音乐"
        case lrclib = "LRCLIB"

        var order: Int {
            switch self {
            case .netease: return 0
            case .qq: return 1
            case .kugou: return 2
            case .lrclib: return 3
            }
        }
    }

    /// 拿到歌词正文的方式
    enum Lookup {
        case netease(Int)
        case qq(songmid: String)
        case kugou(id: String, accessKey: String)
        case inline(synced: String?, plain: String?)
    }

    let id: String
    let source: Source
    let title: String
    let artist: String
    let album: String?
    /// 已知带时间轴（只有 LRCLIB 能在搜索阶段确定）
    let knownSynced: Bool?
    let lookup: Lookup
}

// MARK: - 多源歌词检索

extension LyricsService {

    private static var ua: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }

    /// 四个源并发搜索，按 网易云 → QQ → 酷狗 → LRCLIB 的顺序合并。
    /// 加了个总超时：某个库（尤其国外的 LRCLIB）卡住时不再无限等，先把手上的结果给用户。
    static func searchAll(title: String, artist: String?, timeout: Double = 7) async -> [LyricCandidate] {
        enum Part {
            case result([LyricCandidate])
            case deadline
        }
        let collected = await withTaskGroup(of: Part.self) { group -> [LyricCandidate] in
            group.addTask { .result(await neteaseCandidates(title: title, artist: artist)) }
            group.addTask { .result(await qqCandidates(title: title, artist: artist)) }
            group.addTask { .result(await kugouCandidates(title: title, artist: artist)) }
            group.addTask { .result(await lrclibCandidates(title: title, artist: artist)) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .deadline
            }

            var all: [LyricCandidate] = []
            for await part in group {
                switch part {
                case .result(let list):
                    all.append(contentsOf: list)
                case .deadline:
                    group.cancelAll()
                    return all
                }
            }
            return all
        }
        return collected.sorted { $0.source.order < $1.source.order }
    }

    /// 取某个候选的歌词正文（LRC 或纯文本）
    static func lyricText(for candidate: LyricCandidate) async -> String? {
        switch candidate.lookup {
        case .netease(let id):
            return await MusicSearchService.neteaseLyrics(id: id)
        case .qq(let mid):
            return await qqLyric(songmid: mid)
        case .kugou(let id, let key):
            return await kugouLyric(id: id, accessKey: key)
        case .inline(let synced, let plain):
            return synced ?? plain
        }
    }

    // MARK: 网易云

    static func neteaseCandidates(title: String, artist: String?) async -> [LyricCandidate] {
        let keyword = [artist, title].compactMap { $0 }.joined(separator: " ")
        let songs = await MusicSearchService.search(keyword: keyword, limit: 8)
        return songs.compactMap { s in
            guard let id = s.neteaseID, let name = s.title else { return nil }
            return LyricCandidate(id: "ne-\(id)",
                                  source: .netease,
                                  title: name,
                                  artist: s.artist ?? "",
                                  album: s.album,
                                  knownSynced: nil,
                                  lookup: .netease(id))
        }
    }

    // MARK: QQ 音乐

    struct QQSong {
        let mid: String
        let title: String
        let artist: String
        let album: String?
    }

    /// QQ 音乐搜索（拿 songmid，取歌词要用它）
    static func qqSearchSongs(keyword: String, limit: Int = 8) async -> [QQSong] {
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
            // new_json 用 mid，老接口用 songmid
            let mid = (item["mid"] as? String) ?? (item["songmid"] as? String) ?? ""
            guard !mid.isEmpty else { return nil }
            let title = (item["title"] as? String) ?? (item["songname"] as? String) ?? ""
            var artist = ""
            if let singers = item["singer"] as? [[String: Any]] {
                artist = singers.compactMap { $0["name"] as? String }.joined(separator: "、")
            }
            let album = (item["album"] as? [String: Any])?["name"] as? String
            return QQSong(mid: mid, title: title, artist: artist, album: album)
        }
    }

    static func qqCandidates(title: String, artist: String?) async -> [LyricCandidate] {
        let keyword = [artist, title].compactMap { $0 }.joined(separator: " ")
        let songs = await qqSearchSongs(keyword: keyword, limit: 8)
        return songs.map { s in
            LyricCandidate(id: "qq-\(s.mid)",
                           source: .qq,
                           title: s.title,
                           artist: s.artist,
                           album: s.album,
                           knownSynced: nil,
                           lookup: .qq(songmid: s.mid))
        }
    }

    /// QQ 音乐歌词（nobase64=1 返回 HTML 转义的 LRC）
    static func qqLyric(songmid: String) async -> String? {
        var comps = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
        comps.queryItems = [
            .init(name: "songmid", value: songmid),
            .init(name: "format", value: "json"),
            .init(name: "nobase64", value: "1"),
            .init(name: "g_tk", value: "5381"),
            .init(name: "loginUin", value: "0"),
            .init(name: "hostUin", value: "0"),
            .init(name: "inCharset", value: "utf8"),
            .init(name: "outCharset", value: "utf-8"),
            .init(name: "notice", value: "0"),
            .init(name: "platform", value: "yqq.json"),
            .init(name: "needNewCode", value: "0"),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://y.qq.com/portal/player.html", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["lyric"] as? String else { return nil }

        var text: String
        if raw.contains("[") {
            // nobase64 正常返回 HTML 转义的 LRC
            text = decodeEntities(raw)
        } else if let decoded = Data(base64Encoded: raw),
                  let plain = String(data: decoded, encoding: .utf8) {
            // 少数接口不吃 nobase64，返回 base64
            text = plain
        } else {
            text = decodeEntities(raw)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: 酷狗音乐

    static func kugouCandidates(title: String, artist: String?) async -> [LyricCandidate] {
        let kw = [artist, title].compactMap { $0 }.joined(separator: " ")
        guard !kw.isEmpty else { return [] }
        var comps = URLComponents(string: "https://krcs.kugou.com/search")!
        comps.queryItems = [
            .init(name: "ver", value: "1"),
            .init(name: "man", value: "yes"),
            .init(name: "client", value: "mobi"),
            .init(name: "keyword", value: kw),
            .init(name: "duration", value: ""),
            .init(name: "hash", value: ""),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["candidates"] as? [[String: Any]] else { return [] }

        return list.prefix(8).compactMap { item in
            guard let id = item["id"] as? String,
                  let key = item["accesskey"] as? String else { return nil }
            return LyricCandidate(id: "kg-\(id)",
                                  source: .kugou,
                                  title: item["song"] as? String ?? "",
                                  artist: item["singer"] as? String ?? "",
                                  album: nil,
                                  knownSynced: nil,
                                  lookup: .kugou(id: id, accessKey: key))
        }
    }

    static func kugouLyric(id: String, accessKey: String) async -> String? {
        var comps = URLComponents(string: "https://lyrics.kugou.com/download")!
        comps.queryItems = [
            .init(name: "ver", value: "1"),
            .init(name: "client", value: "pc"),
            .init(name: "id", value: id),
            .init(name: "accesskey", value: accessKey),
            .init(name: "fmt", value: "lrc"),
            .init(name: "charset", value: "utf8"),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = obj["content"] as? String,
              let raw = Data(base64Encoded: b64),
              let text = String(data: raw, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    // MARK: LRCLIB

    static func lrclibCandidates(title: String, artist: String?) async -> [LyricCandidate] {
        guard let list = try? await search(title: title, artist: artist) else { return [] }
        return list.map { c in
            LyricCandidate(id: "lr-\(c.id)",
                           source: .lrclib,
                           title: c.trackName,
                           artist: c.artistName,
                           album: nil,
                           knownSynced: c.synced,
                           lookup: .inline(synced: c.syncedLyrics, plain: c.plain))
        }
    }

    // MARK: 工具

    /// QQ 接口返回的 LRC 是 HTML 转义过的（&#10; 换行、&#58; 冒号等）
    static func decodeEntities(_ input: String) -> String {
        var s = input
        let map: [String: String] = [
            "&#10;": "\n", "&#13;": "", "&#58;": ":", "&#46;": ".",
            "&#32;": " ", "&#39;": "'", "&#40;": "(", "&#41;": ")",
            "&quot;": "\"", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&amp;": "&",
        ]
        for (k, v) in map { s = s.replacingOccurrences(of: k, with: v) }
        return s
    }

    /// 把任意来源的歌词文本整理成时间轴行；没有时间轴时按纯文本行处理
    static func lines(from text: String) -> [LyricLine] {
        let parsed = LRCParser.parse(text)
        if !parsed.isEmpty { return parsed }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: -1, text: $0.element) }
    }
}
