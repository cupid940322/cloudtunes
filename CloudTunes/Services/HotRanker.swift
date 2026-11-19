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
/// **为什么是三个信号**
/// 只用网易云 + 酷我会有硬伤：很多歌（尤其周杰伦、五月天等）在这两家没有版权，
/// 查不到分就被当成 0 分垫底，可它们在全网其实很热。所以换成下面三个：
///
/// - 网易云 `cloudsearch` 的 `pop`（0~100 站内流行度）—— 有版权时最准
/// - 酷狗 `song_search_v2` 的 `OwnerCount`（加入歌单的用户数）—— 版权覆盖极广，
///   搜索接口直接返回数值，实测 8/8 都能匹配到正版
/// - **QQ 音乐热歌榜**（topId 26）—— 官方定义就是「按播放、下载、收藏综合热度排名前 300 首」，
///   一次请求拿全榜，专门补 QQ 独占版权的歌（周杰伦在榜 11 首）
///
/// 酷我（`PLAYCNT`）曾经用过，后来实测发现它的搜索接口返回的几乎全是 KTV 伴奏、
/// DJ 版、演唱会片段，连正版都匹配不到，数值又只有几十几百的量级 —— 是纯噪声，已移除。
///
/// **综合分**：三个信号各自归一化到 0~1 后加权（网易云 0.35 / 酷狗 0.40 / QQ榜 0.25），
/// 分母只算「当前实际拿到的那几个源」，缺源不会把分数拉低。
/// 只有单个源命中时整体乘 0.90：证据不足，不该封顶。
///
/// **成本控制**：每首歌 2 个请求（QQ 榜是整榜一次拉，摊到每首约等于 0），结果缓存 7 天；
/// 榜单缓存 12 小时。缓存命中后排序是纯本地计算，不联网。
@MainActor
final class HotRanker: ObservableObject {
    static let shared = HotRanker()

    struct Entry: Codable, Sendable {
        /// 综合分 0~1
        var score: Double
        /// 网易云归一化分（nil 表示没匹配到）
        var netease: Double?
        /// 酷狗归一化分（nil 表示没匹配到）
        var kugou: Double? = nil
        /// QQ 热歌榜归一化分（nil 表示没进榜）
        var qq: Double? = nil
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

