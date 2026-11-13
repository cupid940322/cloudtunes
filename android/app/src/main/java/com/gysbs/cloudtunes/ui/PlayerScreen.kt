package com.gysbs.cloudtunes.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.RepeatOne
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.outlined.Favorite
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.gysbs.cloudtunes.core.LibraryStore
import com.gysbs.cloudtunes.core.LyricSources
import com.gysbs.cloudtunes.core.LyricsCache
import com.gysbs.cloudtunes.player.PlayMode
import com.gysbs.cloudtunes.player.PlayerManager
import kotlinx.coroutines.launch

// ── 网易云风格深色沉浸配色 ──
private val PlayerBgTop = Color(0xFF33323B)
private val PlayerBgBottom = Color(0xFF141318)
private val PlayerAccent = Color(0xFFE85D5D)
private val OnPlayerBg = Color.White
private val OnPlayerBgDim = Color.White.copy(alpha = 0.55f)

private fun modeIcon(mode: PlayMode): ImageVector = when (mode) {
    PlayMode.SEQUENTIAL -> Icons.Filled.Repeat
    PlayMode.REPEAT_ONE -> Icons.Filled.RepeatOne
    PlayMode.SHUFFLE -> Icons.Filled.Shuffle
}

private fun modeLabel(mode: PlayMode): String = when (mode) {
    PlayMode.SEQUENTIAL -> "顺序播放"
    PlayMode.REPEAT_ONE -> "单曲循环"
    PlayMode.SHUFFLE -> "随机播放"
}

