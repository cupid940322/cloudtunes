import Foundation

/// 直链播放失败时的本地缓存兜底。
///
/// 有些网盘（尤其夸克）的直链对请求头极其敏感：AVPlayer 发出的请求一旦少了 Cookie/Referer
/// 就会被 CDN 拒绝，但用 URLSession 带完整请求头是能正常下载的。
/// 所以播放失败时这里把文件拉到本地缓存再播——能播总比一直转圈强。
enum StreamCache {
    static let maxBytes: Int64 = 800 * 1024 * 1024

    /// 独立会话：关闭系统 Cookie 自动管理，避免 HTTPCookieStorage 里的旧 Cookie
    /// 干扰手动设置的 Cookie 头（夸克直链对 Cookie 极敏感）
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 60
        return URLSession(configuration: cfg)
    }()

    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("StreamCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func cacheFileName(forKey key: String, source fileName: String) -> String {
        let safe = key.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let base = String(safe.prefix(72))
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    static func existing(key: String, source fileName: String) -> URL? {
        let url = directory.appendingPathComponent(cacheFileName(forKey: key, source: fileName))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attrs: [FileAttributeKey: Any] = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return size > 0 ? url : nil
    }

    /// 下载到本地缓存（命中缓存直接返回），失败抛出带 HTTP 状态的错误。
    /// - Parameter onProgress: 0…1 的进度回调（后台线程），未知总长度时不回调
    static func localCopy(of url: URL,
                          headers: [String: String],
                          key: String,
                          source fileName: String,
                          onProgress: ((Double) -> Void)? = nil) async throws -> URL {
        if let hit = existing(key: key, source: fileName) { return hit }

        var req = URLRequest(url: url)
        // 无损文件动辄几十上百 MB，单请求超时放宽，避免大文件卡在 30 秒上
        req.timeoutInterval = 60
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        let dest = directory.appendingPathComponent(cacheFileName(forKey: key, source: fileName))
        let part = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)

        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CloudError.network("无响应") }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.network("直链返回 HTTP \(http.statusCode)（Cookie 可能已过期，或该文件需要会员权限）")
        }

        guard FileManager.default.createFile(atPath: part.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: part.path) else {
            throw CloudError.network("无法写入缓存文件")
        }

        let total = http.expectedContentLength
        var received: Int64 = 0
        var lastReport: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)

        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= chunkSize {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if let onProgress, total > 0, received - lastReport >= total / 20 {
                        lastReport = received
                        onProgress(min(0.999, Double(received) / Double(total)))
                    }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: part)
            throw error
        }

        guard received > 0 else {
            try? FileManager.default.removeItem(at: part)
            throw CloudError.network("下载为空，直链可能已失效")
        }

        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: part, to: dest)
        onProgress?(1)
        trim()
        return dest
    }

    private static let chunkSize = 1 << 20

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
