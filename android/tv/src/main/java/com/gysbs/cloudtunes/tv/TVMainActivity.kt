package com.gysbs.cloudtunes.tv

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
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
import com.gysbs.cloudtunes.core.SyncService
import com.gysbs.cloudtunes.player.PlaybackService
import com.gysbs.cloudtunes.player.PlayerManager
import com.gysbs.cloudtunes.ui.FavoritesTab
import com.gysbs.cloudtunes.ui.LibraryDetailScreen
import com.gysbs.cloudtunes.ui.PlayerDock
import com.gysbs.cloudtunes.ui.ProfileTab
import com.gysbs.cloudtunes.ui.SearchTab
import com.gysbs.cloudtunes.ui.SyncStatusLine
import com.gysbs.cloudtunes.ui.formatDuration
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
                    val interaction = remember { MutableInteractionSource() }
                    Text(
                        "重扫",
                        Modifier.tvFocusable(interaction) {
                            scope.launch { LibraryStore.rescanLibrary(lib.id) }
                        }
                            .border(1.dp, Color.White.copy(alpha = 0.3f), RoundedCornerShape(8.dp))
                            .padding(horizontal = 14.dp, vertical = 6.dp),
                        color = Color.White.copy(alpha = 0.8f),
                        style = MaterialTheme.typography.labelLarge,
                    )
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

    val view = LocalView.current
    DisposableEffect(Unit) {
        view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }
    BackHandler { onClose() }

    var showLyrics by remember { mutableStateOf(true) }
    val lyricState = rememberLazyListState()
    LaunchedEffect(lyricIndex) {
        if (lyricIndex >= 0) {
            lyricState.animateScrollToItem((lyricIndex - 4).coerceAtLeast(0))
        }
    }

    Column(
        Modifier.fillMaxSize().background(Color(0xFF0A0B12)).padding(horizontal = 64.dp, vertical = 28.dp),
    ) {
        // 顶栏
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            TVSmallButton("返回", onClose)
            Spacer(Modifier.weight(1f))
            Text("正在播放", color = Color.White.copy(alpha = 0.6f), style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.weight(1f))
            TVSmallButton(if (showLyrics) "隐藏歌词" else "显示歌词") { showLyrics = !showLyrics }
        }
        Spacer(Modifier.height(16.dp))

        // 封面 + 信息 + 歌词
        Row(Modifier.weight(1f).fillMaxWidth()) {
            val artwork = LibraryStore.findTrack(track.id)?.second?.artworkURL
            AsyncImage(
                artwork, null,
                Modifier.size(340.dp).align(Alignment.CenterVertically),
                contentScale = ContentScale.Crop,
            )
            Spacer(Modifier.width(48.dp))
            Column(Modifier.weight(1f).fillMaxHeight()) {
                Text(track.displayTitle, style = MaterialTheme.typography.headlineMedium,
                    color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(track.displayArtist, style = MaterialTheme.typography.titleMedium,
                    color = Color.White.copy(alpha = 0.6f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(12.dp))
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
                    Spacer(Modifier.weight(1f))
                }
            }
        }

        // 进度条
        Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
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

        // 控制按钮（默认焦点在播放/暂停上）
        Row(
            Modifier.fillMaxWidth().padding(vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(28.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val playFocus = remember { FocusRequester() }
            LaunchedEffect(track.id) { playFocus.requestFocus() }

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
        }
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
private fun TVControlButton(icon: androidx.compose.ui.graphics.vector.ImageVector, desc: String, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    Surface(
        modifier = Modifier.size(76.dp).tvFocusable(interaction, onClick),
        shape = CircleShape,
        color = if (focused) TVAccent else TVSurface,
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(icon, desc, Modifier.size(34.dp),
                tint = if (focused) Color.White else Color.White.copy(alpha = 0.75f))
        }
    }
}
