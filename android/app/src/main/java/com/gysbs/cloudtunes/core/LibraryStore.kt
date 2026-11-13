package com.gysbs.cloudtunes.core

import android.content.Context
import android.os.Build
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import java.time.Instant

/// 本地音乐库中枢（对齐 iOS LibraryStore 的数据与持久化结构）
object LibraryStore {

    private lateinit var appContext: Context

    val libraries = mutableStateListOf<MusicLibrary>()
    val favorites = mutableStateListOf<String>()
    val recent = mutableStateListOf<String>()
    /// 收藏的库 ID（本地偏好，不同步）等
    val deletedLibraries = mutableStateMapOf<String, Instant>()
    val deletedTracks = mutableStateMapOf<String, MutableMap<String, Instant>>()
    val session = mutableStateOf<PlaybackSession?>(null)
    val scanProgress = mutableStateOf<ScanProgress?>(null)

    private val prefs by lazy { appContext.getSharedPreferences("cloudtunes", Context.MODE_PRIVATE) }
    private val filesDir by lazy { appContext.filesDir }

    /// account 级数据（收藏 / 最近播放 / 会话）最后一次**真实改动**的时间。
    /// 以前 snapshot 里直接写 Instant.now()，等于每台设备每次同步都自称「刚刚改过」，
    /// 结果新设备拿空收藏把云端覆盖掉——iOS 有 25 首收藏、安卓这边一首不剩就是这么来的。
    private var localChangedAt: Instant = Instant.EPOCH

    private fun markLocalChanged(at: Instant = Instant.now()) {
        localChangedAt = at
        prefs.edit().putString("localChangedAt", at.toString()).apply()
    }

    fun init(context: Context) {
        appContext = context.applicationContext
        load()
    }

    // ── 持久化 ──

    private fun load() {
        try {
            val f = java.io.File(filesDir, "library.json")
            if (f.exists()) {
                val data = gistJson.decodeFromString<PersistedLibrary>(f.readText())
                libraries.clear()
                libraries.addAll(data.libraries)
                favorites.clear()
                favorites.addAll(data.favorites)
                recent.clear()
                recent.addAll(data.recent)
                deletedLibraries.clear()
                data.deletedLibraries.forEach { (k, v) -> deletedLibraries[k] = v }
                deletedTracks.clear()
                data.deletedTracks.forEach { (k, v) -> deletedTracks[k] = v.toMutableMap() }
            }
            val sf = java.io.File(filesDir, "playback-session.json")
            if (sf.exists()) {
                session.value = try {
                    gistJson.decodeFromString<PlaybackSession>(sf.readText())
                        .takeIf { it.tracks.isNotEmpty() && it.index < it.tracks.size }
                } catch (e: Exception) { null }
            }
            // 老版本没存过这个时间戳：退化成「各库最近修改时间」，避免凭空比云端新
            localChangedAt = prefs.getString("localChangedAt", null)
                ?.let { runCatching { Instant.parse(it) }.getOrNull() }
                ?: (libraries.mapNotNull { it.updatedAt ?: it.createdAt }.maxOrNull() ?: Instant.EPOCH)
        } catch (e: Exception) {
            android.util.Log.e("LibraryStore", "load failed", e)
        }
    }

    @Serializable
    private data class PersistedLibrary(
        val libraries: List<MusicLibrary> = emptyList(),
        val favorites: Set<String> = emptySet(),
        val recent: List<String> = emptyList(),
        @Serializable(with = ISODateMapSerializer::class) val deletedLibraries: Map<String, Instant> = emptyMap(),
        @Serializable(with = ISODateNestedMapSerializer::class) val deletedTracks: Map<String, Map<String, Instant>> = emptyMap(),
    )

    @Synchronized
    fun persist() = try {
        val data = PersistedLibrary(
            libraries = libraries.toList(),
            favorites = favorites.toSet(),
            recent = recent.toList(),
            deletedLibraries = deletedLibraries.toMap(),
            deletedTracks = deletedTracks.mapValues { it.value.toMap() },
        )
        java.io.File(filesDir, "library.json").writeText(gistJson.encodeToString(data))
        // 本地数据确实变了，记下时间；applySync 落完云端数据后会把它改回 merged.updatedAt
        markLocalChanged()
    } catch (e: Exception) {
        android.util.Log.e("LibraryStore", "persist failed", e)
    }

    @Synchronized
    fun persistSession() {
        try {
            val s = session.value ?: return
            val valid = s.tracks.isNotEmpty() && s.index < s.tracks.size
            val f = java.io.File(filesDir, "playback-session.json")
            if (valid) f.writeText(gistJson.encodeToString(s)) else f.delete()
        } catch (e: Exception) {
            android.util.Log.e("LibraryStore", "persistSession failed", e)
        }
    }

