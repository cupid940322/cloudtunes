import Foundation

/// 锁屏歌词：把系统播放控件里显示的那两行文字换成歌词。
///
/// 为什么不用「实时活动」：那是媒体控件**下方**另起一张卡片，而用户要的是
/// 控件本身那个区域滚动。锁屏播放器是系统绘制的，第三方 App 唯一能控制的
/// 是喂给 `MPNowPlayingInfoCenter` 的那几个字段，它们对应控件的固定位置：
///
///   第一行  ← MPMediaItemPropertyTitle
///   第二行  ← MPMediaItemPropertyArtist（有 AlbumTitle 时显示成 "Artist — Album"）
///
/// 所以这里的做法是：第一行放当前这句歌词，第二行放「歌名 — 歌手」。
/// 换一句就重写一次 nowPlayingInfo，锁屏上看到的效果就是歌词在原地滚动。
enum LockScreenLyrics {

    private static let key = "cloudtunes.lockLyrics.enabled"

    /// 用户可在「我的 → 播放」里关掉（关掉后锁屏恢复显示歌名 / 歌手）
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// 当前这一句 + 下一句
    static func lines(_ all: [LyricLine], at time: TimeInterval) -> (current: String, next: String) {
        guard let idx = activeIndex(all, at: time) else { return ("", "") }
        let current = all.indices.contains(idx) ? all[idx].text : ""
        let next = all.indices.contains(idx + 1) ? all[idx + 1].text : ""
        return (current, next)
    }

    /// 与播放页用的是同一套判断（0.25 秒提前量），两边显示的永远是同一句
    static func activeIndex(_ lines: [LyricLine], at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        let limit = time + 0.25
        var result: Int?
        for (i, line) in lines.enumerated() where line.time >= 0 && line.time <= limit {
            result = i
        }
        return result
    }
}
