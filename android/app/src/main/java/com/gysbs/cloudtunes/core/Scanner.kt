package com.gysbs.cloudtunes.core

/// 音乐文件识别 + 文件名解析（对齐 iOS MusicScanner）
object Scanner {

    val audioExtensions = setOf("mp3", "flac", "m4a", "aac", "wav", "aiff", "aif", "alac", "m4b")

    fun isAudioFile(name: String): Boolean {
        val ext = name.substringAfterLast('.', "").lowercase()
        return ext in audioExtensions
    }

    fun filterAudio(files: List<CloudFile>): List<CloudFile> =
        files.filter { !it.isFolder && isAudioFile(it.name) }

    data class ParsedName(val title: String, val artist: String?)

    fun parse(filename: String): ParsedName {
        val rawBase = filename.substringBeforeLast('.')
        val cleaned = cleanBase(filename)
        if (cleaned.isEmpty()) return ParsedName(rawBase, null)

        // 《歌名》歌手
        if (cleaned.startsWith("《")) {
            val close = cleaned.indexOf("》")
            if (close > 0) {
                val inner = cleaned.substring(1, close).trim()
                val rest = cleaned.substring(close + 1).trim()
                if (inner.isNotEmpty() && rest.isNotEmpty()) return ParsedName(inner, sanitizeArtist(rest))
            }
        }

        val pair = splitArtistTitle(cleaned)
        if (pair != null) {
            var artist = sanitizeArtist(pair.first)
            var title = pair.second.trim()

            // "115 - 周杰伦 - 晴天"：左边是无效序号，把右边再拆一次
            if (artist == null) {
                val inner = splitArtistTitle(title)
                if (inner != null) {
                    val innerArtist = sanitizeArtist(inner.first)
                    if (innerArtist != null) {
                        artist = innerArtist
                        title = inner.second.trim()
                    }
                }
            }

            if (title.isNotEmpty()) {
                val cleanedTitle = stripLeadingIndex(title).trim()
                return ParsedName(cleanedTitle.ifEmpty { title }, artist)
            }
        }
        return ParsedName(cleaned, null)
    }

    fun parseTitle(filename: String): String = parse(filename).title
    fun parseArtist(filename: String): String? = parse(filename).artist

    // ── 清洗 ──

    private val noiseWords = setOf(
        "flac", "ape", "wav", "mp3", "aac", "m4a", "ogg", "opus", "dsd", "dsf",
        "hires", "hi", "res", "sq", "hq", "320k", "320kbps", "192k", "128k",
        "无损", "高音质", "超品", "母带", "原盘", "cd", "vinyl", "web",
        "mqms", "qqmusic", "netease", "cloudmusic", "kgm", "ncm",
    )

    fun cleanBase(filename: String): String {
        var s = filename.substringBeforeLast('.')
        s = s.replace("\u3000", " ")
        s = stripBracketedNoise(s)
        s = stripLeadingIndex(s)
        s = trimWrapping(s)
        s = s.trim { it in " \t\r\n-_·.、,，;；" }
        while (s.contains("  ")) s = s.replace("  ", " ")
        return s.trim()
    }

    private fun trimWrapping(s: String): String {
        var t = s
        val pairs = listOf("《" to "》", "「" to "」", "\"" to "\"", "'" to "'", "（" to "）")
        for ((l, r) in pairs) {
            if (t.startsWith(l) && t.endsWith(r) && t.length > l.length + r.length) {
                t = t.drop(l.length).dropLast(r.length)
            }
        }
        return t
    }

    private val bracketPattern = Regex("[\\[（(【<]([^\\]）)】>]*)[\\]）)】>]")

    private fun stripBracketedNoise(s: String): String {
        var result = s
        for (m in bracketPattern.findAll(s).toList().reversed()) {
            val inner = m.groupValues[1].trim().lowercase()
            if (isNoiseToken(inner)) result = result.removeRange(m.range)
        }
        return result
    }

    private fun isNoiseToken(innerRaw: String): Boolean {
        val t = innerRaw.trim().lowercase()
        if (t.isEmpty()) return false
        if (t in noiseWords) return true
        if (t.startsWith("mqms") || t.startsWith("qqmusic") || t.startsWith("netease")) return true
        if (t.contains("kbps") || t.contains("bit") ||
            (t.endsWith("k") && t.dropLast(1).all { it.isDigit() })) return true
        if (t.all { it.isDigit() }) return true
        val words = t.split(' ', '.', '_', '/', '|', '+', '-').filter { it.isNotEmpty() }
        if (words.isNotEmpty() && words.all { it in noiseWords || it.all { c -> c.isDigit() } }) return true
        return false
    }

    private val indexPatterns = listOf(
        Regex("^\\s*\\[\\d{1,3}\\]\\s*"),
        Regex("^\\s*\\d{1,3}\\s*[.、,，:：)）\\-_]\\s*"),
    )

    fun stripLeadingIndex(s: String): String {
        var t = s
        for (p in indexPatterns) {
            val m = p.find(t)
            if (m != null) {
                val rest = t.substring(m.range.last + 1)
                if (rest.isNotBlank()) t = rest
            }
        }
        // "01 歌名"：两位以内数字 + 空格 + 中文才当序号
        val re = Regex("^\\s*\\d{1,2}\\s+")
        val m = re.find(t)
        if (m != null) {
            val rest = t.substring(m.range.last + 1)
            if (rest.containsCJK() && rest.isNotBlank()) t = rest
        }
        return t
    }

    private fun splitArtistTitle(base: String): Pair<String, String>? {
        for (sep in listOf(" - ", " – ", " — ", " － ", " · ", " —")) {
            val idx = base.indexOf(sep)
            if (idx > 0) {
                val left = base.substring(0, idx).trim()
                val right = base.substring(idx + sep.length).trim()
                if (left.isNotEmpty() && right.isNotEmpty()) return left to right
            }
        }
        val chars = base.toCharArray()
        for (i in 1 until chars.size - 1) {
            val c = chars[i]
            if (c != '-' && c != '_' && c != '—' && c != '－') continue
            val left = String(chars, 0, i).trim()
            val right = String(chars, i + 1, chars.size - i - 1).trim()
            if (left.isEmpty() || right.isEmpty()) continue
            if (!left.containsCJK() && !right.containsCJK()) continue
            if (left.length > 30 || right.length > 60) continue
            return left to right
        }
        return null
    }

    private fun sanitizeArtist(raw: String): String? {
        var a = raw.trim()
        a = a.replace(Regex("^\\s*[\\[【（(][^\\]】）)]{0,8}[\\]】）)]\\s*"), "")
        a = a.trim { it in " -_·" }
        if (a.isEmpty()) return null
        if (a.all { !it.isLetter() && !it.isDigit() }) return null
        if (a.all { it.isDigit() }) return null
        val lowered = a.lowercase()
        val unknown = setOf("unknown", "unknown artist", "va", "various", "various artists",
            "未知", "未知艺术家", "群星", "合辑", "杂锦", "其他")
        if (lowered in unknown) return null
        if (a.length > 40) return null
        return a
    }

    fun String.containsCJK(): Boolean = any {
        val c = it.code
        (c in 0x4E00..0x9FFF) || (c in 0x3400..0x4DBF) || (c in 0x3040..0x30FF) || (c in 0xAC00..0xD7AF)
    }
}
