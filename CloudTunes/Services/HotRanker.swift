import Foundation
import SwiftUI

/// 歌曲列表的排序方式。
///
/// 「综合热度」不是猜的：拿各平台**公开的热度指标**归一化后加权，
/// 具体见 `HotRanker` 的注释。
enum TrackSortMode: String, CaseIterable, Identifiable {
    case source      // 库里原本的顺序（扫描/入库顺序）
    case title       // 歌名
    case artist      // 歌手
    case hot         // 各大平台综合热度

    var id: String { rawValue }

    var label: String {
        switch self {
        case .source: return "默认顺序"
        case .title:  return "按歌名"
        case .artist: return "按歌手"
        case .hot:    return "按综合热度"
        }
    }

    var icon: String {
        switch self {
        case .source: return "list.number"
        case .title:  return "textformat.abc"
        case .artist: return "person"
        case .hot:    return "flame.fill"
        }
    }
}

/// 跨平台音乐热度查询 + 本地缓存。
///
/// **数据来源（实测过，别的源拿不到数）**
/// - 网易云 `cloudsearch` 的 `pop` 字段：0~100 的流行度，唯一能直接拿到的成熟热度值
/// - 酷我 `search/r.s` 的 `PLAYCNT` 字段：播放量
/// - QQ 音乐、酷狗的**搜索接口不返回任何数值型热度**（只能再发一次详情请求，
///   成本翻倍且字段随时会变），所以暂不接入
///
/// **综合分**：两源分别归一化到 0~1，再按「当前实际拿到的源」重新归一权重
/// （缺一个源不会把分数拉低，只会用剩下的源算）。网易云权重 0.65、酷我 0.35。
///
/// **成本控制**：每首歌 2 个请求，结果缓存 7 天。首次切到热度排序时会显示进度，
/// 列表越短越快；缓存命中后排序是纯本地计算，不联网。
@MainActor
final class HotRanker: ObservableObject {
    static let shared = HotRanker()

    struct Entry: Codable, Sendable {
        /// 综合分 0~1
        var score: Double
        /// 网易云归一化分（nil 表示没匹配到）
        var netease: Double?
        /// 酷我归一化分（nil 表示没匹配到）
        var kuwo: Double?
        /// 写入时间（秒）
        var at: TimeInterval
    }

    /// key → 记录
    @Published private(set) var entries: [String: Entry] = [:]
    /// 正在批量补齐
    @Published private(set) var ranking = false
    @Published private(set) var doneCount = 0
    @Published private(set) var totalCount = 0

