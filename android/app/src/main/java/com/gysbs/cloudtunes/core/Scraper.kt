package com.gysbs.cloudtunes.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import okhttp3.Request
import org.json.JSONObject
import kotlin.math.max
import kotlin.math.min

/// 文本相似度（对齐 iOS TextMatch：归一化 + 包含加分 + 二元组 Dice）
object TextMatch {

    private val redundantTokens = listOf(
        "feat.", "feat ", "ft.", "ft ", "official", "mv", "lyric video",
        "lyrics", "audio", "hq", "高清", "完整版", "官方", "原版", "修复版",
    )

    fun normalize(raw: String): String {
        if (raw.isEmpty()) return ""
        var s = raw.lowercase()
        s = s.replace(Regex("[（(\\[【<][^）)\\]】>]*[）)\\]】>]"), " ")
        for (token in redundantTokens) s = s.replace(token, " ")
        s = s.filter { c ->
            val t: Byte = Character.getType(c).toByte()
            t != Character.CONNECTOR_PUNCTUATION &&
                t != Character.DASH_PUNCTUATION &&
                t != Character.START_PUNCTUATION &&
                t != Character.END_PUNCTUATION &&
                t != Character.INITIAL_QUOTE_PUNCTUATION &&
                t != Character.FINAL_QUOTE_PUNCTUATION &&
                t != Character.OTHER_PUNCTUATION &&
                t != Character.MATH_SYMBOL &&
                t != Character.CURRENCY_SYMBOL &&
                t != Character.MODIFIER_SYMBOL &&
                t != Character.SPACE_SEPARATOR &&
                t != Character.LINE_SEPARATOR &&
                t != Character.PARAGRAPH_SEPARATOR &&
                !c.isWhitespace()
        }
        return s
    }

    fun similarity(a: String, b: String): Double {
        val x = normalize(a)
        val y = normalize(b)
        if (x.isEmpty() || y.isEmpty()) return 0.0
        if (x == y) return 1.0
        if (x.contains(y) || y.contains(x)) {
            val ratio = minOf(x.length, y.length).toDouble() / maxOf(x.length, y.length)
            return 0.80 + 0.16 * ratio
        }
        return dice(x, y)
    }

    private fun dice(a: String, b: String): Double {
        val ba = bigrams(a)
        val bb = bigrams(b)
        if (ba.isEmpty() || bb.isEmpty()) return 0.0
        val counts = HashMap<String, Int>()
        for (g in ba) counts.merge(g, 1, Int::plus)
        var overlap = 0
        for (g in bb) {
            val c = counts[g] ?: continue
            if (c > 0) { overlap++; counts[g] = c - 1 }
        }
        return 2.0 * overlap / (ba.size + bb.size)
    }

    private fun bigrams(s: String): List<String> {
        val chars = s.toCharArray()
        if (chars.size < 2) return chars.map { it.toString() }
        return (0 until chars.size - 1).map { "${chars[it]}${chars[it + 1]}" }
    }
}

/// 在线音乐元数据搜索（网易云 + QQ音乐 + iTunes 三源，对齐 iOS MusicSearchService）
object Scraper {

    data class SongInfo(
        val title: String?,
        val artist: String?,
        val album: String?,
        val coverURL: String?,
        val neteaseID: Int?,
        val duration: Double?,
        val source: String = "",
    )

    data class Match(val info: SongInfo, val score: Double)

    private const val UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