    // ── 查询 ──

    fun library(id: String): MusicLibrary? = libraries.firstOrNull { it.id == id }

    fun allTracks(): List<Pair<MusicLibrary, LibraryTrack>> =
        libraries.flatMap { lib -> lib.tracks.map { lib to it } }

    fun searchTracks(query: String): List<Pair<MusicLibrary, LibraryTrack>> {
        val q = query.trim()
        if (q.isEmpty()) return emptyList()
        return allTracks().filter { (_, t) ->
            t.title.contains(q, true) || (t.artist?.contains(q, true) == true) ||
                (t.album?.contains(q, true) == true) || t.fileName.contains(q, true)
        }
    }

    fun isFavorite(trackID: String): Boolean = trackID in favorites

    fun toggleFavorite(trackID: String) {
        if (trackID in favorites) favorites.remove(trackID) else favorites.add(trackID)
        persist()
        SyncService.scheduleSync("收藏变化")
    }

    fun recordRecent(trackID: String) {
        recent.removeAll { it == trackID }
        recent.add(0, trackID)
        while (recent.size > 100) recent.removeAt(recent.lastIndex)
        persist()
    }

    fun recentTracks(limit: Int = 30): List<Pair<MusicLibrary, LibraryTrack>> =
        recent.mapNotNull { id -> findTrack(id) }.take(limit)

    fun findTrack(trackID: String): Pair<MusicLibrary, LibraryTrack>? {
        val libID = trackID.substringBefore("·")
        // id 格式：库ID·曲目ID？不——iOS 里 TrackRef 由库上下文给出。
        // 这里直接全库找（几千首的量级全扫足够快）
        for (lib in libraries) {
            val t = lib.tracks.firstOrNull { it.id == trackID }
            if (t != null) return lib to t
        }
        return null
    }

    // ── 库管理 ──

    fun libraryExists(kind: CloudKind, folderID: String): Boolean =
        libraries.any { it.providerKind == kind && it.folderID == folderID }

    fun createLibrary(kind: CloudKind, folder: CloudFile, name: String, includeSubfolders: Boolean): MusicLibrary {
        val lib = MusicLibrary(
            id = java.util.UUID.randomUUID().toString(),
            name = name.ifEmpty { folder.name.ifEmpty { kind.label } },
            providerKindRaw = kind.label,
            folderID = folder.id,
            folderName = folder.name,
            includeSubfolders = includeSubfolders,
            createdAt = Instant.now(),
            updatedAt = Instant.now(),
        )
        libraries.add(lib)
        persist()
        return lib
    }

    fun renameLibrary(id: String, name: String) {
        val idx = libraries.indexOfFirst { it.id == id }
        if (idx >= 0) {
            libraries[idx] = libraries[idx].copy(name = name, updatedAt = Instant.now())
            persist()
        }
    }

    fun deleteLibrary(id: String) {
        val lib = library(id) ?: return
        libraries.removeAll { it.id == id }
        // 曲目墓碑：整库删除时对曲目也记墓碑，防止同步复活
        val marks = mutableMapOf<String, Instant>()
        val now = Instant.now()
        for (t in lib.tracks) marks[t.id] = now
        val existing = deletedTracks[id] ?: mutableMapOf()
        for ((tid, at) in marks) existing[tid] = at
        deletedTracks[id] = existing
        deletedLibraries[id] = now
        // 清理收藏与最近播放
        favorites.removeAll(lib.tracks.map { it.id }.toSet())
        recent.removeAll(lib.tracks.map { it.id }.toSet())
        persist()
    }

    fun deleteTrack(libraryID: String, trackID: String) {
        val idx = libraries.indexOfFirst { it.id == libraryID }
        if (idx < 0) return
        val lib = libraries[idx]
        libraries[idx] = lib.copy(tracks = lib.tracks.filterNot { it.id == trackID },
            updatedAt = Instant.now())
        deletedTracks.getOrPut(libraryID) { mutableMapOf() }[trackID] = Instant.now()
        favorites.remove(trackID)
        recent.removeAll { it == trackID }
        persist()
    }

    // ── 扫描 + 刮削 ──

    private fun providerOf(kind: CloudKind): CloudProvider = when (kind) {
        CloudKind.GUANGYA -> GuangyaProvider
        CloudKind.BAIDU -> BaiduProvider
        CloudKind.QUARK -> QuarkProvider
    }

    /// 递归收集音频文件（includeSubfolders 控制深度）
    private data class AudioHit(val file: CloudFile, val parentID: String, val parentName: String, val folderPath: List<String>)

