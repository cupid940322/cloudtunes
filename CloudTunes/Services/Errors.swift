import Foundation

enum CloudError: LocalizedError {
    case network(String)
    case parse(String)
    case auth(String)
    case notSignedIn
    case unsupported

    var errorDescription: String? {
        switch self {
        case .network(let m): return "网络/服务错误：\(m)"
        case .parse(let m): return "响应解析失败：\(m)"
        case .auth(let m): return "鉴权失败：\(m)"
        case .notSignedIn: return "尚未登录该网盘"
        case .unsupported: return "暂不支持此操作"
        }
    }
}
