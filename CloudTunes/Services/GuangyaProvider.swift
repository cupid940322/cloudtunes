import Foundation

/// 光鸭云盘 Provider。
/// 接口依据 OpenList drivers/guangyapan 与社区 guangya 客户端逆向文档实现：
/// 账户服务 account.guangyapan.com + 资源服务 api.guangyapan.com，短信验证码登录。
final class GuangyaProvider: CloudProvider {
    let kind: CloudKind = .guangya

    private static let accountBase = URL(string: "https://account.guangyapan.com")!
    private static let apiBase = URL(string: "https://api.guangyapan.com")!

    // X-Client-Id：光鸭网页端公共客户端 ID。
    // 默认内置社区逆向客户端使用的公共 ID，用户可在设置中覆盖。
    private static let defaultClientID = "aMe-8VSlkrbQXpUR"

    private var clientID: String {
        let v = CredentialStore.get("guangya.clientID") ?? ""
        return v.isEmpty ? Self.defaultClientID : v
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"

    /// W3C traceparent: 00-<32hex>-<16hex>-01
    private static func traceparent() -> String {
        func hex(_ n: Int) -> String {
            (0..<n).map { _ in String(format: "%x", Int.random(in: 0...15)) }.joined()
        }
        return "00-\(hex(32))-\(hex(16))-01"
    }

    // 每次安装生成一个稳定设备 ID（32 位小写十六进制，MD5 风格）
    private var deviceID: String {
        if let d = CredentialStore.get("guangya.deviceID") { return d }
        let d = Self.randomHex(32)
        CredentialStore.set(d, for: "guangya.deviceID")
        return d
    }

    private static func randomHex(_ count: Int) -> String {
        (0..<count).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private var accessToken: String? {
        get { CredentialStore.get("guangya.accessToken") }
        set { CredentialStore.set(newValue, for: "guangya.accessToken") }
    }
    private var refreshToken: String? {
        get { CredentialStore.get("guangya.refreshToken") }
        set { CredentialStore.set(newValue, for: "guangya.refreshToken") }
    }

    var isSignedIn: Bool { accessToken != nil }

    var displayName: String? { CredentialStore.get("guangya.phone") }

    /// 同一接口调用需间隔 500ms（官方限速）
    private static var lastRequestAt = Date.distantPast

    // MARK: - 公共请求

    private func accountHeaders(auth: Bool = false, captcha: String? = nil) -> [String: String] {
        var h = [
            "Accept": "*/*",
            "Content-Type": "application/json",
            "X-Device-Model": "chrome%2F147.0.0.0",
            "X-Device-Name": "PC-Chrome",
            // 官方签名格式：wdi10.<deviceId><32位随机hex>
            "X-Device-Sign": "wdi10." + deviceID + Self.randomHex(32),
            "X-Net-Work-Type": "NONE",
            "X-OS-Version": "MacIntel",
            "X-Platform-Version": "1",
            "X-Protocol-Version": "301",
            "X-Provider-Name": "NONE",
            "X-SDK-Version": "9.0.2",
            "X-Client-Id": clientID,
            "X-Client-Version": "0.0.1",
            "X-Device-Id": deviceID,
            "Origin": "https://www.guangyapan.com",
            "Referer": "https://www.guangyapan.com/",
            "User-Agent": Self.userAgent,
            "Traceparent": Self.traceparent(),
        ]
        if auth, let t = accessToken { h["Authorization"] = "Bearer \(t)" }
        if let c = captcha { h["X-Captcha-Token"] = c }
        return h
    }

    private func apiHeaders() -> [String: String] {
        var h = [
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json",
            "Did": deviceID,
            "Dt": "4",
            "Origin": "https://www.guangyapan.com",
            "Referer": "https://www.guangyapan.com/",
            "User-Agent": Self.userAgent,
            "Traceparent": Self.traceparent(),
        ]
        if let t = accessToken { h["Authorization"] = "Bearer \(t)" }
        return h
    }

    @discardableResult
    private func post(url: URL, body: [String: Any], headers: [String: String]) async throws -> [String: Any] {
        let wait = 0.5 - Date.now.timeIntervalSince(Self.lastRequestAt)
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        Self.lastRequestAt = Date.now

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CloudError.network("无响应") }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.network("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.parse("响应非 JSON")
        }
        return obj
    }

    @discardableResult
    private func get(url: URL, headers: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudError.network("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.parse("响应非 JSON")
        }
        return obj
    }

    // MARK: - 短信登录（三步）

    /// 第 1 步：安全验证初始化 + 发送短信验证码。返回 verification_id。
    func sendCode(phoneE164: String) async throws -> String {
        // 1) captcha init：换取安全验证令牌
        let initBody: [String: Any] = [
            "client_id": clientID,
            "action": "POST:/v1/auth/verification",
            "device_id": deviceID,
            "meta": ["phone_number": phoneE164],
        ]
        let initResp = try await post(
            url: Self.accountBase.appendingPathComponent("/v1/shield/captcha/init"),
            body: initBody,
            headers: accountHeaders())
        guard let d0 = initResp["data"] as? [String: Any],
              let captchaToken = d0["captcha_token"] as? String, !captchaToken.isEmpty else {
            throw CloudError.parse("安全验证初始化失败：\(initResp)")
        }
        // 2) 发送验证码（带 x-captcha-token）
        let r = try await post(
            url: Self.accountBase.appendingPathComponent("/v1/auth/verification"),
            body: ["phone_number": phoneE164, "target": "ANY", "client_id": clientID],
            headers: accountHeaders(captcha: captchaToken))
        guard let vid = r["data"] as? [String: Any], let id = vid["verification_id"] as? String else {
            throw CloudError.parse("发送验证码失败: \(r)")
        }
        CredentialStore.set(phoneE164, for: "guangya.phone")
        return id
    }

    /// 第 2 步：校验验证码 → verification_token
    private func verify(verificationID: String, code: String) async throws -> String {
        let r = try await post(
            url: Self.accountBase.appendingPathComponent("/v1/auth/verification/verify"),
            body: ["verification_id": verificationID, "verification_code": code, "client_id": clientID],
            headers: accountHeaders())
        guard let d = r["data"] as? [String: Any], let t = d["verification_token"] as? String else {
            throw CloudError.parse("验证码校验失败: \(r)")
        }
        return t
    }

    /// 第 3 步：signin 换取 access/refresh token
    func signIn(phoneE164: String, verificationID: String, code: String) async throws {
        let vt = try await verify(verificationID: verificationID, code: code)
        let r = try await post(
            url: Self.accountBase.appendingPathComponent("/v1/auth/signin"),
            body: [
                "verification_code": code,
                "verification_token": vt,
                "username": phoneE164,
                "client_id": clientID,
            ],
            headers: accountHeaders())
        guard let d = r["data"] as? [String: Any],
              let at = d["access_token"] as? String else {
            throw CloudError.parse("登录失败: \(r)")
        }
        accessToken = at
        refreshToken = d["refresh_token"] as? String
    }

    func signOut() {
        accessToken = nil
        refreshToken = nil
        CredentialStore.remove("guangya.phone")
    }

    /// 刷新 token
    private func refresh() async throws {
        guard let rt = refreshToken else { throw CloudError.notSignedIn }
        let r = try await post(
            url: Self.accountBase.appendingPathComponent("/v1/auth/token"),
            body: ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": rt],
            headers: accountHeaders(auth: false).merging(["X-Action": "401"]) { a, _ in a })
        if let err = r["error"] as? String {
            throw CloudError.auth("token 刷新失败: \(err) \(r["error_description"] ?? "")")
        }
        guard let at = r["access_token"] as? String else { throw CloudError.parse("刷新响应缺 access_token") }
        accessToken = at
        if let nrt = r["refresh_token"] as? String { refreshToken = nrt }
    }

    /// 带自动刷新的 API POST
    private func apiPost(path: String, body: [String: Any]) async throws -> [String: Any] {
        do {
            return try await post(url: Self.apiBase.appendingPathComponent(path),
                                  body: body, headers: apiHeaders())
        } catch CloudError.network(let msg) where msg.contains("401") {
            try await refresh()
            return try await post(url: Self.apiBase.appendingPathComponent(path),
                                  body: body, headers: apiHeaders())
        }
    }

    // MARK: - CloudProvider

    func list(folderID: String) async throws -> [CloudFile] {
        let root = folderID.isEmpty ? "*" : folderID
        var files: [CloudFile] = []
        var page = 0
        let pageSize = 100
        while true {
            let r = try await apiPost(path: "/userres/v1/file/get_file_list", body: [
                "parentId": root, "page": page, "pageSize": pageSize,
                "orderBy": 3, "sortType": 1,
            ])
            guard let data = r["data"] as? [String: Any],
                  let list = data["list"] as? [[String: Any]] else { break }
            for item in list {
                let isFolder = (item["resType"] as? Int) == 2
                files.append(CloudFile(
                    id: item["fileId"] as? String ?? "",
                    name: item["fileName"] as? String ?? "",
                    size: (item["fileSize"] as? NSNumber)?.int64Value ?? 0,
                    isFolder: isFolder,
                    modifiedAt: (item["utime"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }))
            }
            let total = (data["total"] as? NSNumber)?.intValue ?? 0
            page += 1
            if list.count < pageSize || files.count >= total { break }
        }
        return files
    }

    func streamURL(file: CloudFile) async throws -> (url: URL, headers: [String: String]) {
        let r = try await apiPost(path: "/nd.bizuserres.s/v1/get_res_download_url", body: ["fileId": file.id])
        guard let data = r["data"] as? [String: Any] else { throw CloudError.parse("取直链失败: \(r)") }
        let s = data["signedURL"] as? String
        let d = data["downloadURL"] as? String
        guard let urlString = s ?? d, let url = URL(string: urlString) else {
            throw CloudError.parse("空下载直链")
        }
        return (url, [:])
    }
}