    fileprivate static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // v2：加了酷狗和 QQ 榜两个源，旧缓存（只有两源的分）直接失效重算
        return dir.appendingPathComponent("hot-rank-v2.json")
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
            // QQ 热歌榜是整榜一次拉（约 0.3 秒），拿到后所有歌共享，不用每首查
            let chart = await QQChartStore.shared.scores()
            var i = 0
            while i < wanted.count {
                if Task.isCancelled { break }
                let slice = Array(wanted[i..<min(i + self.batchSize, wanted.count)])
                let got = await withTaskGroup(of: (String, Entry?).self) { group -> [(String, Entry?)] in
                    for item in slice {
                        group.addTask {
                            (item.key, await HotRanker.fetch(title: item.title, artist: item.artist, chart: chart))
                        }
                    }
                    var out: [(String, Entry?)] = []
                    for await r in group { out.append(r) }
                    return out
                }
                if Task.isCancelled { break }
                for (key, entry) in got {
                    // 查不到也写一条 0 分：避免每次切排序都重试一遍
                    self.entries[key] = entry ?? Entry(score: 0, netease: nil,
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

    /// 一首歌的综合分。`chart` 是 QQ 热歌榜的「歌名|歌手 → 归一化分」查表
    nonisolated static func fetch(title: String, artist: String, chart: [String: Double]) async -> Entry? {
        async let n = neteaseScore(title: title, artist: artist)
        async let g = kugouScore(title: title, artist: artist)
        let (nv, gv) = await (n, g)
        let qv = chartScore(title: title, artist: artist, chart: chart)
        guard nv != nil || gv != nil || qv != nil else { return nil }

        var num = 0.0, den = 0.0, hits = 0
        if let nv { num += nv * 0.35; den += 0.35; hits += 1 }
        if let gv { num += gv * 0.40; den += 0.40; hits += 1 }
        if let qv { num += qv * 0.25; den += 0.25; hits += 1 }
        var score = den > 0 ? num / den : 0
        // 单个源命中：证据不足，压一下，别让「只有网易云一个 pop=100」直接封顶
        if hits == 1 { score *= 0.90 }
        return Entry(score: score, netease: nv, kugou: gv, qq: qv,
                     at: Date().timeIntervalSince1970)
    }

    /// 从榜单查表里取分。歌手可能是「许嵩、何曼婷」这种多歌手，逐个试
    nonisolated static func chartScore(title: String, artist: String, chart: [String: Double]) -> Double? {
        guard !chart.isEmpty else { return nil }
        if let v = chart[cacheKey(title: title, artist: artist)] { return v }
        for a in splitArtists(artist) {
            if let v = chart[cacheKey(title: title, artist: a)] { return v }
        }
        return nil
    }

    /// 把「许嵩、何曼婷」「mj apanay/aren park」这类多歌手串拆开
    nonisolated static func splitArtists(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        let seps = CharacterSet(charactersIn: "、/／&,，;；+")
        return raw.components(separatedBy: seps)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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

    /// 酷狗：`OwnerCount`（把这首歌加进自己歌单的用户数）→ 对数归一，1 千万约等于 1.0。
    /// 酷狗版权覆盖极广，是「其它平台没版权」时最主要的兜底信号。
    private nonisolated static func kugouScore(title: String, artist: String) async -> Double? {
        let kw = artist.isEmpty ? title : "\(title) \(artist)"
        var comps = URLComponents(string: "https://songsearch.kugou.com/song_search_v2")!
        comps.queryItems = [
            URLQueryItem(name: "keyword", value: kw),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "pagesize", value: "8"),
            URLQueryItem(name: "platform", value: "WebFilter"),
            URLQueryItem(name: "userid", value: "-1"),
            URLQueryItem(name: "clientver", value: "2000"),
            URLQueryItem(name: "iscorrection", value: "1"),
            URLQueryItem(name: "privilege_filter", value: "0"),
            URLQueryItem(name: "filter", value: "10"),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("https://www.kugou.com/", forHTTPHeaderField: "Referer")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let d = root["data"] as? [String: Any],
              let lists = d["lists"] as? [[String: Any]] else { return nil }

        var bestSim = 0.0
        var bestOwner = 0.0
        for s in lists {
            let name = s["SongName"] as? String ?? ""
            let singer = s["SingerName"] as? String ?? ""
            let sim = TextMatch.similarity(title, name)
            guard sim >= 0.55 else { continue }
            if !artist.isEmpty {
                let hit = splitArtists(singer).contains { TextMatch.similarity(artist, $0) >= 0.5 }
                guard hit else { continue }
            }
            let owner = (s["OwnerCount"] as? NSNumber)?.doubleValue ?? 0
            guard owner > 0 else { continue }
            if sim > bestSim { bestSim = sim; bestOwner = owner }
        }
        guard bestSim > 0 else { return nil }
        return min(1, log10(1 + bestOwner) / 7)
    }
}

// MARK: - QQ 音乐热歌榜

/// QQ 音乐热歌榜（topId 26）。
///
/// 官方对这份榜单的定义：「按照歌曲在 QQ 音乐移动端登录用户中产生的完整播放、下载数、
/// 收藏数综合热度进行排名」，每日更新，前 300 首。正好补上 QQ 独占版权的歌
/// （周杰伦在榜 11 首、许嵩 6 首，而这些在网易云/酷我多半查不到）。
///
/// 整榜一次请求（实测 0.3 秒 / 299 首），缓存 12 小时。榜外的歌 `qq` 分为 nil，
/// **不参与加权**（所以不会把其它源的分拉低）。
actor QQChartStore {
    static let shared = QQChartStore()

    private struct Disk: Codable {
        var at: Double
        var total: Int
        var ranks: [String: Int]
    }

    private var memo: Disk?
    private var inflight: Task<[String: Double], Never>?

    private static let ttl: Double = 12 * 3600

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("qq-chart.json")
    }

    /// 并发调用只会真正发一次请求
    func scores() async -> [String: Double] {
        if let t = inflight { return await t.value }
        if let disk = memo ?? loadDisk(),
           Date().timeIntervalSince1970 - disk.at < Self.ttl,
           disk.total > 0 {
            memo = disk
            return Self.expand(disk)
        }
        let task = Task { await self.refresh() }
        inflight = task
        let out = await task.value
        inflight = nil
        return out
    }

    private func refresh() async -> [String: Double] {
        let body: [String: Any] = [
            "comm": ["ct": 24, "cv": 0],
            "req": [
                "module": "musicToplist.ToplistInfoServer",
                "method": "GetDetail",
                "param": ["topId": 26, "offset": 0, "num": 300, "period": ""],
            ],
        ]
        var req = URLRequest(url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        req.setValue(HotRanker.ua, forHTTPHeaderField: "User-Agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let reqDict = root["req"] as? [String: Any],
              let level1 = reqDict["data"] as? [String: Any],
              let level2 = level1["data"] as? [String: Any],
              let songs = level2["song"] as? [[String: Any]] else {
            // 拉不到就用过期缓存，有总比没有好
            if let disk = memo ?? loadDisk(), disk.total > 0 { return Self.expand(disk) }
            return [:]
        }

        var ranks: [String: Int] = [:]
        for s in songs {
            guard let rank = (s["rank"] as? NSNumber)?.intValue, rank > 0 else { continue }
            let title = s["title"] as? String ?? ""
            guard !title.isEmpty else { continue }
            let singers = HotRanker.splitArtists(s["singerName"] as? String ?? "")
            if singers.isEmpty {
                ranks[HotRanker.cacheKey(title: title, artist: nil)] = rank
            } else {
                for a in singers { ranks[HotRanker.cacheKey(title: title, artist: a)] = rank }
            }
        }
        let total = max((level2["totalNum"] as? NSNumber)?.intValue ?? 0, songs.count)
        let disk = Disk(at: Date().timeIntervalSince1970, total: total, ranks: ranks)
        memo = disk
        if let payload = try? JSONEncoder().encode(disk) {
            try? payload.write(to: Self.fileURL, options: .atomic)
        }
        return Self.expand(disk)
    }

    private func loadDisk() -> Disk? {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return nil }
        return try? JSONDecoder().decode(Disk.self, from: data)
    }

    /// 名次 → 0~1：第 1 名 1.0、第 300 名 0.35。
    /// 给下限是因为「能进日榜前 300」本身已经是很强的热度信号。
    private static func expand(_ disk: Disk) -> [String: Double] {
        guard disk.total > 1 else { return [:] }
        var out: [String: Double] = [:]
        out.reserveCapacity(disk.ranks.count)
        let span = Double(disk.total - 1)
        for (key, rank) in disk.ranks {
            let p = 1.0 - Double(rank - 1) / span
            out[key] = 0.35 + 0.65 * max(0, min(1, p))
        }
        return out
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
                    Text("网易云 + 酷狗 + QQ榜")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
