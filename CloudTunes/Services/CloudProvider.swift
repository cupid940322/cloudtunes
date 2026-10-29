import Foundation

/// 网盘服务抽象：登录态 + 目录浏览 + 取直链
protocol CloudProvider {
    var kind: CloudKind { get }
    /// 是否已登录（持有有效凭证）
    var isSignedIn: Bool { get }
    /// 登录账号显示名（手机号/用户名）
    var displayName: String? { get }

    /// 列出目录内容。rootFolder 由各实现自行定义根目录标识。
    func list(folderID: String) async throws -> [CloudFile]

    /// 获取可直接用于 AVPlayer 流式播放的 URL（含必要请求头）
    func streamURL(file: CloudFile) async throws -> (url: URL, headers: [String: String])
}

/// 登录状态变更广播（供 UI 刷新「已登录」标识）
final class AuthState: ObservableObject {
    static let shared = AuthState()
    @Published private(set) var tick = 0

    func bump() { tick += 1 }
}

/// 简单的持久化 KV 存储（网盘凭证）。
/// 注意：正式版应迁移到 Keychain，此处先用 UserDefaults 方便调试。
enum CredentialStore {
    private static let prefix = "cloudtunes.cred."

    static func set(_ value: String?, for key: String) {
        UserDefaults.standard.set(value, forKey: prefix + key)
    }

    static func get(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: prefix + key)
    }

    static func remove(_ key: String) {
        UserDefaults.standard.removeObject(forKey: prefix + key)
    }
}