/// 全屏播放页：网易云风格的深色沉浸设计。
/// 中间区域左右滑切换 封面 ↔ 歌词（顶栏按钮同样能切）；
/// 歌词没抓到时显示「暂无歌词」占位，不再出现"点了没反应"。
@Composable
fun PlayerScreen(onClose: () -> Unit) {
    val track = PlayerManager.currentTrack
    if (track == null) {
        Box(
            Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(PlayerBgTop, PlayerBgBottom))),
            contentAlignment = Alignment.Center,
        ) { Text("还没有正在播放的歌曲", color = OnPlayerBgDim) }
        return
    }
    val isPlaying by PlayerManager.isPlaying
    val currentTime by PlayerManager.currentTime
    val duration by PlayerManager.duration
    val lyricLines by PlayerManager.lyricLines
    val lyricIndex by PlayerManager.nowPlayingLineIndex
    val isLoading by PlayerManager.isLoading
    val error by PlayerManager.loadError
    val playMode by PlayerManager.playMode

    val libTrack = LibraryStore.findTrack(track.id)?.second
    val artwork = libTrack?.artworkURL
    val isFav = LibraryStore.isFavorite(track.id)

    // 0 = 封面，1 = 歌词
    val pagerState = rememberPagerState(pageCount = { 2 })
    val scope = rememberCoroutineScope()
    val onLyricsPage = pagerState.currentPage == 1 || pagerState.targetPage == 1
    val lyricListState = rememberLazyListState()
    var showLyricsSearch by remember { mutableStateOf(false) }

    // 歌词自动滚动到当前行
    LaunchedEffect(lyricIndex, onLyricsPage) {
        if (onLyricsPage && lyricIndex >= 0 && lyricLines.isNotEmpty()) {
            lyricListState.animateScrollToItem(
                maxOf(0, lyricIndex - 3).coerceAtMost(lyricLines.size - 1)
            )
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(listOf(PlayerBgTop, PlayerBgBottom)))
    ) {
        // 背景封面大图（模糊 + 压暗；Android 12 以下不支持模糊就只显示压暗图）
        AsyncImage(
            artwork, null,
            Modifier.fillMaxSize().blur(56.dp),
            contentScale = ContentScale.Crop,
            alpha = 0.28f,
        )
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.30f)))

        Column(Modifier.fillMaxSize().padding(horizontal = 22.dp)) {
            // 顶栏：收起 / 歌曲信息 / 歌词切换
            Row(Modifier.fillMaxWidth().padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) {
                    Icon(Icons.Filled.KeyboardArrowDown, "收起", tint = OnPlayerBg, modifier = Modifier.size(30.dp))
                }
                Column(
                    Modifier.weight(1f),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(track.displayTitle, color = OnPlayerBg, style = MaterialTheme.typography.titleMedium,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(
                        "${track.displayArtist} · ${modeLabel(playMode)}",
                        color = OnPlayerBgDim, style = MaterialTheme.typography.labelSmall,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
                IconButton(onClick = {
                    scope.launch { pagerState.animateScrollToPage(if (onLyricsPage) 0 else 1) }
                }) {
                    Icon(Icons.AutoMirrored.Filled.QueueMusic, "歌词",
                        tint = if (onLyricsPage) PlayerAccent else OnPlayerBg, modifier = Modifier.size(24.dp))
                }
            }

            Spacer(Modifier.height(8.dp))

            // 中间：封面页 / 歌词页
            HorizontalPager(
                state = pagerState,
                modifier = Modifier.weight(1f).fillMaxWidth(),
            ) { page ->
                if (page == 0) {
                    Box(Modifier.fillMaxSize().padding(vertical = 18.dp), contentAlignment = Alignment.Center) {
                        Box(
                            Modifier
                                .fillMaxWidth(0.84f)
                                .aspectRatio(1f)
                                .clip(RoundedCornerShape(20.dp))
                                .border(1.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(20.dp)),
                        ) {
                            AsyncImage(
                                artwork, null,
                                Modifier.fillMaxSize(),
                                contentScale = ContentScale.Crop,
                            )
                        }
                    }
                } else {
                    if (lyricLines.isEmpty()) {
                        Column(
                            Modifier.fillMaxSize(),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center,
                        ) {
                            Icon(Icons.Filled.MusicNote, null, tint = OnPlayerBgDim, modifier = Modifier.size(40.dp))
                            Spacer(Modifier.height(10.dp))
                            Text(
                                if (isLoading) "正在获取歌词…" else "暂无歌词",
                                color = OnPlayerBgDim, style = MaterialTheme.typography.bodyMedium,
                            )
                            if (!isLoading) {
                                Spacer(Modifier.height(14.dp))
                                TextButton(onClick = { showLyricsSearch = true }) {
                                    Icon(Icons.Filled.Search, null, tint = PlayerAccent, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(6.dp))
                                    Text("搜索歌词", color = OnPlayerBg, style = MaterialTheme.typography.labelLarge)
                                }
                            }
                        }
                    } else {
                        LazyColumn(
                            state = lyricListState,
                            modifier = Modifier.fillMaxSize(),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            contentPadding = PaddingValues(vertical = 48.dp),
                        ) {
                            items(lyricLines, key = { it.index }) { line ->
                                val active = line.index == lyricIndex
                                Text(
                                    line.text,
                                    textAlign = TextAlign.Center,
                                    fontSize = if (active) 20.sp else 15.sp,
                                    fontWeight = if (active) FontWeight.Bold else FontWeight.Normal,
                                    color = if (active) OnPlayerBg else OnPlayerBgDim.copy(alpha = 0.55f),
                                    modifier = Modifier.padding(vertical = 10.dp),
                                )
                            }
                        }
                    }
                }
            }

            // 页码指示（封面 / 歌词）
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.align(Alignment.CenterHorizontally).padding(vertical = 8.dp),
            ) {
                repeat(2) { i ->
                    Box(
                        Modifier.size(6.dp).background(
                            if (pagerState.currentPage == i) OnPlayerBg
                            else OnPlayerBg.copy(alpha = 0.25f),
                            CircleShape,
                        )
                    )
                }
            }

            // 播放模式切换
            Row(
                Modifier.fillMaxWidth().clickable { PlayerManager.cyclePlayMode() },
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(modeIcon(playMode), null, tint = PlayerAccent, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text(modeLabel(playMode), color = PlayerAccent, style = MaterialTheme.typography.labelMedium)
            }

            Spacer(Modifier.height(6.dp))

            // 进度条
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(formatDuration(currentTime), color = OnPlayerBgDim, style = MaterialTheme.typography.labelSmall)
                Slider(
                    value = if (duration > 0) (currentTime / duration).toFloat().coerceIn(0f, 1f) else 0f,
                    onValueChange = { frac ->
                        if (duration > 0) PlayerManager.seekTo(frac * duration)
                    },
                    modifier = Modifier.weight(1f).padding(horizontal = 8.dp).height(26.dp),
                    colors = SliderDefaults.colors(
                        thumbColor = OnPlayerBg,
                        activeTrackColor = OnPlayerBg,
                        inactiveTrackColor = OnPlayerBg.copy(alpha = 0.25f),
                    ),
                )
                Text(
                    formatDuration(if (duration > 0) duration else null),
                    color = OnPlayerBgDim, style = MaterialTheme.typography.labelSmall,
                )
            }

            // 控制按钮：模式 / 上一首 / 播放 / 下一首
            Row(
                Modifier.fillMaxWidth().padding(vertical = 14.dp),
                horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = { PlayerManager.cyclePlayMode() }, modifier = Modifier.size(48.dp)) {
                    Icon(modeIcon(playMode), modeLabel(playMode), tint = OnPlayerBg, modifier = Modifier.size(24.dp))
                }
                IconButton(onClick = { PlayerManager.playPrev() }, modifier = Modifier.size(56.dp)) {
                    Icon(Icons.Filled.SkipPrevious, "上一首", tint = OnPlayerBg, modifier = Modifier.size(38.dp))
                }
                // 大播放键：白描边圆圈，网易云样式
                Box(
                    Modifier
                        .size(74.dp)
                        .border(2.5.dp, OnPlayerBg.copy(alpha = 0.9f), CircleShape)
                        .clickable { PlayerManager.togglePlayPause() },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                        null, Modifier.size(36.dp), tint = OnPlayerBg,
                    )
                }
                IconButton(onClick = { PlayerManager.playNext() }, modifier = Modifier.size(56.dp)) {
                    Icon(Icons.Filled.SkipNext, "下一首", tint = OnPlayerBg, modifier = Modifier.size(38.dp))
                }
                // 收藏（与 iOS 播放页一致放在控制区）
                IconButton(onClick = { LibraryStore.toggleFavorite(track.id) }, modifier = Modifier.size(48.dp)) {
                    Icon(
                        if (isFav) Icons.Filled.Favorite else Icons.Outlined.Favorite,
                        "收藏",
                        tint = if (isFav) PlayerAccent else OnPlayerBg,
                        modifier = Modifier.size(24.dp),
                    )
                }
            }

            if (isLoading) {
                Text("加载中…", style = MaterialTheme.typography.bodySmall, color = OnPlayerBgDim,
                    modifier = Modifier.align(Alignment.CenterHorizontally))
            }
            error?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = PlayerAccent,
                    modifier = Modifier.align(Alignment.CenterHorizontally))
            }
            Spacer(Modifier.height(10.dp))
        }
    }

    // 手动搜索/匹配歌词：四源候选——网易云写回 neteaseID，其他源取词直接应用 + 本地缓存
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
                    scope.launch {
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
