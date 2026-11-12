package com.gysbs.cloudtunes.player

import android.content.Context
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultMediaSourceFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.gysbs.cloudtunes.core.BaiduProvider
import com.gysbs.cloudtunes.core.CloudFile
import com.gysbs.cloudtunes.core.CloudKind
import com.gysbs.cloudtunes.core.GuangyaProvider
import com.gysbs.cloudtunes.core.LibraryStore
import com.gysbs.cloudtunes.core.LibraryTrack
import com.gysbs.cloudtunes.core.LyricLine
import com.gysbs.cloudtunes.core.Lyrics
import com.gysbs.cloudtunes.core.PlaybackSession
import com.gysbs.cloudtunes.core.QuarkProvider
import com.gysbs.cloudtunes.core.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant

/// 支持每条直链不同请求头的数据源工厂（夸克直链必须带 Cookie+Referer+UA 三件套）
class HeaderedDataSourceFactory : DataSource.Factory {
    @Volatile
    var headers: Map<String, String> = emptyMap()

    override fun createDataSource(): DataSource {
        val factory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(15000)
            .setReadTimeoutMs(20000)
        if (headers.isNotEmpty()) factory.setDefaultRequestProperties(headers)
        return factory.createDataSource()
    }
}

/// 播放中枢（对齐 iOS PlayerManager 的核心行为：队列/切歌/歌词/继续播放）
object PlayerManager {

    private lateinit var appContext: Context
    private val scope = CoroutineScope(Dispatchers.Main)

    var player: ExoPlayer? = null

    val queue = mutableStateListOf<Track>()
    var currentIndex = mutableIntStateOf(0)
    var isPlaying = mutableStateOf(false)
    var currentTime = mutableStateOf(0.0)
    var duration = mutableStateOf(0.0)
    var lyricLines = mutableStateOf<List<LyricLine>>(emptyList())
    var nowPlayingLineIndex = mutableIntStateOf(-1)
    var isLoading = mutableStateOf(false)
    var currentTrack: Track?
        get() = queue.getOrNull(currentIndex.value)
    var loadError = mutableStateOf<String?>(null)

    private var dataSourceFactory = HeaderedDataSourceFactory()
    private var lyricJob: Job? = null
    private var timePollJob: Job? = null
    private var consecutiveFailures = 0
    private var sessionPersistCounter = 0

    /// 由 PlaybackService.onCreate 调
    fun attach(context: Context) {
        if (player != null) return
        appContext = context.applicationContext
        val p = ExoPlayer.Builder(context)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
            .build()
        p.addListener(playerListener)
        player = p
    }

    private val playerListener = object : Player.Listener {
        override fun onIsPlayingChanged(playing: Boolean) {
            isPlaying.value = playing
            if (playing) startTimePoll() else stopTimePoll()
        }

        override fun onPlaybackStateChanged(state: Int) {
            if (state == Player.STATE_ENDED) {
                // 整张队列播完 → 回卷；否则自动下一首
                if (currentIndex.value >= queue.size - 1) rewindAfterFinish() else playNext(auto = true)
            }
            if (state == Player.STATE_READY) {
                consecutiveFailures = 0
                duration.value = (player?.duration ?: 0L) / 1000.0
                isLoading.value = false
            }
            if (state == Player.STATE_BUFFERING) isLoading.value = true
        }

        override fun onPlayerError(error: PlaybackException) {
            // 直链失败：连续自动切下一首（最多 5 首），避免整张列表被拒时卡死或死循环
            consecutiveFailures++
            loadError.value = "播放失败：${error.errorCodeName}"
            if (consecutiveFailures < 5 && queue.size > 1) {
                playNext(auto = true)
            } else {
                isLoading.value = false
                isPlaying.value = false
            }
        }
    }

    // ── 直链解析 ──

    private suspend fun resolveURL(track: Track): Pair<String, Map<String, String>> {
        val provider = when (track.providerKind) {
            CloudKind.GUANGYA -> GuangyaProvider
            CloudKind.BAIDU -> BaiduProvider
            CloudKind.QUARK -> QuarkProvider
        }
        val file = com.gysbs.cloudtunes.core.CloudFile(
            id = track.file.id,
            name = track.file.name,
            size = track.file.size,
            isFolder = false,
            extra = track.file.extra,
        )
        val (url, headers) = provider.streamURL(file)
        return url to headers
    }

    // ── 队列 ──

    /// 播放列表中第 index 首（UI 主入口）
    fun playAt(tracks: List<Track>, index: Int) {
        if (tracks.isEmpty()) return
        queue.clear()
        queue.addAll(tracks)
        currentIndex.value = index.coerceIn(0, tracks.size - 1)
        LibraryStore.recordRecent(tracks[currentIndex.value].id)
        scope.launch { prepareAndPlay(tracks[currentIndex.value]) }
    }

    /// 恢复上次会话（继续播放卡片）
    fun resumeSession(position: Double) {
        val s = LibraryStore.session.value ?: return
        queue.clear()
        queue.addAll(s.tracks)
        currentIndex.value = s.index.coerceIn(0, s.tracks.size - 1)
        scope.launch {
            prepareAndPlay(s.tracks[currentIndex.value], startAt = position)
        }
    }

