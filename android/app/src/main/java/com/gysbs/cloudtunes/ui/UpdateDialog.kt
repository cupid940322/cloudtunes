package com.gysbs.cloudtunes.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.gysbs.cloudtunes.core.UpdateCenter
import kotlinx.coroutines.launch

/// 全局更新弹窗（放在 AppRoot / TVApp 里一次即可）
@Composable
fun UpdateDialogs() {
    val state by UpdateCenter.state
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    when (val s = state) {
        is UpdateCenter.State.Available -> {
            val info = s.info
            AlertDialog(
                onDismissRequest = { UpdateCenter.dismiss() },
                title = { Text("发现新版本 v${info.versionName}") },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            if (info.size > 0) "${(info.size / 1048576.0).let { "%.1f".format(it) }} MB · 直接覆盖安装，数据不丢"
                            else "直接覆盖安装，数据不丢",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Text(info.notes, style = MaterialTheme.typography.bodyMedium)
                    }
                },
                confirmButton = {
                    Button(onClick = {
                        scope.launch {
                            val file = UpdateCenter.download(context, info)
                            if (file != null) UpdateCenter.install(context, file, info)
                        }
                    }) { Text("立即更新") }
                },
                dismissButton = {
                    TextButton(onClick = { UpdateCenter.dismiss() }) { Text("稍后") }
                },
            )
        }

        is UpdateCenter.State.Downloading -> {
            AlertDialog(
                onDismissRequest = { /* 下载中不让关，避免下载协程被取消 */ },
                title = { Text("正在下载更新") },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        LinearProgressIndicator(
                            progress = { s.progress },
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Text("${(s.progress * 100).toInt()}%", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                },
                confirmButton = {},
            )
        }

        is UpdateCenter.State.Ready -> {
            AlertDialog(
                onDismissRequest = { UpdateCenter.dismiss() },
                title = { Text("安装包已下载") },
                text = { Text("点击「立即安装」，系统会弹出安装确认（首次需允许「安装未知应用」）。") },
                confirmButton = {
                    Button(onClick = { UpdateCenter.install(context, s.file, s.info) }) { Text("立即安装") }
                },
                dismissButton = {
                    TextButton(onClick = { UpdateCenter.dismiss() }) { Text("稍后") }
                },
            )
        }

        is UpdateCenter.State.Failed -> {
            AlertDialog(
                onDismissRequest = { UpdateCenter.dismiss() },
                title = { Text("更新未完成") },
                text = { Text(s.message) },
                confirmButton = {
                    TextButton(onClick = { UpdateCenter.dismiss() }) { Text("知道了") }
                },
            )
        }

        UpdateCenter.State.UpToDate -> {
            AlertDialog(
                onDismissRequest = { UpdateCenter.dismiss() },
                title = { Text("已是最新版本") },
                text = {
                    Text("当前版本 v${UpdateCenter.currentVersionName(context)}",
                        style = MaterialTheme.typography.bodyMedium)
                },
                confirmButton = {
                    TextButton(onClick = { UpdateCenter.dismiss() }) { Text("好的") }
                },
            )
        }

        else -> Unit
    }
}

/// 「我的」页的版本更新卡片
@Composable
fun UpdateCard() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val state by UpdateCenter.state
    val checking = state is UpdateCenter.State.Checking

    Card {
        Row(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("版本更新", style = MaterialTheme.typography.titleMedium)
                Text(
                    "当前版本 v${UpdateCenter.currentVersionName(context)}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Button(
                enabled = !checking,
                onClick = { scope.launch { UpdateCenter.check(context, force = true) } },
            ) { Text(if (checking) "检查中…" else "检查更新") }
        }
    }
}
