package com.gysbs.cloudtunes.core

import kotlin.math.abs

/// 歌词：LRC 解析 + 网易云歌词获取
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

    /// 获取歌词：优先用已刮削到的 neteaseID，没有就按多个关键词现场搜一轮。
    /// 关键词依次为「歌手 歌名」→ 歌名 → 去掉括号标注的歌名，任一命中即用。
    suspend fun fetch(track: LibraryTrack): String? {
        var id = track.neteaseID
        if (id == null || id <= 0) {
            val artist = track.artist?.takeIf { it.isNotBlank() }
            val rawTitle = track.title
            val cleanTitle = Scanner.parseTitle(rawTitle).ifBlank { rawTitle }
            val queries = buildList {
                artist?.let { add("$it $rawTitle") }
                add(rawTitle)
                if (cleanTitle != rawTitle) add(cleanTitle)
            }.distinct()
            for (kw in queries) {
                val hit = Scraper.neteaseSearch(kw, limit = 4).firstOrNull { song ->
                    val songTitle = song.title ?: return@firstOrNull false
                    val titleOk = TextMatch.similarity(cleanTitle, Scanner.parseTitle(songTitle)) >= 0.55 ||
                        TextMatch.similarity(cleanTitle, songTitle) >= 0.55
                    val artistOk = artist == null || song.artist.isNullOrBlank() ||
                        TextMatch.similarity(artist, song.artist) >= 0.40
                    titleOk && artistOk
                }?.neteaseID ?: continue
                id = hit
                break
            }
        }
        if (id == null || id <= 0) return null
        return Scraper.neteaseLyrics(id)
    }
}
