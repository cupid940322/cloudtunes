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
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
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
/// 只用网易云 + 酷我会有硬伤：很多歌（周杰伦、五月天等）在这两家没有版权，
/// 查不到分就被当成 0 分垫底，可它们在全网其实很热。所以换成三个信号：
///
/// - 网易云 cloudsearch 的 `pop`（0~100 站内流行度）—— 有版权时最准
/// - 酷狗 `song_search_v2` 的 `OwnerCount`（加入歌单的用户数）—— 版权覆盖极广，一次请求即得
/// - **QQ 音乐热歌榜**（topId 26）—— 官方定义「按播放/下载/收藏综合热度排名前 300 首」，
///   整榜一次拉，补 QQ 独占版权的歌；榜外的歌不参与加权，不会拉低其它源
///
/// 酷我（PLAYCNT）已移除：实测它的搜索接口返回的几乎全是 KTV 伴奏、DJ 版、演唱会片段，
/// 连正版都匹配不到，数值又只有几十几百的量级，是纯噪声。
///
/// 综合分 = 三源各归一化到 0~1 后加权（网易云 0.35 / 酷狗 0.40 / QQ榜 0.25），
/// 分母按「实际拿到的源」重算，缺源不会把分数拉低；只有单源命中时整体乘 0.90。
/// 每首 2 个请求（QQ 榜整榜一次、摊到每首约等于 0），结果缓存 7 天，榜单缓存 12 小时。
object HotRanker {

    @Serializable
    data class Entry(
        val score: Double,
        val netease: Double? = null,
        val kugou: Double? = null,
        val qq: Double? = null,
        val at: Long = 0,
    )

