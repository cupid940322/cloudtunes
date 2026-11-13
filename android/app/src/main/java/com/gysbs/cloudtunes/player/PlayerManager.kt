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
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import android.net.Uri
import com.gysbs.cloudtunes.core.BaiduProvider
import com.gysbs.cloudtunes.core.CloudFile
import com.gysbs.cloudtunes.core.CloudKind
import com.gysbs.cloudtunes.core.CrashLog
import com.gysbs.cloudtunes.core.GuangyaProvider
import com.gysbs.cloudtunes.core.LibraryStore
import com.gysbs.cloudtunes.core.LibraryTrack
import com.gysbs.cloudtunes.core.LyricLine
import com.gysbs.cloudtunes.core.Lyrics
import com.gysbs.cloudtunes.core.PlaybackSession
import com.gysbs.cloudtunes.core.QuarkProvider
import com.gysbs.cloudtunes.core.Track
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
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

/// 播放模式：顺序循环 / 单曲循环 / 随机播放
enum class PlayMode { SEQUENTIAL, REPEAT_ONE, SHUFFLE }

/// 播放中枢（对齐 iOS PlayerManager 的核心行为：队列/切歌/歌词/继续播放）
object PlayerManager {

    private lateinit var appContext: Context

    /// 播放协程域：SupervisorJob 保证一次失败不会连坐整个域，异常统一进崩溃日志而不是闪退
    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.Main + CoroutineExceptionHandler { _, t ->
            CrashLog.record("播放协程", t)
        }
    )

    var player: ExoPlayer? = null

    val queue = mutableStateListOf<Track>()
    var currentIndex = mutableIntStateOf(0)
    var isPlaying = mutableStateOf(false)
    var currentTime = mutableStateOf(0.0)
    var duration = mutableStateOf(0.0)
    var lyricLines = mutableStateOf<List<LyricLine>>(emptyList())
    var nowPlayingLineIndex = mutableIntStateOf(-1)
    var isLoading = mutableStateOf(false)
    val currentTrack: Track?
        get() = queue.getOrNull(currentIndex.value)
    var loadError = mutableStateOf<String?>(null)

    /// 播放模式（持久化；手机版和 TV 版共用同一套逻辑）
    var playMode = mutableStateOf(PlayMode.SEQUENTIAL)
        private set
    private val modePrefs: android.content.SharedPreferences? by lazy {
        if (::appContext.isInitialized)
            appContext.getSharedPreferences("cloudtunes.player", android.content.Context.MODE_PRIVATE)
        else null
    }
    /// 随机模式下的回退历史（「上一首」回到刚才随机跳过的歌）
    private val shuffleHistory = mutableListOf<Int>()

    private var dataSourceFactory = HeaderedDataSourceFactory()
    private var lyricJob: Job? = null
    private var timePollJob: Job? = null
    private var consecutiveFailures = 0
    private var sessionPersistCounter = 0

    /// 由 PlaybackService.onCreate 调；也作为播放前的兜底（服务被杀后自动重建）
    fun attach(context: Context) {
        if (player != null) return
        appContext = context.applicationContext
        try {
            val p = ExoPlayer.Builder(appContext)
                .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
                .build()
            // WAKE_MODE_NETWORK 需要 android.permission.WAKE_LOCK。
            // 个别 ROM 会拒绝，抛 SecurityException 就直接放弃唤醒锁，不影响播放本身。
            try {
                p.setWakeMode(androidx.media3.common.C.WAKE_MODE_NETWORK)
            } catch (t: Throwable) {
                CrashLog.record("setWakeMode（WAKE_LOCK 权限缺失？）", t)
            }
            // 音频焦点 + 媒体用途：锁屏/通知栏媒体卡片、与其他 App 抢焦点时自动暂停都依赖这个
            try {
                p.setAudioAttributes(
                    androidx.media3.common.AudioAttributes.Builder()
                        .setUsage(androidx.media3.common.C.USAGE_MEDIA)
                        .setContentType(androidx.media3.common.C.AUDIO_CONTENT_TYPE_MUSIC)
                        .build(),
                    true,
                )
            } catch (t: Throwable) {
                CrashLog.record("setAudioAttributes", t)
            }
            p.addListener(playerListener)
            // 恢复上次的播放模式
            playMode.value = modePrefs?.getString("mode", null)?.let { saved ->
                runCatching { PlayMode.valueOf(saved) }.getOrNull()
            } ?: PlayMode.SEQUENTIAL
            applyExoRepeatMode(p)
            player = p
        } catch (t: Throwable) {
            CrashLog.record("创建 ExoPlayer 失败", t)
        }
    }

    /// 拿播放器；为空时尝试重建（例如前台服务被系统回收过）
    private fun ensurePlayer(): ExoPlayer? {
        if (player == null && ::appContext.isInitialized) attach(appContext)
        return player
    }

    // ── 播放模式 ──

    /// 顺序循环 → 单曲循环 → 随机播放 → 顺序循环
    fun cyclePlayMode() {
        val next = when (playMode.value) {
            PlayMode.SEQUENTIAL -> PlayMode.REPEAT_ONE
            PlayMode.REPEAT_ONE -> PlayMode.SHUFFLE
            PlayMode.SHUFFLE -> PlayMode.SEQUENTIAL
        }
        playMode.value = next
        modePrefs?.edit()?.putString("mode", next.name)?.apply()
        shuffleHistory.clear()
        applyExoRepeatMode(player)
    }

    /// 单曲循环交给 ExoPlayer 的 repeatMode 原生实现（无缝循环，且 STATE_ENDED 不会触发）
    private fun applyExoRepeatMode(p: ExoPlayer?) {
        try {
            p?.repeatMode = if (playMode.value == PlayMode.REPEAT_ONE)
                Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
        } catch (t: Throwable) {
            CrashLog.record("设置播放模式", t)
        }
    }

    private val playerListener = object : Player.Listener {
        override fun onIsPlayingChanged(playing: Boolean) {
            isPlaying.value = playing
            if (playing) startTimePoll() else stopTimePoll()
        }

        override fun onPlaybackStateChanged(state: Int) {
            if (state == Player.STATE_ENDED) {
                // 单曲循环由 ExoPlayer repeatMode 处理，不会走到这里；
                // 随机模式播完就继续随机下一首，顺序模式播完整张队列回卷
                if (playMode.value == PlayMode.SHUFFLE) {
                    playNext(auto = true)
                } else if (currentIndex.value >= queue.size - 1) {
                    rewindAfterFinish()
                } else {
                    playNext(auto = true)
                }
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
        shuffleHistory.clear()
        currentIndex.value = index.coerceIn(0, tracks.size - 1)
        LibraryStore.recordRecent(tracks[currentIndex.value].id)
        scope.launch { prepareAndPlay(tracks[currentIndex.value]) }
    }

    /// 恢复上次会话（继续播放卡片）
    fun resumeSession(position: Double) {
        val s = LibraryStore.session.value ?: return
        queue.clear()
        queue.addAll(s.tracks)
        shuffleHistory.clear()
        currentIndex.value = s.index.coerceIn(0, s.tracks.size - 1)
        scope.launch {
            prepareAndPlay(s.tracks[currentIndex.value], startAt = position)
        }
    }

    fun togglePlayPause() {
        if (queue.isEmpty()) {
            // 没有队列：尝试恢复会话
            LibraryStore.session.value?.let { resumeSession(it.position) }
            return
        }
        val p = ensurePlayer() ?: return
        try {
            if (p.isPlaying) p.pause() else { p.prepare(); p.play() }
        } catch (t: Throwable) {
            CrashLog.record("切换播放/暂停", t)
        }
    }

    fun seekTo(seconds: Double) {
        try {
            ensurePlayer()?.seekTo((seconds * 1000).toLong())
        } catch (t: Throwable) {
            CrashLog.record("seek", t)
        }
        currentTime.value = seconds
        updateLyricLine()
    }

    fun playNext(auto: Boolean = false) {
        if (queue.isEmpty()) return
        val next = when {
            playMode.value == PlayMode.SHUFFLE && queue.size > 1 -> {
                // 随机：记住当前首（供「上一首」回退），挑一个不是当前首的
                shuffleHistory.add(currentIndex.value)
                var r = currentIndex.value
                while (r == currentIndex.value) r = kotlin.random.Random.nextInt(queue.size)
                r
            }
            else -> currentIndex.value + 1
        }
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
        val prev = when {
            currentTime.value > 3.0 -> currentIndex.value
            playMode.value == PlayMode.SHUFFLE && shuffleHistory.isNotEmpty() ->
                shuffleHistory.removeAt(shuffleHistory.lastIndex).coerceIn(0, queue.size - 1)
            else -> (currentIndex.value - 1).coerceAtLeast(0)
        }
        currentIndex.value = prev
        scope.launch { prepareAndPlay(queue[prev]) }
    }

    /// 整张列表自然放完：回到第一首、进度清零、暂停（对齐 iOS 行为）
    private fun rewindAfterFinish() {
        currentIndex.value = 0
        currentTime.value = 0.0
        duration.value = 0.0
        try {
            player?.pause()
            player?.seekTo(0)
        } catch (t: Throwable) {
            CrashLog.record("列表播完回卷", t)
        }
        persistSession()
    }

    private suspend fun prepareAndPlay(track: Track, startAt: Double = 0.0) {
        isLoading.value = true
        loadError.value = null
        currentTime.value = startAt
        duration.value = track.duration ?: 0.0
        updateLyricLine()

        // ① 取直链：一定放在 IO 线程（网盘接口是阻塞的），失败只降级不闪退
        val resolved = try {
            withContext(Dispatchers.IO) { resolveURL(track) }
        } catch (t: Throwable) {
            CrashLog.record("解析播放直链失败 ${track.displayTitle}", t)
            null
        }
        if (resolved == null) {
            onPlayFailed("取播放直链失败，换下一首试试")
            return
        }

        // ② 交给 ExoPlayer：同样全程兜底
        withContext(Dispatchers.Main) {
            try {
                val p = ensurePlayer() ?: run {
                    onPlayFailed("播放器未就绪，请退出重进")
                    return@withContext
                }
                val (url, headers) = resolved
                dataSourceFactory.headers = headers
                val artwork = LibraryStore.findTrack(track.id)?.second?.artworkURL
                    ?: track.artworkFile?.takeIf { it.startsWith("http") }
                val metadata = MediaMetadata.Builder()
                    .setTitle(track.displayTitle)
                    .setArtist(track.displayArtist)
                    .setAlbumTitle(track.album)
                    .apply { artwork?.let { runCatching { setArtworkUri(Uri.parse(it)) } } }
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
            } catch (t: Throwable) {
                CrashLog.record("启动播放失败 ${track.displayTitle}", t)
                onPlayFailed("播放失败：${t.message ?: t.javaClass.simpleName}")
            }
        }
    }

    private fun onPlayFailed(message: String) {
        isLoading.value = false
        isPlaying.value = false
        loadError.value = message
        consecutiveFailures++
        if (consecutiveFailures < 5 && queue.size > 1) playNext(auto = true)
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

    /// 手动匹配歌词后重新拉取当前曲目的歌词（UI 从歌词搜索弹窗调用）。
    fun refetchLyrics() {
        currentTrack?.let { fetchLyrics(it) }
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
        try {
            PlayerManager.attach(this)
            val p = PlayerManager.player
            if (p != null) {
                // 点锁屏/通知栏的媒体卡片直接回到 App
                val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                val activityPi = launchIntent?.let {
                    android.app.PendingIntent.getActivity(
                        this, 0, it,
                        android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE,
                    )
                }
                val builder = MediaSession.Builder(this, p)
                activityPi?.let { builder.setSessionActivity(it) }
                mediaSession = builder.build()
            }
        } catch (t: Throwable) {
            // 媒体会话建不起来只是没有通知栏控件，绝不能让 App 起不来
            CrashLog.record("PlaybackService 初始化", t)
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = mediaSession

    override fun onTaskRemoved(rootIntent: android.content.Intent?) {
        try {
            val player = mediaSession?.player
            if (player == null || !player.playWhenReady || player.mediaItemCount == 0) {
                stopSelf()
            }
        } catch (t: Throwable) {
            CrashLog.record("onTaskRemoved", t)
        }
    }

    override fun onDestroy() {
        try {
            mediaSession?.release()
        } catch (t: Throwable) {
            CrashLog.record("释放媒体会话", t)
        }
        mediaSession = null
        // 注意：不 release ExoPlayer、也不把 PlayerManager.player 置空。
        // 服务被系统回收时界面还在用播放器，置空会让「继续播放」变成点了没反应。
        super.onDestroy()
    }
}