    fun togglePlayPause() {
        val p = player ?: return
        if (queue.isEmpty()) {
            // 没有队列：尝试恢复会话
            LibraryStore.session.value?.let { resumeSession(it.position) }
            return
        }
        if (p.isPlaying) p.pause() else p.prepare(); p.play()
    }

    fun seekTo(seconds: Double) {
        player?.seekTo((seconds * 1000).toLong())
        currentTime.value = seconds
        updateLyricLine()
    }

    fun playNext(auto: Boolean = false) {
        if (queue.isEmpty()) return
        val next = currentIndex.value + 1
        if (next >= queue.size) {
            if (!auto) rewindAfterFinish()
            return
        }
        currentIndex.value = next
        LibraryStore.recordRecent(queue[next].id)
        scope.launch { prepareAndPlay(queue[next]) }
    }

    fun playPrev() {
        if (queue.isEmpty()) return
        val prev = if (currentTime.value > 3.0) currentIndex.value else (currentIndex.value - 1).coerceAtLeast(0)
        currentIndex.value = prev
        scope.launch { prepareAndPlay(queue[prev]) }
    }

    /// 整张列表自然放完：回到第一首、进度清零、暂停（对齐 iOS 行为）
    private fun rewindAfterFinish() {
        currentIndex.value = 0
        currentTime.value = 0.0
        duration.value = 0.0
        player?.pause()
        player?.seekTo(0)
        persistSession()
    }

    private suspend fun prepareAndPlay(track: Track, startAt: Double = 0.0) = withContext(Dispatchers.Main) {
        val p = player ?: return@withContext
        isLoading.value = true
        loadError.value = null
        currentTime.value = startAt
        duration.value = track.duration ?: 0.0
        updateLyricLine()

        try {
            val (url, headers) = resolveURL(track)
            dataSourceFactory.headers = headers
            val artwork = LibraryStore.findTrack(track.id)?.second?.artworkURL
                ?: track.artworkFile?.takeIf { it.startsWith("http") }
            val metadata = MediaMetadata.Builder()
                .setTitle(track.displayTitle)
                .setArtist(track.displayArtist)
                .setAlbumTitle(track.album)
                .apply { artwork?.let { setArtworkUri(it) } }
                .build()
            val item = MediaItem.Builder()
                .setUri(url)
                .setMediaId(track.id)
                .setMediaMetadata(metadata)
                .build()
            p.setMediaItem(item, (startAt * 1000).toLong())
            p.prepare()
            p.play()
            persistSession()
            fetchLyrics(track)
        } catch (e: Exception) {
            isLoading.value = false
            loadError.value = "取播放直链失败：${e.message}"
            consecutiveFailures++
            if (consecutiveFailures < 5 && queue.size > 1) playNext(auto = true)
        }
    }

    // ── 歌词 ──

    private fun fetchLyrics(track: Track) {
        lyricJob?.cancel()
        lyricLines.value = emptyList()
        nowPlayingLineIndex.value = -1
        val libTrack = LibraryStore.findTrack(track.id)?.second
        lyricJob = scope.launch {
            val lrc = try {
                Lyrics.fetch(libTrack ?: track.toLibraryLike())
            } catch (e: Exception) { null }
            if (currentTrack?.id == track.id) {
                lyricLines.value = lrc?.let { Lyrics.parse(it) } ?: emptyList()
            }
        }
    }

    private fun Track.toLibraryLike() = LibraryTrack(
        id = id, fileID = file.id, fileName = file.name,
        title = displayTitle, artist = artistOverride, album = album,
        neteaseID = neteaseID,
    )

    // ── 时间轮询（歌词高亮 + 进度条 + 定期存会话）──

    private fun startTimePoll() {
        if (timePollJob?.isActive == true) return
        timePollJob = scope.launch {
            while (true) {
                val p = player ?: break
                if (!p.isPlaying) break
                currentTime.value = p.currentPosition / 1000.0
                if (duration.value <= 0 && p.duration > 0) duration.value = p.duration / 1000.0
                updateLyricLine()
                // 播放中每 5 秒存一次继续播放
                if (++sessionPersistCounter % 5 == 0) persistSession()
                delay(500)
            }
        }
    }

    private fun stopTimePoll() {
        timePollJob?.cancel()
        timePollJob = null
        persistSession()
    }

    private fun updateLyricLine() {
        val lines = lyricLines.value
        if (lines.isEmpty()) { nowPlayingLineIndex.value = -1; return }
        val idx = Lyrics.activeIndex(lines, currentTime.value)
        nowPlayingLineIndex.value = idx ?: -1
    }

    // ── 继续播放持久化 ──

    fun persistSession() {
        if (queue.isEmpty()) return
        LibraryStore.session.value = PlaybackSession(
            tracks = queue.toList(),
            index = currentIndex.value,
            position = currentTime.value,
            updatedAt = Instant.now(),
        )
        LibraryStore.persistSession()
    }
}

/// 前台服务：锁屏/通知栏媒体控件
class PlaybackService : MediaSessionService() {

    private var mediaSession: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        PlayerManager.attach(this)
        mediaSession = MediaSession.Builder(this, PlayerManager.player!!).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = mediaSession

    override fun onTaskRemoved(rootIntent: android.content.Intent?) {
        val player = mediaSession?.player
        if (player == null || !player.playWhenReady || player.mediaItemCount == 0) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        mediaSession?.run {
            player.release()
            release()
        }
        mediaSession = null
        PlayerManager.player = null
        super.onDestroy()
    }
}
