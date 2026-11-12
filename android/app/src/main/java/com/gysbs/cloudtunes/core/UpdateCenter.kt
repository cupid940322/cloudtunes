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

/// 软件内更新。两条通道：
/// ① 光鸭云盘（国内直连，不受网络限制）——把自己的安装包丢进光鸭根目录或 CloudTunes 文件夹，
///    文件名形如 cloudtunes-phone-1.0.16.apk / cloudtunes-tv-1.0.16.apk；
/// ② GitHub（仓库里的 update/android-latest.json + 多镜像，或 Releases 兜底）。
/// 手机版与 TV 版共用；版本号/包名从 PackageManager 读，避免共享代码引用各模块的 BuildConfig。
object UpdateCenter {

    private const val REPO = "cupid940322/cloudtunes"
    private const val TAG_PREFIX = "app-android-"
    private const val PROXY = "https://gh-proxy.com/"

    // 更新清单（CI 每次发版提交到 main）：国内可达镜像按序尝试（2026-11 实测存活）
    private val MANIFEST_MIRRORS = listOf(
        "https://gh-proxy.com/https://raw.githubusercontent.com/$REPO/main/update/android-latest.json",
        "https://ghproxy.net/https://raw.githubusercontent.com/$REPO/main/update/android-latest.json",
        "https://ghfast.top/https://raw.githubusercontent.com/$REPO/main/update/android-latest.json",
        "https://gcore.jsdelivr.net/gh/$REPO@main/update/android-latest.json",
        "https://testingcf.jsdelivr.net/gh/$REPO@main/update/android-latest.json",
        "https://raw.githubusercontent.com/$REPO/main/update/android-latest.json",
    )

    /// 光鸭里用来放安装包的文件夹名（根目录下），没有这个文件夹就读根目录
    private val UPDATE_FOLDER_NAMES = setOf("cloudtunes", "cloudtunes-update", "cloudtunes_update", "update", "updates", "更新")

    /// 安装包命名约定：cloudtunes-phone-1.0.16.apk / cloudtunes-tv-1.0.16.apk
    private val APK_NAME = Regex("""cloudtunes-(phone|tv)[-_ ]?v?(\d+(?:[._]\d+)*)\.apk""", RegexOption.IGNORE_CASE)

    /// 下载页（浏览器直连 github.com，最后的兜底出口）
    const val RELEASES_PAGE = "https://github.com/cupid940322/cloudtunes/releases/latest"

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
        /// 光鸭云盘里的 fileId（非空表示从光鸭取包）
        val guangyaFileID: String? = null,
        val guangyaName: String? = null,
        /// 展示用：本次更新来自哪个通道
        val source: String = "GitHub",
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

    /// 最近一次检查的通道诊断信息（失败时展示给用户）
    var lastDiagnostics: String = ""
        private set

    // ── 本地信息 ──

    private fun currentVersionCode(context: Context): Int = try {
        val pm = context.packageManager
        if (Build.VERSION.SDK_INT >= 28) pm.getPackageInfo(context.packageName, 0).longVersionCode.toInt()
        else @Suppress("DEPRECATION") pm.getPackageInfo(context.packageName, 0).versionCode
    } catch (e: Exception) {
        0
    }

    fun currentVersionName(context: Context): String = try {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "-"
    } catch (e: Exception) {
        "-"
    }

    private fun isTv(context: Context): Boolean = context.packageName.endsWith(".tv")

    private fun prefs(context: Context) =
        context.getSharedPreferences("cloudtunes.update", Context.MODE_PRIVATE)

    /// 光鸭更新源是否可用（已登录才谈得上）
    fun guangyaReady(): Boolean = GuangyaProvider.isSignedIn

    // ── 检查更新 ──

