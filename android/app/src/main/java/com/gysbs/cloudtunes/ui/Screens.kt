package com.gysbs.cloudtunes.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import com.gysbs.cloudtunes.core.*
import com.gysbs.cloudtunes.player.PlayerManager
import kotlinx.coroutines.launch
import java.time.format.DateTimeFormatter

// ───────────────────────── 公共组件 ─────────────────────────

fun formatDuration(sec: Double?): String {
    val s = sec?.toInt() ?: return "--:--"
    return "%d:%02d".format(s / 60, s % 60)
}

@Composable
fun TrackRow(
    lib: MusicLibrary,
    track: LibraryTrack,
    queueTracks: List<LibraryTrack>,
    onDeleted: () -> Unit = {},
    indexInQueue: Int = 0,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val isFav = LibraryStore.isFavorite(track.id)

    Row(
        Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val cover = track.artworkURL
        if (cover != null) {
            AsyncImage(cover, null, Modifier.size(42.dp), contentScale = ContentScale.Crop)
        } else {
            Surface(Modifier.size(42.dp), shape = MaterialTheme.shapes.small,
                color = MaterialTheme.colorScheme.surfaceVariant) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.MusicNote, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f).clickable {
            PlayerManager.playAt(queueTracks.map { it.toTrack() }, indexInQueue)
        }) {
            Text(track.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodyMedium)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(track.displayArtist, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (track.needsReview) {
                    Spacer(Modifier.width(6.dp))
                    Text("待确认", style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.tertiary)
                }
            }
        }
        Text(formatDuration(track.duration), style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        IconButton(onClick = { LibraryStore.toggleFavorite(track.id) }, modifier = Modifier.size(40.dp)) {
            Icon(
                if (isFav) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                null,
                tint = if (isFav) Color(0xFFE0455E) else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Box {
            IconButton(onClick = { menuOpen = true }, modifier = Modifier.size(40.dp)) {
                Icon(Icons.Filled.MoreVert, null)
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(text = { Text("在线重新匹配") }, onClick = {
                    menuOpen = false
                    scope.launch { LibraryStore.rescrapeTrack(lib.id, track.id) }
                })
                DropdownMenuItem(text = { Text("从库中删除") }, onClick = {
                    menuOpen = false
                    LibraryStore.deleteTrack(lib.id, track.id)
                    onDeleted()
                })
            }
        }
    }
}

// ───────────────────────── 首页（乐库） ─────────────────────────

@Composable
fun HomeTab(openLibrary: (String) -> Unit) {
    val session by LibraryStore.session
    val progress = LibraryStore.scanProgress
    var addDialog by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    Box(Modifier.fillMaxSize()) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(vertical = 12.dp)) {
            item {
                Text("乐库", style = MaterialTheme.typography.headlineMedium,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            }

            // 继续播放 / 正在播放：图标和标题都跟着真实播放状态走，不再永远挂着 ▶
            val s = session
            val live = PlayerManager.currentTrack
            val playing = PlayerManager.isPlaying.value
            val cardTrack = (if (playing) live else null) ?: s?.tracks?.getOrNull(s.index)
            if (cardTrack != null) {
                item {
                    val t = cardTrack
                    val queueSize = if (PlayerManager.queue.isNotEmpty()) PlayerManager.queue.size else (s?.tracks?.size ?: 0)
                    Card(Modifier.padding(horizontal = 16.dp, vertical = 6.dp).clickable {
                        if (PlayerManager.queue.isEmpty()) {
                            s?.let { PlayerManager.resumeSession(it.position) }
                        } else {
                            PlayerManager.togglePlayPause()
                        }
                    }) {
                        Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                            val cover = LibraryStore.findTrack(t.id)?.second?.artworkURL
                            if (cover != null) AsyncImage(cover, null, Modifier.size(52.dp), contentScale = ContentScale.Crop)
                            else Surface(Modifier.size(52.dp), shape = MaterialTheme.shapes.small,
                                color = MaterialTheme.colorScheme.surfaceVariant) {
                                Box(contentAlignment = Alignment.Center) { Icon(Icons.Filled.MusicNote, null) }
                            }
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(if (playing) "正在播放" else "继续播放", style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.primary)
                                Text(t.displayTitle, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                    style = MaterialTheme.typography.titleSmall)
                                Text("${t.displayArtist} · 队列 $queueSize 首",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Icon(
                                if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                                null, tint = MaterialTheme.colorScheme.primary,
                            )
                        }
                    }
                }
            }

            item {
                Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text("我的音乐库", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.weight(1f))
                    FilledTonalButton(onClick = { addDialog = true }) {
                        Icon(Icons.Filled.Add, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(4.dp))
                        Text("添加云盘文件夹")
                    }
                }
            }

            // 扫描进度
            val p = progress.value
            if (p != null) {
                item {
                    Card(Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) {
                        Column(Modifier.padding(14.dp)) {
                            Text("${p.phase}（${p.scrapedTracks}/${p.totalToScrape}）",
                                style = MaterialTheme.typography.bodyMedium)
                            if (p.totalToScrape > 0) {
                                LinearProgressIndicator(
                                    progress = { p.scrapedTracks.toFloat() / p.totalToScrape },
                                    Modifier.fillMaxWidth().padding(top = 8.dp),
                                )
                            }
                        }
                    }
                }
            }

            items(LibraryStore.libraries.toList(), key = { it.id }) { lib ->
                Card(Modifier.padding(horizontal = 16.dp, vertical = 6.dp).clickable { openLibrary(lib.id) }) {
                    Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                        val cover = lib.coverArtwork
                        if (cover != null) AsyncImage(cover, null, Modifier.size(52.dp), contentScale = ContentScale.Crop)
                        else Surface(Modifier.size(52.dp), shape = MaterialTheme.shapes.small,
                            color = MaterialTheme.colorScheme.surfaceVariant) {
                            Box(contentAlignment = Alignment.Center) { Icon(Icons.Filled.LibraryMusic, null) }
                        }
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(lib.name, style = MaterialTheme.typography.titleSmall)
                            Text("${lib.providerKind.label} · ${lib.tracks.size} 首 · ${lib.artistCount} 位歌手",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        IconButton(onClick = {
                            scope.launch { LibraryStore.rescanLibrary(lib.id) }
                        }) {
                            Text("重扫", style = MaterialTheme.typography.labelMedium)
                        }
                    }
                }
            }

            if (LibraryStore.libraries.isEmpty() && p == null) {
                item {
                    Text(
                        "还没有音乐库。点上面的「添加云盘文件夹」，\n先登录一个网盘（在「我的」页），再选一个存音乐的文件夹。",
                        Modifier.padding(32.dp), style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        if (addDialog) {
            AddLibraryDialog(onDismiss = { addDialog = false })
        }
    }
}

/// 添加库：选网盘类型 → 浏览文件夹
@Composable
fun AddLibraryDialog(onDismiss: () -> Unit) {
    var kind by remember { mutableStateOf<CloudKind?>(null) }
    kind?.let { k ->
        FolderBrowserDialog(kind = k, onDismiss = { kind = null }, onPicked = { _, _ -> }, pickLibrary = true)
    } ?: run {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("添加云盘文件夹") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("选择网盘类型。对应账号可在「我的」页登录。")
                    for (k in CloudKind.entries) {
                        FilledTonalButton(onClick = { kind = k }, modifier = Modifier.fillMaxWidth()) {
                            Text(k.label)
                        }
                    }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
        )
    }
}

/// 网盘文件夹浏览（新建库用）
@Composable
fun FolderBrowserDialog(
    kind: CloudKind,
    onDismiss: () -> Unit,
    onPicked: (CloudKind, CloudFile) -> Unit,
    pickLibrary: Boolean,
) {
    val provider = when (kind) {
        CloudKind.GUANGYA -> GuangyaProvider
        CloudKind.BAIDU -> BaiduProvider
        CloudKind.QUARK -> QuarkProvider
    }
    val rootID = when (kind) {
        CloudKind.GUANGYA -> ""
        CloudKind.QUARK -> "0"
        CloudKind.BAIDU -> "/"
    }
    val scope = rememberCoroutineScope()
    var current by remember { mutableStateOf(CloudFile(id = rootID, name = "根目录", isFolder = true)) }
    val backStack = remember { mutableStateListOf<CloudFile>() }
    var files by remember { mutableStateOf<List<CloudFile>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(current, provider.isSignedIn) {
        if (!provider.isSignedIn) {
            error = "请先在「我的」页登录${kind.label}"
            return@LaunchedEffect
        }
        loading = true; error = null
        try {
            files = provider.list(current.id).filter { it.isFolder }
        } catch (e: Exception) {
            error = e.message
        }
        loading = false
    }

    var nameInput by remember { mutableStateOf("") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("选择${kind.label}文件夹") },
        text = {
            Column(Modifier.heightIn(max = 400.dp)) {
                if (provider.isSignedIn) {
                    Text("当前：${current.name}", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(6.dp))
                    InputField(nameInput, { nameInput = it },
                        label = "库名称（可选）", modifier = Modifier.fillMaxWidth())
                }
                Spacer(Modifier.height(6.dp))
                when {
                    loading -> Box(Modifier.fillMaxWidth().height(120.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator()
                    }
                    error != null -> Text(error!!, color = MaterialTheme.colorScheme.error)
                    else -> LazyColumn {
                        if (current.id != rootID) {
                            item {
                                Text("返回上级", Modifier.fillMaxWidth().padding(10.dp).clickable {
                                    val prev = backStack.removeLastOrNull()
                                    current = prev ?: CloudFile(id = rootID, name = "根目录", isFolder = true)
                                }, color = MaterialTheme.colorScheme.primary)
                            }
                        }
                        items(files, key = { it.id }) { f ->
                            Text(f.name, Modifier.fillMaxWidth().padding(10.dp).clickable {
                                backStack.add(current)
                                current = f
                            })
                        }
                        if (files.isEmpty() && !loading) {
                            item { Text("没有子文件夹", Modifier.padding(10.dp),
                                color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = provider.isSignedIn && error == null && !loading,
                onClick = {
                    scope.launch {
                        val lib = LibraryStore.createLibrary(kind, current, nameInput, includeSubfolders = true)
                        LibraryStore.rescanLibrary(lib.id)
                        onDismiss()
                    }
                },
            ) { Text("创建库并扫描") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

// ───────────────────────── 乐库详情 ─────────────────────────

@Composable
fun LibraryDetailScreen(libraryID: String, onClose: () -> Unit) {
    val lib = LibraryStore.library(libraryID) ?: return
    Surface(Modifier.fillMaxSize()) {
        Column {
            Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) { Text("←", style = MaterialTheme.typography.titleLarge) }
                Column(Modifier.weight(1f)) {
                    Text(lib.name, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${lib.tracks.size} 首 · ${lib.albumCount} 张专辑 · ${formatDuration(lib.totalDuration)}",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                IconButton(onClick = {
                    val tracks = lib.tracks
                    if (tracks.isNotEmpty()) PlayerManager.playAt(tracks.map { it.toTrack() }, 0)
                }) {
                    Icon(Icons.Filled.PlayArrow, null, tint = MaterialTheme.colorScheme.primary)
                }
            }
            val tracks = lib.tracks
            LazyColumn {
                itemsIndexed(tracks, key = { _, t -> t.id }) { idx, t ->
                    TrackRow(lib, t, tracks, indexInQueue = idx)
                }
            }
        }
    }
}

// ───────────────────────── 搜索 ─────────────────────────

@Composable
fun SearchTab() {
    var query by remember { mutableStateOf("") }
    val results = remember(query) { LibraryStore.searchTracks(query) }

    Column(Modifier.fillMaxSize()) {
        InputField(query, { query = it },
            label = "搜索歌曲 / 歌手 / 专辑",
            modifier = Modifier.fillMaxWidth().padding(16.dp), singleLine = true)
        LazyColumn {
            itemsIndexed(results, key = { _, r -> r.second.id }) { idx, (lib, t) ->
                TrackRow(lib, t, results.map { it.second }, indexInQueue = idx)
            }
            if (query.isNotBlank() && results.isEmpty()) {
                item {
                    Text("没有匹配的歌曲", Modifier.padding(32.dp),
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

// ───────────────────────── 收藏 ─────────────────────────

@Composable
fun FavoritesTab() {
    val favs = LibraryStore.favorites.toList()
    val all = remember(favs) { favs.mapNotNull { LibraryStore.findTrack(it) } }

    Column(Modifier.fillMaxSize()) {
        Text("收藏", Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
            style = MaterialTheme.typography.headlineMedium)
        if (all.isEmpty()) {
            Text("还没有收藏。播放页点☆收藏，或列表里的红心。",
                Modifier.padding(32.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            LazyColumn {
                itemsIndexed(all, key = { _, r -> r.second.id }) { idx, (lib, t) ->
                    TrackRow(lib, t, all.map { it.second }, indexInQueue = idx)
                }
            }
        }
    }
}
