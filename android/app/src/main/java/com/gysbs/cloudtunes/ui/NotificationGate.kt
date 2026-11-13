package com.gysbs.cloudtunes.ui

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner

/// 通知权限引导：Android 13+ 媒体控件属于通知，没有通知权限锁屏上不会出现播放条。
/// 系统授权弹窗关掉之后（下一次 ON_RESUME）如果仍未授权，就用这个对话框说明并给跳转按钮。
@Composable
fun NotificationPermissionGate() {
    if (android.os.Build.VERSION.SDK_INT < 33) return
    val context = LocalContext.current
    val prefs = remember {
        context.getSharedPreferences("cloudtunes.ui", android.content.Context.MODE_PRIVATE)
    }
    var allowed by remember { mutableStateOf(true) }
    var armed by remember { mutableStateOf(false) }
    var dismissed by remember { mutableStateOf(prefs.getBoolean("notif_hint_dismissed", false)) }

    val owner = context as? LifecycleOwner
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                allowed = notificationsAllowed(context)
                armed = true
            }
        }
        owner?.lifecycle?.addObserver(observer)
        onDispose { owner?.lifecycle?.removeObserver(observer) }
    }

    fun dismiss() {
        dismissed = true
        prefs.edit().putBoolean("notif_hint_dismissed", true).apply()
    }

    if (armed && !allowed && !dismissed) {
        AlertDialog(
            onDismissRequest = { dismiss() },
            title = { Text("开启通知才有锁屏播放器") },
            text = {
                Text(
                    "安卓的锁屏 / 通知栏播放控件是系统媒体通知的一部分。没有通知权限，锁屏上就不会出现" +
                        "上一首、播放、下一首。\n\n点「去开启」允许通知即可；打开系统设置返回后会自动生效。"
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    openNotificationSettings(context)
                    dismissed = true
                }) { Text("去开启") }
            },
            dismissButton = { TextButton(onClick = { dismiss() }) { Text("稍后") } },
        )
    }
}