    private suspend fun collectAudio(provider: CloudProvider, folderID: String, includeSubfolders: Boolean): List<AudioHit> {
        val result = mutableListOf<AudioHit>()
        suspend fun walk(folder: CloudFile, path: List<String>, depth: Int) {
            scanProgress.value?.let {
                it.scannedFolders++
                scanProgress.value = it.copy(phase = "扫描目录：${folder.name}")
            }
            val files = try {
                provider.list(folder.id)
            } catch (e: Exception) {
                scanProgress.value?.let { it.failed++; scanProgress.value = it }
                return
            }
            for (f in files) {
                if (f.isFolder) {
                    if (includeSubfolders && depth < 6) walk(f, path + f.name, depth + 1)
                } else if (Scanner.isAudioFile(f.name)) {
                    result += AudioHit(f, folder.id, folder.name, path)
                }
            }
        }
        walk(CloudFile(id = folderID, name = "", isFolder = true), emptyList(), 0)
        return result
    }

    /// 重新扫描 + 刮削一个库（阻塞式，返回新增数量）
    suspend fun rescanLibrary(libraryID: String, scrape: Boolean = true): Int = withContext(Dispatchers.IO) {
        val lib = library(libraryID) ?: return@withContext 0
        val kind = lib.providerKind
        scanProgress.value = ScanProgress()
        val audio = collectAudio(providerOf(kind), lib.folderID, lib.includeSubfolders ?: true)
        scanProgress.value?.let { it.foundTracks = audio.size; scanProgress.value = it }

        val existing = lib.tracks.associateBy { it.id }.toMutableMap()
        val fresh = mutableListOf<LibraryTrack>()
        var added = 0
        for (hit in audio) {
            val file = hit.file
            val id = "${kind.label}-${file.id}"
            if (existing.containsKey(id)) continue
            val parsed = Scanner.parse(file.name)
            // 从目录结构推断歌手：「周杰伦/范特西/晴天.flac」→ 周杰伦
            val artistHint = hit.folderPath.firstOrNull { it.isNotBlank() }
            fresh += LibraryTrack(
                id = id,
                fileID = file.id,
                fileName = file.name,
                size = file.size,
                parentID = hit.parentID,
                title = parsed.title.ifEmpty { file.name.substringBeforeLast('.') },
                artist = parsed.artist ?: artistHint,
                scraped = false,
                addedAt = Instant.now(),
                parentName = hit.parentName,
                folderPath = hit.folderPath.ifEmpty { null },
            )
            existing[id] = fresh.last()
            added++
        }
        scanProgress.value?.let { it.totalToScrape = fresh.size; scanProgress.value = it.copy(phase = "刮削元数据…") }

        val updated = existing.values.toMutableList()
        if (scrape) {
            for (t in fresh) {
                val m = try {
                    Scraper.bestMatch(t.title, t.artist, t.folderPath?.firstOrNull())
                } catch (e: Exception) { null }
                val idx = updated.indexOfFirst { it.id == t.id }
                if (idx >= 0) {
                    updated[idx] = if (m != null) {
                        scanProgress.value?.let { it.scrapedTracks++; scanProgress.value = it }
                        updated[idx].copy(
                            title = m.info.title ?: updated[idx].title,
                            artist = m.info.artist ?: updated[idx].artist,
                            album = m.info.album,
                            duration = m.info.duration,
                            neteaseID = m.info.neteaseID,
                            artworkURL = m.info.coverURL,
                            confidence = m.score,
                            metaSource = "online",
                            scraped = true,
                        )
                    } else {
                        updated[idx].copy(metaSource = "filename", scraped = true, confidence = null)
                    }
                }
                delay(300) // 刮削限速
            }
        } else {
            for (t in fresh) {
                val idx = updated.indexOfFirst { it.id == t.id }
                if (idx >= 0) updated[idx] = updated[idx].copy(metaSource = "filename", scraped = true)
            }
        }

        val libIdx = libraries.indexOfFirst { it.id == libraryID }
        if (libIdx >= 0) {
            libraries[libIdx] = libraries[libIdx].copy(
                tracks = updated,
                lastScanAt = Instant.now(),
                updatedAt = Instant.now(),
            )
        }
        scanProgress.value?.let { it.phase = "完成"; scanProgress.value = it }
        persist()
        SyncService.scheduleSync("扫描完成")
        scanProgress.value = null
        added
    }

