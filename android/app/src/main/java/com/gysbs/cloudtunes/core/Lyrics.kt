package com.gysbs.cloudtunes.core

import kotlin.math.abs

/// 歌词：LRC 解析 + 四源歌词获取（网易云 / QQ音乐 / 酷狗 / LRCLIB，对齐 iOS LyricsService）
object Lyrics {

    /// 解析 LRC 文本 → 按时间排序的歌词行
    fun parse(lrc: String): List<LyricLine> {
        val timeRegex = Regex("\\[(\\d{1,2}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]")
        val out = mutableListOf<LyricLine>()
        var index = 0
        for (rawLine in lrc.lines()) {
            val times = timeRegex.findAll(rawLine).mapNotNull { m ->
                val min = m.groupValues[1].toInt()
                val sec = m.groupValues[2].toInt()
                val fracStr = m.groupValues[3]
                val frac = if (fracStr.isEmpty()) 0.0 else {
                    val v = fracStr.toInt()
                    when (fracStr.length) {
                        1 -> v * 0.1
                        2 -> v * 0.01
                        else -> v / 1000.0
                    }
                }
                min * 60.0 + sec + frac
            }.toList()
            if (times.isEmpty()) continue
            val text = rawLine.replace(timeRegex, "").trim()
            if (text.isEmpty()) continue
            for (t in times) {
                out += LyricLine(index++, t, text)
            }
        }
        return out.sortedBy { it.time }
    }

    /// 解析任意来源歌词：有时间轴按 LRC，没有就按纯文本行（time=-1，对齐 iOS lines(from:)）
    fun parseAny(text: String): List<LyricLine> {
        val parsed = parse(text)
        if (parsed.isNotEmpty()) return parsed
        return text.lines()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .mapIndexed { i, line -> LyricLine(i, -1.0, line) }
    }

    /// 找出当前时间应该显示的行号
    fun activeIndex(lines: List<LyricLine>, at: Double, leadIn: Double = 0.0): Int? {
        if (lines.isEmpty()) return null
        var lo = 0
        var result: Int? = null
        for (i in lines.indices) {
            if (lines[i].time - leadIn <= at + 1e-9) { result = i; lo = i } else break
        }
        return result
    }

    // ── 自动获取 ──

    /// 获取歌词：①缓存 ②网易云（已有 ID 或关键词搜索）③QQ → ④酷狗 → ⑤LRCLIB。
    /// 关键词依次为「歌手 歌名」→ 歌名 → 去掉括号标注的歌名，任一命中即用。
    suspend fun fetch(track: LibraryTrack): String? {
        // ① 缓存优先（手动匹配过的非网易云歌词只有这里有）
        LyricsCache.get(track.id)?.let { return it }

        val artist = track.artist?.takeIf { it.isNotBlank() }
        val rawTitle = track.title
        val cleanTitle = Scanner.parseTitle(rawTitle).ifBlank { rawTitle }
        val queries = buildList {
            artist?.let { add("$it $rawTitle") }
            add(rawTitle)
            if (cleanTitle != rawTitle) add(cleanTitle)
        }.distinct()

        // ② 网易云（优先已刮削的 ID，最快）
        var neteaseId: Int? = track.neteaseID
        if (neteaseId == null || neteaseId <= 0) {
            for (kw in queries) {
                val hit = Scraper.neteaseSearch(kw, limit = 4).firstOrNull { song ->
                    matches(song.title, song.artist, cleanTitle, artist)
                }?.neteaseID ?: continue
                neteaseId = hit
                break
            }
        }
        if (neteaseId != null && neteaseId > 0) {
            val lrc = runCatching { Scraper.neteaseLyrics(neteaseId) }.getOrNull()
            if (!lrc.isNullOrBlank()) {
                LyricsCache.put(track.id, lrc)
                return lrc
            }
        }

        // ③④⑤ 其他三源按顺序兜底（每源限时，避免整体拖太久）
        for (kw in queries) {
            LyricSources.qqSearch(kw, limit = 5).firstOrNull {
                matches(it.title, it.artist, cleanTitle, artist)
            }?.let { hit ->
                LyricSources.qqLyric(hit.qqMid!!)?.let { lrc ->
                    LyricsCache.put(track.id, lrc)
                    return lrc
                }
            }
        }
        for (kw in queries) {
            LyricSources.kugouSearch(kw).firstOrNull {
                matches(it.title, it.artist, cleanTitle, artist)
            }?.let { hit ->
                LyricSources.kugouLyric(hit.kugouId!!, hit.kugouKey!!)?.let { lrc ->
                    LyricsCache.put(track.id, lrc)
                    return lrc
                }
            }
        }
        LyricSources.lrclibSearch(cleanTitle, artist).firstOrNull {
            matches(it.title, it.artist, cleanTitle, artist)
        }?.let { hit ->
            hit.inlineText?.let { lrc ->
                LyricsCache.put(track.id, lrc)
                return lrc
            }
        }
        return null
    }

    /// 标题/歌手相似度校验（四种来源共用同一套阈值）
    private fun matches(
        songTitle: String?,
        songArtist: String?,
        cleanTitle: String,
        artist: String?,
    ): Boolean {
        val t = songTitle ?: return false
        val titleOk = TextMatch.similarity(cleanTitle, Scanner.parseTitle(t)) >= 0.55 ||
            TextMatch.similarity(cleanTitle, t) >= 0.55
        val artistOk = artist == null || songArtist.isNullOrBlank() ||
            TextMatch.similarity(artist, songArtist) >= 0.40
        return titleOk && artistOk
    }
}
