package com.gysbs.cloudtunes.core

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.runtime.mutableStateOf
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/// 软件内更新：查 GitHub Releases（tag app-android-<build>）→ 应用内下载 → 调系统安装器。
/// 手机版与 TV 版共用；版本号/包名从 PackageManager 读，避免共享代码引用各模块的 BuildConfig。
object UpdateCenter {

    private const val REPO = "cupid940322/cloudtunes"
    private const val TAG_PREFIX = "app-android-"
    private const val PROXY = "https://gh-proxy.com/"

    // 更新清单（CI 每次发版提交到 main）：国内可达镜像按序尝试
    private val MANIFEST_MIRRORS = listOf(
        "https://gh-proxy.com/https://raw.githubusercontent.com/$REPO/main/update/android-latest.json",
        "https://ghproxy.net/https://raw.githubusercontent.com/$REPO/main/update/android-latest.json",
        "https://raw.githubusercontent.com/$REPO/main/update/android-latest.json",
        "https://cdn.jsdelivr.net/gh/$REPO@main/update/android-latest.json",
        "https://fastly.jsdelivr.net/gh/$REPO@main/update/android-latest.json",
    )

    /// 短超时客户端（多镜像快速切换）
    private val fastClient by lazy {
        okhttp3.OkHttpClient.Builder()
            .connectTimeout(java.time.Duration.ofSeconds(8))
            .readTimeout(java.time.Duration.ofSeconds(10))
            .build()
    }

    data class UpdateInfo(
        val versionCode: Int,
        val versionName: String,
        val notes: String,
        val apkUrl: String,
        val size: Long,
    )

    sealed class State {
        data object Idle : State()
        data object Checking : State()
        data class Available(val info: UpdateInfo) : State()
        data class Downloading(val progress: Float) : State()
        data class Ready(val file: File, val info: UpdateInfo) : State()
        data class Failed(val message: String) : State()
        data object UpToDate : State()
    }

    val state = mutableStateOf<State>(State.Idle)

    // ── 本地信息 ──

    private fun currentVersionCode(context: Context): Int = try {
        val pm = context.packageManager
        if (Build.VERSION.SDK_INT >= 28) pm.getPackageInfo(context.packageName, 0).longVersionCode.toInt()
        else @Suppress("DEPRECATION") pm.getPackageInfo(context.packageName, 0).versionCode
    } catch (e: Exception) { 0 }

    fun currentVersionName(context: Context): String = try {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "-"
    } catch (e: Exception) { "-" }

    private fun isTv(context: Context): Boolean = context.packageName.endsWith(".tv")

    private fun prefs(context: Context) =
        context.getSharedPreferences("cloudtunes.update", Context.MODE_PRIVATE)

    // ── 检查更新 ──

    /// force=false 时 24 小时内只查一次（避免每次开 App 都打 API）
    suspend fun check(context: Context, force: Boolean = true): UpdateInfo? {
        val p = prefs(context)
        if (!force) {
            val last = p.getLong("lastCheck", 0L)
            if (System.currentTimeMillis() - last < 24 * 3600_000L) return null
        }
        state.value = State.Checking

        // ① 首选：仓库里的更新清单（镜像多、国内可达，不依赖 Releases API）
        val manifest = fetchManifest(isTv(context))
        if (manifest != null) {
            p.edit().putLong("lastCheck", System.currentTimeMillis()).apply()
            val current = currentVersionCode(context)
            return if (manifest.versionCode > current) {
                state.value = State.Available(manifest)
                manifest
            } else {
                // 启动静默检查时不弹「已是最新版本」
                state.value = if (force) State.UpToDate else State.Idle
                null
            }
        }

        // ② 兜底：GitHub Releases API
        val releases = fetchReleases()
        if (releases == null) {
            // 静默检查失败不出声，手动检查才提示
            state.value = if (force) State.Failed("检查更新失败：无法连接 GitHub（可稍后再试）") else State.Idle
            return null
        }
        p.edit().putLong("lastCheck", System.currentTimeMillis()).apply()

        // 找 tag 里 build 号最大的一版
        var best: Triple<Int, JSONObject, JSONObject>? = null
        for (i in 0 until releases.length()) {
            val rel = releases.optJSONObject(i) ?: continue
            val tag = rel.optString("tag_name")
            if (!tag.startsWith(TAG_PREFIX)) continue
            val code = tag.removePrefix(TAG_PREFIX).trim().toIntOrNull() ?: continue
            val assets = rel.optJSONArray("assets") ?: continue
            val wantTv = isTv(context)
            var apk: JSONObject? = null
            for (j in 0 until assets.length()) {
                val a = assets.optJSONObject(j) ?: continue
                val name = a.optString("name").lowercase()
                if (!name.endsWith(".apk")) continue
                val nameIsTv = name.contains("tv")
                if (nameIsTv == wantTv) { apk = a; break }
            }
            if (apk == null) continue
            if (best == null || code > best!!.first) best = Triple(code, rel, apk)
        }

        val candidate = best ?: run {
            state.value = if (force) State.Failed("没有找到可用的安装包") else State.Idle
            return null
        }
        val (code, rel, asset) = candidate
        val current = currentVersionCode(context)

        val notes = rel.optString("body").trim().ifEmpty { "本次更新包含问题修复与体验优化。" }
        val versionName = "1.0.$code"
        val info = UpdateInfo(
            versionCode = code,
            versionName = versionName,
            notes = notes,
            apkUrl = asset.optString("browser_download_url"),
            size = asset.optLong("size", 0L),
        )

        return if (code > current) {
            state.value = State.Available(info)
            info
        } else {
            // 启动静默检查时不弹「已是最新版本」
            state.value = if (force) State.UpToDate else State.Idle
            null
        }
    }

