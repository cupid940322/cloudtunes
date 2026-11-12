package com.gysbs.cloudtunes.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.gysbs.cloudtunes.core.UpdateCenter
import kotlinx.coroutines.launch

/// 用系统浏览器打开链接；没有浏览器的设备（TV）返回 false
internal fun openUrl(context: android.content.Context, url: String): Boolean = try {
    context.startActivity(
        android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))
            .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
    )
    true
} catch (e: Exception) {
    false
}

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
                            (if (info.size > 0) "${(info.size / 1048576.0).let { "%.1f".format(it) }} MB · " else "") +
                                "来源：${info.source} · 直接覆盖安装，数据不丢",
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
                    Button(onClick = {
                        // TV 等无浏览器设备打不开时保留弹窗（消息里已有网址）
                        if (openUrl(context, com.gysbs.cloudtunes.core.UpdateCenter.RELEASES_PAGE)) {
                            UpdateCenter.dismiss()
                        }
                    }) { Text("用浏览器打开下载页") }
                },
                dismissButton = {
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
    // 光鸭登录状态变了要重算这一行
    val gyReady = UpdateCenter.guangyaReady()

    Card {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                Modifier.fillMaxWidth(),
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
            Text(
                if (gyReady) "更新源：光鸭云盘优先（国内直连，不受网络限制），失败自动改走 GitHub"
                else "更新源：GitHub（登录光鸭云盘后，可把安装包放进光鸭根目录或 CloudTunes 文件夹，改用国内直连）",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
