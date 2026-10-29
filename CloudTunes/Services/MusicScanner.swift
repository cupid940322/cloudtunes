import Foundation

/// 音乐文件识别 + 文件名解析。
///
/// 云盘里的文件名千奇百怪：「01. 周杰伦 - 晴天 [FLAC].flac」「周杰伦_晴天」「晴天-周杰伦(320k)」
/// 这里先把序号、音质标记、来源标记等噪声剥掉，再按多种分隔符拆分「艺术家 - 标题」。
enum MusicScanner {
    /// iOS AVPlayer 原生可播的音频扩展名（ape/ogg/wma/opus 等原生不支持，暂不收录）
    static let audioExtensions: Set<String> = [
        "mp3", "flac", "m4a", "aac", "wav", "aiff", "aif", "alac", "m4b",
    ]

    static func isAudioFile(_ name: String) -> Bool {
        guard let ext = name.split(separator: ".").last else { return false }
        return audioExtensions.contains(ext.lowercased())
    }

    /// 从目录列表中筛出音频文件
    static func filterAudio(_ files: [CloudFile]) -> [CloudFile] {
        files.filter { !$0.isFolder && isAudioFile($0.name) }
    }

    // MARK: - 解析结果

    struct ParsedName {
        var title: String
        var artist: String?
    }

    static func parse(_ filename: String) -> ParsedName {
        let rawBase = (filename as NSString).deletingPathExtension
        let cleaned = cleanBase(filename)
        guard !cleaned.isEmpty else { return ParsedName(title: rawBase, artist: nil) }

        // 《歌名》歌手
        if cleaned.hasPrefix("《"), let close = cleaned.firstIndex(of: "》") {
            let inner = String(cleaned[cleaned.index(after: cleaned.startIndex)..<close])
            let rest = String(cleaned[cleaned.index(after: close)...])
                .trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty, !rest.isEmpty {
                return ParsedName(title: inner, artist: sanitizeArtist(rest))
            }
        }

        if let pair = splitArtistTitle(cleaned) {
            var artist = sanitizeArtist(pair.0)
            var title = pair.1.trimmingCharacters(in: .whitespaces)

            // "115 - 周杰伦 - 晴天" 这类：左边是无效序号，把右边再拆一次
            if artist == nil, let inner = splitArtistTitle(title) {
                if let innerArtist = sanitizeArtist(inner.0) {
                    artist = innerArtist
                    title = inner.1.trimmingCharacters(in: .whitespaces)
                }
            }

            if !title.isEmpty {
                let cleanedTitle = stripLeadingIndex(title).trimmingCharacters(in: .whitespaces)
                return ParsedName(title: cleanedTitle.isEmpty ? title : cleanedTitle, artist: artist)
            }
        }
        return ParsedName(title: cleaned, artist: nil)
    }

    static func parseTitle(_ filename: String) -> String { parse(filename).title }
    static func parseArtist(_ filename: String) -> String? { parse(filename).artist }

    // MARK: - 清洗

    /// 只去掉「格式/音质/来源」类标记，不动曲名本身（Live/伴奏/Remix 等要保留，否则会匹配到别的版本）
    private static let noiseWords: Set<String> = [
        "flac", "ape", "wav", "mp3", "aac", "m4a", "ogg", "opus", "dsd", "dsf",
        "hires", "hi", "res", "sq", "hq", "320k", "320kbps", "192k", "128k",
        "无损", "高音质", "超品", "母带", "原盘", "cd", "vinyl", "web",
        "mqms", "qqmusic", "netease", "cloudmusic", "kgm", "ncm",
    ]

    static func cleanBase(_ filename: String) -> String {
        var s = (filename as NSString).deletingPathExtension
        s = s.replacingOccurrences(of: "\u{3000}", with: " ")
        s = stripBracketedNoise(s)
        s = stripLeadingIndex(s)
        // 去掉包裹整个名字的书名号/引号
        s = trimWrapping(s)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n-_·.、,，;；"))
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func trimWrapping(_ s: String) -> String {
        var t = s
        let pairs: [(String, String)] = [("《", "》"), ("「", "」"), ("\"", "\""), ("'", "'"), ("（", "）")]
        for (l, r) in pairs {
            if t.hasPrefix(l) && t.hasSuffix(r) && t.count > l.count + r.count {
                t = String(t.dropFirst(l.count).dropLast(r.count))
            }
        }
        return t
    }

    /// 去掉括号里的音质/来源标记，如 [FLAC]、(320kbps)、【mqms2】；保留 (Live)、(Remix) 之类
    private static func stripBracketedNoise(_ s: String) -> String {
        let pattern = "[\\[（(【<]([^\\]）)】>]*)[\\]）)】>]"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        var result = s
        let matches = re.matches(in: s, range: NSRange(s.startIndex..., in: s))
        for m in matches.reversed() {
            guard m.numberOfRanges > 1,
                  let full = Range(m.range, in: result) else { continue }
            let inner = (s as NSString).substring(with: m.range(at: 1))
            if isNoiseToken(inner) {
                result.removeSubrange(full)
            }
        }
        return result
    }

    private static func isNoiseToken(_ inner: String) -> Bool {
        let t = inner.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return false }
        if noiseWords.contains(t) { return true }
        if t.hasPrefix("mqms") || t.hasPrefix("qqmusic") || t.hasPrefix("netease") { return true }
        if t.contains("kbps") || t.contains("bit") || t.hasSuffix("k") && t.dropLast().allSatisfy({ $0.isNumber }) {
            return true
        }
        // 纯数字（如 (1)、(2009)）通常是重复下载/年份标记
        if t.allSatisfy({ $0.isNumber }) { return true }
        // 由噪声词与数字组合而成，如 "flac 320k"
        let words = t.split(whereSeparator: { " ._/|+-".contains($0) }).map(String.init)
        if !words.isEmpty, words.allSatisfy({ noiseWords.contains($0) || $0.allSatisfy({ $0.isNumber }) }) {
            return true
        }
        return false
    }

