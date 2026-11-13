package com.gysbs.cloudtunes.tv

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.RepeatOne
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.outlined.Favorite
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import com.gysbs.cloudtunes.core.LibraryStore
import com.gysbs.cloudtunes.core.LyricSources
import com.gysbs.cloudtunes.core.LyricsCache
import com.gysbs.cloudtunes.player.PlayMode
import com.gysbs.cloudtunes.core.SyncService
import com.gysbs.cloudtunes.player.PlaybackService
import com.gysbs.cloudtunes.player.PlayerManager
import com.gysbs.cloudtunes.ui.FavoritesTab
import com.gysbs.cloudtunes.ui.LibraryDetailScreen
import com.gysbs.cloudtunes.ui.PlayerDock
import com.gysbs.cloudtunes.ui.ProfileTab
import com.gysbs.cloudtunes.ui.SearchTab
import com.gysbs.cloudtunes.ui.SyncStatusLine
import com.gysbs.cloudtunes.ui.LyricsSearchDialog
import com.gysbs.cloudtunes.ui.formatDuration
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private val TVBackground = Color(0xFF0E0F16)
private val TVSurface = Color(0xFF1A1C28)
private val TVAccent = Color(0xFF7C8CFF)

class TVMainActivity : ComponentActivity() {

    private val notifPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33) {
            notifPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        // 预启动播放服务（注册媒体会话）；个别 ROM 拒绝时不影响界面
        try {
            startService(android.content.Intent(this, PlaybackService::class.java))
        } catch (t: Throwable) {
            com.gysbs.cloudtunes.core.CrashLog.record("TV 启动播放服务", t)
        }
        setContent { TVApp() }
    }
}

/// 遥控器焦点高亮：聚焦放大 + 描边
private fun Modifier.tvFocusable(interaction: MutableInteractionSource, onClick: () -> Unit): Modifier =
    composed {
        val focused by interaction.collectIsFocusedAsState()
        this
            .focusable(interactionSource = interaction)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            .scale(if (focused) 1.04f else 1f)
    }

@Composable
fun TVApp() {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = TVAccent,
            background = TVBackground,
            surface = TVSurface,
        )
    ) {
        val tabs = listOf("乐库", "搜索", "收藏", "我的")
        var tab by remember { mutableStateOf(0) }
        var openLibraryID by remember { mutableStateOf<String?>(null) }
        var showPlayer by remember { mutableStateOf(false) }

        LaunchedEffect(Unit) { SyncService.syncIfStale() }
        // 启动静默检查更新（24 小时内只查一次）
        val ctx = androidx.compose.ui.platform.LocalContext.current
        LaunchedEffect(Unit) {
            com.gysbs.cloudtunes.core.UpdateCenter.check(ctx, force = false)
        }

        BackHandler(enabled = showPlayer || openLibraryID != null) {
            if (showPlayer) showPlayer = false else openLibraryID = null
        }

        if (showPlayer) {
            TVPlayerScreen(onClose = { showPlayer = false })
        } else {
            Column(Modifier.fillMaxSize().background(TVBackground)) {
                // 顶栏
                val tabFocus = remember { FocusRequester() }
                LaunchedEffect(Unit) { tabFocus.requestFocus() }

                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 48.dp, vertical = 18.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("汤圆云音盒", style = MaterialTheme.typography.headlineMedium,
                        color = TVAccent, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.width(40.dp))
                    tabs.forEachIndexed { i, label ->
                        val interaction = remember { MutableInteractionSource() }
                        val focused by interaction.collectIsFocusedAsState()
                        Text(
                            label,
                            Modifier
                                .then(if (i == 0) Modifier.focusRequester(tabFocus) else Modifier)
                                .tvFocusable(interaction) { tab = i }
                                .border(
                                    if (focused) 2.dp else 0.dp,
                                    if (focused) TVAccent else Color.Transparent,
                                    RoundedCornerShape(10.dp),
                                )
                                .padding(horizontal = 20.dp, vertical = 8.dp),
                            color = if (tab == i) TVAccent else Color.White.copy(alpha = 0.75f),
                            fontWeight = if (tab == i) FontWeight.Bold else FontWeight.Normal,
                            style = MaterialTheme.typography.titleMedium,
                        )
                        Spacer(Modifier.width(16.dp))
                    }
                    Spacer(Modifier.weight(1f))
                    SyncStatusLine()
                }

                // 内容区
                Box(Modifier.weight(1f)) {
                    when (tab) {
                        0 -> TVHome(openLibrary = { openLibraryID = it }, onOpenPlayer = { showPlayer = true })
                        1 -> SearchTab()
                        2 -> FavoritesTab()
                        3 -> ProfileTab()
                    }
                    val libID = openLibraryID
                    if (libID != null) {
                        LibraryDetailScreen(libID, onClose = { openLibraryID = null })
                    }
                }

                PlayerDock(showPlayer = { showPlayer = true })
            }
        }

        com.gysbs.cloudtunes.ui.UpdateDialogs()
    }
}

