import Foundation

/// 夸克网盘 Provider —— ⚠️ 实验性。
/// 夸克官方未开放 API，此实现基于社区逆向的 Web 端接口（drive-pc.quark.cn），
/// 需要用户从网页版 F12 复制登录 Cookie。接口随时可能失效或触发风控，仅限自用。
final class QuarkProvider: CloudProvider {
    let kind: CloudKind = .quark

    private var cookie: String {
        CredentialStore.get("quark.cookie") ?? ""
    }

    var isSignedIn: Bool { !cookie.isEmpty }
    var displayName: String? { cookie.isEmpty ? nil : "已导入 Cookie" }

    func setCookie(_ c: String) { CredentialStore.set(c, for: "quark.cookie") }
    func signOut() { CredentialStore.remove("quark.cookie") }

    private func get(_ path: String, query: [String: String]) async throws -> [String: Any] {
        var comps = URLComponents(string: "https://drive-pc.quark.cn\(path)")!
        var items = [URLQueryItem(name: "pr", value: "ucpro"), URLQueryItem(name: "fr", value: "pc")]
        items += query.map { URLQueryItem(name: $0.key, value: $0.value) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudError.network("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.parse("响应非 JSON")
        }
        if let code = obj["status"] as? Int, code != 200 {
            throw CloudError.network("夸克 status=\(code) \(obj["message"] ?? "")")
        }
        return obj
    }

    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://drive-pc.quark.cn\(path)?pr=ucpro&fr=pc")!)
        req.httpMethod = "POST"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudError.network("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.parse("响应非 JSON")
        }
        if let code = obj["status"] as? Int, code != 200 {
            throw CloudError.network("夸克 status=\(code) \(obj["message"] ?? "")")
        }
        return obj
    }

    /// folderID: 根目录为 "0"
    func list(folderID: String) async throws -> [CloudFile] {
        let pdir = folderID.isEmpty ? "0" : folderID
        let r = try await get("/1/clouddrive/file/sort", query: [
            "pdir_fid": pdir, "_page": "1", "_size": "200",
            "fetch_total": "1", "sort_field": "file_type", "sort_order": "asc",
        ])
        guard let data = r["data"] as? [String: Any],
              let list = data["list"] as? [[String: Any]] else { return [] }
        return list.map { item in
            CloudFile(
                id: item["fid"] as? String ?? "",
                name: item["file_name"] as? String ?? "",
                size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                isFolder: (item["dir"] as? Bool) == true || (item["file_type"] as? Int) == 0,
                modifiedAt: nil,
                extra: [:])
        }
    }

    func streamURL(file: CloudFile) async throws -> (url: URL, headers: [String: String]) {
        let r = try await post("/1/clouddrive/file/download", body: ["fids": [file.id]])
        guard let data = r["data"] as? [String: Any],
              let arr = data["data"] as? [[String: Any]],
              let urlString = arr.first?["download_url"] as? String,
              let url = URL(string: urlString) else {
            throw CloudError.parse("未取得夸克直链（Cookie 可能已失效）")
        }
        return (url, ["User-Agent": "Mozilla/5.0"])
    }
}
