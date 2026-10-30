import Foundation

/// 夸克网盘 Provider —— ⚠️ 实验性。
/// 夸克官方未开放 API，此实现基于社区逆向的 Web 端接口（对齐 OpenList/alist 的 quark_uc 驱动），
/// 需要用户从网页版 F12 复制登录 Cookie。接口随时可能失效或触发风控，仅限自用。
///
/// 播放要点（踩坑记录，缺一个都可能 403）：
/// 1. **__puus Cookie 会话刷新（最关键）**：夸克每次 API 响应都会 Set-Cookie 一个新的
///    `__puus`，下载直链只认**最新**的那个。把用户粘贴的 Cookie 存死不更新，
///    过一会儿直链就 403——这正是「列目录正常但播放/缓存都失败」的典型原因。
/// 2. 直链请求必须带 Cookie + Referer + 客户端 UA 三件套，缺 Referer 会被 302 到登录页。
/// 3. 客户端 UA（quark-cloud-drive/…Electron/…）可绕过非会员单文件 50MB 下载限制（23018）。
/// 4. 直链有时效（几分钟）且绑定 IP，必须每次播放前重新获取，不能缓存。
final class QuarkProvider: CloudProvider {
    let kind: CloudKind = .quark

    // MARK: - 常量（对齐 OpenList quark_uc 驱动）

    /// API 基址：官方网页端域名在前，社区常用域名兜底
    private static let apiBases = [
        "https://drive.quark.cn/1/clouddrive",
        "https://drive-pc.quark.cn/1/clouddrive",
    ]
    /// 客户端 UA（绕过非会员 50MB 限制）
    private static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
    private static let referer = "https://pan.quark.cn"

    /// 独立会话：关闭系统 Cookie 自动管理，请求头完全由我们自己控制
    /// （否则 HTTPCookieStorage 里的旧 Cookie 可能覆盖/混入手动 Cookie 头）
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

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

    // MARK: - __puus 会话刷新（OpenList 同款机制）

    /// 每次 API 响应后调用：响应里的 Set-Cookie 若带新的 __puus/__pus，
    /// 立刻更新到本地存储。下载直链只认最新 __puus。
    private func refreshCookie(from response: HTTPURLResponse) {
        let setCookies = response.allHeaderFields.compactMap { key, value -> String? in
            guard let k = key as? String,
                  k.caseInsensitiveCompare("set-cookie") == .orderedSame else { return nil }
            return value as? String
        }.joined(separator: ", ")
        guard !setCookies.isEmpty else { return }
        var updated = cookie
        var changed = false
        for name in ["__puus", "__pus"] {
            if let v = Self.cookieValue(named: name, in: setCookies) {
                let next = Self.setCookieValue(updated, name: name, value: v)
                if next != updated { updated = next; changed = true }
            }
        }
        if changed {
            CredentialStore.set(updated, for: "quark.cookie")
        }
    }

    static func cookieValue(named name: String, in text: String) -> String? {
        guard let r = text.range(of: "\(NSRegularExpression.escapedPattern(for: name))=([^;,\\s]+)",
                                 options: .regularExpression) else { return nil }
        let pair = String(text[r])
        guard let eq = pair.firstIndex(of: "=") else { return nil }
        let v = String(pair[pair.index(after: eq)...])
        return v.isEmpty ? nil : v
    }

    static func setCookieValue(_ cookie: String, name: String, value: String) -> String {
        let pattern = "(?:^|;\\s*)\(NSRegularExpression.escapedPattern(for: name))=[^;]*"
        if let r = cookie.range(of: pattern, options: .regularExpression) {
            return cookie.replacingCharacters(in: r, with: "\(name)=\(value)")
        }
        return cookie.isEmpty ? "\(name)=\(value)" : "\(cookie); \(name)=\(value)"
    }

    // MARK: - 请求

    private func makeRequest(base: String,
                             path: String,
                             method: String,
                             query: [String: String],
                             body: [String: Any]?) throws -> URLRequest {
        var comps = URLComponents(string: base + path)!
        var items = [URLQueryItem(name: "pr", value: "ucpro"), URLQueryItem(name: "fr", value: "pc")]
        items += query.map { URLQueryItem(name: $0.key, value: $0.value) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        req.setValue(Self.referer, forHTTPHeaderField: "Referer")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    @discardableResult
    private func call(_ path: String,
                      method: String = "GET",
                      query: [String: String] = [:],
                      body: [String: Any]? = nil) async throws -> [String: Any] {
        var lastError: Error = CloudError.network("未发送请求")
        // 传输层失败 / HTTP >= 400 时换备用域名再试一次；业务错误（如 23018）不重试
        for base in Self.apiBases {
            do {
                let req = try makeRequest(base: base, path: path, method: method, query: query, body: body)
                let (data, resp) = try await Self.session.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw CloudError.network("无响应") }
                refreshCookie(from: http)
                guard (200..<300).contains(http.statusCode) else {
                    throw CloudError.network("HTTP \(http.statusCode) \(String(data: data.prefix(160), encoding: .utf8) ?? "")")
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CloudError.parse("响应非 JSON")
                }
                let status = (obj["status"] as? Int) ?? 200
                if status != 200 {
                    throw CloudError.network(Self.describe(obj))
                }
                return obj
            } catch {
                lastError = error
                // 业务层错误（夸克返回的 status/message）换域名也没用，直接抛
                if let cloud = error as? CloudError {
                    switch cloud {
                    case .network(let m) where m.hasPrefix("HTTP 5") || m.hasPrefix("HTTP 4"):
                        continue
                    case .parse:
                        continue
                    default:
                        throw error
                    }
                } else {
                    continue
                }
            }
        }
        throw lastError
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
            hint = " → 非会员单文件 50MB 下载限制"
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
            let r = try await call("/file/sort", query: [
                "pdir_fid": pdir,
                "_page": String(page),
                "_size": "100",
                "_fetch_total": "1",
                "fetch_all_file": "1",
                "fetch_risk_file_name": "1",
                "_sort": "file_type:asc,file_name:asc",
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

        let r = try await call("/file/download", method: "POST", body: ["fids": [file.id]])
        let urls = Self.extractURLs(r)
        if !urls.isEmpty {
            candidates = urls
        } else {
            lastMessage = "接口未返回 download_url（返回结构：\(Self.brief(r))）"
        }

        guard let first = candidates.first, let url = Self.makeURL(first) else {
            throw CloudError.parse("取夸克直链失败：\(lastMessage)")
        }

        // 注意：这里读的是「刚刚被 Set-Cookie 刷新过」的 Cookie，__puus 是新的
        return (url, Self.mediaHeaders(cookie: cookie))
    }

    /// 直链请求头：三者缺一不可，缺 Referer 会被 302 到登录页，__puus 过期会 403
    private static func mediaHeaders(cookie: String) -> [String: String] {
        [
            "Cookie": cookie,
            "User-Agent": ua,
            "Referer": referer,
            "Accept": "*/*",
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
        out.append("Cookie 长度：\(cookie.count)，含 __puus：\(cookie.contains("__puus") ? "是" : "否")")
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
        out.append("Cookie 已刷新：\(cookie.contains("__puus") ? "是" : "否")（长度 \(cookie.count)）")
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
            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpCookieStorage = nil
            cfg.httpShouldSetCookies = false
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
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
