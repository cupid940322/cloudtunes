package com.gysbs.cloudtunes.core

import android.content.Context
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min

/// 歌曲列表排序方式（与 iOS 的 TrackSortMode 一一对应）
enum class TrackSortMode(val label: String) {
    SOURCE("默认顺序"),
    TITLE("按歌名"),
    ARTIST("按歌手"),
    HOT("按综合热度"),
}

/// 综合热度：各平台**公开的热度指标**归一化后加权。
///
/// 数据来源（实测过，别的源拿不到数）：
/// - 网易云 cloudsearch 的 `pop`（0~100 流行度）
/// - 酷我 search/r.s 的 `PLAYCNT`（播放量）
/// - QQ 音乐、酷狗的搜索接口不返回任何数值型热度，只能再发一次详情，暂不接入
///
/// 综合分 = 两源各归一化到 0~1 后加权（网易云 0.65 / 酷我 0.35），
/// 按「实际拿到的源」重新归一分母，缺一个源不会把分数拉低。
/// 每首 2 个请求，结果缓存 7 天；缓存命中后排序是纯本地计算。
object HotRanker {

    @Serializable
    data class Entry(
        val score: Double,
        val netease: Double? = null,
        val kuwo: Double? = null,
        val at: Long = 0,
    )

    private lateinit var appContext: Context
    private val json = Json { ignoreUnknownKeys = true }
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(12, TimeUnit.SECONDS)
        .build()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null
    private var loaded = false

    private val _entries = mutableStateOf<Map<String, Entry>>(emptyMap())
    val entries: State<Map<String, Entry>> = _entries
    private val _ranking = mutableStateOf(false)
    val ranking: State<Boolean> = _ranking
    private val _progress = mutableStateOf(0 to 0)
    val progress: State<Pair<Int, Int>> = _progress

    private val ttlMs = 7L * 24 * 3600 * 1000
    private val batchSize = 6

    private const val UA =
        "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/120.0.0.0 Mobile Safari/537.36"

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    private val file get() = appContext.filesDir.resolve("hot-rank.json")

    private fun loadIfNeeded() {
        if (loaded) return
        loaded = true
        runCatching {
            if (file.exists()) {
                _entries.value = json.decodeFromString<Map<String, Entry>>(file.readText())
            }
        }
    }

    private fun save() {
        runCatching { file.writeText(json.encodeToString(_entries.value)) }
    }

    private fun fresh(e: Entry) = System.currentTimeMillis() - e.at < ttlMs

    /// 缓存 key：歌名 + 歌手同样归一化，让「晴天 (Live)」也能命中「晴天」
    fun cacheKey(title: String, artist: String?): String =
        "${TextMatch.normalize(title)}|${TextMatch.normalize(artist ?: "")}"

    fun score(title: String, artist: String?): Double? {
        loadIfNeeded()
        val e = _entries.value[cacheKey(title, artist)] ?: return null
        return if (fresh(e)) e.score else null
    }

    fun score(track: LibraryTrack): Double? = score(track.title, track.artist)

    /// 还有多少首没算过热
    fun missingCount(tracks: List<LibraryTrack>): Int {
        loadIfNeeded()
        val seen = HashSet<String>()
        var n = 0
        for (t in tracks) {
            val key = cacheKey(t.title, t.artist)
            if (!seen.add(key)) continue
            val e = _entries.value[key]
            if (e != null && fresh(e)) continue
            n++
        }
        return n
    }

    // MARK: 排序

