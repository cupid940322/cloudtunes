package com.gysbs.cloudtunes.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.time.Duration

/// 多源歌词检索（对齐 iOS LyricsSources：网易云 / QQ音乐 / 酷狗 / LRCLIB）。
/// 网易云的搜索在 Scraper.neteaseSearch，这里只补另外三源 + 四源并发合并。
object LyricSources {

    private const val UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

    /// 一个歌词候选；取正文的方式由来源决定（neteaseID / qqMid / kugou id+key / 内联文本）
    data class Candidate(
        val source: String,          // 网易云 / QQ音乐 / 酷狗 / LRCLIB
        val title: String,
        val artist: String,
        val album: String?,
        val neteaseID: Int? = null,
        val qqMid: String? = null,
        val kugouId: String? = null,
        val kugouKey: String? = null,
        val inlineText: String? = null,   // LRCLIB 搜索阶段就带正文（synced ?: plain）
        val knownSynced: Boolean? = null, // 仅 LRCLIB 在搜索阶段能确定
    )

    private val sourceOrder = listOf("网易云", "QQ音乐", "酷狗", "LRCLIB")

    // ── HTTP 帮手（独立于 Scraper，避免碰它的 private）──

    private suspend fun httpJson(url: String, referer: String?, timeoutSec: Long = 8): JSONObject? =
        withContext(Dispatchers.IO) {
            try {
                val client = OkHttpClient.Builder()
                    .connectTimeout(Duration.ofSeconds(timeoutSec))
                    .readTimeout(Duration.ofSeconds(timeoutSec)).build()
                val req = Request.Builder().url(url)
                    .header("User-Agent", UA)
                    .apply { referer?.let { header("Referer", it) } }
                    .get().build()
                client.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) return@withContext null
                    JSONObject(resp.body?.string() ?: return@withContext null)
                }
            } catch (e: Exception) {
                null
            }
        }

    private suspend fun httpJsonArray(url: String, timeoutSec: Long = 8): org.json.JSONArray? =
        withContext(Dispatchers.IO) {
            try {
                val client = OkHttpClient.Builder()
                    .connectTimeout(Duration.ofSeconds(timeoutSec))
                    .readTimeout(Duration.ofSeconds(timeoutSec)).build()
                val req = Request.Builder().url(url).header("User-Agent", UA).get().build()
                client.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) return@withContext null
                    org.json.JSONArray(resp.body?.string() ?: return@withContext null)
                }
            } catch (e: Exception) {
                null
            }
        }

    private fun enc(s: String): String = java.net.URLEncoder.encode(s, "UTF-8")

    // ── QQ 音乐 ──

    /// QQ 音乐搜索（拿 songmid，取歌词要用它）
    suspend fun qqSearch(keyword: String, limit: Int = 8): List<Candidate> {
        val kw = keyword.trim()
        if (kw.isEmpty()) return emptyList()
        val url = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=$limit" +
            "&w=${enc(kw)}&format=json&cr=1&new_json=1"
        val obj = withTimeoutOrNull(8000) { httpJson(url, referer = "https://y.qq.com/") }
            ?: return emptyList()
        val list = obj.optJSONObject("data")?.optJSONObject("song")?.optJSONArray("list")
            ?: return emptyList()
        return (0 until list.length()).mapNotNull { i ->
            val it = list.getJSONObject(i)
            val mid = it.optString("mid", "").ifBlank { it.optString("songmid", "") }
            if (mid.isEmpty()) return@mapNotNull null
            val title = it.optString("title", "").ifBlank { it.optString("songname", "") }
            val singers = it.optJSONArray("singer")
            var artist = ""
            if (singers != null) {
                artist = (0 until singers.length()).mapNotNull { j ->
                    singers.optJSONObject(j)?.optString("name")
                }.joinToString("、")
            }
            Candidate(
                source = "QQ音乐",
                title = title,
                artist = artist,
                album = it.optJSONObject("album")?.optString("name"),
                qqMid = mid,
            )
        }
    }

    /// QQ 音乐歌词（nobase64=1 返回 HTML 转义的 LRC；个别返回 base64，兜底解码）
    suspend fun qqLyric(songmid: String): String? {
        val url = "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg" +
            "?songmid=${enc(songmid)}&format=json&nobase64=1&g_tk=5381&loginUin=0&hostUin=0" +
            "&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0"
        val obj = withTimeoutOrNull(8000) { httpJson(url, referer = "https://y.qq.com/portal/player.html") }
            ?: return null
        val raw = obj.optString("lyric", "")
        if (raw.isEmpty()) return null
        val text = if (raw.contains("[")) {
            decodeEntities(raw)
        } else {
            runCatching {
                String(android.util.Base64.decode(raw, android.util.Base64.DEFAULT), Charsets.UTF_8)
            }.getOrDefault(decodeEntities(raw))
        }.trim()
        return text.ifEmpty { null }
    }

    // ── 酷狗 ──

    suspend fun kugouSearch(keyword: String): List<Candidate> {
        val kw = keyword.trim()
        if (kw.isEmpty()) return emptyList()
        val url = "https://krcs.kugou.com/search?ver=1&man=yes&client=mobi&keyword=${enc(kw)}&duration=&hash="
        val obj = withTimeoutOrNull(8000) { httpJson(url, referer = null) } ?: return emptyList()
        val list = obj.optJSONArray("candidates") ?: return emptyList()
        return (0 until list.length()).take(8).mapNotNull { i ->
            val it = list.optJSONObject(i) ?: return@mapNotNull null
            val id = it.optString("id", "")
            val key = it.optString("accesskey", "")
            if (id.isEmpty() || key.isEmpty()) return@mapNotNull null
            Candidate(
                source = "酷狗",
                title = it.optString("song", ""),
                artist = it.optString("singer", ""),
                album = null,
                kugouId = id,
                kugouKey = key,
            )
        }
    }

    suspend fun kugouLyric(id: String, accessKey: String): String? {
        val url = "https://lyrics.kugou.com/download?ver=1&client=pc&id=${enc(id)}" +
            "&accesskey=${enc(accessKey)}&fmt=lrc&charset=utf8"
        val obj = withTimeoutOrNull(8000) { httpJson(url, referer = null) } ?: return null
        val b64 = obj.optString("content", "")
        if (b64.isEmpty()) return null
        val text = runCatching {
            String(android.util.Base64.decode(b64, android.util.Base64.DEFAULT), Charsets.UTF_8)
        }.getOrNull() ?: return null
        return text.trim().ifEmpty { null }
    }

    // ── LRCLIB ──

    suspend fun lrclibSearch(title: String, artist: String?): List<Candidate> {
        if (title.isBlank()) return emptyList()
        var url = "https://lrclib.net/api/search?track_name=${enc(title.trim())}"
        if (!artist.isNullOrBlank()) url += "&artist_name=${enc(artist.trim())}"
        val arr = withTimeoutOrNull(8000) { httpJsonArray(url) } ?: return emptyList()
        return (0 until arr.length()).take(15).mapNotNull { i ->
            val it = arr.optJSONObject(i) ?: return@mapNotNull null
            val synced = it.optString("syncedLyrics", "")
            val plain = it.optString("plainLyrics", "")
            Candidate(
                source = "LRCLIB",
                title = it.optString("trackName", ""),
                artist = it.optString("artistName", ""),
                album = null,
                inlineText = synced.ifBlank { plain.ifBlank { null } },
                knownSynced = synced.isNotEmpty(),
            )
        }
    }

    // ── 四源并发合并（手动搜索弹窗用；总超时兜底防某个源卡死拖住整个列表）──

    suspend fun searchAll(query: String, timeoutMs: Long = 8000): List<Candidate> {
        val q = query.trim()
        if (q.isEmpty()) return emptyList()
        return withTimeoutOrNull(timeoutMs) {
            coroutineScope {
                val netease = async { runCatching { Scraper.neteaseSearch(q, limit = 8) }.getOrDefault(emptyList()) }
                val qq = async { runCatching { qqSearch(q, limit = 8) }.getOrDefault(emptyList()) }
                val kugou = async { runCatching { kugouSearch(q) }.getOrDefault(emptyList()) }
                val lrclib = async { runCatching { lrclibSearch(q, null) }.getOrDefault(emptyList()) }
                val merged = netease.await() + qq.await() + kugou.await() + lrclib.await()
                merged.sortedBy { sourceOrder.indexOf(it.source).let { o -> if (o < 0) 99 else o } }
            }
        } ?: emptyList()
    }

    /// 取某个候选的歌词正文（LRC 或纯文本）
    suspend fun textFor(c: Candidate): String? = withTimeoutOrNull(10000) {
        when {
            c.neteaseID != null && c.neteaseID > 0 ->
                runCatching { Scraper.neteaseLyrics(c.neteaseID) }.getOrNull()
            c.qqMid != null -> qqLyric(c.qqMid)
            c.kugouId != null && c.kugouKey != null -> kugouLyric(c.kugouId, c.kugouKey)
            else -> c.inlineText
        }
    }

    // ── 工具 ──

    /// QQ 接口返回的 LRC 是 HTML 转义过的（&#10; 换行、&#58; 冒号等）
    fun decodeEntities(input: String): String {
        var s = input
        val map = mapOf(
            "&#10;" to "\n", "&#13;" to "", "&#58;" to ":", "&#46;" to ".",
            "&#32;" to " ", "&#39;" to "'", "&#40;" to "(", "&#41;" to ")",
            "&quot;" to "\"", "&apos;" to "'", "&lt;" to "<", "&gt;" to ">", "&amp;" to "&",
        )
        for ((k, v) in map) s = s.replace(k, v)
        return s
    }
}
