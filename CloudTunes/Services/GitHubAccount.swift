import Foundation
import Security

/// GitHub 账号：只负责「凭证」和「身份」，不掺业务。
///
/// 为什么用 GitHub 而不是自建账号系统：
/// 这个 App 是免费 Apple ID 自签的，拿不到 iCloud/CloudKit 权限，
/// 跨设备同步必须有一个 HTTPS 后端。GitHub 的私有 Gist 正好能当
/// 「一小块只有本人才看得到的云盘」，还省掉了注册、服务器和维护成本。
enum GitHubAccount {

    // MARK: - Keychain

    private static let tokenKey = "com.gysbs.cloudtunes.github.token"
    private static let loginKey = "com.gysbs.cloudtunes.github.login"

    /// 令牌存在 Keychain 而不是 UserDefaults：UserDefaults 是明文 plist，
    /// 备份/导出的时候会被一起带走。Keychain 对自签 App 可用（不需要额外 entitlements）。
    static var token: String? {
        get { Keychain.get(tokenKey) }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.set(newValue, forKey: tokenKey)
            } else {
                Keychain.delete(tokenKey)
            }
        }
    }

    /// 登录名（仅用于界面显示，不是凭证）
    static var cachedLogin: String? {
        get { UserDefaults.standard.string(forKey: loginKey) }
        set { UserDefaults.standard.set(newValue, forKey: loginKey) }
    }

    static var isSignedIn: Bool { (token?.isEmpty == false) }

    static func signOut() {
        token = nil
        cachedLogin = nil
    }

    // MARK: - 令牌校验

    struct Identity: Sendable {
        let login: String
        let name: String?
        let avatarURL: String?
    }

    enum AuthError: LocalizedError {
        case invalidToken
        case noGistScope
        case network(String)

        var errorDescription: String? {
            switch self {
            case .invalidToken:
                return "令牌无效或已过期，请重新生成一个"
            case .noGistScope:
                return "这个令牌没有 gist 权限。生成令牌时要勾选 gist"
            case .network(let msg):
                return "连不上 GitHub：\(msg)"
            }
        }
    }

    /// 校验令牌并拿回账号信息。顺手确认它有 gist 权限，
    /// 否则后面同步会一直 404 报「找不到 Gist」，很难看出是权限问题。
    static func verify(_ token: String) async throws -> Identity {
        var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw AuthError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AuthError.network("响应异常")
        }
        if http.statusCode == 401 {
            throw AuthError.invalidToken
        }
        guard http.statusCode == 200 else {
            throw AuthError.network("HTTP \(http.statusCode)")
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = obj["login"] as? String else {
            throw AuthError.invalidToken
        }

        // X-OAuth-Scopes 是逗号分隔的已授权范围；细粒度令牌这里可能为空，
        // 所以不做硬性拦截，只在调用方遇到 404 时兜底提示。
        if let scopes = http.value(forHTTPHeaderField: "X-OAuth-Scopes"), !scopes.isEmpty {
            let list = scopes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if !list.contains("gist") {
                throw AuthError.noGistScope
            }
        }

        return Identity(login: login,
                        name: obj["name"] as? String,
                        avatarURL: obj["avatar_url"] as? String)
    }
}

// MARK: - Keychain 读写

enum Keychain {
    static func set(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        // 先尝试更新，失败再新增，避免重复项
        let attrs: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) != errSecSuccess {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
