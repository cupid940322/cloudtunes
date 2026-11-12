package com.gysbs.cloudtunes.core

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

/// GitHub 账号（token 存本地，verify 用 /user）
object GitHubAccount {
    var token: String
        get() = CredentialStore.get("github.token") ?: ""
        set(v) = CredentialStore.set(v, "github.token")

    var cachedLogin: String?
        get() = CredentialStore.get("github.login")
        set(v) = CredentialStore.set(v, "github.login")

    val isSignedIn: Boolean get() = token.isNotEmpty()

    fun signOut() {
        CredentialStore.remove("github.token")
        CredentialStore.remove("github.login")
    }

    class AuthException(msg: String) : Exception(msg)

    suspend fun verify(t: String): String = withContext(Dispatchers.IO) {
        val req = Request.Builder().url("https://api.github.com/user")
            .header("Authorization", "Bearer $t")
            .header("Accept", "application/vnd.github+json")
            .get().build()
        Http.client.newCall(req).execute().use { resp ->
            if (resp.code == 401) throw AuthException("令牌无效")
            if (!resp.isSuccessful) throw AuthException("GitHub 返回 HTTP ${resp.code}")
            JSONObject(resp.body?.string() ?: "").optString("login").takeIf { it.isNotEmpty() }
                ?: throw AuthException("无法获取用户名")
        }
    }
}

/// 跨设备同步：Gist（account.json + library-<id>.json，LWW + 墓碑）
/// 协议与 iOS 端 SyncService 完全一致，三端互通。
object SyncService {

    sealed class Status {
        data object Idle : Status()
        data class Syncing(val reason: String) : Status()
        data class Done(val tracks: Int, val at: Instant) : Status()
        data class Failed(val message: String) : Status()

        val isRunning: Boolean get() = this is Syncing
    }

    val status = kotlinx.coroutines.flow.MutableStateFlow<Status>(Status.Idle)

    var gistID: String? = null
    var lastTrackCount = 0
    var lastSyncAt: Instant? = null

    private const val ACCOUNT_FILE = "account.json"
    private const val SYNC_DESCRIPTION = "cloudtunes-sync"
    private const val GIST_KEY = "sync.gistID"
    private const val LAST_SYNC_KEY = "sync.lastAt"
    private const val LAST_COUNT_KEY = "sync.lastCount"

    private lateinit var prefs: android.content.SharedPreferences

    fun init(context: Context) {
        prefs = context.getSharedPreferences("cloudtunes.sync", Context.MODE_PRIVATE)
        gistID = prefs.getString(GIST_KEY, null)
        lastSyncAt = prefs.getString(LAST_SYNC_KEY, null)?.let {
            try { Instant.parse(it) } catch (e: Exception) { null }
        }
        lastTrackCount = prefs.getInt(LAST_COUNT_KEY, 0)
    }

    fun signIn(tok: String): String {
        val cleaned = tok.trim()
        if (cleaned.isEmpty()) throw GitHubAccount.AuthException("令牌为空")
        val login = kotlinx.coroutines.runBlocking { GitHubAccount.verify(cleaned) }
        GitHubAccount.token = cleaned
        GitHubAccount.cachedLogin = login
        return login
    }

    fun signOut() {
        GitHubAccount.signOut()
        prefs.edit().clear().apply()
        gistID = null
        lastSyncAt = null
        lastTrackCount = 0
        status.value = Status.Idle
    }

    fun resetRemoteLink() {
        prefs.edit().remove(GIST_KEY).apply()
        gistID = null
    }

    // ── 触发 ──

