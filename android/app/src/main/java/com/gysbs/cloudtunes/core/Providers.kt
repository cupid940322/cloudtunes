package com.gysbs.cloudtunes.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.json.JSONObject
import java.security.MessageDigest

// ════════════════════════════════════════════════════════════
// 光鸭云盘（短信三步登录；同接口 500ms 限速）
// ════════════════════════════════════════════════════════════
object GuangyaProvider : CloudProvider {

    override val kind = CloudKind.GUANGYA
    private const val ACCOUNT_BASE = "https://account.guangyapan.com"
    private const val API_BASE = "https://api.guangyapan.com"
    private const val DEFAULT_CLIENT_ID = "aMe-8VSlkrbQXpUR"
    private val UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Mobile Safari/537.36"

    private var clientID: String
        get() = CredentialStore.get("guangya.clientID")?.takeIf { it.isNotEmpty() } ?: DEFAULT_CLIENT_ID
        set(v) = CredentialStore.set(v, "guangya.clientID")

    private var accessToken: String?
        get() = CredentialStore.get("guangya.accessToken")
        set(v) = CredentialStore.set(v, "guangya.accessToken")

    private var refreshToken: String?
        get() = CredentialStore.get("guangya.refreshToken")
        set(v) = CredentialStore.set(v, "guangya.refreshToken")

    override val isSignedIn: Boolean get() = accessToken != null
    override val displayName: String? get() = CredentialStore.get("guangya.phone")

    // 每次安装生成一个稳定设备 ID（32 位十六进制）
    private val deviceID: String by lazy {
        CredentialStore.get("guangya.deviceID") ?: run {
            val d = randomHex(32)
            CredentialStore.set(d, "guangya.deviceID")
            d
        }
    }

    private fun randomHex(n: Int): String {
        val bytes = ByteArray(n / 2)
        java.security.SecureRandom().nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }

    private fun traceparent(): String = "00-${randomHex(32)}-${randomHex(16)}-01"

    private fun accountHeaders(auth: Boolean = false, captcha: String? = null): Map<String, String> = buildMap {
        put("Accept", "*/*")
        put("Content-Type", "application/json")
        put("X-Device-Model", "chrome%2F147.0.0.0")
        put("X-Device-Name", "PC-Chrome")
        put("X-Device-Sign", "wdi10.$deviceID${randomHex(32)}")
        put("X-Net-Work-Type", "NONE")
        put("X-OS-Version", "Linux armv8l")
        put("X-Platform-Version", "1")
        put("X-Protocol-Version", "301")
        put("X-Provider-Name", "NONE")
        put("X-SDK-Version", "9.0.2")
        put("X-Client-Id", clientID)
        put("X-Client-Version", "0.0.1")
        put("X-Device-Id", deviceID)
        put("Origin", "https://www.guangyapan.com")
        put("Referer", "https://www.guangyapan.com/")
        put("User-Agent", UA)
        put("Traceparent", traceparent())
        if (auth) accessToken?.let { put("Authorization", "Bearer $it") }
        captcha?.let { put("X-Captcha-Token", it) }
    }

    private fun apiHeaders(): Map<String, String> = buildMap {
        put("Accept", "application/json, text/plain, */*")
        put("Content-Type", "application/json")
        put("Did", deviceID)
        put("Dt", "4")
        put("Origin", "https://www.guangyapan.com")
        put("Referer", "https://www.guangyapan.com/")
        put("User-Agent", UA)
        put("Traceparent", traceparent())
        accessToken?.let { put("Authorization", "Bearer $it") }
    }

    private var lastRequestAt = 0L

    private suspend fun post(url: String, body: JSONObject, headers: Map<String, String>): JSONObject =
        withContext(Dispatchers.IO) {
            val wait = 500 - (System.currentTimeMillis() - lastRequestAt)
            if (wait > 0) delay(wait.toLong())
            lastRequestAt = System.currentTimeMillis()
            val req = Request.Builder().url(url).post(body.toString().toRequestBody("application/json".toMediaType()))
                .apply { headers.forEach { (k, v) -> header(k, v) } }.build()
            Http.client.newCall(req).execute().use { resp ->
                val text = resp.body?.string() ?: ""
                if (!resp.isSuccessful) throw CloudError.network("HTTP ${resp.code}: $text")
                JSONObject(text)
            }
        }

