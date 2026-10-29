import Foundation

/// 网盘类型
enum CloudKind: String, Codable, CaseIterable, Identifiable {
    case guangya = "光鸭云盘"
    case baidu = "百度网盘"
    case quark = "夸克网盘"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .guangya: return "bird.fill"
        case .baidu: return "internaldrive.fill"
        case .quark: return "cube.fill"
        }
    }
}

/// 云端文件/目录条目
struct CloudFile: Identifiable, Hashable {
    let id: String            // 网盘侧文件 ID（百度用 path 作为 id）
    let name: String
    let size: Int64
    let isFolder: Bool
    let modifiedAt: Date?
    /// 附加信息（百度: fs_id；夸克: fid 等）
    let extra: [String: String]

    init(id: String, name: String, size: Int64, isFolder: Bool, modifiedAt: Date? = nil, extra: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.size = size
        self.isFolder = isFolder
        self.modifiedAt = modifiedAt
        self.extra = extra
    }
}

/// 一首待播放的曲目
struct Track: Identifiable, Hashable {
    let id: String
    let file: CloudFile
    let providerKind: CloudKind
    let accountID: String
    /// 刮削得到的元数据覆盖（为空则从文件名解析）
    var titleOverride: String? = nil
    var artistOverride: String? = nil
    var album: String? = nil
    var artworkFile: String? = nil
    var duration: Double? = nil
    var neteaseID: Int? = nil

    /// 从文件名解析出的标题
    var title: String { titleOverride ?? MusicScanner.parseTitle(file.name) }
    /// 从文件名解析出的艺术家（可能为空）
    var artist: String? { artistOverride ?? MusicScanner.parseArtist(file.name) }
    /// 展示用艺术家
    var displayArtist: String { (artist?.isEmpty == false) ? artist! : "未知艺术家" }
}

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: TimeInterval
    let text: String
}
