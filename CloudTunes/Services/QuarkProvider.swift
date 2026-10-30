import Foundation

/// 夸克网盘 Provider —— ⚠️ 实验性。
/// 夸克官方未开放 API，此实现基于社区逆向的 Web 端接口（drive-pc.quark.cn），
/// 需要用户从网页版 F12 复制登录 Cookie。接口随时可能失效或触发风控，仅限自用。
///
/// 播放要点（踩坑记录）：
/// 1. `/1/clouddrive/file/download` 返回的直链**必须**带 Cookie + Referer 去请求，
///    否则 CDN 直接 302 到登录页 / 返回 403，AVPlayer 表现为「点了没反应」。
/// 2. 夸克对网页端非会员有单文件 50MB 下载限制（code=23018），换客户端 UA 才能拿到可用直链，
///    所以这里优先用客户端 UA 取直链，失败再退回网页 UA。
/// 3. 直链有时效（几分钟）且绑定 IP，必须每次播放前重新获取，不能缓存。
final class QuarkProvider: CloudProvider {
    let kind: CloudKind = .quark

    // MARK: - 常量

    private static let apiHost = "https://drive-pc.quark.cn"

    /// 网页版 UA（列目录）
    private static let webUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    /// 客户端 UA：绕过非会员 50MB 限制的关键
    private static let clientUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.56 Chrome/100.0.4896.160 Electron/18.3.5.12 Safari/537.36 Channel/pckk_other_ch"
    private static let referer = "https://pan.quark.cn/"

    // MARK: - 凭证

    private var cookie: String { CredentialStore.get("quark.cookie") ?? "" }

    var isSignedIn: Bool { !cookie.isEmpty }
    var displayName: String? { cookie.isEmpty ? nil : "已导入 Cookie" }

    func setCookie(_ c: String) {
        CredentialStore.set(Self.sanitizeCookie(c), for: "quark.cookie")
    }

    func signOut() { CredentialStore.remove("quark.cookie") }

    /// F12 复制出来的 Cookie 常带换行、「Cookie:」前缀或首尾空格，
    /// 直接塞进 HTTP 头会因非法字符被服务端拒绝（表现为登录态丢失 / 403）。
    static func sanitizeCookie(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "cookie:", options: [.caseInsensitive, .anchored]) {
            s = String(s[r.upperBound...])
        }
        s = s.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 请求

    private func makeRequest(_ path: String,
                             method: String = "GET",
                             query: [String: String] = [:],
                             body: [String: Any]? = nil,
                             userAgent: String = QuarkProvider.webUA) throws -> URLRequest {
        var comps = URLComponents(string: Self.apiHost + path)!
        var items = [URLQueryItem(name: "pr", value: "ucpro"), URLQueryItem(name: "fr", value: "pc")]
        items += query.map { URLQueryItem(name: $0.key, value: $0.value) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(Self.referer, forHTTPHeaderField: "Referer")
        req.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    @discardableResult
    private func call(_ path: String,
                      method: String = "GET",
                      query: [String: String] = [:],
                      body: [String: Any]? = nil,
                      userAgent: String = QuarkProvider.webUA) async throws -> [String: Any] {
        let req = try makeRequest(path, method: method, query: query, body: body, userAgent: userAgent)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CloudError.network("无响应") }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.network("HTTP \(http.statusCode) \(String(data: data.prefix(120), encoding: .utf8) ?? "")")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.parse("响应非 JSON")
        }
        let status = (obj["status"] as? Int) ?? 200
        if status != 200 {
            throw CloudError.network(Self.describe(obj))
        }
        return obj
    }

    /// 把夸克的错误码翻译成人话（用户看得懂才知道该怎么办）
    static func describe(_ obj: [String: Any]) -> String {
        let status = (obj["status"] as? Int) ?? -1
        let code = (obj["code"] as? Int) ?? 0
        let msg = (obj["message"] as? String) ?? ""
        var hint = ""
        switch code {
        case 31001, 31000, 31002:
            hint = " → Cookie 已失效，请重新从网页版复制完整 Cookie"
        case 23018:
            hint = " → 非会员单文件 50MB 下载限制，换客户端 UA 或改用会员账号"
        case 41004, 41006:
            hint = " → 文件不存在或已被删除"
        default:
            if status == 401 { hint = " → 未登录 / Cookie 失效" }
        }
        return "status=\(status) code=\(code) \(msg)\(hint)"
    }

    // MARK: - 目录

    /// folderID: 根目录为 "0"
    func list(folderID: String) async throws -> [CloudFile] {
        let pdir = folderID.isEmpty ? "0" : folderID
        var result: [CloudFile] = []
        var page = 1
        var total = Int.max
        while page <= 20 && result.count < total {
            let r = try await call("/1/clouddrive/file/sort", query: [
                "pdir_fid": pdir,
                "_page": String(page),
                "_size": "100",
                "fetch_total": "1",
                "sort_field": "file_type",
                "sort_order": "asc",
            ])
            guard let data = r["data"] as? [String: Any] else { break }
            let list = (data["list"] as? [[String: Any]]) ?? []
            if list.isEmpty { break }
            if let meta = data["metadata"] as? [String: Any], let t = meta["_total"] as? Int { total = t }
            result += list.map(Self.file(from:))
            if result.count >= total { break }
            if list.count < 100 { break }
            page += 1
        }
        return result
    }

    private static func file(from item: [String: Any]) -> CloudFile {
        let type = (item["file_type"] as? Int) ?? -1
        let isDir = (item["dir"] as? Bool) ?? (type == 0)
        return CloudFile(
            id: item["fid"] as? String ?? "",
            name: item["file_name"] as? String ?? "",
            size: (item["size"] as? NSNumber)?.int64Value ?? 0,
            isFolder: isDir,
            modifiedAt: nil,
            extra: [:])
    }