    private var running = false
    private var pending = false
    private var debounceJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.Main)

    /// 改动后调这个：5 秒内多次改动只同步一次
    fun scheduleSync(reason: String = "自动同步") {
        if (!GitHubAccount.isSignedIn) return
        debounceJob?.cancel()
        debounceJob = scope.launch {
            delay(5000)
            sync(reason)
        }
    }

    /// 冷启动/回到前台：距上次同步不到 2 分钟就跳过
    suspend fun syncIfStale(minIntervalSec: Long = 120) {
        if (!GitHubAccount.isSignedIn) return
        val last = lastSyncAt ?: return sync("自动同步")
        if (System.currentTimeMillis() / 1000 - last.epochSecond < minIntervalSec) return
        sync("自动同步")
    }

    suspend fun sync(reason: String = "手动同步") {
        val tok = GitHubAccount.token
        if (!GitHubAccount.isSignedIn || tok.isEmpty()) return
        if (running) { pending = true; return }
        running = true
        try {
            status.value = Status.Syncing(reason)
            val count = performSync(tok)
            lastTrackCount = count
            lastSyncAt = Instant.now()
            prefs.edit().putString(LAST_SYNC_KEY, lastSyncAt!!.toString()).putInt(LAST_COUNT_KEY, count).apply()
            status.value = Status.Done(count, Instant.now())
        } catch (e: Exception) {
            status.value = Status.Failed(e.message ?: e.toString())
        } finally {
            running = false
        }
        if (pending) {
            pending = false
            sync("补同步")
        }
    }

    // ── 主流程 ──

    private fun libraryFile(id: String): String {
        val safe = id.replace("/", "_").replace(" ", "_")
        return "library-$safe.json"
    }

    private suspend fun performSync(token: String): Int {
        val gid = ensureGist(token)
        gistID = gid
        prefs.edit().putString(GIST_KEY, gid).apply()

        // 1. 拉云端
        val remoteFiles = fetchFiles(gid, token)
        val remoteAccount = decodeAccount(remoteFiles[ACCOUNT_FILE])

        // 2. 本地快照
        val localAccount = LibraryStore.syncSnapshot()

        // 3. account 级合并
        val merged = mergeAccount(localAccount, remoteAccount)

        // 4. 逐库合并曲目
        val libraryPayloads = mutableMapOf<String, String>()
        val mergedLibraries = mutableListOf<MusicLibrary>()
        var totalTracks = 0

        for (meta in merged.libraries) {
            val localLib = LibraryStore.library(meta.id)
            val remoteLib = decodeLibrary(remoteFiles[libraryFile(meta.id)])
            val tombstones = merged.deletedTracks[meta.id] ?: emptyMap()

            val tracks = mergeTracks(localLib?.tracks ?: emptyList(), remoteLib?.tracks ?: emptyList(), tombstones)
            totalTracks += tracks.count

            val lib = MusicLibrary(
                id = meta.id,
                name = meta.name,
                providerKindRaw = meta.providerKindRaw,
                folderID = meta.folderID,
                folderName = meta.folderName,
                tracks = tracks,
                createdAt = meta.createdAt,
                lastScanAt = meta.lastScanAt,
                includeSubfolders = meta.includeSubfolders,
                updatedAt = meta.updatedAt,
            )
            // 本地没有这个库时（新设备）：沿用云端时间戳，避免覆盖云端曲目
            val libOut = if (localLib == null) lib.copy(updatedAt = remoteLib?.updatedAt ?: meta.updatedAt) else lib
            mergedLibraries += libOut

            // 只有合并结果和云端不一样时才上传
            val remoteTracks = remoteLib?.tracks ?: emptyList()
            if (needsUpload(remoteTracks, tracks)) {
                libraryPayloads[libraryFile(meta.id)] =
                    gistJson.encodeToString(SyncLibraryFile(meta.id, Instant.now(), tracks))
            }
        }

        // 5. 落到本地
        LibraryStore.applySync(
            newLibraries = mergedLibraries,
            newFavorites = merged.favorites.toSet(),
            newRecent = merged.recent,
            newSession = merged.session,
            newDeletedLibraries = merged.deletedLibraries,
            newDeletedTracks = merged.deletedTracks,
        )

        // 6. 上传 account.json（没实质变化就跳过，Gist 会留版本历史）
        val filesToPush = HashMap(libraryPayloads)
        if (accountNeedsUpload(remoteAccount, merged)) {
            filesToPush[ACCOUNT_FILE] = gistJson.encodeToString(merged)
        }

        if (filesToPush.isNotEmpty()) patchFiles(gid, token, filesToPush)
        return totalTracks
    }

    private fun decodeAccount(text: String?): SyncAccount =
        text?.let { runCatching { gistJson.decodeFromString<SyncAccount>(it) }.getOrNull() } ?: SyncAccount()

    private fun decodeLibrary(text: String?): SyncLibraryFile? =
        text?.let { runCatching { gistJson.decodeFromString<SyncLibraryFile>(it) }.getOrNull() }

    private fun needsUpload(remote: List<LibraryTrack>, merged: List<LibraryTrack>): Boolean {
        if (remote.size != merged.size) return true
        val remoteMap = remote.associateBy { it.id }
        for (t in merged) {
            val r = remoteMap[t.id] ?: return true
            if (r.updatedAt != t.updatedAt) return true
            if (r.title != t.title || r.artist != t.artist || r.artworkURL != t.artworkURL) return true
        }
        return false
    }

    private fun accountNeedsUpload(remote: SyncAccount, merged: SyncAccount): Boolean {
        if (remote.libraries.size != merged.libraries.size) return true
        val remoteMap = remote.libraries.associateBy { it.id }
        for (m in merged.libraries) {
            val r = remoteMap[m.id] ?: return true
            if (r.name != m.name || r.folderID != m.folderID || r.updatedAt != m.updatedAt) return true
        }
        if (remote.favorites.toSet() != merged.favorites.toSet()) return true
        if (remote.recent != merged.recent) return true
        if (remote.session?.updatedAt != merged.session?.updatedAt) return true
        if (remote.deletedLibraries != merged.deletedLibraries) return true
        if (remote.deletedTracks != merged.deletedTracks) return true
        return false
    }

    // ── 合并（对齐 iOS）──

    fun mergeAccount(local: SyncAccount, remote: SyncAccount): SyncAccount {
        val remoteIsNewer = remote.updatedAt > local.updatedAt

        val libMap = LinkedHashMap<String, LibraryMeta>()
        for (m in remote.libraries) libMap[m.id] = m
        for (m in local.libraries) {
            val r = libMap[m.id]
            if (r != null) {
                if (m.updatedAt >= r.updatedAt) libMap[m.id] = m
            } else libMap[m.id] = m
        }
        // 墓碑：删除时间晚于该库最后修改时间才算真的删了
        val deletedLibs = LinkedHashMap<String, Instant>()
        local.deletedLibraries.forEach { (k, v) -> deletedLibs.merge(k, v, ::minOf) }
        remote.deletedLibraries.forEach { (k, v) -> deletedLibs.merge(k, v, ::minOf) }
        for ((id, at) in deletedLibs) {
            val m = libMap[id]
            if (m != null && at > m.updatedAt) libMap.remove(id)
        }

        val favorites = if (remoteIsNewer) remote.favorites else local.favorites
        val recent = if (remoteIsNewer) remote.recent else local.recent

        val session = when {
            local.session != null && remote.session != null ->
                if (local.session.updatedAt >= remote.session.updatedAt) local.session else remote.session
            local.session != null -> local.session
            else -> remote.session
        }

        return SyncAccount(
            schemaVersion = 1,
            updatedAt = maxOf(local.updatedAt, remote.updatedAt),
            deviceName = local.deviceName,
            libraries = libMap.values.sortedBy { it.createdAt },
            favorites = favorites,
            recent = recent,
            session = session,
            deletedLibraries = deletedLibs,
            deletedTracks = mergeTombstoneMaps(local.deletedTracks, remote.deletedTracks),
        )
    }

    private fun mergeTombstoneMaps(
        a: Map<String, Map<String, Instant>>,
        b: Map<String, Map<String, Instant>>,
    ): Map<String, Map<String, Instant>> {
        val out = HashMap(a)
        for ((libID, marks) in b) {
            val existing = out[libID]?.toMutableMap() ?: mutableMapOf()
            for ((tid, at) in marks) existing[tid] = minOf(existing[tid] ?: at, at)
            out[libID] = existing
        }
        return out
    }

    fun mergeTracks(local: List<LibraryTrack>, remote: List<LibraryTrack>, tombstones: Map<String, Instant>): List<LibraryTrack> {
        val map = LinkedHashMap<String, LibraryTrack>()
        for (t in remote) map[t.id] = t
        for (t in local) {
            val r = map[t.id]
            if (r != null) {
                if ((t.updatedAt ?: Instant.EPOCH) >= (r.updatedAt ?: Instant.EPOCH)) map[t.id] = t
            } else map[t.id] = t
        }
        for ((id, at) in tombstones) {
            val t = map[id]
            if (t != null && at > (t.updatedAt ?: Instant.EPOCH)) map.remove(id)
        }
        return map.values.sortedBy { it.addedAt ?: Instant.EPOCH }
    }

    // ── GitHub Gist API ──

    private fun request(url: String, token: String, method: String = "GET", body: String? = null): Request {
        val builder = Request.Builder().url(url)
            .header("Authorization", "Bearer $token")
            .header("Accept", "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28")
        when (method) {
            "GET" -> builder.get()
            "PATCH" -> builder.patch(body!!.toRequestBody("application/json".toMediaType()))
            "POST" -> builder.post(body!!.toRequestBody("application/json".toMediaType()))
        }
        return builder.build()
    }

    private suspend fun send(req: Request): Pair<String, Int> = withContext(Dispatchers.IO) {
        val resp = Http.client.newCall(req).execute()
        val text = resp.body?.string() ?: ""
        val code = resp.code
        resp.close()
        if (code == 401) throw Exception("令牌已失效，请到账号页重新登录")
        if (code == 403) throw Exception("GitHub 拒绝了请求（403），可能是令牌权限不足或请求过于频繁")
        if (code !in 200..299) throw Exception("GitHub 返回 HTTP $code")
        text to code
    }

    private suspend fun ensureGist(token: String): String {
        val cached = gistID
        if (!cached.isNullOrEmpty()) {
            val ok = runCatching {
                val (text, _) = send(request("https://api.github.com/gists/$cached", token))
                JSONObject(text).has("id")
            }.getOrDefault(false)
            if (ok) return cached
            resetRemoteLink()
        }

        for (page in 1..3) {
            val (text, _) = send(request("https://api.github.com/gists?per_page=100&page=$page", token))
            val arr = JSONArray(text)
            for (i in 0 until arr.length()) {
                val g = arr.getJSONObject(i)
                if (g.optString("description") == SYNC_DESCRIPTION) {
                    val id = g.getString("id")
                    prefs.edit().putString(GIST_KEY, id).apply()
                    return id
                }
            }
            if (arr.length() < 100) break
        }

        // 没有就建一个私有的
        val body = JSONObject()
            .put("description", SYNC_DESCRIPTION)
            .put("public", false)
            .put("files", JSONObject().put(ACCOUNT_FILE, JSONObject().put("content", "{}")))
        val (resp, _) = send(request("https://api.github.com/gists", token, "POST", body.toString()))
        val id = JSONObject(resp).optString("id").takeIf { it.isNotEmpty() }
            ?: throw Exception("创建同步空间失败")
        prefs.edit().putString(GIST_KEY, id).apply()
        return id
    }

    private suspend fun fetchFiles(gistID: String, token: String): Map<String, String> {
        val (text, _) = try {
            send(request("https://api.github.com/gists/$gistID", token))
        } catch (e: Exception) {
            return emptyMap()
        }
        val payload = JSONObject(text)
        val files = payload.optJSONObject("files") ?: return emptyMap()
        val out = mutableMapOf<String, String>()
        val keys = files.keys()
        while (keys.hasNext()) {
            val name = keys.next()
            val f = files.getJSONObject(name)
            if (!f.optBoolean("truncated", false)) {
                out[name] = f.optString("content")
            } else {
                // 超 1MB 的内容 API 给 truncated，走 raw_url 拉全量
                val raw = f.optString("raw_url")
                if (raw.isNotEmpty()) {
                    runCatching { out[name] = send(request(raw, token)).first }
                }
            }
        }
        return out
    }

    private suspend fun patchFiles(gistID: String, token: String, files: Map<String, String>) {
        val payload = JSONObject()
        for ((name, content) in files) payload.put(name, JSONObject().put("content", content))
        send(request("https://api.github.com/gists/$gistID", token, "PATCH", JSONObject().put("files", payload).toString()))
    }
}