    fun sorted(tracks: List<LibraryTrack>, mode: TrackSortMode): List<LibraryTrack> {
        if (mode == TrackSortMode.SOURCE) return tracks
        loadIfNeeded()
        return when (mode) {
            TrackSortMode.TITLE -> tracks.sortedBy { it.title.lowercase() }
            TrackSortMode.ARTIST -> tracks.sortedWith(
                compareBy({ it.displayArtist.lowercase() }, { it.title.lowercase() })
            )
            TrackSortMode.HOT -> tracks.sortedWith { a, b ->
                val sa = score(a)
                val sb = score(b)
                when {
                    sa != null && sb != null ->
                        if (abs(sa - sb) > 0.0005) sb.compareTo(sa) else a.title.compareTo(b.title)
                    sa != null -> -1          // 有分的排前面
                    sb != null -> 1
                    else -> a.title.compareTo(b.title)
                }
            }
            else -> tracks
        }
    }

    fun <T> sortedBy(items: List<T>, mode: TrackSortMode, track: (T) -> LibraryTrack): List<T> {
        if (mode == TrackSortMode.SOURCE) return items
        val order = sorted(items.map(track), mode)
        val pos = HashMap<String, Int>(order.size)
        order.forEachIndexed { i, t -> pos[t.id] = i }
        return items.sortedBy { pos[track(it).id] ?: Int.MAX_VALUE }
    }

    // MARK: 批量补齐

    fun prefetch(tracks: List<LibraryTrack>, mode: TrackSortMode) {
        if (mode != TrackSortMode.HOT) return
        loadIfNeeded()
        job?.cancel()

        val seen = HashSet<String>()
        val wanted = ArrayList<Triple<String, String, String>>()
        for (t in tracks) {
            val key = cacheKey(t.title, t.artist)
            if (!seen.add(key)) continue
            val e = _entries.value[key]
            if (e != null && fresh(e)) continue
            wanted.add(Triple(key, t.title, t.artist ?: ""))
        }
        if (wanted.isEmpty()) {
            _ranking.value = false
            _progress.value = 0 to 0
            return
        }

        _ranking.value = true
        _progress.value = 0 to wanted.size

        job = scope.launch {
            var i = 0
            while (i < wanted.size && isActive) {
                val slice = wanted.subList(i, min(i + batchSize, wanted.size))
                val got = coroutineScope {
                    slice.map { (key, title, artist) ->
                        async { key to fetch(title, artist) }
                    }.awaitAll()
                }
                if (!isActive) break
                val next = _entries.value.toMutableMap()
                for ((key, entry) in got) {
                    // 查不到也写 0 分：避免每次切排序都重试一遍
                    next[key] = entry ?: Entry(0.0, null, null, System.currentTimeMillis())
                }
                _entries.value = next
                save()
                i += slice.size
                _progress.value = i to wanted.size
                delay(120)   // 让一下，别把两个平台打得太狠
            }
            _ranking.value = false
            save()
        }
    }

    fun cancelPrefetch() {
        job?.cancel()
        job = null
        _ranking.value = false
    }

    // MARK: 网络

    private suspend fun fetch(title: String, artist: String): Entry? = coroutineScope {
        val n = async { neteaseScore(title, artist) }
        val k = async { kuwoScore(title, artist) }
        val nv = n.await()
        val kv = k.await()
        if (nv == null && kv == null) return@coroutineScope null
        var num = 0.0
        var den = 0.0
        nv?.let { num += it * 0.65; den += 0.65 }
        kv?.let { num += it * 0.35; den += 0.35 }
        Entry(if (den > 0) num / den else 0.0, nv, kv, System.currentTimeMillis())
    }

    private fun getText(url: String, referer: String): String? = runCatching {
        val req = Request.Builder()
            .url(url)
            .header("Referer", referer)
            .header("User-Agent", UA)
            .build()
        client.newCall(req).execute().use { r ->
            if (r.isSuccessful) r.body?.string() else null
        }
    }.getOrNull()

