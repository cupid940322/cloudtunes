package com.gysbs.cloudtunes.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import com.gysbs.cloudtunes.core.LibraryStore
import com.gysbs.cloudtunes.core.SyncService
import com.gysbs.cloudtunes.player.PlayerManager

/// 底部导航页
enum class Tab { Home, Search, Favorites, Profile }

@Composable
fun AppRoot() {
    var tab by remember { mutableStateOf(Tab.Home) }
    var openLibraryID by remember { mutableStateOf<String?>(null) }
    var showPlayer by remember { mutableStateOf(false) }
    val context = androidx.compose.ui.platform.LocalContext.current

    // 登录后冷启动同步
    LaunchedEffect(Unit) {
        SyncService.syncIfStale()
    }
    // 启动时静默检查更新（24 小时内只查一次，发现新版才弹窗）
    LaunchedEffect(Unit) {
        com.gysbs.cloudtunes.core.UpdateCenter.check(context, force = false)
    }

    val snackbar = remember { SnackbarHostState() }
    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        bottomBar = {
            if (!showPlayer) {
                Column {
                    PlayerDock(showPlayer = { showPlayer = true })
                    NavigationBar {
                        NavigationBarItem(tab == Tab.Home, { tab = Tab.Home },
                            icon = { Icon(Icons.Filled.LibraryMusic, null) }, label = { Text("乐库") })
                        NavigationBarItem(tab == Tab.Search, { tab = Tab.Search },
                            icon = { Icon(Icons.Filled.Search, null) }, label = { Text("搜索") })
                        NavigationBarItem(tab == Tab.Favorites, { tab = Tab.Favorites },
                            icon = { Icon(Icons.Filled.Favorite, null) }, label = { Text("收藏") })
                        NavigationBarItem(tab == Tab.Profile, { tab = Tab.Profile },
                            icon = { Icon(Icons.Filled.Person, null) }, label = { Text("我的") })
                    }
                }
            }
        }
    ) { padding ->
        Box(Modifier.padding(padding)) {
            when (tab) {
                Tab.Home -> HomeTab(openLibrary = { openLibraryID = it })
                Tab.Search -> SearchTab()
                Tab.Favorites -> FavoritesTab()
                Tab.Profile -> ProfileTab()
            }
            val libID = openLibraryID
            if (libID != null) {
                LibraryDetailScreen(libID, onClose = { openLibraryID = null })
            }
            if (showPlayer) {
                PlayerScreen(onClose = { showPlayer = false })
            }
        }
    }

    UpdateDialogs()
}

/// 迷你播放条
@Composable
fun PlayerDock(showPlayer: () -> Unit) {
    val track = PlayerManager.currentTrack ?: return
    val isPlaying by PlayerManager.isPlaying
    val isLoading by PlayerManager.isLoading

    Surface(tonalElevation = 3.dp) {
        Row(
            Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val cover = LibraryStore.findTrack(track.id)?.second?.artworkURL
            AsyncImage(
                cover, null,
                Modifier.size(40.dp),
                contentScale = ContentScale.Crop,
            )
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(track.displayTitle, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
                Text(track.displayArtist, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            IconButton(onClick = { PlayerManager.togglePlayPause() }) {
                Icon(if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, null)
            }
            IconButton(onClick = { PlayerManager.playNext() }) {
                Icon(Icons.Filled.SkipNext, null)
            }
            IconButton(onClick = { showPlayer() }) {
                Icon(Icons.AutoMirrored.Filled.QueueMusic, null)
            }
        }
    }
}

/// 同步状态徽标（Profile 顶部也用）
@Composable
fun SyncStatusLine() {
    val status by SyncService.status.collectAsStateWithLifecycle()
    val text = when (val s = status) {
        is SyncService.Status.Idle -> if (com.gysbs.cloudtunes.core.GitHubAccount.isSignedIn) "未同步过" else "未登录 GitHub"
        is SyncService.Status.Syncing -> "同步中：${s.reason}"
        is SyncService.Status.Done -> "上次同步 ${s.tracks} 首"
        is SyncService.Status.Failed -> "同步失败：${s.message}"
    }
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}
