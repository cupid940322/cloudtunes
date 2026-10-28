import Foundation
import AuthenticationServices

/// 百度网盘 Provider —— 走官方开放平台 API。
/// 前提：需在 https://pan.baidu.com/union 注册应用获得 AppKey / SecretKey（个人可申请）。
/// OAuth 回调 URI 填写 oob（显示授权码），应用内引导用户粘贴授权码换取长期 access_token。
final class BaiduProvider: CloudProvider {
    let kind: CloudKind = .baidu

    private var appKey: String { CredentialStore.get("baidu.appKey") ?? "" }
    private var secretKey: String { CredentialStore.get("baidu.secretKey") ?? "" }

    private var accessToken: String? {
        get { CredentialStore.get("baidu.accessToken") }
        set { CredentialStore.set(newValue, for: "baidu.accessToken") }
    }

    var isSignedIn: Bool { accessToken != nil }
    var displayName: String? { CredentialStore.get("baidu.display") }

    /// 授权页 URL（oob 模式：授权后在页面显示授权码，用户复制回填）
    static var authorizeURL: URL {
        let key = CredentialStore.get("baidu.appKey") ?? ""
        var comps = URLComponents(string: "https://openapi.baidu.com/oauth/2.0/authorize")!
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: key),
            .init(name: "redirect_uri", value: "oob"),
            .init(name: "scope", value: "basic,netdisk"),
            .init(name: "display", value: "mobile"),
        ]
        return comps.url!
    }

    /// 用授权码换取 access_token（有效期约 10 年）
    func exchangeCode(_ code: String) async throws {
        guard !appKey.isEmpty, !secretKey.isEmpty else {
            throw CloudError.auth("请先在设置中填写 AppKey / SecretKey")
        }
        var comps = URLComponents(string: "https://openapi.baidu.com/oauth/2.0/token")!
        comps.queryItems = [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "client_id", value: appKey),
            .init(name: "client_secret", value: secretKey),
            .init(name: "redirect_uri", value: "oob"),
        ]
        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: comps.url!))
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudError.network("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["access_token"] as? String else {
            throw CloudError.parse("授权码换 token 失败: \(String(data: data, encoding: .utf8) ?? "")")
        }
        accessToken = token
        CredentialStore.set("已授权", for: "baidu.display")
    }

    func signOut() {
        accessToken = nil
        CredentialStore.remove("baidu.display")
    }

    private func request(_ url: URL) async throws -> [String: Any] {
        guard let token = accessToken else { throw CloudError.notSignedIn }
        var req = URLRequest(url: url)
        req.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = (comps.queryItems ?? []) + [.init(name: "access_token", value: token)]
        req.url = comps.url
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudError.network("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(String(data: data, encoding: .utf8) ?? "")")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.parse("响应非 JSON")
        }
        if let errno = obj["errno"] as? Int, errno != 0 {
            throw CloudError.network("百度 errno=\(errno)")
        }
        return obj
    }

    /// list 使用 path 作为 folder 标识；根目录为 "/"
    func list(folderID: String) async throws -> [CloudFile] {
        let dir = folderID.isEmpty ? "/" : folderID
        var comps = URLComponents(string: "https://pan.baidu.com/rest/2.0/xpan/file")!
        comps.queryItems = [.init(name: "method", value: "list"), .init(name: "dir", value: dir)]
        let r = try await request(comps.url!)
        guard let list = r["list"] as? [[String: Any]] else { return [] }
        return list.map { item in
            CloudFile(
                id: item["path"] as? String ?? "",
                name: item["server_filename"] as? String ?? "",
                size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                isFolder: (item["isdir"] as? Int) == 1,
                modifiedAt: nil,
                extra: ["fs_id": String((item["fs_id"] as? NSNumber)?.int64Value ?? 0)])
        }
    }

    func streamURL(file: CloudFile) async throws -> (url: URL, headers: [String: String]) {
        guard let fsid = file.extra["fs_id"] else { throw CloudError.parse("缺少 fs_id") }
        var comps = URLComponents(string: "https://pan.baidu.com/rest/2.0/xpan/file")!
        comps.queryItems = [
            .init(name: "method", value: "filemetas"),
            .init(name: "fsids", value: "[\(fsid)]"),
            .init(name: "dlink", value: "1"),
        ]
        let r = try await request(comps.url!)
        guard let list = r["list"] as? [[String: Any]],
              let dlink = list.first?["dlink"] as? String, let url = URL(string: dlink) else {
            throw CloudError.parse("未取得 dlink")
        }
        // dlink 直链要求带 UA，且 access_token 拼到直链上
        var dcomps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        dcomps.queryItems = (dcomps.queryItems ?? []) + [.init(name: "access_token", value: accessToken!)]
        return (dcomps.url!, ["User-Agent": "pan.baidu.com"])
    }
}
