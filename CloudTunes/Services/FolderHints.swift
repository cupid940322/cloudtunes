import Foundation

/// 从文件夹结构推断歌手 / 专辑。
///
/// 云盘里的音乐库基本都是人工整理过的：
///   `周杰伦/范特西/晴天.flac`、`周杰伦 - 范特西/03 晴天.mp3`、`陈奕迅《U87》/…`
/// 这些目录名本身就是「人给出的元数据」，比文件名靠谱得多。
/// 把它们当作上下文去约束在线匹配，能挡掉大量「同名不同人 / 同名不同专辑」的错配。
enum FolderHints {

    struct Hint {
        var artist: String?
        var album: String?
        /// 歌手可信度 0~1：只有可信时才拿它去惩罚候选
        var artistConfidence: Double = 0
        var albumConfidence: Double = 0

        var isEmpty: Bool { artist == nil && album == nil }
    }

    /// 明显不是歌手/专辑的目录名（云盘里常见的容器目录）
    private static let noiseNames: Set<String> = [
        "music", "音乐", "我的音乐", "音乐库", "歌曲", "song", "songs",
        "下载", "download", "downloads", "新建文件夹", "new folder",
        "未分类", "其他", "其它", "杂项", "整理", "待整理",
        "album", "albums", "artist", "artists", "local", "itunes",
        "unknown", "未知", "未知专辑", "未知艺术家", "未知歌手",
        "cloud", "cloudmusic", "netease", "qqmusic", "kugou",
        "无损", "flac", "mp3", "ape", "wav", "hires",
    ]

    static func isNoise(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return true }
        if noiseNames.contains(s.lowercased()) { return true }
        // 纯数字 / 纯符号
        if s.range(of: "^[0-9\\s._\\-]+$", options: .regularExpression) != nil { return true }
        // CD1 / Disc 2 / Vol.3
        if s.range(of: "^(cd|disc|disk|vol|part)\\s*[0-9]+$",
                   options: [.regularExpression, .caseInsensitive]) != nil { return true }
        // 只有年份
        if s.range(of: "^(19|20)[0-9]{2}$", options: .regularExpression) != nil { return true }
        return false
    }

    /// 从「库根 → 父目录」的目录名数组推断歌手/专辑。
    /// - Parameters:
    ///   - folderPath: 不含库根自身的目录名，最后一个是歌曲所在目录
    ///   - filenameArtist: 文件名里解析出的歌手（用来交叉验证哪一层是歌手目录）
    static func hint(for folderPath: [String], filenameArtist: String? = nil) -> Hint {
        var h = rawHint(for: folderPath, filenameArtist: filenameArtist)
        // 合辑目录不能当歌手用（「群星」「Various Artists」下歌手各不相同）
        if let a = h.artist, variousArtists.contains(a.lowercased()) {
            h.artist = nil
            h.artistConfidence = 0
        }
        return h
    }

    private static let variousArtists: Set<String> = [
        "群星", "合辑", "精选集", "杂锦", "杂锦合辑",
        "various artists", "various", "va", "v.a.", "compilation",
    ]

    private static func rawHint(for folderPath: [String], filenameArtist: String?) -> Hint {
        let levels = folderPath
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !isNoise($0) }
        guard !levels.isEmpty else { return Hint() }

        // ① 任意一层是「歌手 - 专辑」/「歌手《专辑》」——这是最可靠的信号
        for name in levels.reversed() {
            if let pair = splitArtistAlbum(name) {
                return Hint(artist: pair.0, album: pair.1,
                            artistConfidence: 0.90, albumConfidence: 0.85)
            }
        }

        let inner = stripYearTag(levels[levels.count - 1])
        let outer = levels.count >= 2 ? stripYearTag(levels[levels.count - 2]) : nil
        let fileArtist = filenameArtist?.trimmingCharacters(in: .whitespaces)

        if let fa = fileArtist, !fa.isEmpty, !isNoise(fa) {
            // ② 目录名本身就是歌手（库根/周杰伦/晴天.mp3）
            if TextMatch.similarity(fa, inner) >= 0.60 {
                return Hint(artist: inner, album: outer,
                            artistConfidence: 0.95,
                            albumConfidence: outer == nil ? 0 : 0.35)
            }
            // ③ 标准的「歌手/专辑」两层
            if let outer, TextMatch.similarity(fa, outer) >= 0.60 {
                return Hint(artist: outer, album: inner,
                            artistConfidence: 0.95, albumConfidence: 0.80)
            }
        }

        if let outer, !outer.isEmpty, outer.caseInsensitiveCompare(inner) != .orderedSame {
            // ④ 两层但文件名里没有歌手可验证：靠结构猜（可信度中等）
            return Hint(artist: outer, album: inner,
                        artistConfidence: 0.55, albumConfidence: 0.60)
        }

        // ⑤ 只有一层：多半是专辑名（也可能是歌手，要看在线匹配结果来定）
        return Hint(artist: nil, album: inner, artistConfidence: 0, albumConfidence: 0.40)
    }

    // MARK: - 拆「歌手 - 专辑」

    /// 支持：`周杰伦 - 范特西`、`周杰伦《范特西》`、`周杰伦 - 《范特西》`、`范特西(2001)`
    static func splitArtistAlbum(_ raw: String) -> (String, String)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 3 else { return nil }

        // 《专辑》
        if let l = s.firstIndex(of: "《"), let r = s.lastIndex(of: "》"), l < r {
            var artist = String(s[s.startIndex..<l])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—·_、,"))
            let album = String(s[s.index(after: l)..<r]).trimmingCharacters(in: .whitespaces)
            artist = stripYearTag(artist)
            if plausible(artist), plausible(album) { return (artist, album) }
        }

        // 「A - B」：要求分隔符两侧都有内容
        let separators = [" - ", " – ", " — ", " —", "－", "—", "–"]
        for sep in separators {
            guard let r = s.range(of: sep) else { continue }
            let a = stripYearTag(String(s[s.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces))
            let b = stripYearTag(String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces))
            if plausible(a), plausible(b) { return (a, b) }
        }
        return nil
    }

    private static func plausible(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 40 else { return false }
        if isNoise(s) { return false }
        // 不能是「01」「Track 03」这种
        if s.range(of: "^[0-9\\s.]+$", options: .regularExpression) != nil { return false }
        return true
    }

    /// 去掉「(2001)」「[FLAC]」「(320kbps)」这类后缀
    static func stripYearTag(_ raw: String) -> String {
        var s = raw
        let patterns = [
            "[（(\\[【]\\s*(19|20)[0-9]{2}[^）)\\]】]*[）)\\]】]",
            "[（(\\[【]\\s*[0-9]{2,3}\\s*k(bps)?[^）)\\]】]*[）)\\]】]",
            "[（(\\[【]\\s*(flac|ape|wav|mp3|hi-?res|dsd|无损)[^）)\\]】]*[）)\\]】]",
        ]
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
