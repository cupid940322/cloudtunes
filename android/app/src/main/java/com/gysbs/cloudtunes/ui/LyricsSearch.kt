package com.gysbs.cloudtunes.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import com.gysbs.cloudtunes.core.Scraper
import kotlinx.coroutines.launch

// ── 手动搜索/匹配歌词弹窗（手机端与 TV 端共用）──
// 打开时自动用预填关键词搜一次；改词可重搜；点选结果把 neteaseID 写回曲目。
// 结果行做了 focusable + 焦点高亮，TV 遥控器也能上下选中。

private val LyricsSearchBg = Color(0xFF26252E)
private val LyricsSearchAccent = Color(0xFFE85D5D)

@Composable
fun LyricsSearchDialog(
    initialQuery: String,
    onPick: (Scraper.SongInfo) -> Unit,
    onDismiss: () -> Unit,
) {
    var query by remember { mutableStateOf(initialQuery) }
    var results by remember { mutableStateOf<List<Scraper.SongInfo>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val firstRowFocus = remember { FocusRequester() }

    fun doSearch(kw: String) {
        val trimmed = kw.trim()
        if (trimmed.isEmpty()) return
        scope.launch {
            searching = true
            results = try {
                Scraper.neteaseSearch(trimmed, limit = 12)
            } catch (e: Exception) {
                emptyList()
            }
            searching = false
        }
    }

    // 打开即自动搜一次（预填「歌手 歌名」）
    LaunchedEffect(Unit) { if (initialQuery.isNotBlank()) doSearch(initialQuery) }
    // TV 上把焦点落到第一个结果，遥控器直接按 OK 就能选
    LaunchedEffect(results) { if (results.isNotEmpty()) runCatching { firstRowFocus.requestFocus() } }

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(18.dp),
            color = LyricsSearchBg,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(18.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("搜索歌词", color = Color.White, fontSize = 18.sp,
                        style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = onDismiss) { Text("关闭", color = Color.White.copy(alpha = 0.6f)) }
                }

                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = query,
                        onValueChange = { query = it },
                        modifier = Modifier.weight(1f),
                        singleLine = true,
                        placeholder = { Text("歌手 歌名", color = Color.White.copy(alpha = 0.35f), fontSize = 14.sp) },
                        textStyle = androidx.compose.ui.text.TextStyle(color = Color.White, fontSize = 15.sp),
                    )
                    IconButton(onClick = { doSearch(query) }) {
                        Icon(Icons.Filled.Search, "搜索", tint = LyricsSearchAccent)
                    }
                }

                Spacer(Modifier.height(8.dp))

                when {
                    searching -> Row(
                        Modifier.fillMaxWidth().padding(vertical = 28.dp),
                        horizontalArrangement = Arrangement.Center,
                    ) { CircularProgressIndicator(color = LyricsSearchAccent, modifier = Modifier.size(28.dp)) }

                    results.isEmpty() -> Text(
                        "没有找到匹配的歌曲，换个关键词再试",
                        color = Color.White.copy(alpha = 0.45f),
                        fontSize = 14.sp,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )

                    else -> LazyColumn(
                        modifier = Modifier.fillMaxWidth().height(340.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        itemsIndexed(results) { idx, song ->
                            LyricsSearchRow(
                                song = song,
                                focusedBg = Color.White.copy(alpha = 0.12f),
                                autoFocus = idx == 0,
                                focusRequester = firstRowFocus,
                                onClick = { onPick(song) },
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun LyricsSearchRow(
    song: Scraper.SongInfo,
    focusedBg: Color,
    autoFocus: Boolean,
    focusRequester: FocusRequester,
    onClick: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(if (focused) focusedBg else Color.Transparent)
            .onFocusChanged { focused = it.isFocused }
            .then(if (autoFocus) Modifier.focusRequester(focusRequester) else Modifier)
            .focusable()
            .clickable { onClick() }
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                song.title ?: "未知歌曲",
                color = Color.White,
                fontSize = 15.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodyLarge,
            )
            Text(
                listOfNotNull(song.artist, song.album).joinToString(" · ").ifBlank { "未知歌手" },
                color = Color.White.copy(alpha = 0.55f),
                fontSize = 13.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
        Text(
            if (song.source.isBlank()) "网易云" else song.source,
            color = Color.White.copy(alpha = 0.35f),
            fontSize = 11.sp,
        )
    }
}