    private fun opt(obj: JSONObject, key: String): String? {
        if (obj.has(key) && !obj.isNull(key)) return obj.optString(key).takeIf { it.isNotEmpty() }
        val data = obj.optJSONObject("data") ?: return null
        return data.optString(key).takeIf { it.isNotEmpty() && !data.isNull(key) }
    }

    /// 第 1 步：captcha init + 发送短信验证码，返回 verification_id
    suspend fun sendCode(phoneE164: String): String {
        val initBody = JSONObject()
            .put("client_id", clientID)
            .put("action", "POST:/v1/auth/verification")
            .put("device_id", deviceID)
            .put("meta", JSONObject().put("phone_number", phoneE164))
        val initResp = post("$ACCOUNT_BASE/v1/shield/captcha/init", initBody, accountHeaders())
        val captchaToken = opt(initResp, "captcha_token")
            ?: throw CloudError.parse("安全验证初始化失败：$initResp")
        val r = post(
            "$ACCOUNT_BASE/v1/auth/verification",
            JSONObject().put("phone_number", phoneE164).put("target", "ANY").put("client_id", clientID),
            accountHeaders(captcha = captchaToken),
        )
        val vid = opt(r, "verification_id") ?: throw CloudError.parse("发送验证码失败: $r")
        CredentialStore.set(phoneE164, "guangya.phone")
        return vid
    }

    /// 第 2+3 步：校验验证码 + signin
    suspend fun signIn(phoneE164: String, verificationID: String, code: String) {
        val vt = opt(
            post(
                "$ACCOUNT_BASE/v1/auth/verification/verify",
                JSONObject().put("verification_id", verificationID).put("verification_code", code).put("client_id", clientID),
                accountHeaders(),
            ),
            "verification_token",
        ) ?: throw CloudError.parse("验证码校验失败")

        val r = post(
            "$ACCOUNT_BASE/v1/auth/signin",
            JSONObject()
                .put("verification_code", code)
                .put("verification_token", vt)
                .put("username", phoneE164)
                .put("client_id", clientID),
            accountHeaders(),
        )
        val at = opt(r, "access_token") ?: throw CloudError.parse("登录失败: $r")
        accessToken = at
        refreshToken = opt(r, "refresh_token")
    }

    override fun signOut() {
        accessToken = null
        refreshToken = null
        CredentialStore.remove("guangya.phone")
    }

    private suspend fun refresh() {
        val rt = refreshToken ?: throw CloudError.notSignedIn()
        val headers = accountHeaders().toMutableMap().apply { put("X-Action", "401") }
        val r = post(
            "$ACCOUNT_BASE/v1/auth/token",
            JSONObject().put("client_id", clientID).put("grant_type", "refresh_token").put("refresh_token", rt),
            headers,
        )
        val at = r.optString("access_token").takeIf { it.isNotEmpty() }
            ?: throw CloudError.auth("token 刷新失败: $r")
        accessToken = at
        r.optString("refresh_token").takeIf { it.isNotEmpty() }?.let { refreshToken = it }
    }

    private suspend fun apiPost(path: String, body: JSONObject): JSONObject {
        return try {
            post("$API_BASE$path", body, apiHeaders())
        } catch (e: CloudError) {
            if (e.message?.contains("401") == true) {
                refresh()
                post("$API_BASE$path", body, apiHeaders())
            } else throw e
        }
    }

    override suspend fun list(folderID: String): List<CloudFile> = withContext(Dispatchers.IO) {
        val files = mutableListOf<CloudFile>()
        var page = 0
        val pageSize = 100
        while (true) {
            val r = apiPost("/userres/v1/file/get_file_list", JSONObject()
                .put("parentId", folderID)
                .put("page", page)
                .put("pageSize", pageSize)
                .put("orderBy", 3)
                .put("sortType", 1))
            val data = r.optJSONObject("data") ?: break
            val list = data.optJSONArray("list") ?: break
            for (i in 0 until list.length()) {
                val item = list.getJSONObject(i)
                files += CloudFile(
                    id = item.optString("fileId"),
                    name = item.optString("fileName"),
                    size = item.optLong("fileSize"),
                    isFolder = item.optInt("resType") == 2,
                    modifiedAt = item.optLong("utime", 0).takeIf { it > 0 }
                        ?.let { java.time.Instant.ofEpochSecond(it) },
                )
            }
            val total = data.optInt("total", 0)
            page++
            if (list.length() < pageSize || files.size >= total || page >= 50) break
        }
        files
    }

