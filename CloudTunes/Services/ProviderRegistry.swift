import Foundation

/// 网盘 Provider 注册表：按类型提供单例
enum ProviderRegistry {
    static let guangya = GuangyaProvider()
    static let baidu = BaiduProvider()
    static let quark = QuarkProvider()

    static func provider(kind: CloudKind) -> CloudProvider? {
        switch kind {
        case .guangya: return guangya
        case .baidu: return baidu
        case .quark: return quark
        }
    }

    /// 列目录并给每个文件补上 parentID（供歌词 .lrc 同目录查找用）
    static func listWithParent(_ provider: CloudProvider, folderID: String) async throws -> [CloudFile] {
        let files = try await provider.list(folderID: folderID)
        return files.map { f in
            var extra = f.extra
            extra["parentID"] = folderID.isEmpty ? rootID(of: provider.kind) : folderID
            return CloudFile(id: f.id, name: f.name, size: f.size, isFolder: f.isFolder,
                             modifiedAt: f.modifiedAt, extra: extra)
        }
    }

    static func rootID(of kind: CloudKind) -> String {
        switch kind {
        case .guangya: return ""
        case .baidu: return "/"
        case .quark: return "0"
        }
    }
}
