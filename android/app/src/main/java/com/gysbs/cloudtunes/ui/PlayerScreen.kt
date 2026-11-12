package com.gysbs.cloudtunes.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.gysbs.cloudtunes.core.LibraryStore
import com.gysbs.cloudtunes.player.PlayerManager
import kotlinx.coroutines.delay

/// 全屏播放页（含歌词）
@Composable
fun PlayerScreen(onClose: () -> Unit) {
    val track = PlayerManager.currentTrack
    if (track == null) {
        Text("还没有正在播放的歌曲", Modifier.padding(32.dp))
        return
    }
    val isPlaying by PlayerManager.isPlaying
    val currentTime by PlayerManager.currentTime
    val duration by PlayerManager.duration
    val lyricLines by PlayerManager.lyricLines
    val lyricIndex by PlayerManager.nowPlayingLineIndex
    val isLoading by PlayerManager.isLoading
    val error by PlayerManager.loadError

    val libTrack = LibraryStore.findTrack(track.id)?.second
    val artwork = libTrack?.artworkURL
    val isFav = LibraryStore.isFavorite(track.id)

    var showLyrics by remember { mutableStateOf(true) }
    val lyricListState = rememberLazyListState()

    // 歌词自动滚动到当前行
    LaunchedEffect(lyricIndex, showLyrics) {
        if (showLyrics && lyricIndex >= 0) {
            lyricListState.animateScrollToItem(
                maxOf(0, lyricIndex - 3).coerceAtMost((lyricLines.size - 1).coerceAtLeast(0))
            )
        }
    }

    Column(
        Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface).padding(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // 顶栏
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onClose) { Icon(Icons.Filled.Close, null) }
            Spacer(Modifier.weight(1f))
            IconButton(onClick = { showLyrics = !showLyrics }) {
                Icon(Icons.AutoMirrored.Filled.QueueMusic, null,
                    tint = if (showLyrics) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }

        Spacer(Modifier.height(8.dp))

        // 封面（歌词模式下缩小）
        val coverSize = if (showLyrics && lyricLines.isNotEmpty()) 160.dp else 320.dp
        AsyncImage(
            artwork, null,
            Modifier.size(coverSize),
            contentScale = ContentScale.Crop,
        )

        Spacer(Modifier.height(16.dp))

        // 歌词区
        if (showLyrics && lyricLines.isNotEmpty()) {
            LazyColumn(
                state = lyricListState,
                modifier = Modifier.weight(1f).fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                items(lyricLines, key = { it.index }) { line ->
                    val active = line.index == lyricIndex
                    Text(
                        line.text,
                        textAlign = TextAlign.Center,
                        style = MaterialTheme.typography.titleMedium.copy(
                            fontWeight = if (active) FontWeight.Bold else FontWeight.Normal,
                        ),
                        color = if (active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 8.dp),
                    )
                }
            }
        } else {
            Spacer(Modifier.weight(1f))
        }

        Spacer(Modifier.height(12.dp))

        // 标题
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(track.displayTitle, style = MaterialTheme.typography.titleLarge,
                    maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                Text(track.displayArtist, style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            IconButton(onClick = { LibraryStore.toggleFavorite(track.id) }) {
                Icon(
                    if (isFav) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                    null,
                    tint = if (isFav) Color(0xFFE0455E) else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        // 进度条
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(formatDuration(currentTime), style = MaterialTheme.typography.labelSmall)
            Slider(
                value = if (duration > 0) (currentTime / duration).toFloat().coerceIn(0f, 1f) else 0f,
                onValueChange = { frac ->
                    if (duration > 0) PlayerManager.seekTo(frac * duration)
                },
                modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
            )
            Text(formatDuration(if (duration > 0) duration else null),
                style = MaterialTheme.typography.labelSmall)
        }

        if (isLoading) {
            Text("加载中…", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        error?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        }

        // 控制按钮
        Row(
            Modifier.fillMaxWidth().padding(vertical = 12.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = { PlayerManager.playPrev() }, modifier = Modifier.size(56.dp)) {
                Icon(Icons.Filled.SkipPrevious, null, Modifier.size(36.dp))
            }
            FilledIconButton(
                onClick = { PlayerManager.togglePlayPause() },
                modifier = Modifier.size(72.dp),
            ) {
                Icon(
                    if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    null, Modifier.size(40.dp),
                )
            }
            IconButton(onClick = { PlayerManager.playNext() }, modifier = Modifier.size(56.dp)) {
                Icon(Icons.Filled.SkipNext, null, Modifier.size(36.dp))
            }
        }
    }
}