    override suspend fun streamURL(file: CloudFile): Pair<String, Map<String, String>> {
        val r = apiPost("/nd.bizuserres.s/v1/get_res_download_url", JSONObject().put("fileId", file.id))
        val data = r.optJSONObject("data") ?: throw CloudError.parse("取直链失败: $r")
        val url = data.optString("signedURL").ifEmpty { data.optString("downloadURL") }
        if (url.isEmpty()) throw CloudError.parse("空下载直链")
        return url to emptyMap()
    }
}

// ════════════════════════════════════════════════════════════
// 夸克网盘（Cookie 登录；__puus 会话刷新是命门）
// ════════════════════════════════════════════════════════════
object QuarkProvider : CloudProvider {

    override val kind = CloudKind.QUARK

    private val apiBases = listOf(
        "https://drive.quark.cn/1/clouddrive",
        "https://drive-pc.quark.cn/1/clouddrive",
    )
    const val UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
    private const val REFERER = "https://pan.quark.cn"

    var cookie: String
        get() = CredentialStore.get("quark.cookie") ?: ""
        set(c) = CredentialStore.set(sanitizeCookie(c), "quark.cookie")

    override val isSignedIn: Boolean get() = cookie.isNotEmpty()
    override val displayName: String? get() = if (cookie.isEmpty()) null else "已导入 Cookie"

    override fun signOut() = CredentialStore.remove("quark.cookie")

    fun sanitizeCookie(raw: String): String {
        var s = raw.trim()
        if (s.lowercase().startsWith("cookie:")) s = s.substring(7).trim()
        s = s.replace("\r", " ").replace("\n", " ").replace("\t", " ")
        while (s.contains("  ")) s = s.replace("  ", " ")
        return s.trim()
    }

    /// 每次响应后检查 Set-Cookie，更新 __puus/__pus 到本地
    private fun refreshCookieFromResponse(setCookieHeaders: List<String>) {
        if (setCookieHeaders.isEmpty()) return
        val joined = setCookieHeaders.joinToString(", ")
        var updated = cookie
        var changed = false
        for (name in listOf("__puus", "__pus")) {
            val v = cookieValueNamed(name, joined) ?: continue
            val next = setCookieValue(updated, name, v)
            if (next != updated) { updated = next; changed = true }
        }
        if (changed) CredentialStore.set(updated, "quark.cookie")
    }

    fun cookieValueNamed(name: String, text: String): String? {
        val re = Regex("(?:^|[,;\\s])${Regex.escape(name)}=([^;,\\s]+)")
        return re.find(text)?.groupValues?.get(1)?.takeIf { it.isNotEmpty() }
    }

    fun setCookieValue(cookie: String, name: String, value: String): String {
        val re = Regex("(?:^|;\\s*)${Regex.escape(name)}=[^;]*")
        return if (re.containsMatchIn(cookie)) re.replace(cookie, "$name=$value")
        else if (cookie.isEmpty()) "$name=$value" else "$cookie; $name=$value"
    }

    private suspend fun call(path: String, method: String = "GET", query: Map<String, String> = emptyMap(), body: JSONObject? = null): JSONObject =
        withContext(Dispatchers.IO) {
            var lastError: Exception = CloudError.network("未发送请求")
            for (base in apiBases) {
                try {
                    val url = "$base$path".toHttpUrl().newBuilder()
                        .addQueryParameter("pr", "ucpro")
                        .addQueryParameter("fr", "pc")
                        .apply { query.forEach { (k, v) -> addQueryParameter(k, v) } }
                        .build()
                    val builder = Request.Builder().url(url)
                        .header("Cookie", cookie)
                        .header("User-Agent", UA)
                        .header("Referer", REFERER)
                        .header("Accept", "application/json, text/plain, */*")
                    if (body != null) {
                        builder.post(body.toString().toRequestBody("application/json;charset=UTF-8".toMediaType()))
                    } else {
                        builder.get()
                    }
                    val resp = Http.quarkClient.newCall(builder.build()).execute()
                    val setCookies = (resp.headers("set-cookie"))
                    val text = resp.body?.string() ?: ""
                    refreshCookieFromResponse(setCookies)
                    if (!resp.isSuccessful) throw CloudError.network("HTTP ${resp.code} ${text.take(160)}")
                    val obj = JSONObject(text)
                    val status = obj.optInt("status", 200)
                    if (status != 200) throw CloudError.network(describe(obj))
                    return@withContext obj
                } catch (e: Exception) {
                    lastError = e
                    val msg = e.message ?: ""
                    // 业务错误（夸克返回的 status/message）换域名也没用，直接抛
                    if (msg.startsWith("status=")) throw e
                    continue
                }
            }
            throw lastError
        }