    private suspend fun getJSON(url: String, referer: String? = null, timeoutSec: Long = 10): JSONObject? =
        withContext(Dispatchers.IO) {
            try {
                val builder = okhttp3.OkHttpClient.Builder()
                    .connectTimeout(java.time.Duration.ofSeconds(timeoutSec))
                    .readTimeout(java.time.Duration.ofSeconds(timeoutSec)).build()
                val req = Request.Builder().url(url)
                    .header("User-Agent", UA)
                    .apply { referer?.let { header("Referer", it) } }
                    .get().build()
                builder.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) return@withContext null
                    JSONObject(resp.body?.string() ?: return@withContext null)
                }
            } catch (e: Exception) {
                null
            }
        }

    private suspend fun getJSONArray(url: String, timeoutSec: Long = 12): org.json.JSONArray? =
        withContext(Dispatchers.IO) {
            try {
                val builder = okhttp3.OkHttpClient.Builder()
                    .connectTimeout(java.time.Duration.ofSeconds(timeoutSec))
                    .readTimeout(java.time.Duration.ofSeconds(timeoutSec)).build()
                val req = Request.Builder().url(url).header("User-Agent", UA).get().build()
                builder.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) return@withContext null
                    org.json.JSONArray(resp.body?.string() ?: return@withContext null)
                }
            } catch (e: Exception) {
                null
            }
        }

    private fun keyword(title: String, artist: String?): String {
        val a = (artist ?: "").trim()
        val t = title.trim()
        return when { a.isEmpty() -> t; t.isEmpty() -> a; else -> "$a $t" }
    }

    // ── 网易云 ──

    suspend fun neteaseSearch(kw: String, limit: Int = 8): List<SongInfo> {
        val trimmed = kw.trim()
        if (trimmed.isEmpty()) return emptyList()
        val url = "https://music.163.com/api/search/get/web?s=${enc(trimmed)}&type=1&limit=$limit&offset=0"
        val obj = getJSON(url, referer = "https://music.163.com/") ?: return emptyList()
        val songs = obj.optJSONObject("result")?.optJSONArray("songs") ?: return emptyList()
        return (0 until songs.length()).mapNotNull { i ->
            val s = songs.getJSONObject(i)
            val album = s.optJSONObject("album")
            val artists = s.optJSONArray("artists")
            var pic = album?.optString("picUrl")?.takeIf { it.isNotEmpty() }
            if (pic?.startsWith("http://") == true) pic = "https://" + pic.drop(7)
            SongInfo(
                title = s.optString("name").takeIf { it.isNotEmpty() },
                artist = artists?.optJSONObject(0)?.optString("name"),
                album = album?.optString("name"),
                coverURL = pic,
                neteaseID = if (s.has("id")) s.getInt("id") else null,
                duration = s.optLong("duration", 0).takeIf { it > 0 }?.let { it / 1000.0 },
                source = "网易云",
            )
        }
    }

    suspend fun neteaseDetails(ids: List<Int>): Map<Int, SongInfo> {
        val uniq = ids.filter { it > 0 }.toSet().take(20)
        if (uniq.isEmpty()) return emptyMap()
        val url = "https://music.163.com/api/song/detail?ids=%5B${uniq.joinToString(",")}%5D"
        val obj = getJSON(url, referer = "https://music.163.com/") ?: return emptyMap()
        val songs = obj.optJSONArray("songs") ?: return emptyMap()
        val out = mutableMapOf<Int, SongInfo>()
        for (i in 0 until songs.length()) {
            val s = songs.getJSONObject(i)
            val al = s.optJSONObject("al") ?: s.optJSONObject("album")
            val ar = s.optJSONArray("ar") ?: s.optJSONArray("artists")
            var pic = al?.optString("picUrl")?.takeIf { it.isNotEmpty() }
            if (pic?.startsWith("http://") == true) pic = "https://" + pic.drop(7)
            val ms = if (s.has("dt")) s.optLong("dt") else s.optLong("duration")
            s.optInt("id", 0).takeIf { it > 0 }?.let { id ->
                out[id] = SongInfo(
                    title = s.optString("name").takeIf { it.isNotEmpty() },
                    artist = ar?.optJSONObject(0)?.optString("name"),
                    album = al?.optString("name"),
                    coverURL = pic,
                    neteaseID = id,
                    duration = ms.takeIf { it > 0 }?.let { it / 1000.0 },
                    source = "网易云",
                )
            }
        }
        return out
    }

    suspend fun neteaseDetail(id: Int): SongInfo? = neteaseDetails(listOf(id))[id]

    /// 网易云歌词（LRC）
    suspend fun neteaseLyrics(id: Int): String? {
        val obj = getJSON("https://music.163.com/api/song/lyric?id=$id&lv=1&kv=1&tv=-1",
            referer = "https://music.163.com/") ?: return null
        return obj.optJSONObject("lrc")?.optString("lyric")?.takeIf { it.isNotEmpty() }
    }

    // ── QQ 音乐 ──

    suspend fun qqSearch(kw: String, limit: Int = 5): List<SongInfo> {
        val trimmed = kw.trim()
        if (trimmed.isEmpty()) return emptyList()
        val url = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=$limit&w=${enc(trimmed)}&format=json&cr=1&new_json=1"
        val obj = getJSON(url, referer = "https://y.qq.com/") ?: return emptyList()
        val list = obj.optJSONObject("data")?.optJSONObject("song")?.optJSONArray("list") ?: return emptyList()
        return (0 until list.length()).mapNotNull { i ->
            val item = list.getJSONObject(i)
            val title = item.optString("title").ifEmpty { item.optString("songname") }.takeIf { it.isNotEmpty() }
                ?: return@mapNotNull null
            val artistName = item.optJSONArray("singer")?.optJSONObject(0)?.optString("name")
            val album = item.optJSONObject("album")
            val albumName = album?.optString("name")
            val albumMid = album?.optString("mid")
            val cover = albumMid?.takeIf { it.isNotEmpty() }
                ?.let { "https://y.qq.com/music/photo_new/T002R500x500M000$it.jpg" }
            SongInfo(
                title = title,
                artist = artistName,
                album = albumName,
                coverURL = cover,
                neteaseID = null,
                duration = item.optDouble("interval", 0.0).takeIf { it > 0 },
                source = "QQ音乐",
            )
        }
    }

    // ── iTunes ──

    suspend fun itunesSearch(kw: String, limit: Int = 8): List<SongInfo> {
        val trimmed = kw.trim()
        if (trimmed.isEmpty()) return emptyList()
        val url = "https://itunes.apple.com/search?term=${enc(trimmed)}&media=music&entity=song&limit=$limit"
        val arr = getJSONArray(url) ?: return emptyList()
        return (0 until arr.length()).mapNotNull { i ->
            val r = arr.getJSONObject(i)
            val name = r.optString("trackName").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val cover = r.optString("artworkUrl100").takeIf { it.isNotEmpty() }?.replace("100x100", "600x600")
            SongInfo(
                title = name,
                artist = r.optString("artistName").takeIf { it.isNotEmpty() },
                album = r.optString("collectionName").takeIf { it.isNotEmpty() },
                coverURL = cover,
                neteaseID = null,
                duration = r.optLong("trackTimeMillis", 0).takeIf { it > 0 }?.let { it / 1000.0 },
                source = "iTunes",
            )
        }
    }

    private fun enc(s: String): String = java.net.URLEncoder.encode(s, "UTF-8")

    // ── 打分匹配（对齐 iOS score/bestMatch）──

    private fun score(candidate: SongInfo, title: String, artist: String?, artistHint: String? = null): Double {
        val tSim = TextMatch.similarity(title, candidate.title ?: "")
        if (tSim < 0.45) return tSim * 0.5

        val base: Double = if (!artist.isNullOrEmpty() && !candidate.artist.isNullOrEmpty()) {
            val aSim = candidate.artist!!.split('/', '、', ',', '&', ';', '；')
                .maxOf { TextMatch.similarity(artist, it.trim()) }
            tSim * 0.66 + aSim * 0.34
        } else {
            tSim * 0.9
        }

        var s = if (isAlternateVersion(candidate.title)) base * 0.94 else base

        if (!artistHint.isNullOrBlank() && !candidate.artist.isNullOrEmpty()) {
            val hSim = candidate.artist!!.split('/', '、', ',', '&', ';', '；')
                .maxOf { TextMatch.similarity(artistHint.trim(), it.trim()) }
            s = when {
                hSim >= 0.55 -> min(1.0, s + 0.06)
                hSim < 0.20 -> max(0.0, s - 0.12)
                else -> s
            }
        }
        return s
    }

    private fun isAlternateVersion(title: String?): Boolean {
        val lower = (title ?: "").lowercase()
        return listOf("live", "现场", "演唱会", "伴奏", "翻唱", "cover", "karaoke",
            "remix", "dj版", "网友自制", "翻自", "纯音乐", "instrumental").any { lower.contains(it) }
    }

    private fun pickBest(pool: List<SongInfo>, title: String, artist: String?, artistHint: String?): Match? {
        var best: Match? = null
        for (c in pool) {
            val s = score(c, title, artist, artistHint)
            if (s > (best?.score ?: 0.0)) best = Match(c, s)
        }
        return best
    }

    /// 统一入口：网易云 → QQ音乐 → iTunes 逐级兜底（对齐 iOS bestMatch）
    suspend fun bestMatch(title: String, artist: String?, artistHint: String? = null): Match? {
        val cleanTitle = title.trim()
        if (cleanTitle.isEmpty()) return null

        val kw = keyword(cleanTitle, artist)
        val plain = cleanTitle
        val hasArtist = !artist.isNullOrBlank() || !artistHint.isNullOrBlank()
        val threshold = if (hasArtist) 0.70 else 0.78

        var best = pickBest(neteaseSearch(kw, 10), cleanTitle, artist, artistHint)
        if ((best?.score ?: 0.0) < threshold && plain != kw) {
            val alt = pickBest(neteaseSearch(plain, 10), cleanTitle, artist, artistHint)
            if (alt != null && alt.score > (best?.score ?: 0.0)) best = alt
        }
        if ((best?.score ?: 0.0) < threshold) {
            var pool = qqSearch(kw, 10)
            if (pool.isEmpty() && plain != kw) pool += qqSearch(plain, 10)
            val alt = pickBest(pool, cleanTitle, artist, artistHint)
            if (alt != null && alt.score > (best?.score ?: 0.0)) best = alt
        }
        if ((best?.score ?: 0.0) < threshold) {
            val alt = pickBest(itunesSearch(kw, 8), cleanTitle, artist, artistHint)
            if (alt != null && alt.score > (best?.score ?: 0.0)) best = alt
        }

        var b = best ?: return null
        if (b.score < threshold) return null

        // 网易云命中但封面缺失时补详情
        val id = b.info.neteaseID
        if (id != null && b.info.coverURL.isNullOrEmpty()) {
            val detail = neteaseDetail(id)
            if (detail != null) {
                b = b.copy(info = b.info.copy(
                    coverURL = b.info.coverURL ?: detail.coverURL,
                    album = b.info.album ?: detail.album,
                    artist = b.info.artist ?: detail.artist,
                    duration = b.info.duration ?: detail.duration,
                ))
            }
        }
        return b
    }

    /// 手动匹配：多源候选按置信度排序
    suspend fun rankedCandidates(title: String, artist: String?): List<Pair<SongInfo, Double>> {
        val kw = keyword(title, artist)
        val plain = title.trim()
        if (kw.isEmpty()) return emptyList()
        val pool = coroutineScope {
            val n1 = async { neteaseSearch(kw, 12) }
            val n2 = if (plain != kw) async { neteaseSearch(plain, 12) } else async { emptyList() }
            val q = async { qqSearch(kw, 12) }
            val i = async { itunesSearch(kw, 8) }
            n1.await() + n2.await() + q.await() + i.await()
        }
        val seen = mutableSetOf<String>()
        return pool
            .filter { !it.title.isNullOrEmpty() }
            .filter { seen.add("${it.source}|${it.title}|${it.artist ?: ""}".lowercase()) }
            .map { it to score(it, title, artist, null) }
            .filter { it.second >= 0.30 }
            .sortedByDescending { it.second }
    }
}
