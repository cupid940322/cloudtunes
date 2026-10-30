import Foundation

/// 歌词缓存（内存 + 磁盘）。
///
/// 之前每次切歌都要重新走一遍「列云盘目录 → 网易云 → LRCLIB」，
/// 一首歌 3~5 个网络往返，国内网络下要好几秒，所以歌词总是"加载中"。
/// 命中缓存后切歌瞬间就有歌词，退到后台再回来也不会重来一次。
enum LyricsCache {
    private static let lock = NSLock()
    private static var memory: [String: (lines: [LyricLine], note: String)] = [:]
    private static let maxMemory = 60

    /// 稳定的键（FNV-1a，避免 Swift 每次启动随机化的 hashValue 导致缓存穿透）
    static func key(title: String, artist: String?) -> String {
        let raw = "\(title)|\(artist ?? "")".lowercased()
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in raw.utf8 {
            h ^= UInt64(b)
            h = h &* 0x1000_0000_01b3
        }
        return String(h, radix: 16)
    }

    static var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyrics", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func get(_ key: String) -> (lines: [LyricLine], note: String)? {
        lock.lock()
        if let hit = memory[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        // 磁盘兜底
        let url = directory.appendingPathComponent(key + ".lrc")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var note = "歌词已缓存"
        var lines: [LyricLine] = []
        var index = 0
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("#NOTE\t") {
                note = String(raw.dropFirst(6))
                continue
            }
            guard let tab = raw.firstIndex(of: "\t") else { continue }
            let timeText = raw[raw.startIndex..<tab]
            let content = String(raw[raw.index(after: tab)...])
            guard let t = TimeInterval(timeText), !content.isEmpty else { continue }
            lines.append(LyricLine(id: index, time: t, text: content))
            index += 1
        }
        guard !lines.isEmpty else { return nil }
        lock.lock()
        memory[key] = (lines, note)
        lock.unlock()
        return (lines, note)
    }

    static func store(_ lines: [LyricLine], note: String, for key: String) {
        guard !lines.isEmpty else { return }
        lock.lock()
        memory[key] = (lines, note)
        if memory.count > maxMemory { memory.removeAll() }
        lock.unlock()

        var text = "#NOTE\t\(note)\n"
        for line in lines {
            text += String(format: "%.3f", line.time) + "\t" + line.text + "\n"
        }
        let url = directory.appendingPathComponent(key + ".lrc")
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    static var count: Int {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count) ?? 0
    }

    static var totalSize: Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(Int64(0)) { acc, url in
            acc + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    static func clear() {
        lock.lock()
        memory.removeAll()
        lock.unlock()
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        items.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