    fun describe(obj: JSONObject): String {
        val status = obj.optInt("status", -1)
        val code = obj.optInt("code", 0)
        val msg = obj.optString("message")
        val hint = when (code) {
            31001, 31000, 31002 -> " → Cookie 已失效，请重新从网页版复制完整 Cookie"
            23018 -> " → 非会员单文件 50MB 下载限制"
            41004, 41006 -> " → 文件不存在或已被删除"
            else -> if (status == 401) " → 未登录 / Cookie 失效" else ""
        }
        return "status=$status code=$code $msg$hint"
    }

    override suspend fun list(folderID: String): List<CloudFile> = withContext(Dispatchers.IO) {
        val pdir = folderID.ifEmpty { "0" }
        val result = mutableListOf<CloudFile>()
        var page = 1
        var total = Int.MAX_VALUE
        while (page <= 20 && result.size < total) {
            val r = call("/file/sort", query = mapOf(
                "pdir_fid" to pdir,
                "_page" to page.toString(),
                "_size" to "100",
                "_fetch_total" to "1",
                "fetch_all_file" to "1",
                "fetch_risk_file_name" to "1",
                "_sort" to "file_type:asc,file_name:asc",
            ))
            val data = r.optJSONObject("data") ?: break
            val list = data.optJSONArray("list") ?: break
            if (list.length() == 0) break
            total = data.optJSONObject("metadata")?.optInt("_total", Int.MAX_VALUE) ?: total
            for (i in 0 until list.length()) {
                val item = list.getJSONObject(i)
                val type = item.optInt("file_type", -1)
                val isDir = item.optBoolean("dir", type == 0)
                result += CloudFile(
                    id = item.optString("fid"),
                    name = item.optString("file_name"),
                    size = item.optLong("size"),
                    isFolder = isDir,
                )
            }
            if (result.size >= total || list.length() < 100) break
            page++
        }
        result
    }

    override suspend fun streamURL(file: CloudFile): Pair<String, Map<String, String>> {
        if (cookie.isEmpty()) throw CloudError.notSignedIn()
        val r = call("/file/download", method = "POST", body = JSONObject().put("fids", org.json.JSONArray().put(file.id)))
        val urls = extractURLs(r)
        val first = urls.firstOrNull() ?: throw CloudError.parse("取夸克直链失败：接口未返回 download_url")
        return makeURL(first) to mediaHeaders()
    }

    private fun mediaHeaders() = mapOf(
        "Cookie" to cookie,   // 注意：此刻的 cookie 刚被 Set-Cookie 刷新过，__puus 是最新的
        "User-Agent" to UA,
        "Referer" to REFERER,
        "Accept" to "*/*",
    )

    private fun extractURLs(obj: JSONObject): List<String> {
        val out = mutableListOf<String>()
        fun push(v: Any?) { if (v is String && v.startsWith("http") && v !in out) out += v }
        val data = obj.opt("data")
        when (data) {
            is JSONObject -> {
                val arr = data.optJSONArray("data")
                if (arr != null) for (i in 0 until arr.length()) {
                    push(arr.getJSONObject(i).optString("download_url"))
                    push(arr.getJSONObject(i).optString("download_url_2"))
                }
                push(data.optString("download_url").ifEmpty { null })
            }
            is org.json.JSONArray -> for (i in 0 until data.length()) {
                push(data.getJSONObject(i).optString("download_url"))
                push(data.getJSONObject(i).optString("download_url_2"))
            }
        }
        return out
    }

    fun makeURL(s: String): String {
        // 中文/空格兜底百分号编码
        return if (s.toHttpUrlOrNull() != null) s
        else s.split("/").joinToString("/") { part ->
            java.net.URLEncoder.encode(part, "UTF-8").replace("+", "%20")
        }.replace("https%3A%2F%2F", "https://")
    }
}