    // MARK: - 直链

    func streamURL(file: CloudFile) async throws -> (url: URL, headers: [String: String]) {
        guard !cookie.isEmpty else { throw CloudError.notSignedIn }

        var candidates: [String] = []
        var lastMessage = "接口未返回 download_url"

        // 先客户端 UA，再网页 UA
        for ua in [Self.clientUA, Self.webUA] {
            do {
                let r = try await call("/1/clouddrive/file/download",
                                       method: "POST",
                                       body: ["fids": [file.id]],
                                       userAgent: ua)
                let urls = Self.extractURLs(r)
                if !urls.isEmpty { candidates = urls; break }
                lastMessage = "接口未返回 download_url（返回结构：\(Self.brief(r))）"
            } catch {
                lastMessage = error.localizedDescription
            }
        }

        guard let first = candidates.first, let url = Self.makeURL(first) else {
            throw CloudError.parse("取夸克直链失败：\(lastMessage)")
        }

        return (url, Self.mediaHeaders(cookie: cookie))
    }

    /// 直链请求头：三者缺一不可，缺 Referer 会被 302 到登录页
    private static func mediaHeaders(cookie: String) -> [String: String] {
        [
            "Cookie": cookie,
            "User-Agent": clientUA,
            "Referer": referer,
            "Accept": "*/*",
            "Accept-Language": "zh-CN,zh;q=0.9",
        ]
    }

    /// 兼容几种不同的返回结构
    private static func extractURLs(_ obj: [String: Any]) -> [String] {
        var out: [String] = []
        func push(_ v: Any?) {
            if let s = v as? String, s.hasPrefix("http"), !out.contains(s) { out.append(s) }
        }
        if let data = obj["data"] as? [String: Any] {
            if let arr = data["data"] as? [[String: Any]] {
                for item in arr {
                    push(item["download_url"])
                    push(item["download_url_2"])
                }
            }
            push(data["download_url"])
        }
        if let arr = obj["data"] as? [[String: Any]] {
            for item in arr {
                push(item["download_url"])
                push(item["download_url_2"])
            }
        }
        return out
    }

    /// 文件名里带中文/空格时 `URL(string:)` 会返回 nil，这里做一次百分号编码兜底
    static func makeURL(_ s: String) -> URL? {
        if let u = URL(string: s) { return u }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/?#[]@!$&'()*+,;=%")
        if let encoded = s.addingPercentEncoding(withAllowedCharacters: allowed), let u = URL(string: encoded) {
            return u
        }
        return nil
    }

    private static func brief(_ obj: [String: Any]) -> String {
        if let data = obj["data"] {
            let text = String(describing: data)
            return String(text.prefix(160))
        }
        return "空"
    }

    // MARK: - 自检（给用户排查用，出问题时把这段发我）

    func selfTest() async -> String {
        var out: [String] = []
        out.append("Cookie 长度：\(cookie.count)")
        guard !cookie.isEmpty else {
            out.append("未导入 Cookie")
            return out.joined(separator: "\n")
        }
        do {
            let files = try await list(folderID: "0")
            out.append("列目录成功：根目录 \(files.count) 项")
        } catch {
            out.append("列目录失败：\(error.localizedDescription)")
        }
        guard let audio = await firstAudio(folderID: "0", depth: 0) else {
            out.append("根目录两层内没找到音频文件")
            return out.joined(separator: "\n")
        }
        out.append("测试文件：\(audio.name)（\(max(1, audio.size / 1024)) KB）")
        do {
            let (url, headers) = try await streamURL(file: audio)
            out.append("直链域名：\(url.host ?? "-")")
            let result = await QuarkProbe.run(url, headers: headers)
            out.append("直链探测：\(result)")
        } catch {
            out.append("取直链失败：\(error.localizedDescription)")
        }
        return out.joined(separator: "\n")
    }

    private func firstAudio(folderID: String, depth: Int) async -> CloudFile? {
        guard depth <= 2, let files = try? await list(folderID: folderID) else { return nil }
        if let hit = files.first(where: { !$0.isFolder && MusicScanner.isAudioFile($0.name) }) {
            return hit
        }
        for folder in files.filter({ $0.isFolder }).prefix(3) {
            if let hit = await firstAudio(folderID: folder.id, depth: depth + 1) { return hit }
        }
        return nil
    }
}

/// 只读取 HTTP 状态码/内容类型，收到响应头就掐断，不会把整首歌拉下来
final class QuarkProbe: NSObject, URLSessionDataDelegate {
    private var statusText = ""
    private var finished = false
    private var continuation: CheckedContinuation<String, Never>?
    private var session: URLSession?

    static func run(_ url: URL, headers: [String: String]) async -> String {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let probe = QuarkProbe()
        return await probe.start(req)
    }

    private func start(_ req: URLRequest) async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            continuation = c
            let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            session = s
            s.dataTask(with: req).resume()
        }
    }

    private func finish(_ text: String) {
        guard !finished else { return }
        finished = true
        session?.invalidateAndCancel()
        session = nil
        continuation?.resume(returning: text)
        continuation = nil
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        let type = response.mimeType ?? "未知类型"
        let len = response.expectedContentLength
        let size = len > 0 ? "\(len / 1024) KB" : "大小未知"
        statusText = "HTTP \(code) · \(type) · \(size)"
        completionHandler(.cancel)
        finish(statusText)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if statusText.isEmpty {
            finish("失败：\(error?.localizedDescription ?? "无响应")")
        } else {
            finish(statusText)
        }
    }
}
