package com.gysbs.cloudtunes.core

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/// 崩溃/异常日志：写进应用私有目录，供「我的 → 崩溃日志」查看或复制。
/// 目的：手机不在身边接 adb 时也能拿到堆栈，定位闪退。
object CrashLog {

    private const val TAG = "CloudTunes"
    private const val MAX_BYTES = 256 * 1024L
    private const val FILE_NAME = "crash.log"

    private var logFile: File? = null

    /// 在 Application.onCreate 里调用：接管未捕获异常
    fun install(context: Context) {
        logFile = File(context.filesDir, FILE_NAME)
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            record("未捕获异常 @${thread.name}", error)
            // 交给系统默认处理（该弹「应用已停止」还是弹，不要吞掉）
            previous?.uncaughtException(thread, error)
        }
    }

    fun record(tag: String, error: Throwable) {
        record(tag, Log.getStackTraceString(error))
    }

    fun record(tag: String, text: String) {
        try {
            val f = logFile ?: return
            if (f.exists() && f.length() > MAX_BYTES) f.writeText("")
            val ts = SimpleDateFormat("MM-dd HH:mm:ss", Locale.US).format(Date())
            f.appendText("\n===== $ts  $tag =====\n${text.trim()}\n")
        } catch (t: Throwable) {
            // 记日志本身绝不能再抛
        }
    }

    fun read(): String = try {
        val f = logFile ?: return ""
        if (f.exists()) f.readText().trim().ifEmpty { "" } else ""
    } catch (t: Throwable) {
        ""
    }

    fun clear() {
        try {
            logFile?.takeIf { it.exists() }?.writeText("")
        } catch (t: Throwable) {
            // 忽略
        }
    }

    fun path(): String = logFile?.absolutePath ?: "-"
}