    /// 拉取仓库更新清单（多镜像），返回 null 表示全部失败
    private fun fetchManifest(isTv: Boolean): UpdateInfo? {
        for (url in MANIFEST_MIRRORS) {
            try {
                val req = Request.Builder().url(url)
                    .header("User-Agent", "CloudTunes-Android")
                    .get().build()
                fastClient.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) return@use
                    val text = resp.body?.string() ?: return@use
                    val obj = JSONObject(text)
                    val code = obj.optInt("versionCode", 0)
                    if (code <= 0) return@use
                    val apkUrl = (if (isTv) obj.optString("apkTv") else obj.optString("apkPhone"))
                        .takeIf { it.isNotEmpty() } ?: return@use
                    return UpdateInfo(
                        versionCode = code,
                        versionName = obj.optString("versionName").ifEmpty { "1.0.$code" },
                        notes = obj.optString("notes").ifEmpty { "本次更新包含问题修复与体验优化。" },
                        apkUrl = apkUrl,
                        size = 0L,
                    )
                }
            } catch (e: Exception) {
                // 换下一个镜像
            }
        }
        return null
    }

    private fun fetchReleases(): JSONArray? {
        val path = "https://api.github.com/repos/$REPO/releases?per_page=20"
        // 直连优先，失败走加速代理
        for (url in listOf(path, PROXY + path)) {
            try {
                val req = Request.Builder().url(url)
                    .header("Accept", "application/vnd.github+json")
                    .header("User-Agent", "CloudTunes-Android")
                    .get().build()
                Http.client.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) return@use
                    val text = resp.body?.string() ?: return@use
                    return JSONArray(text)
                }
            } catch (e: Exception) {
                // 继续尝试下一个地址
            }
        }
        return null
    }

    // ── 下载 ──

    suspend fun download(context: Context, info: UpdateInfo): File? = withContext(Dispatchers.IO) {
        state.value = State.Downloading(0f)
        val file = File(context.cacheDir, "update-${info.versionCode}.apk")
        if (file.exists() && info.size > 0 && file.length() == info.size) {
            state.value = State.Ready(file, info)
            return@withContext file
        }
        // 清掉旧包
        context.cacheDir.listFiles()?.forEach { f ->
            if (f.name.startsWith("update-") && f.name.endsWith(".apk") && f != file) f.delete()
        }

        val urls = listOf(PROXY + info.apkUrl, info.apkUrl).distinct()
        for (url in urls) {
            try {
                val req = Request.Builder().url(url).get().build()
                Http.client.newCall(req).execute().use { resp ->
                    val body = resp.body ?: return@use
                    if (!resp.isSuccessful) return@use
                    val total = if (body.contentLength() > 0) body.contentLength() else info.size
                    val tmp = File(file.absolutePath + ".part")
                    body.byteStream().use { input ->
                        tmp.outputStream().use { output ->
                            val buf = ByteArray(64 * 1024)
                            var written = 0L
                            while (true) {
                                val n = input.read(buf)
                                if (n <= 0) break
                                output.write(buf, 0, n)
                                written += n
                                if (total > 0) {
                                    state.value = State.Downloading((written.toFloat() / total).coerceIn(0f, 1f))
                                }
                            }
                        }
                    }
                    if (tmp.length() > 0) {
                        if (file.exists()) file.delete()
                        tmp.renameTo(file)
                        state.value = State.Ready(file, info)
                        return@withContext file
                    }
                }
            } catch (e: Exception) {
                // 换下一个地址
            }
        }
        state.value = State.Failed("下载失败，请检查网络后重试")
        null
    }

    // ── 安装 ──

    /// 需要时先引导去开「安装未知应用」权限；已授权则直接拉起系统安装器
    fun install(context: Context, file: File, info: UpdateInfo? = null) {
        if (!file.exists() || file.length() == 0L) {
            state.value = State.Failed("安装包不存在，请重新下载")
            return
        }
        // Android 8+ 需要用户单独授权「安装未知应用」
        if (Build.VERSION.SDK_INT >= 26 && !context.packageManager.canRequestPackageInstalls()) {
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                context.startActivity(intent)
                state.value = State.Failed("请允许「安装未知应用」后回到本页，再点「立即安装」")
            } catch (e: Exception) {
                state.value = State.Failed("安装包已下载：\n${file.absolutePath}\n请用文件管理器打开安装")
            }
            return
        }
        try {
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
        } catch (e: Exception) {
            state.value = State.Failed("安装包已下载：\n${file.absolutePath}\n请用文件管理器打开安装")
        }
    }

    fun dismiss() {
        state.value = State.Idle
    }
}
