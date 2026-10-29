import Foundation

/// 文本相似度：用来校验「在线搜索到的这首歌」是不是真的对得上本地文件。
///
/// 之前直接取搜索第一条，导致大量张冠李戴（封面/专辑全错）。现在改成打分 + 阈值过滤，
/// 宁可没有封面，也不要错的封面。
enum TextMatch {

    /// 归一化：小写、去括号内容、去标点与空白、去官方前缀后缀
    static func normalize(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var s = raw.lowercased()
        s = stripBrackets(s)
        // 常见冗余词
        for token in ["feat.", "feat ", "ft.", "ft ", "official", "mv", "lyric video",
                      "lyrics", "audio", "hq", "高清", "完整版", "官方", "原版", "修复版"] {
            s = s.replacingOccurrences(of: token, with: " ")
        }
        s = s.unicodeScalars
            .filter { scalar in
                !CharacterSet.punctuationCharacters.contains(scalar)
                    && !CharacterSet.symbols.contains(scalar)
                    && !CharacterSet.whitespacesAndNewlines.contains(scalar)
            }
            .map { String($0) }
            .joined()
        return s
    }

    private static func stripBrackets(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "[（(\\[【<][^）)\\]】>]*[）)\\]】>]") else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
    }

    /// 0...1 的相似度
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = normalize(a)
        let y = normalize(b)
        if x.isEmpty || y.isEmpty { return 0 }
        if x == y { return 1 }

        // 一方包含另一方（如「晴天」vs「晴天 (Live)」归一化后相等；「告白气球」vs「告白气球啊」）
        if x.contains(y) || y.contains(x) {
            let ratio = Double(min(x.count, y.count)) / Double(max(x.count, y.count))
            return 0.80 + 0.16 * ratio
        }
        return dice(x, y)
    }

    /// 二元组 Dice 系数，对中文短标题比较稳
    private static func dice(_ a: String, _ b: String) -> Double {
        let ba = bigrams(a)
        let bb = bigrams(b)
        guard !ba.isEmpty, !bb.isEmpty else { return 0 }
        var counts: [String: Int] = [:]
        for g in ba { counts[g, default: 0] += 1 }
        var overlap = 0
        for g in bb {
            if let c = counts[g], c > 0 {
                overlap += 1
                counts[g] = c - 1
            }
        }
        return 2.0 * Double(overlap) / Double(ba.count + bb.count)
    }

    private static func bigrams(_ s: String) -> [String] {
        let chars = Array(s)
        guard chars.count >= 2 else { return chars.map(String.init) }
        var result: [String] = []
        result.reserveCapacity(chars.count - 1)
        for i in 0..<(chars.count - 1) {
            result.append(String(chars[i]) + String(chars[i + 1]))
        }
        return result
    }
}
