import Foundation

/// 直链播放失败时的本地缓存兜底。
///
/// 有些网盘（尤其夸克）的直链对请求头极其敏感：AVPlayer 发出的请求一旦少了 Cookie/Referer
/// 就会被 CDN 拒绝，但用 URLSession 带完整请求头是能正常下载的。
/// 所以播放失败时这里把文件拉到本地缓存再播——能播总比一直转圈强。
enum StreamCache {
    static let maxBytes: Int64 = 800 * 1024 * 1024

    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("StreamCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func fileName(forKey key: String, source fileName: String) -> String {
        let safe = key.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let base = String(safe.prefix(72))
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    static func existing(key: String, source fileName: String) -> URL? {
        let url = directory.appendingPathComponent(fileName(forKey: key, source: fileName))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return size > 0 ? url : nil
    }

    /// 下载到本地缓存（命中缓存直接返回），失败抛出带 HTTP 状态的错误
    static func localCopy(of url: URL,
                          headers: [String: String],
                          key: String,
                          source fileName: String) async throws -> URL {
        if let hit = existing(key: key, source: fileName) { return hit }

        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CloudError.network("无响应") }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.network("直链返回 HTTP \(http.statusCode)（Cookie 可能已过期，或该文件需要会员权限）")
        }
        let dest = directory.appendingPathComponent(fileName(forKey: key, source: fileName))
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        trim()
        return dest
    }

    static var totalSize: Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(Int64(0)) { acc, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return acc + Int64(size)
        }
    }

    static var count: Int {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count) ?? 0
    }

    /// LRU 清理：超过上限时按修改时间从旧到新删
    static func trim(maxBytes: Int64 = StreamCache.maxBytes) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries: [(URL, Int64, Date)] = items.map { url in
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, Int64(v?.fileSize ?? 0), v?.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        guard total > maxBytes else { return }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries {
            if total <= maxBytes { break }
            try? fm.removeItem(at: url)
            total -= size
        }
    }

    static func clear() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        items.forEach { try? fm.removeItem(at: $0) }
    }
}