    /// 单曲重新刮削
    suspend fun rescrapeTrack(libraryID: String, trackID: String, candidate: Scraper.SongInfo? = null): Boolean {
        val lib = library(libraryID) ?: return false
        val idx = lib.tracks.indexOfFirst { it.id == trackID }
        if (idx < 0) return false
        val t = lib.tracks[idx]
        val m = candidate?.let { Scraper.Match(it, 1.0) }
            ?: Scraper.bestMatch(t.title, t.artist, t.folderPath?.firstOrNull())
            ?: return false
        val updated = t.copy(
            title = m.info.title ?: t.title,
            artist = m.info.artist ?: t.artist,
            album = m.info.album,
            duration = m.info.duration,
            neteaseID = m.info.neteaseID,
            artworkURL = m.info.coverURL,
            confidence = m.score,
            metaSource = "online",
            scraped = true,
            updatedAt = Instant.now(),
        )
        val libIdx = libraries.indexOfFirst { it.id == libraryID }
        libraries[libIdx] = lib.copy(tracks = lib.tracks.toMutableList().also { it[idx] = updated },
            updatedAt = Instant.now())
        persist()
        SyncService.scheduleSync("重新刮削")
        return true
    }

    /// 手动匹配歌词：把用户从搜索结果里选中的网易云歌曲 ID 写回曲目。
    /// 只改 neteaseID（不动标题/歌手等元数据），下次取歌词会直接用这个 ID。
    fun setTrackNeteaseID(libraryID: String, trackID: String, neteaseID: Int): Boolean {
        val lib = library(libraryID) ?: return false
        val idx = lib.tracks.indexOfFirst { it.id == trackID }
        if (idx < 0 || neteaseID <= 0) return false
        val updated = lib.tracks[idx].copy(
            neteaseID = neteaseID,
            confidence = 1.0,
            scraped = true,
            updatedAt = Instant.now(),
        )
        val libIdx = libraries.indexOfFirst { it.id == libraryID }
        libraries[libIdx] = lib.copy(tracks = lib.tracks.toMutableList().also { it[idx] = updated },
            updatedAt = Instant.now())
        persist()
        SyncService.scheduleSync("手动匹配歌词")
        return true
    }

    // ── 同步 ──

    fun syncSnapshot(deviceName: String = Build.MODEL ?: "Android"): SyncAccount {
        // account.updatedAt 必须是「本机数据真实最后改动时间」，不能是 now()，
        // 否则这台设备每次都会在 LWW 里赢，把另一台设备的收藏/最近播放覆盖掉。
        val newestLibrary = libraries.mapNotNull { it.updatedAt ?: it.createdAt }.maxOrNull() ?: Instant.EPOCH
        return SyncAccount(
            schemaVersion = 1,
            updatedAt = maxOf(newestLibrary, localChangedAt),
            deviceName = deviceName,
            libraries = libraries.map {
                LibraryMeta(
                    id = it.id,
                    name = it.name,
                    providerKindRaw = it.providerKindRaw,
                    folderID = it.folderID,
                    folderName = it.folderName,
                    includeSubfolders = it.includeSubfolders ?: true,
                    createdAt = it.createdAt,
                    lastScanAt = it.lastScanAt,
                    updatedAt = it.updatedAt ?: it.createdAt,
                )
            },
            favorites = favorites.toList(),
            recent = recent.toList(),
            session = session.value,
            deletedLibraries = deletedLibraries.toMap(),
            deletedTracks = deletedTracks.mapValues { it.value.toMap() },
        )
    }

    fun applySync(
        newLibraries: List<MusicLibrary>,
        newFavorites: Set<String>,
        newRecent: List<String>,
        newSession: PlaybackSession?,
        newDeletedLibraries: Map<String, Instant>,
        newDeletedTracks: Map<String, Map<String, Instant>>,
        /// 合并结果的时间戳：落盘后本机就算「和云端一样新」，不要伪装成刚改过
        mergedUpdatedAt: Instant = Instant.EPOCH,
    ) {
        libraries.clear()
        libraries.addAll(newLibraries)
        favorites.clear()
        favorites.addAll(newFavorites)
        recent.clear()
        recent.addAll(newRecent)
        deletedLibraries.clear()
        newDeletedLibraries.forEach { (k, v) -> deletedLibraries[k] = v }
        deletedTracks.clear()
        newDeletedTracks.forEach { (k, v) -> deletedTracks[k] = v.toMutableMap() }
        newSession?.let { session.value = it }
        persist()
        persistSession()
        // persist() 会把 localChangedAt 顶成 now()，这里改回合入结果的时间，
        // 让「刚同步完」的设备在下一轮 LWW 里不会凭空虚赢
        if (mergedUpdatedAt > Instant.EPOCH) markLocalChanged(mergedUpdatedAt)
    }
}

// mutableStateSetOf 由 androidx.compose.runtime 提供

private fun CloudFile.providerKind(): CloudKind {
    // 从库上下文调用时其实不需要这个；walk 用的根节点没有 kind，靠外部闭包
    return CloudKind.GUANGYA
}