    private var rankTask: Task<Void, Never>?
    private var loaded = false
    private let ttl: TimeInterval = 7 * 86_400
    /// 一批同时查几首（每首内部还会并发两个源）
    private let batchSize = 6

    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("hot-rank.json")
    }

    // MARK: - 读取 / 写入

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = map
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func isFresh(_ e: Entry) -> Bool {
        Date().timeIntervalSince1970 - e.at < ttl
    }

    /// 缓存 key：歌名 + 歌手，都做同样的归一化（去括号/标点/大小写），
    /// 这样「晴天 (Live)」和「晴天」能命中同一条
    nonisolated static func cacheKey(title: String, artist: String?) -> String {
        "\(TextMatch.normalize(title))|\(TextMatch.normalize(artist ?? ""))"
    }

    /// 已缓存的热度分（0~1）。没有或过期返回 nil
    func score(title: String, artist: String?) -> Double? {
        loadIfNeeded()
        guard let e = entries[Self.cacheKey(title: title, artist: artist)], isFresh(e) else { return nil }
        return e.score
    }

    func score(for track: LibraryTrack) -> Double? {
        score(title: track.title, artist: track.artist)
    }

    /// 还有多少首没算过热
    func missingCount(_ tracks: [LibraryTrack]) -> Int {
        loadIfNeeded()
        var seen = Set<String>()
        var n = 0
        for t in tracks {
            let key = Self.cacheKey(title: t.title, artist: t.artist)
            if seen.contains(key) { continue }
            seen.insert(key)
            if let e = entries[key], isFresh(e) { continue }
            n += 1
        }
        return n
    }

    // MARK: - 排序

    func sorted(_ tracks: [LibraryTrack], by mode: TrackSortMode) -> [LibraryTrack] {
        switch mode {
        case .source:
            return tracks
        case .title:
            return tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            return tracks.sorted {
                let a = $0.displayArtist, b = $1.displayArtist
                if a != b { return a.localizedStandardCompare(b) == .orderedAscending }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .hot:
            loadIfNeeded()
            return tracks.sorted { a, b in
                let sa = score(for: a), sb = score(for: b)
                switch (sa, sb) {
                case let (x?, y?):
                    if abs(x - y) > 0.0005 { return x > y }
                case (_?, nil):
                    return true          // 有分的排前面
                case (nil, _?):
                    return false
                default:
                    break
                }
                // 同分（或都没分）按歌名，保证顺序稳定
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    // MARK: - 批量补齐

    /// 补齐这批歌的热度。已经算过且没过期的不再请求。
    /// - 只在 `mode == .hot` 时值得调用，其它排序模式不浪费请求
    func prefetch(_ tracks: [LibraryTrack], mode: TrackSortMode) {
        guard mode == .hot else { return }
        loadIfNeeded()
        rankTask?.cancel()

        var seen = Set<String>()
        var wanted: [(key: String, title: String, artist: String)] = []
        for t in tracks {
            let key = Self.cacheKey(title: t.title, artist: t.artist)
            if seen.contains(key) { continue }
            seen.insert(key)
            if let e = entries[key], isFresh(e) { continue }
            wanted.append((key, t.title, t.artist ?? ""))
        }
        guard !wanted.isEmpty else {
            ranking = false
            doneCount = 0
            totalCount = 0
            return
        }

        ranking = true
        doneCount = 0
        totalCount = wanted.count

        rankTask = Task { [weak self] in
            guard let self else { return }
            var i = 0
            while i < wanted.count {
                if Task.isCancelled { break }
                let slice = Array(wanted[i..<min(i + self.batchSize, wanted.count)])
                let got = await withTaskGroup(of: (String, Entry?).self) { group -> [(String, Entry?)] in
                    for item in slice {
                        group.addTask {
                            (item.key, await HotRanker.fetch(title: item.title, artist: item.artist))
                        }
                    }
                    var out: [(String, Entry?)] = []
                    for await r in group { out.append(r) }
                    return out
                }
                if Task.isCancelled { break }
                for (key, entry) in got {
                    // 查不到也写一条 0 分：避免每次切排序都重试一遍
                    self.entries[key] = entry ?? Entry(score: 0, netease: nil, kuwo: nil,
                                                       at: Date().timeIntervalSince1970)
                }
                i += slice.count
                self.doneCount = i
                self.save()
                // 让一下，别把两个平台的接口打得太狠
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            self.ranking = false
            self.save()
        }
    }

    func cancelPrefetch() {
        rankTask?.cancel()
        rankTask = nil
        ranking = false
    }

    // MARK: - 网络

    /// 一首歌的综合分
    nonisolated static func fetch(title: String, artist: String) async -> Entry? {
        async let n = neteaseScore(title: title, artist: artist)
        async let k = kuwoScore(title: title, artist: artist)
        let (nv, kv) = await (n, k)
        guard nv != nil || kv != nil else { return nil }

        var num = 0.0, den = 0.0
        if let nv { num += nv * 0.65; den += 0.65 }
        if let kv { num += kv * 0.35; den += 0.35 }
        let score = den > 0 ? num / den : 0
        return Entry(score: score, netease: nv, kuwo: kv, at: Date().timeIntervalSince1970)
    }

    /// 网易云：`pop` 0~100 → 0~1
    private nonisolated static func neteaseScore(title: String, artist: String) async -> Double? {
        let kw = artist.isEmpty ? title : "\(title) \(artist)"
        var comps = URLComponents(string: "https://music.163.com/api/cloudsearch/pc")!
        comps.queryItems = [
            URLQueryItem(name: "s", value: kw),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "6"),
            URLQueryItem(name: "offset", value: "0"),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else { return nil }

        var bestSim = 0.0
        var bestPop = 0.0
        for s in songs {
            let name = s["name"] as? String ?? ""
            let singers = (s["ar"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let sim = TextMatch.similarity(title, name)
            guard sim >= 0.55 else { continue }
            if !artist.isEmpty {
                let hit = singers.contains { TextMatch.similarity(artist, $0) >= 0.5 }
                guard hit else { continue }
            }
            let pop = (s["pop"] as? NSNumber)?.doubleValue ?? 0
            if sim > bestSim { bestSim = sim; bestPop = pop }
        }
        guard bestSim > 0 else { return nil }
        return min(1, max(0, bestPop / 100))
    }

    /// 酷我：`PLAYCNT` 播放量 → 对数归一（1 万次播放约等于 1.0）
    private nonisolated static func kuwoScore(title: String, artist: String) async -> Double? {
        let kw = artist.isEmpty ? title : "\(title) \(artist)"
        var comps = URLComponents(string: "https://search.kuwo.cn/r.s")!
        comps.queryItems = [
            URLQueryItem(name: "all", value: kw),
            URLQueryItem(name: "ft", value: "music"),
            URLQueryItem(name: "itemset", value: "web_2013"),
            URLQueryItem(name: "client", value: "kt"),
            URLQueryItem(name: "pn", value: "0"),
            URLQueryItem(name: "rn", value: "8"),
            URLQueryItem(name: "rformat", value: "json"),
            URLQueryItem(name: "encoding", value: "utf8"),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("https://www.kuwo.cn/", forHTTPHeaderField: "Referer")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return nil }

        var bestSim = 0.0
        var bestPlay = 0.0
        for item in kuwoItems(text) {
            let sim = TextMatch.similarity(title, item.name)
            guard sim >= 0.55 else { continue }
            if !artist.isEmpty, TextMatch.similarity(artist, item.artist) < 0.5 { continue }
            guard let play = Double(item.play) else { continue }
            if sim > bestSim { bestSim = sim; bestPlay = play }
        }
        guard bestSim > 0 else { return nil }
        return min(1, log10(1 + bestPlay) / 4)
    }

    /// 酷我返回的是**单引号 JSON**（不是合法 JSON），而且夹着 `&nbsp;`、`\\u0026`，
    /// 所以不能用 JSONSerialization。这里按 `{...}` 平衡切出每首歌，再按 `'KEY':'value'` 取字段。
    private nonisolated static func kuwoItems(_ text: String) -> [(name: String, artist: String, play: String)] {
        guard let head = text.range(of: "'abslist':[") else { return [] }
        var items: [(String, String, String)] = []
        var depth = 0
        var start: String.Index?
        var i = head.upperBound
        while i < text.endIndex {
            let c = text[i]
            if c == "{" {
                if depth == 0 { start = i }
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0, let s = start {
                    let obj = String(text[s...i])
                    items.append((kuwoField(obj, "SONGNAME"),
                                  kuwoField(obj, "ARTIST"),
                                  kuwoField(obj, "PLAYCNT")))
                    start = nil
                }
            }
            i = text.index(after: i)
        }
        return items
    }

    private nonisolated static func kuwoField(_ obj: String, _ key: String) -> String {
        guard let r = obj.range(of: "'\(key)':'") else { return "" }
        let rest = obj[r.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return "" }
        return cleanKuwo(String(rest[..<end]))
    }

    private nonisolated static func cleanKuwo(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\/", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 列表排序

extension Array where Element == TrackRef {
    /// 按排序模式重排。热度模式下用缓存分数，没算过的排后面（不会因为缺分而乱序）
    @MainActor
    func sortedRefs(_ mode: TrackSortMode) -> [TrackRef] {
        switch mode {
        case .source:
            return self
        case .title:
            return sorted { $0.track.title.localizedStandardCompare($1.track.title) == .orderedAscending }
        case .artist:
            return sorted {
                let a = $0.track.displayArtist, b = $1.track.displayArtist
                if a != b { return a.localizedStandardCompare(b) == .orderedAscending }
                return $0.track.title.localizedStandardCompare($1.track.title) == .orderedAscending
            }
        case .hot:
            let ranker = HotRanker.shared
            return sorted { a, b in
                let sa = ranker.score(for: a.track), sb = ranker.score(for: b.track)
                switch (sa, sb) {
                case let (x?, y?):
                    if abs(x - y) > 0.0005 { return x > y }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }
                return a.track.title.localizedStandardCompare(b.track.title) == .orderedAscending
            }
        }
    }
}

// MARK: - 排序菜单

/// 列表顶部的排序选择器。切到「综合热度」时自动开始补齐并显示进度。
struct TrackSortMenu: View {
    @Binding var mode: TrackSortMode
    @ObservedObject private var hot = HotRanker.shared

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("排序方式", selection: $mode) {
                    ForEach(TrackSortMode.allCases) { m in
                        Label(m.label, systemImage: m.icon).tag(m)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: mode.icon).font(.caption)
                    Text(mode.label).font(.caption.weight(.medium))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Theme.surface, in: Capsule())
                .foregroundStyle(mode == .hot ? Theme.accent : .secondary)
            }

            if mode == .hot {
                if hot.ranking {
                    HStack(spacing: 5) {
                        ProgressView().scaleEffect(0.55).frame(width: 14, height: 14)
                        Text("获取热度 \(hot.doneCount)/\(hot.totalCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("网易云 + 酷我")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