    /// 网易云：pop 0~100 → 0~1
    private fun neteaseScore(title: String, artist: String): Double? {
        val kw = if (artist.isEmpty()) title else "$title $artist"
        val url = "https://music.163.com/api/cloudsearch/pc" +
            "?s=${enc(kw)}&type=1&limit=6&offset=0"
        val text = getText(url, "https://music.163.com/") ?: return null
        val root = runCatching { JSONObject(text) }.getOrNull() ?: return null
        val songs = root.optJSONObject("result")?.optJSONArray("songs") ?: return null

        var bestSim = 0.0
        var bestPop = 0.0
        for (i in 0 until songs.length()) {
            val s = songs.optJSONObject(i) ?: continue
            val name = s.optString("name")
            val sim = TextMatch.similarity(title, name)
            if (sim < 0.55) continue
            if (artist.isNotEmpty()) {
                val ars = s.optJSONArray("ar")
                var hit = false
                if (ars != null) {
                    for (j in 0 until ars.length()) {
                        val n = ars.optJSONObject(j)?.optString("name") ?: continue
                        if (TextMatch.similarity(artist, n) >= 0.5) { hit = true; break }
                    }
                }
                if (!hit) continue
            }
            val pop = s.optDouble("pop", 0.0)
            if (sim > bestSim) { bestSim = sim; bestPop = pop }
        }
        if (bestSim <= 0) return null
        return min(1.0, max(0.0, bestPop / 100.0))
    }

    /// 酷我：PLAYCNT 播放量 → 对数归一（1 万次播放≈1.0）
    private fun kuwoScore(title: String, artist: String): Double? {
        val kw = if (artist.isEmpty()) title else "$title $artist"
        val url = "https://search.kuwo.cn/r.s?all=${enc(kw)}&ft=music&itemset=web_2013" +
            "&client=kt&pn=0&rn=8&rformat=json&encoding=utf8"
        val text = getText(url, "https://www.kuwo.cn/") ?: return null

        var bestSim = 0.0
        var bestPlay = 0.0
        for (item in kuwoItems(text)) {
            val sim = TextMatch.similarity(title, item.name)
            if (sim < 0.55) continue
            if (artist.isNotEmpty() && TextMatch.similarity(artist, item.artist) < 0.5) continue
            val play = item.play.toDoubleOrNull() ?: continue
            if (sim > bestSim) { bestSim = sim; bestPlay = play }
        }
        if (bestSim <= 0) return null
        return min(1.0, log10(1 + bestPlay) / 4.0)
    }

    private data class KuwoItem(val name: String, val artist: String, val play: String)

    /// 酷我返回的是**单引号 JSON**（不是合法 JSON），还夹着 `&nbsp;`、`\u0026`，
    /// 不能用 JSONObject。这里按 {...} 平衡切出每首歌，再按 'KEY':'value' 取字段。
    private fun kuwoItems(text: String): List<KuwoItem> {
        val head = text.indexOf("'abslist':[")
        if (head < 0) return emptyList()
        val out = ArrayList<KuwoItem>()
        var depth = 0
        var start = -1
        var i = head + "'abslist':[".length
        while (i < text.length) {
            when (text[i]) {
                '{' -> { if (depth == 0) start = i; depth++ }
                '}' -> {
                    depth--
                    if (depth == 0 && start >= 0) {
                        val obj = text.substring(start, i + 1)
                        out.add(KuwoItem(
                            name = kuwoField(obj, "SONGNAME"),
                            artist = kuwoField(obj, "ARTIST"),
                            play = kuwoField(obj, "PLAYCNT"),
                        ))
                        start = -1
                    }
                }
            }
            i++
        }
        return out
    }

    private fun kuwoField(obj: String, key: String): String {
        val marker = "'$key':'"
        val at = obj.indexOf(marker)
        if (at < 0) return ""
        val from = at + marker.length
        val end = obj.indexOf('\'', from)
        if (end < 0) return ""
        return obj.substring(from, end)
            .replace("&nbsp;", " ")
            .replace("\\u0026", "&")
            .replace("\\/", "/")
            .trim()
    }

    private fun enc(s: String): String = java.net.URLEncoder.encode(s, "UTF-8")
}