    /// force=false 时 24 小时内只查一次（避免每次开 App 都打接口）
    suspend fun check(context: Context, force: Boolean = true): UpdateInfo? {
        val p = prefs(context)
        if (!force) {
            val last = p.getLong("lastCheck", 0L)
            if (System.currentTimeMillis() - last < 24 * 3600_000L) return null
        }
        state.value = State.Checking
        val diags = mutableListOf<String>()

        // ① 光鸭云盘：国内直连，优先
        val (gyInfo, gyDiag) = findGuangyaUpdate(context)
        if (gyInfo != null) {
            p.edit().putLong("lastCheck", System.currentTimeMillis()).apply()
            lastDiagnostics = gyDiag
            state.value = State.Available(gyInfo)
            return gyInfo
        }
        diags += gyDiag

        // ② 仓库里的更新清单（镜像多、国内可达，不依赖 Releases API）
        val (manifest, manifestDiag) = fetchManifest(isTv(context))
        if (manifest != null) {
            p.edit().putLong("lastCheck", System.currentTimeMillis()).apply()
            lastDiagnostics = gyDiag
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
        diags += manifestDiag

        // ③ 兜底：GitHub Releases API
        val releases = fetchReleases()
        if (releases == null) {
            lastDiagnostics = diags.joinToString("；")
            // 静默检查失败不出声，手动检查才提示
            state.value = if (force) State.Failed(
                "所有更新通道都连不上（${diags.joinToString("；")}）。\n" +
                    "提示：把安装包放进光鸭云盘后，登录光鸭即可用它检查更新；\n" +
                    "也可以点下面的按钮用浏览器打开下载页：\n$RELEASES_PAGE"
            ) else State.Idle
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
                if (nameIsTv == wantTv) {
                    apk = a; break
                }
            }
            if (apk == null) continue
            if (best == null || code > best!!.first) best = Triple(code, rel, apk)
        }

        val candidate = best ?: run {
            lastDiagnostics = diags.joinToString("；")
            state.value = if (force) State.Failed("没有找到可用的安装包") else State.Idle
            return null
        }
        val (code, rel, asset) = candidate
        val current = currentVersionCode(context)

        val notes = rel.optString("body").trim().ifEmpty { "本次更新包含问题修复与体验优化。" }
        val info = UpdateInfo(
            versionCode = code,
            versionName = "1.0.$code",
            notes = notes,
            apkUrl = asset.optString("browser_download_url"),
            size = asset.optLong("size", 0L),
            source = "GitHub Releases",
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

    /// 在光鸭云盘里找安装包（根目录 + 一层 CloudTunes 目录）。
    /// 返回 (新版本信息, 诊断说明)；没有更新或不可用时 info 为 null。
    private suspend fun findGuangyaUpdate(context: Context): Pair<UpdateInfo?, String> {
        if (!GuangyaProvider.isSignedIn) return null to "光鸭：未登录"
        val wantTv = isTv(context)
        val files = mutableListOf<CloudFile>()
        try {
            // 根目录只取第一页（可能有几千个文件）；命名文件夹里再全量找一遍
            val root = GuangyaProvider.listFirstPage("", pageSize = 100)
            files += root.filter { !it.isFolder }
            for (dir in root.filter { it.isFolder && UPDATE_FOLDER_NAMES.contains(it.name.lowercase()) }) {
                val inner = (try {
                    GuangyaProvider.list(dir.id)
                } catch (t: Throwable) {
                    null
                }) ?: continue
                files += inner.filter { !it.isFolder }
            }
        } catch (t: Throwable) {
            return null to "光鸭：${t.message?.take(40) ?: "列表失败"}"
        }

        var best: Pair<Int, CloudFile>? = null
        for (f in files) {
            val code = versionCodeOf(f.name, wantTv) ?: continue
            if (best == null || code > best!!.first) best = code to f
        }
        val tag = if (wantTv) "tv" else "phone"
        val hit = best ?: return null to "光鸭：没找到 cloudtunes-$tag-版本号.apk"

        val current = currentVersionCode(context)
        if (hit.first <= current) return null to "光鸭：已是最新（v1.0.${hit.first}）"
        val info = UpdateInfo(
            versionCode = hit.first,
            versionName = "1.0.${hit.first}",
            notes = "更新包来自你的光鸭云盘：国内直连，不依赖 GitHub，也不受网络限制。",
            apkUrl = "",
            size = hit.second.size,
            guangyaFileID = hit.second.id,
            guangyaName = hit.second.name,
            source = "光鸭云盘",
        )
        return info to "光鸭：发现 v1.0.${hit.first}"
    }

    /// 从文件名解析版本号（1.0.16 → 16）
    private fun versionCodeOf(fileName: String, wantTv: Boolean): Int? {
        val m = APK_NAME.find(fileName) ?: return null
        val isTvName = m.groupValues[1].equals("tv", true)
        if (isTvName != wantTv) return null
        return m.groupValues[2].split('.', '_').lastOrNull()?.toIntOrNull()
    }

    /// 拉取仓库更新清单（多镜像）。返回 (结果, 各镜像失败原因摘要)
    private fun fetchManifest(isTv: Boolean): Pair<UpdateInfo?, String> {
        val errors = mutableListOf<String>()
        for (url in MANIFEST_MIRRORS) {
            val host = runCatching { java.net.URI(url).host }.getOrDefault("镜像")
            try {
                val req = Request.Builder().url(url)
                    .header("User-Agent", "CloudTunes-Android")
                    .get().build()
                fastClient.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) {
                        errors += "$host(HTTP ${resp.code})"
                        return@use
                    }
                    val text = resp.body?.string() ?: run { errors += "$host(空响应)"; return@use }
                    val obj = JSONObject(text)
                    val code = obj.optInt("versionCode", 0)
                    if (code <= 0) {
                        errors += "$host(内容异常)"; return@use
                    }
                    val apkUrl = (if (isTv) obj.optString("apkTv") else obj.optString("apkPhone"))
                        .takeIf { it.isNotEmpty() } ?: run { errors += "$host(缺APK地址)"; return@use }
                    return UpdateInfo(
                        versionCode = code,
                        versionName = obj.optString("versionName").ifEmpty { "1.0.$code" },
                        notes = obj.optString("notes").ifEmpty { "本次更新包含问题修复与体验优化。" },
                        apkUrl = apkUrl,
                        size = 0L,
                        source = "GitHub 镜像",
                    ) to "已通过 $host 获取"
                }
            } catch (e: Exception) {
                errors += "$host(${e.message?.take(36) ?: "连接失败"})"
            }
        }
        return null to "GitHub：${errors.joinToString("；")}"
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
        val file = File(context.cacheDir, "update-${info.versionCode}-${if (info.guangyaFileID != null) "gy" else "gh"}.apk")
        if (file.exists() && (info.size <= 0 || file.length() == info.size)) {
            state.value = State.Ready(file, info)
            return@withContext file
        }
        // 清掉旧包
        context.cacheDir.listFiles()?.forEach { f ->
            if (f.name.startsWith("update-") && f.name.endsWith(".apk") && f.name != file.name) f.delete()
        }

        // 候选地址：光鸭直链优先（国内 CDN），再走 GitHub 镜像
        val sources = mutableListOf<String>()
        if (info.guangyaFileID != null) {
            val url = try {
                GuangyaProvider.streamURL(
                    CloudFile(id = info.guangyaFileID, name = info.guangyaName ?: "", size = info.size, isFolder = false)
                ).first
            } catch (t: Throwable) {
                CrashLog.record("光鸭取更新包直链", t)
                null
            }
            if (!url.isNullOrEmpty()) sources += url
        }
        if (info.apkUrl.isNotEmpty()) {
            sources += PROXY + info.apkUrl
            sources += info.apkUrl
        }

        for (url in sources.distinct()) {
            val ok = try {
                fetchTo(url, file, info.size)
            } catch (t: Throwable) {
                CrashLog.record("下载更新包 $url", t)
                false
            }
            if (ok) {
                state.value = State.Ready(file, info)
                return@withContext file
            }
        }
        state.value = State.Failed(
            "下载失败：${if (info.guangyaFileID != null) "光鸭" else "GitHub"} 通道都没成功，请检查网络后重试"
        )
        null
    }

    /// 单地址下载到 file（先写 .part 再改名），成功返回 true
    private fun fetchTo(url: String, file: File, sizeHint: Long): Boolean {
        val req = Request.Builder().url(url)
            .header("User-Agent", "CloudTunes-Android")
            .get().build()
        return Http.client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) return@use false
            val body = resp.body ?: return@use false
            val total = if (body.contentLength() > 0) body.contentLength() else sizeHint
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
            if (tmp.length() <= 0L) {
                tmp.delete()
                return@use false
            }
            if (file.exists()) file.delete()
            tmp.renameTo(file)
        }
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
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${context.packageName}")
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
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
            CrashLog.record("拉起安装器", e)
            state.value = State.Failed("安装包已下载：\n${file.absolutePath}\n请用文件管理器打开安装")
        }
    }

    fun dismiss() {
        state.value = State.Idle
    }
}