    @Serializable
    private data class ChartDisk(
        val at: Long = 0,
        val total: Int = 0,
        val ranks: Map<String, Int> = emptyMap(),
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

    private val JSON_MEDIA = "application/json".toMediaType()

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    private val file get() = appContext.filesDir.resolve("hot-rank-v2.json")
    private val chartFile get() = appContext.filesDir.resolve("qq-chart.json")

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
            // QQ 热歌榜整榜一次拉（约 0.3 秒 / 300 首），所有歌共享这张表
            val chart = chartScores()
            var i = 0
            while (i < wanted.size && isActive) {
                val slice = wanted.subList(i, min(i + batchSize, wanted.size))
                val got = coroutineScope {
                    slice.map { (key, title, artist) ->
                        async { key to fetch(title, artist, chart) }
                    }.awaitAll()
                }
                if (!isActive) break
                val next = _entries.value.toMutableMap()
                for ((key, entry) in got) {
                    // 查不到也写 0 分：避免每次切排序都重试一遍
                    next[key] = entry ?: Entry(score = 0.0, at = System.currentTimeMillis())
                }
                _entries.value = next
                save()
                i += slice.size
                _progress.value = i to wanted.size
                delay(120)   // 让一下，别把几个平台打得太狠
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

    /// 一首歌的综合分。`chart` 是 QQ 热歌榜的「歌名|歌手 → 归一化分」查表
    private suspend fun fetch(
        title: String,
        artist: String,
        chart: Map<String, Double>,
    ): Entry? = coroutineScope {
        val n = async { neteaseScore(title, artist) }
        val g = async { kugouScore(title, artist) }
        val nv = n.await()
        val gv = g.await()
        val qv = chartScore(title, artist, chart)
        if (nv == null && gv == null && qv == null) return@coroutineScope null
        var num = 0.0
        var den = 0.0
        var hits = 0
        nv?.let { num += it * 0.35; den += 0.35; hits++ }
        gv?.let { num += it * 0.40; den += 0.40; hits++ }
        qv?.let { num += it * 0.25; den += 0.25; hits++ }
        var score = if (den > 0) num / den else 0.0
        // 单个源命中：证据不足，压一下，别让「只有网易云一个 pop=100」直接封顶
        if (hits == 1) score *= 0.90
        Entry(
            score = score,
            netease = nv,
            kugou = gv,
            qq = qv,
            at = System.currentTimeMillis(),
        )
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

    /// 酷狗：`OwnerCount`（把这首歌加进自己歌单的用户数）→ 对数归一，1 千万约等于 1.0。
    /// 酷狗版权覆盖极广，是「其它平台没版权」时最主要的兜底信号。
    private fun kugouScore(title: String, artist: String): Double? {
        val kw = if (artist.isEmpty()) title else "$title $artist"
        val url = "https://songsearch.kugou.com/song_search_v2?keyword=${enc(kw)}" +
            "&page=1&pagesize=8&platform=WebFilter&userid=-1&clientver=2000" +
            "&iscorrection=1&privilege_filter=0&filter=10"
        val text = getText(url, "https://www.kugou.com/") ?: return null
        val root = runCatching { JSONObject(text) }.getOrNull() ?: return null
        val lists = root.optJSONObject("data")?.optJSONArray("lists") ?: return null

        var bestSim = 0.0
        var bestOwner = 0.0
        for (i in 0 until lists.length()) {
            val s = lists.optJSONObject(i) ?: continue
            val sim = TextMatch.similarity(title, s.optString("SongName"))
            if (sim < 0.55) continue
            if (artist.isNotEmpty()) {
                val hit = splitArtists(s.optString("SingerName"))
                    .any { TextMatch.similarity(artist, it) >= 0.5 }
                if (!hit) continue
            }
            val owner = s.optDouble("OwnerCount", 0.0)
            if (owner <= 0) continue
            if (sim > bestSim) { bestSim = sim; bestOwner = owner }
        }
        if (bestSim <= 0) return null
        return min(1.0, log10(1 + bestOwner) / 7.0)
    }

    // MARK: QQ 音乐热歌榜

    @Volatile
    private var chartMemo: Map<String, Double>? = null

    /// QQ 音乐热歌榜（topId 26）：官方定义「按播放/下载/收藏综合热度排名前 300 首」。
    /// 整榜一次请求，缓存 12 小时；榜外的歌返回 nil，不参与加权。
    private fun chartScores(): Map<String, Double> {
        chartMemo?.let { return it }
        val disk = runCatching {
            if (chartFile.exists()) json.decodeFromString<ChartDisk>(chartFile.readText()) else null
        }.getOrNull()

        if (disk != null && disk.total > 0 &&
            System.currentTimeMillis() - disk.at < 12 * 3600_000L
        ) {
            val memo = expandChart(disk)
            chartMemo = memo
            return memo
        }

        val fresh = runCatching { requestChart() }.getOrNull()
        val use = fresh ?: disk
        if (use == null || use.total <= 0) return emptyMap()
        if (fresh != null) runCatching { chartFile.writeText(json.encodeToString(fresh)) }
        val memo = expandChart(use)
        chartMemo = memo
        return memo
    }

    private fun requestChart(): ChartDisk? {
        val body = JSONObject().apply {
            put("comm", JSONObject().put("ct", 24).put("cv", 0))
            put(
                "req",
                JSONObject()
                    .put("module", "musicToplist.ToplistInfoServer")
                    .put("method", "GetDetail")
                    .put("param", JSONObject().put("topId", 26).put("offset", 0)
                        .put("num", 300).put("period", "")),
            )
        }
        val req = Request.Builder()
            .url("https://u.y.qq.com/cgi-bin/musicu.fcg")
            .post(body.toString().toRequestBody(JSON_MEDIA))
            .header("Referer", "https://y.qq.com/")
            .header("User-Agent", UA)
            .build()
        val text = client.newCall(req).execute().use { r ->
            if (r.isSuccessful) r.body?.string() else null
        } ?: return null

        val level = runCatching {
            JSONObject(text).optJSONObject("req")?.optJSONObject("data")?.optJSONObject("data")
        }.getOrNull() ?: return null
        val songs = level.optJSONArray("song") ?: return null

        val ranks = HashMap<String, Int>()
        for (i in 0 until songs.length()) {
            val s = songs.optJSONObject(i) ?: continue
            val rank = s.optInt("rank", 0)
            if (rank <= 0) continue
            val name = s.optString("title")
            if (name.isEmpty()) continue
            val singers = splitArtists(s.optString("singerName"))
            if (singers.isEmpty()) {
                ranks[cacheKey(name, null)] = rank
            } else {
                for (a in singers) ranks[cacheKey(name, a)] = rank
            }
        }
        val total = max(level.optInt("totalNum", 0), songs.length())
        return ChartDisk(at = System.currentTimeMillis(), total = total, ranks = ranks)
    }

    /// 名次 → 0~1：第 1 名 1.0、第 300 名 0.35（能进日榜前 300 本身已是很强的热度信号）
    private fun expandChart(disk: ChartDisk): Map<String, Double> {
        if (disk.total <= 1) return emptyMap()
        val span = (disk.total - 1).toDouble()
        val out = HashMap<String, Double>(disk.ranks.size)
        for ((key, rank) in disk.ranks) {
            val p = (1.0 - (rank - 1) / span).coerceIn(0.0, 1.0)
            out[key] = 0.35 + 0.65 * p
        }
        return out
    }

    private fun chartScore(title: String, artist: String, chart: Map<String, Double>): Double? {
        if (chart.isEmpty()) return null
        chart[cacheKey(title, artist)]?.let { return it }
        for (a in splitArtists(artist)) chart[cacheKey(title, a)]?.let { return it }
        return null
    }

    /// 「许嵩、何曼婷」「mj apanay/aren park」这类多歌手串拆开
    private fun splitArtists(raw: String): List<String> =
        raw.split('、', '/', '／', '&', ',', '，', ';', '；', '+')
            .map { it.trim() }
            .filter { it.isNotEmpty() }

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

    private fun enc(s: String): String = java.net.URLEncoder.encode(s, "UTF-8")
}
