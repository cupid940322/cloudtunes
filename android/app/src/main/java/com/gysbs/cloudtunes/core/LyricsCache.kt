package com.gysbs.cloudtunes.core

/// 本地歌词缓存（SharedPreferences，LRU 上限 60 条）。
/// 用途：①手动从 QQ/酷狗/LRCLIB 匹配的歌词没有「ID」可存，只能存文本；
/// ②自动抓到的歌词也缓存一份，重进播放页不用再搜一轮。
object LyricsCache {

    private const val PREFS = "cloudtunes.lyrics"
    private const val KEY_LRU = "lru"
    private const val CAP = 60

    private fun prefs(): android.content.SharedPreferences? =
        com.gysbs.cloudtunes.App.instance
            ?.getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)

    fun get(trackID: String): String? {
        val p = prefs() ?: return null
        val text = p.getString("t:$trackID", null) ?: return null
        touchLru(p, trackID)
        return text
    }

    fun put(trackID: String, text: String) {
        val p = prefs() ?: return
        p.edit().putString("t:$trackID", text).apply()
        touchLru(p, trackID)
    }

    fun remove(trackID: String) {
        val p = prefs() ?: return
        p.edit().remove("t:$trackID").apply()
        val lru = p.getStringSet(KEY_LRU, emptySet())?.toMutableSet() ?: return
        lru.remove(trackID)
        p.edit().putStringSet(KEY_LRU, lru).apply()
    }

    private fun touchLru(p: android.content.SharedPreferences, trackID: String) {
        val lru = p.getStringSet(KEY_LRU, emptySet())?.toMutableSet() ?: return
        lru.remove(trackID)
        lru.add(trackID)
        if (lru.size > CAP) {
            // 超限就先踢最早进来的（StringSet 无序，够用了；缓存被踢最多重新搜一轮）
            val excess = lru.size - CAP
            lru.sorted().take(excess).forEach { victim ->
                lru.remove(victim)
                p.edit().remove("t:$victim").apply()
            }
        }
        p.edit().putStringSet(KEY_LRU, lru).apply()
    }
}
