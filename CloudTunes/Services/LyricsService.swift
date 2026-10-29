import Foundation

/// LRC 歌词解析
enum LRCParser {
    static func parse(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var index = 0
        for raw in lrc.components(separatedBy: .newlines) {
            // 支持 [mm:ss.xx] 与多时间标签 [mm:ss.xx][mm:ss.xx]
            let times = parseTimeTags(raw)
            let text = raw.replacingOccurrences(
                of: #"\[\d{1,3}:\d{2}([.:]\d{1,3})?\]"#,
                with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            for t in times where !text.isEmpty {
                lines.append(LyricLine(id: index, time: t, text: text))
                index += 1
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    private static func parseTimeTags(_ line: String) -> [TimeInterval] {
        let regex = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#)
        let ns = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).map { m in
            let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
            var frac = 0.0
            if m.range(at: 3).location != NSNotFound {
                let f = ns.substring(with: m.range(at: 3))
                frac = (Double(f) ?? 0) / pow(10, Double(f.count))
            }
            return min * 60 + sec + frac
        }
    }
}

/// 在线歌词服务：LRCLIB（开源免费、无需 Key）
enum LyricsService {
    struct Candidate: Identifiable {
        let id: String
        let trackName: String
        let artistName: String
        let synced: Bool
        let plain: String?
        let syncedLyrics: String?
    }

    /// 网易云歌词（优先用已刮削到的 ID，否则按歌名搜索）
    static func neteaseLyrics(title: String, artist: String?, neteaseID: Int?) async -> String? {
        if let id = neteaseID, let lrc = await MusicSearchService.neteaseLyrics(id: id) {
            return lrc
        }
        let list = await MusicSearchService.neteaseSearch(title: title, artist: artist, limit: 1)
        if let id = list.first?.neteaseID {
            return await MusicSearchService.neteaseLyrics(id: id)
        }
        return nil
    }

    static func search(title: String, artist: String?) async throws -> [Candidate] {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        var items = [URLQueryItem(name: "track_name", value: title)]
        if let a = artist, !a.isEmpty { items.append(.init(name: "artist_name", value: a)) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.setValue("CloudTunes/0.1 (personal use)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.prefix(15).map { item in
            Candidate(
                id: item["id"] as? String ?? UUID().uuidString,
                trackName: item["trackName"] as? String ?? "",
                artistName: item["artistName"] as? String ?? "",
                synced: (item["syncedLyrics"] as? String)?.isEmpty == false,
                plain: item["plainLyrics"] as? String,
                syncedLyrics: item["syncedLyrics"] as? String)
        }
    }
}