    /// 去掉开头的曲目序号：01. / 01 - / 01、/ 01) / [01] / "01 歌名"
    private static func stripLeadingIndex(_ s: String) -> String {
        let patterns = [
            "^\\s*\\[\\d{1,3}\\]\\s*",
            "^\\s*\\d{1,3}\\s*[\\.、,，:：\\)）\\-_]\\s*",
        ]
        var t = s
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
               let r = Range(m.range, in: t) {
                let rest = String(t[r.upperBound...])
                if !rest.trimmingCharacters(in: .whitespaces).isEmpty {
                    t = rest
                }
            }
        }
        // "01 歌名"：只有「两位以内数字 + 空格 + 中文」才当序号，避免吃掉 "99 Problems"
        if let re = try? NSRegularExpression(pattern: "^\\s*\\d{1,2}\\s+"),
           let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let r = Range(m.range, in: t) {
            let rest = String(t[r.upperBound...])
            if rest.containsCJK, !rest.trimmingCharacters(in: .whitespaces).isEmpty {
                t = rest
            }
        }
        return t
    }

    // MARK: - 拆分「艺术家 - 标题」

    private static func splitArtistTitle(_ base: String) -> (String, String)? {
        // 1) 带空格的常见分隔符，最可靠
        for sep in [" - ", " – ", " — ", " － ", " · ", " —"] {
            if let r = base.range(of: sep), r.lowerBound != base.startIndex {
                let left = String(base[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let right = String(base[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !left.isEmpty, !right.isEmpty { return (left, right) }
            }
        }
        // 2) 无空格的 - _ —：只在有中文参与时拆，避免把 "Bling-Bling"、"Jay-Z" 拆坏
        let chars = Array(base)
        for i in chars.indices where i > 0 && i < chars.count - 1 {
            let c = chars[i]
            guard c == "-" || c == "_" || c == "—" || c == "－" else { continue }
            let left = String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
            let right = String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
            guard !left.isEmpty, !right.isEmpty else { continue }
            let hasCJK = left.containsCJK || right.containsCJK
            guard hasCJK else { continue }
            guard left.count <= 30, right.count <= 60 else { continue }
            return (left, right)
        }
        return nil
    }

    private static func sanitizeArtist(_ raw: String) -> String? {
        var a = raw.trimmingCharacters(in: .whitespaces)
        // 去掉开头的分类标签，如「【华语】」「[经典]」
        a = a.replacingOccurrences(of: "^\\s*[\\[【（(][^\\]】）)]{0,8}[\\]】）)]\\s*",
                                   with: "", options: .regularExpression)
        // 去掉结尾的 " -" 残留
        a = a.trimmingCharacters(in: CharacterSet(charactersIn: " -_·"))
        guard !a.isEmpty else { return nil }
        // 纯数字或纯符号不是艺术家
        if a.allSatisfy({ !$0.isLetter && !$0.isNumber }) { return nil }
        if a.allSatisfy({ $0.isNumber }) { return nil }
        let lowered = a.lowercased()
        let unknown: Set<String> = ["unknown", "unknown artist", "va", "various", "various artists",
                                    "未知", "未知艺术家", "群星", "合辑", "杂锦", "其他"]
        if unknown.contains(lowered) { return nil }
        if a.count > 40 { return nil }
        return a
    }
}

extension String {
    /// 是否包含 CJK 字符（用于判断中英文混排场景）
    var containsCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)      // 基本汉字
                || (0x3400...0x4DBF).contains(scalar.value)  // 扩展 A
                || (0x3040...0x30FF).contains(scalar.value)  // 日文假名
                || (0xAC00...0xD7AF).contains(scalar.value)  // 韩文
        }
    }
}
