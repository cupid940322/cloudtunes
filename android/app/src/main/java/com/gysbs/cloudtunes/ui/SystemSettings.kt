package com.gysbs.cloudtunes.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings

/// 系统设置相关跳转（手机版与自诊断卡共用）

internal fun openNotificationSettings(context: Context) {
    val flags = Intent.FLAG_ACTIVITY_NEW_TASK
    try {
        context.startActivity(
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                .addFlags(flags)
        )
    } catch (t: Throwable) {
        try {
            context.startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:${context.packageName}"),
                ).addFlags(flags)
            )
        } catch (t2: Throwable) {
            // 设置页都打不开就放弃，不影响其他功能
        }
    }
}

internal fun requestIgnoreBatteryOptimization(context: Context) {
    try {
        context.startActivity(
            Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:${context.packageName}"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    } catch (t: Throwable) {
        // 部分 ROM 没有这个页面，忽略
    }
}

internal fun notificationsAllowed(context: Context): Boolean = try {
    context.getSystemService(android.app.NotificationManager::class.java)
        ?.areNotificationsEnabled() ?: true
} catch (t: Throwable) {
    true
}