// ════════════════════════════════════════════════════════════
// 百度网盘（官方开放平台 OAuth oob）
// ════════════════════════════════════════════════════════════
object BaiduProvider : CloudProvider {

    override val kind = CloudKind.BAIDU

    private var appKey: String get() = CredentialStore.get("baidu.appKey") ?: ""
    private var secretKey: String get() = CredentialStore.get("baidu.secretKey") ?: ""
    private var accessToken: String?
        get() = CredentialStore.get("baidu.accessToken")
        set(v) = CredentialStore.set(v, "baidu.accessToken")

    override val isSignedIn: Boolean get() = accessToken != null
    override val displayName: String? get() = CredentialStore.get("baidu.display")

    fun setAppKey(k: String) = CredentialStore.set(k, "baidu.appKey")
    fun setSecretKey(k: String) = CredentialStore.set(k, "baidu.secretKey")

    fun authorizeURL(): String {
        val key = appKey
        return "https://openapi.baidu.com/oauth/2.0/authorize" +
            "?response_type=code&client_id=$key&redirect_uri=oob&scope=basic,netdisk&display=mobile"
    }

    suspend fun exchangeCode(code: String) = withContext(Dispatchers.IO) {
        if (appKey.isEmpty() || secretKey.isEmpty()) throw CloudError.auth("请先在设置中填写 AppKey / SecretKey")
        val url = "https://openapi.baidu.com/oauth/2.0/token" +
            "?grant_type=authorization_code&code=$code&client_id=$appKey&client_secret=$secretKey&redirect_uri=oob"
        val req = Request.Builder().url(url).get().build()
        Http.client.newCall(req).execute().use { resp ->
            val text = resp.body?.string() ?: ""
            if (!resp.isSuccessful) throw CloudError.network("HTTP ${resp.code}")
            val token = JSONObject(text).optString("access_token").takeIf { it.isNotEmpty() }
                ?: throw CloudError.parse("授权码换 token 失败: $text")
            accessToken = token
            CredentialStore.set("已授权", "baidu.display")
        }
    }

    override fun signOut() {
        accessToken = null
        CredentialStore.remove("baidu.display")
    }

    private suspend fun request(url: String): JSONObject = withContext(Dispatchers.IO) {
        val token = accessToken ?: throw CloudError.notSignedIn()
        val req = Request.Builder()
            .url(url.toHttpUrl().newBuilder().addQueryParameter("access_token", token).build())
            .header("User-Agent", "pan.baidu.com")
            .get().build()
        Http.client.newCall(req).execute().use { resp ->
            val text = resp.body?.string() ?: ""
            if (!resp.isSuccessful) throw CloudError.network("HTTP ${resp.code}: $text")
            val obj = JSONObject(text)
            val errno = obj.optInt("errno", 0)
            if (errno != 0) throw CloudError.network("百度 errno=$errno")
            obj
        }
    }

    override suspend fun list(folderID: String): List<CloudFile> {
        val dir = folderID.ifEmpty { "/" }
        val url = "https://pan.baidu.com/rest/2.0/xpan/file?method=list&dir=" +
            java.net.URLEncoder.encode(dir, "UTF-8")
        val r = request(url)
        val list = r.optJSONArray("list") ?: return emptyList()
        return (0 until list.length()).map { i ->
            val item = list.getJSONObject(i)
            CloudFile(
                id = item.optString("path"),
                name = item.optString("server_filename"),
                size = item.optLong("size"),
                isFolder = item.optInt("isdir") == 1,
                extra = mapOf("fs_id" to item.optLong("fs_id").toString()),
            )
        }
    }

    override suspend fun streamURL(file: CloudFile): Pair<String, Map<String, String>> {
        val fsid = file.extra["fs_id"] ?: throw CloudError.parse("缺少 fs_id")
        val token = accessToken ?: throw CloudError.notSignedIn()
        val r = request("https://pan.baidu.com/rest/2.0/xpan/file?method=filemetas&fsids=%5B$fsid%5D&dlink=1")
        val list = r.optJSONArray("list") ?: throw CloudError.parse("未取得 dlink")
        val dlink = list.getJSONObject(0).optString("dlink").takeIf { it.isNotEmpty() }
            ?: throw CloudError.parse("未取得 dlink")
        val url = dlink.toHttpUrl().newBuilder().addQueryParameter("access_token", token).build()
        return url.toString() to mapOf("User-Agent" to "pan.baidu.com")
    }
}
