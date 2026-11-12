package com.gysbs.cloudtunes.core

import android.content.Context

/// 凭证存储（对应 iOS CredentialStore：UserDefaults 前缀 cloudtunes.cred.）
object CredentialStore {
    private lateinit var prefs: android.content.SharedPreferences

    fun init(context: Context) {
        prefs = context.getSharedPreferences("cloudtunes.cred", Context.MODE_PRIVATE)
    }

    fun get(key: String): String? = prefs.getString(key, null)

    fun set(value: String?, key: String = "") {
        prefs.edit().apply {
            if (value.isNullOrEmpty()) remove(key) else putString(key, value)
        }.apply()
    }

    fun remove(key: String) = set(null, key)
}

/// OkHttp 单例。夸克需要一个完全自管 Cookie 的独立 client
object Http {
    val client: okhttp3.OkHttpClient by lazy {
        okhttp3.OkHttpClient.Builder()
            .connectTimeout(java.time.Duration.ofSeconds(20))
            .readTimeout(java.time.Duration.ofSeconds(30))
            .followRedirects(true)
            .build()
    }

    val quarkClient: okhttp3.OkHttpClient by lazy {
        okhttp3.OkHttpClient.Builder()
            .connectTimeout(java.time.Duration.ofSeconds(15))
            .readTimeout(java.time.Duration.ofSeconds(20))
            .followRedirects(false) // 直链丢失 Referer 会 302，自己看得到
            .build()
    }
}

/// 通用网络错误
class CloudError(message: String) : Exception(message) {
    companion object {
        fun network(msg: String) = CloudError("网络错误：$msg")
        fun parse(msg: String) = CloudError(msg)
        fun auth(msg: String) = CloudError(msg)
        fun notSignedIn() = CloudError("未登录")
    }
}

/// 云盘 Provider 协议（对齐 iOS CloudProvider）
interface CloudProvider {
    val kind: CloudKind
    val isSignedIn: Boolean
    val displayName: String?

    suspend fun list(folderID: String): List<CloudFile>
    suspend fun streamURL(file: CloudFile): Pair<String, Map<String, String>>
    fun signOut()
}
