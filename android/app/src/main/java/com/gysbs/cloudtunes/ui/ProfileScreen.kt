package com.gysbs.cloudtunes.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.gysbs.cloudtunes.core.BaiduProvider
import com.gysbs.cloudtunes.core.CloudKind
import com.gysbs.cloudtunes.core.GitHubAccount
import com.gysbs.cloudtunes.core.GuangyaProvider
import com.gysbs.cloudtunes.core.QuarkProvider
import com.gysbs.cloudtunes.core.SyncService
import kotlinx.coroutines.launch

@Composable
fun ProfileTab() {
    val scroll = rememberScrollState()
    Column(Modifier.fillMaxSize().verticalScroll(scroll).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {

        Text("我的", style = MaterialTheme.typography.headlineMedium)
        SyncStatusLine()

        UpdateCard()

        GitHubCard()

        ProviderCard(
            kind = CloudKind.GUANGYA,
            signedIn = GuangyaProvider.isSignedIn,
            displayName = GuangyaProvider.displayName,
        ) {
            GuangyaLoginDialog(onDismiss = it)
        }
        ProviderCard(
            kind = CloudKind.QUARK,
            signedIn = QuarkProvider.isSignedIn,
            displayName = QuarkProvider.displayName,
        ) {
            QuarkLoginDialog(onDismiss = it)
        }
        ProviderCard(
            kind = CloudKind.BAIDU,
            signedIn = BaiduProvider.isSignedIn,
            displayName = BaiduProvider.displayName,
        ) {
            BaiduLoginDialog(onDismiss = it)
        }

        Spacer(Modifier.height(20.dp))
        Text("iOS / 安卓 / 小程序 数据互通", style = MaterialTheme.typography.titleSmall)
        Text(
            "登录同一个 GitHub 账号即可同步音乐库元数据、封面、收藏、播放记录和继续播放。安卓与 iOS 端数据结构完全一致。",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun GitHubCard() {
    val scope = rememberCoroutineScope()
    val signedIn = GitHubAccount.isSignedIn
    var token by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val status by SyncService.status.collectAsStateWithLifecycle()

    Card {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("GitHub 同步", style = MaterialTheme.typography.titleMedium)
            if (signedIn) {
                Text("已登录：${GitHubAccount.cachedLogin}", style = MaterialTheme.typography.bodyMedium)
                when (val s = status) {
                    is SyncService.Status.Failed -> Text("上次失败：${s.message}",
                        color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                    is SyncService.Status.Done -> Text("上次同步 ${s.tracks} 首", style = MaterialTheme.typography.bodySmall)
                    is SyncService.Status.Syncing -> Text("同步中…", style = MaterialTheme.typography.bodySmall)
                    else -> {}
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilledTonalButton(enabled = !busy && !status.isRunning, onClick = {
                        busy = true
                        scope.launch {
                            try { SyncService.sync("手动同步") } finally { busy = false }
                        }
                    }) { Text(if (busy || status.isRunning) "同步中…" else "手动同步") }
                    OutlinedButton(onClick = {
                        SyncService.signOut()
                    }) { Text("退出登录") }
                }
            } else {
                Text("需要一个 GitHub 个人访问令牌（经典 token，勾选 gist 权限即可）：Settings → Developer settings → Personal access tokens",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedTextField(token, { token = it }, label = { Text("GitHub Token") },
                    modifier = Modifier.fillMaxWidth(), singleLine = true)
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                Button(enabled = token.isNotBlank() && !busy, onClick = {
                    busy = true
                    scope.launch {
                        try {
                            SyncService.signIn(token)
                            SyncService.sync("登录后同步")
                        } catch (e: Exception) {
                            error = e.message
                        }
                        busy = false
                    }
                }) { Text(if (busy) "验证中…" else "登录并同步") }
            }
        }
    }
}

@Composable
private fun ProviderCard(
    kind: CloudKind,
    signedIn: Boolean,
    displayName: String?,
    dialog: @Composable (onDismiss: () -> Unit) -> Unit,
) {
    var showLogin by remember { mutableStateOf(false) }
    Card {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Text(kind.label, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                Text(
                    if (signedIn) "已登录${displayName?.let { "：$it" } ?: ""}" else "未登录",
                    style = MaterialTheme.typography.bodySmall,
                    color = if (signedIn) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { showLogin = true }) { Text(if (signedIn) "重新登录" else "登录") }
                if (signedIn) {
                    OutlinedButton(onClick = {
                        when (kind) {
                            CloudKind.GUANGYA -> GuangyaProvider.signOut()
                            CloudKind.QUARK -> QuarkProvider.signOut()
                            CloudKind.BAIDU -> BaiduProvider.signOut()
                        }
                    }) { Text("退出") }
                }
            }
        }
    }
    if (showLogin) dialog { showLogin = false }
}

@Composable
private fun GuangyaLoginDialog(onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var phone by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var vid by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("登录光鸭云盘（短信验证码）") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(phone, { phone = it }, label = { Text("手机号（+86 前缀，如 +8613800138000）") },
                    singleLine = true, modifier = Modifier.fillMaxWidth())
                if (vid != null) {
                    OutlinedTextField(code, { code = it }, label = { Text("短信验证码") },
                        singleLine = true, modifier = Modifier.fillMaxWidth())
                }
                if (busy && vid == null) Text("验证码发送中…")
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            }
        },
        confirmButton = {
            Button(enabled = !busy && phone.isNotBlank() && (vid == null || code.isNotBlank()),
                onClick = {
                    busy = true
                    scope.launch {
                        try {
                            if (vid == null) {
                                vid = GuangyaProvider.sendCode(phone.trim())
                            } else {
                                GuangyaProvider.signIn(phone.trim(), vid!!, code.trim())
                                onDismiss()
                            }
                        } catch (e: Exception) {
                            error = e.message
                        }
                        busy = false
                    }
                }) { Text(if (vid == null) "发送验证码" else "登录") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

@Composable
private fun QuarkLoginDialog(onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var cookie by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("登录夸克网盘（粘贴 Cookie）") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("电脑浏览器打开 pan.quark.cn 并登录 → F12 → 网络 → 任一请求 → 复制完整 Cookie 粘到下面。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedTextField(cookie, { cookie = it }, label = { Text("Cookie（含 __puus）") },
                    modifier = Modifier.fillMaxWidth(), minLines = 3)
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                if (busy) Text("验证中…")
            }
        },
        confirmButton = {
            Button(enabled = cookie.isNotBlank() && !busy, onClick = {
                busy = true
                scope.launch {
                    try {
                        QuarkProvider.cookie = cookie
                        QuarkProvider.list("0") // 验证 + 顺带刷新 __puus
                        onDismiss()
                    } catch (e: Exception) {
                        error = e.message
                    }
                    busy = false
                }
            }) { Text("导入并验证") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

@Composable
private fun BaiduLoginDialog(onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var appKey by remember { mutableStateOf(com.gysbs.cloudtunes.core.CredentialStore.get("baidu.appKey") ?: "") }
    var secretKey by remember { mutableStateOf(com.gysbs.cloudtunes.core.CredentialStore.get("baidu.secretKey") ?: "") }
    var code by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("登录百度网盘（开放平台）") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(appKey, { appKey = it }, label = { Text("AppKey") },
                    singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(secretKey, { secretKey = it }, label = { Text("SecretKey") },
                    singleLine = true, modifier = Modifier.fillMaxWidth())
                Button(onClick = {
                    BaiduProvider.setAppKey(appKey.trim())
                    BaiduProvider.setSecretKey(secretKey.trim())
                    val url = BaiduProvider.authorizeURL()
                    try {
                        context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW,
                            android.net.Uri.parse(url)))
                    } catch (e: Exception) {
                        error = "无法打开浏览器：$url"
                    }
                }) { Text("① 打开授权页（浏览器）") }
                Text("② 授权后在页面显示授权码，粘贴到下面", style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(code, { code = it }, label = { Text("授权码") },
                    singleLine = true, modifier = Modifier.fillMaxWidth())
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                if (busy) Text("换取 token 中…")
            }
        },
        confirmButton = {
            Button(enabled = code.isNotBlank() && !busy, onClick = {
                busy = true
                scope.launch {
                    try {
                        BaiduProvider.setAppKey(appKey.trim())
                        BaiduProvider.setSecretKey(secretKey.trim())
                        BaiduProvider.exchangeCode(code.trim())
                        onDismiss()
                    } catch (e: Exception) {
                        error = e.message
                    }
                    busy = false
                }
            }) { Text("③ 换取 token") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}
