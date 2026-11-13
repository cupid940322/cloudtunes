package com.gysbs.cloudtunes

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import com.gysbs.cloudtunes.core.CrashLog
import com.gysbs.cloudtunes.core.CredentialStore
import com.gysbs.cloudtunes.core.LibraryStore
import com.gysbs.cloudtunes.core.SyncService
import com.gysbs.cloudtunes.player.PlaybackService
import com.gysbs.cloudtunes.ui.AppRoot
import com.gysbs.cloudtunes.ui.Theme.CloudTunesTheme

class App : android.app.Application() {

    companion object {
        /// 全局 Application 引用（手机/TV 共用此类）；给无 Context 的单例对象（如歌词缓存）用
        @Volatile
        var instance: App? = null
            private set
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        // 最先装崩溃日志，后面任何初始化异常都能留下堆栈
        CrashLog.install(this)
        try {
            CredentialStore.init(this)
            LibraryStore.init(this)
            SyncService.init(this)
        } catch (t: Throwable) {
            CrashLog.record("App 初始化", t)
        }
    }
}

class MainActivity : ComponentActivity() {

    private val notifPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33) {
            notifPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        // 预启动播放服务（注册媒体会话）；个别 ROM 会拒绝后台起服务，失败也不该让 App 挂掉
        try {
            startService(Intent(this, PlaybackService::class.java))
        } catch (t: Throwable) {
            CrashLog.record("启动播放服务", t)
        }
        setContent {
            CloudTunesTheme {
                // 通知权限引导叠在最上层：没有通知权限时锁屏/通知栏不会出现播放控件
                androidx.compose.foundation.layout.Box {
                    AppRoot()
                    com.gysbs.cloudtunes.ui.NotificationPermissionGate()
                }
            }
        }
    }
}