/// TV 首页：继续播放 + 音乐库
@Composable
fun TVHome(openLibrary: (String) -> Unit, onOpenPlayer: () -> Unit) {
    val scope = rememberCoroutineScope()
    val session by LibraryStore.session
    val progress = LibraryStore.scanProgress
    val firstFocus = remember { FocusRequester() }

    LazyColumn(
        Modifier.fillMaxSize().padding(horizontal = 48.dp),
        contentPadding = PaddingValues(vertical = 12.dp),
    ) {
        val s = session
        if (s != null && s.tracks.isNotEmpty()) {
            item {
                val t = s.tracks.getOrNull(s.index)
                if (t != null) {
                    TVCard(
                        cover = LibraryStore.findTrack(t.id)?.second?.artworkURL,
                        title = t.displayTitle,
                        subtitle = "继续播放 · ${t.displayArtist} · 队列 ${s.tracks.size} 首",
                        onClick = { PlayerManager.resumeSession(s.position); onOpenPlayer() },
                        modifier = Modifier.focusRequester(firstFocus),
                    )
                }
            }
        }
        item {
            Row(Modifier.padding(vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("我的音乐库", style = MaterialTheme.typography.headlineSmall, color = Color.White)
                Spacer(Modifier.width(16.dp))
                val p = progress.value
                if (p != null) {
                    Text("${p.phase}（${p.scrapedTracks}/${p.totalToScrape}）",
                        color = TVAccent, style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
        items(LibraryStore.libraries.toList(), key = { it.id }) { lib ->
            TVCard(
                cover = lib.coverArtwork,
                title = lib.name,
                subtitle = "${lib.providerKind.label} · ${lib.tracks.size} 首 · ${lib.artistCount} 位歌手",
                onClick = { openLibrary(lib.id) },
                trailing = {
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        val interactionScan = remember { MutableInteractionSource() }
                        Text(
                            "重扫",
                            Modifier.tvFocusable(interactionScan) {
                                scope.launch { LibraryStore.rescanLibrary(lib.id) }
                            }
                                .border(1.dp, Color.White.copy(alpha = 0.3f), RoundedCornerShape(8.dp))
                                .padding(horizontal = 14.dp, vertical = 6.dp),
                            color = Color.White.copy(alpha = 0.8f),
                            style = MaterialTheme.typography.labelLarge,
                        )
                        val interactionReid = remember { MutableInteractionSource() }
                        Text(
                            "识别",
                            Modifier.tvFocusable(interactionReid) {
                                scope.launch { LibraryStore.reidentifyLibrary(lib.id) }
                            }
                                .border(1.dp, Color.White.copy(alpha = 0.3f), RoundedCornerShape(8.dp))
                                .padding(horizontal = 14.dp, vertical = 6.dp),
                            color = Color.White.copy(alpha = 0.8f),
                            style = MaterialTheme.typography.labelLarge,
                        )
                    }
                },
            )
        }
        if (LibraryStore.libraries.isEmpty() && progress.value == null) {
            item {
                Text(
                    "还没有音乐库。先在「我的」页登录网盘账号，\n登录后在手机版或电脑上添加音乐库（会通过 Gist 同步过来）。",
                    Modifier.padding(24.dp),
                    color = Color.White.copy(alpha = 0.6f),
                    style = MaterialTheme.typography.bodyLarge,
                )
            }
        }
    }
}

/// TV 卡片
@Composable
fun TVCard(
    cover: String?,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    trailing: (@Composable () -> Unit)? = null,
) {
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp)
            .tvFocusable(interaction, onClick)
            .border(
                if (focused) 3.dp else 0.dp,
                if (focused) TVAccent else Color.Transparent,
                RoundedCornerShape(14.dp),
            ),
        shape = RoundedCornerShape(14.dp),
        color = TVSurface,
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            if (cover != null) {
                AsyncImage(cover, null, Modifier.size(72.dp), contentScale = ContentScale.Crop)
            } else {
                Surface(Modifier.size(72.dp), shape = RoundedCornerShape(8.dp),
                    color = Color.White.copy(alpha = 0.08f)) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(Icons.Filled.MusicNote, null, tint = Color.White.copy(alpha = 0.5f))
                    }
                }
            }
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleLarge,
                    color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(subtitle, style = MaterialTheme.typography.bodyMedium,
                    color = Color.White.copy(alpha = 0.6f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            trailing?.invoke()
            Spacer(Modifier.width(8.dp))
        }
    }
}

/// TV 全屏播放页（遥控器操作：左右键在按钮间移动，OK 键执行）
@Composable
fun TVPlayerScreen(onClose: () -> Unit) {
    val track = PlayerManager.currentTrack
    if (track == null) {
        Column(Modifier.fillMaxSize().background(TVBackground), verticalArrangement = Arrangement.Center) {
            Text("没有正在播放的歌曲", Modifier.padding(48.dp), color = Color.White)
        }
        return
    }
    val isPlaying by PlayerManager.isPlaying
    val currentTime by PlayerManager.currentTime
    val duration by PlayerManager.duration
    val lyricLines by PlayerManager.lyricLines
    val lyricIndex by PlayerManager.nowPlayingLineIndex
    val playMode by PlayerManager.playMode

    val view = LocalView.current
    DisposableEffect(Unit) {
        view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }
    BackHandler { onClose() }

    var showLyrics by remember { mutableStateOf(true) }
    var showLyricsSearch by remember { mutableStateOf(false) }
    val lyricScope = rememberCoroutineScope()
    val lyricState = rememberLazyListState()
    LaunchedEffect(lyricIndex) {
        if (lyricIndex >= 0 && lyricLines.isNotEmpty()) {
            lyricState.animateScrollToItem((lyricIndex - 4).coerceAtLeast(0).coerceAtMost(lyricLines.size - 1))
        }
    }

    val artwork = LibraryStore.findTrack(track.id)?.second?.artworkURL
    val isFav = LibraryStore.isFavorite(track.id)

    // ── 控制区自动隐藏：5 秒无操作后只留封面和歌词，按遥控器任意键立刻恢复正常播放页 ──
    var controlsVisible by remember { mutableStateOf(true) }
    var idleTick by remember { mutableIntStateOf(0) }
    val playFocus = remember { FocusRequester() }
    // 全部控件隐藏后界面上没有可聚焦元素，遥控器按键会直接丢掉，
    // 所以藏起来时放一个全屏透明焦点锚点接管焦点，保证「按任意键」一定能被收到
    val idleAnchor = remember { FocusRequester() }

    LaunchedEffect(idleTick, track.id) {
        controlsVisible = true
        delay(5000)
        controlsVisible = false
    }
    val controlsAlpha by animateFloatAsState(
        targetValue = if (controlsVisible) 1f else 0f,
        animationSpec = tween(durationMillis = 260),
        label = "tvControls",
    )
    val showControls = controlsAlpha > 0.02f
    // 控制区重新出现（或切歌）时把焦点还给播放键；隐藏完成时焦点交给锚点
    LaunchedEffect(showControls, track.id) {
        delay(120)
        runCatching { if (showControls) playFocus.requestFocus() else idleAnchor.requestFocus() }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color(0xFF0A0B12))
            .onPreviewKeyEvent { e ->
                if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                val nav = e.key == Key.DirectionCenter || e.key == Key.Enter ||
                    e.key == Key.DirectionLeft || e.key == Key.DirectionRight ||
                    e.key == Key.DirectionUp || e.key == Key.DirectionDown
                if (!showControls) {
                    // 沉浸状态：任意方向键/OK 都立刻恢复正常播放页（这一下只负责唤出，不触发动作）
                    idleTick++
                    nav
                } else {
                    idleTick++ // 任意按键重置计时
                    false
                }
            }
    ) {
        // 沉浸背景：当前封面放大压暗（老系统不支持模糊也能正常显示）
        AsyncImage(
            artwork, null,
            Modifier.fillMaxSize().blur(64.dp),
            contentScale = ContentScale.Crop,
            alpha = 0.22f,
        )
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f)))

        Column(Modifier.fillMaxSize().padding(horizontal = 64.dp, vertical = 28.dp)) {
            // 顶栏（自动隐藏时一并淡出）
            if (showControls) {
                Row(
                    Modifier.fillMaxWidth().alpha(controlsAlpha),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TVSmallButton("返回", onClose)
                    Spacer(Modifier.weight(1f))
                    Text("正在播放", color = Color.White.copy(alpha = 0.6f), style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.weight(1f))
                    TVSmallButton(if (showLyrics) "隐藏歌词" else "显示歌词") { showLyrics = !showLyrics }
                }
                Spacer(Modifier.height(16.dp))
            }

            // 封面 + 信息 + 歌词
            Row(Modifier.weight(1f).fillMaxWidth()) {
                AsyncImage(
                    artwork, null,
                    Modifier
                        .size(340.dp)
                        .align(Alignment.CenterVertically)
                        .clip(RoundedCornerShape(18.dp))
                        .border(1.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(18.dp)),
                    contentScale = ContentScale.Crop,
                )
                Spacer(Modifier.width(48.dp))
                Column(Modifier.weight(1f).fillMaxHeight()) {
                    // 歌名/歌手/播放模式：自动隐藏时淡出，只留封面与歌词
                    if (showControls) {
                        Column(Modifier.alpha(controlsAlpha)) {
                            Text(track.displayTitle, style = MaterialTheme.typography.headlineMedium,
                                color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            Text(track.displayArtist, style = MaterialTheme.typography.titleMedium,
                                color = Color.White.copy(alpha = 0.6f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Spacer(Modifier.height(4.dp))
                            // 当前播放模式
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(
                                    when (playMode) {
                                        PlayMode.SEQUENTIAL -> Icons.Filled.Repeat
                                        PlayMode.REPEAT_ONE -> Icons.Filled.RepeatOne
                                        PlayMode.SHUFFLE -> Icons.Filled.Shuffle
                                    },
                                    null, tint = TVAccent, modifier = Modifier.size(16.dp),
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    when (playMode) {
                                        PlayMode.SEQUENTIAL -> "顺序播放"
                                        PlayMode.REPEAT_ONE -> "单曲循环"
                                        PlayMode.SHUFFLE -> "随机播放"
                                    },
                                    color = TVAccent, style = MaterialTheme.typography.labelLarge,
                                )
                            }
                            Spacer(Modifier.height(12.dp))
                        }
                    }
                    if (showLyrics && lyricLines.isNotEmpty()) {
                        LazyColumn(state = lyricState, modifier = Modifier.weight(1f).fillMaxWidth()) {
                            items(lyricLines, key = { it.index }) { line ->
                                val active = line.index == lyricIndex
                                Text(
                                    line.text,
                                    textAlign = TextAlign.Center,
                                    fontSize = if (active) 24.sp else 18.sp,
                                    fontWeight = if (active) FontWeight.Bold else FontWeight.Normal,
                                    color = if (active) TVAccent else Color.White.copy(alpha = 0.45f),
                                    modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                                )
                            }
                        }
                    } else {
                        // 没抓到歌词也给个明确说法，别让右侧空着像出错了
                        Column(
                            Modifier.weight(1f).fillMaxWidth(),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center,
                        ) {
                            Icon(Icons.Filled.MusicNote, null,
                                tint = Color.White.copy(alpha = 0.4f), modifier = Modifier.size(36.dp))
                            Spacer(Modifier.height(8.dp))
                            Text("暂无歌词", color = Color.White.copy(alpha = 0.45f),
                                style = MaterialTheme.typography.bodyMedium)
                            Spacer(Modifier.height(14.dp))
                            TVSmallButton("搜索歌词") { showLyricsSearch = true }
                        }
                    }
                }
            }

            // 进度条 + 控制按钮（自动隐藏时整体淡出）
            if (showControls) {
                Column(Modifier.fillMaxWidth().alpha(controlsAlpha)) {
                    Row(
                        Modifier.fillMaxWidth().padding(vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(formatDuration(currentTime), color = Color.White.copy(alpha = 0.7f),
                            style = MaterialTheme.typography.labelLarge)
                        LinearProgressIndicator(
                            progress = { if (duration > 0) (currentTime / duration).toFloat().coerceIn(0f, 1f) else 0f },
                            modifier = Modifier.weight(1f).padding(horizontal = 16.dp).height(6.dp),
                            color = TVAccent,
                            trackColor = Color.White.copy(alpha = 0.15f),
                        )
                        Text(formatDuration(if (duration > 0) duration else null),
                            color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.labelLarge)
                    }

                    Row(
                        Modifier.fillMaxWidth().padding(vertical = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(24.dp, Alignment.CenterHorizontally),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {

                        // 播放模式：顺序 → 单曲循环 → 随机
                        TVControlButton(
                            when (playMode) {
                                PlayMode.SEQUENTIAL -> Icons.Filled.Repeat
                                PlayMode.REPEAT_ONE -> Icons.Filled.RepeatOne
                                PlayMode.SHUFFLE -> Icons.Filled.Shuffle
                            },
                            when (playMode) {
                                PlayMode.SEQUENTIAL -> "顺序播放"
                                PlayMode.REPEAT_ONE -> "单曲循环"
                                PlayMode.SHUFFLE -> "随机播放"
                            },
                        ) { PlayerManager.cyclePlayMode() }
                        TVControlButton(Icons.Filled.SkipPrevious, "上一首") { PlayerManager.playPrev() }
                        TVControlButton(Icons.Filled.FastRewind, "后退 10 秒") {
                            PlayerManager.seekTo((currentTime - 10.0).coerceAtLeast(0.0))
                        }
                        FilledIconButton(
                            onClick = { PlayerManager.togglePlayPause() },
                            modifier = Modifier.size(96.dp).focusRequester(playFocus),
                            colors = IconButtonDefaults.filledIconButtonColors(
                                containerColor = TVAccent, contentColor = Color.White,
                            ),
                        ) {
                            Icon(if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, null, Modifier.size(44.dp))
                        }
                        TVControlButton(Icons.Filled.FastForward, "前进 10 秒") {
                            PlayerManager.seekTo(currentTime + 10.0)
                        }
                        TVControlButton(Icons.Filled.SkipNext, "下一首") { PlayerManager.playNext() }
                        // 收藏（与手机版播放页一致）
                        TVControlButton(
                            if (isFav) Icons.Filled.Favorite else Icons.Outlined.Favorite,
                            if (isFav) "取消收藏" else "收藏",
                            tint = if (isFav) TVAccent else Color.White.copy(alpha = 0.85f),
                        ) { LibraryStore.toggleFavorite(track.id) }
                    }
                }
            }
        }

        // 沉浸状态下的透明焦点锚点：保证遥控器按键始终有接收者
        if (!showControls) {
            Box(
                Modifier
                    .fillMaxSize()
                    .focusRequester(idleAnchor)
                    .focusable()
            )
        }
    }

    // 手动搜索/匹配歌词（复用手机端弹窗；预填「歌手 歌名」并自动搜一次）
    // 网易云候选写回 neteaseID；其他源取词直接应用 + 本地缓存
    if (showLyricsSearch) {
        val lib = LibraryStore.findTrack(track.id)
        LyricsSearchDialog(
            initialQuery = listOfNotNull(
                lib?.second?.artist?.takeIf { it.isNotBlank() },
                lib?.second?.title ?: track.displayTitle,
            ).joinToString(" "),
            onPick = { song ->
                val nid = song.neteaseID
                if (nid != null && nid > 0) {
                    lib?.let { LibraryStore.setTrackNeteaseID(it.first.id, it.second.id, nid) }
                    LyricsCache.remove(track.id)
                    PlayerManager.refetchLyrics()
                } else {
                    lyricScope.launch {
                        val text = runCatching { LyricSources.textFor(song) }.getOrNull()
                        if (!text.isNullOrBlank()) PlayerManager.applyLyricsText(track.id, text)
                    }
                }
                showLyricsSearch = false
            },
            onDismiss = { showLyricsSearch = false },
        )
    }
}

@Composable
private fun TVSmallButton(label: String, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    Text(
        label,
        Modifier.tvFocusable(interaction, onClick)
            .border(
                if (focused) 2.dp else 1.dp,
                if (focused) TVAccent else Color.White.copy(alpha = 0.3f),
                RoundedCornerShape(10.dp),
            )
            .padding(horizontal = 18.dp, vertical = 8.dp),
        color = if (focused) TVAccent else Color.White.copy(alpha = 0.8f),
        style = MaterialTheme.typography.labelLarge,
    )
}

@Composable
private fun TVControlButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    desc: String,
    tint: Color = Color.White.copy(alpha = 0.75f),
    onClick: () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    Surface(
        modifier = Modifier.size(76.dp).tvFocusable(interaction, onClick),
        shape = CircleShape,
        color = if (focused) TVAccent else TVSurface,
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(icon, desc, Modifier.size(34.dp),
                tint = if (focused) Color.White else tint)
        }
    }
}
