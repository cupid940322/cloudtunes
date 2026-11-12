package com.gysbs.cloudtunes

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import com.gysbs.cloudtunes.core.CredentialStore
import com.gysbs.cloudtunes.core.LibraryStore
import com.gysbs.cloudtunes.core.SyncService
import com.gysbs.cloudtunes.player.PlaybackService
import com.gysbs.cloudtunes.ui.AppRoot
import com.gysbs.cloudtunes.ui.Theme.CloudTunesTheme

class App : android.app.Application() {
    override fun onCreate() {
        super.onCreate()
        CredentialStore.init(this)
        LibraryStore.init(this)
        SyncService.init(this)
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
        // 预启动播放服务（注册媒体会话）
        startService(Intent(this, PlaybackService::class.java))
        setContent {
            CloudTunesTheme {
                AppRoot()
            }
        }
    }
}
