import Foundation

/// 在线音乐元数据/封面搜索：网易云 → QQ音乐 → iTunes 依次兜底
enum MusicSearchService {

    struct SongInfo {
        var title: String?
        var artist: String?
        var album: String?
        var coverURL: String?
        var neteaseID: Int?
    }

    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    // MARK: - 网易云

    static func neteaseSearch(title: String, artist: String?, limit: Int = 5) async -> [SongInfo] {
        let keyword = [artist, title].compactMap { $0 }.joined(separator: " ")
        var comps = URLComponents(string: "https://music.163.com/api/search/get/web")!
        comps.queryItems = [
            .init(name: "s", value: keyword),
            .init(name: "type", value: "1"),
            .init(name: "limit", value: "\(limit)"),
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
            return SongInfo(title: s["name"] as? String,
                            artist: artists?.first?["name"] as? String,
                            album: album?["name"] as? String,
                            coverURL: nil,
                            neteaseID: s["id"] as? Int)
        }
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
        return SongInfo(title: s["name"] as? String,
                        artist: ar?.first?["name"] as? String,
                        album: al?["name"] as? String,
                        coverURL: pic,
                        neteaseID: id)
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

    static func qqCover(title: String, artist: String?) async -> String? {
        let keyword = [artist, title].compactMap { $0 }.joined(separator: " ")
        var comps = URLComponents(string: "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg")!
        comps.queryItems = [.init(name: "key", value: keyword), .init(name: "format", value: "json")]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let album = d["album"] as? [String: Any],
              let items = album["itemlist"] as? [[String: Any]],
              let pic = items.first?["pic"] as? String else { return nil }
        return pic.replacingOccurrences(of: "T002R180x180M000", with: "T002R500x500M000")
            .replacingOccurrences(of: "http://", with: "https://")
    }

    // MARK: - 统一入口

    /// 依次尝试：网易云 → QQ封面 → iTunes，返回最可信的一条
    static func bestMatch(title: String, artist: String?) async -> SongInfo? {
        let list = await neteaseSearch(title: title, artist: artist)
        if let first = list.first, let id = first.neteaseID {
            if let detail = await neteaseDetail(id: id) {
                var merged = first
                if let c = detail.coverURL { merged.coverURL = c }
                if let a = detail.album, !a.isEmpty { merged.album = a }
                if let ar = detail.artist, !ar.isEmpty { merged.artist = ar }
                return merged
            }
            return first
        }
        if let cover = await qqCover(title: title, artist: artist) {
            return SongInfo(title: title, artist: artist, album: nil, coverURL: cover, neteaseID: nil)
        }
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
