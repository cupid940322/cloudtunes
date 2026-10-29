import AVFoundation
import Foundation
import UIKit

/// 音乐元数据刮削：
/// 1) 优先读文件内嵌标签（ID3 / FLAC / MP4 等，AVAsset commonMetadata）
/// 2) 内嵌封面缺失时，用 iTunes 搜索 API 兜底匹配封面
enum MetadataScraper {

    struct Result {
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var artworkFile: String?
    }

    /// 刮削单个文件（需要直链）
    static func scrape(url: URL, headers: [String: String], trackID: String) async -> Result {
        var result = Result()
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])

        // 时长
        if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 {
            result.duration = d.seconds
        }

        // 内嵌标签
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    result.title = try? await item.load(.stringValue)
                case .commonKeyArtist:
                    result.artist = try? await item.load(.stringValue)
                case .commonKeyAlbumName:
                    result.album = try? await item.load(.stringValue)
                case .commonKeyArtwork:
                    if let data = try? await item.load(.dataValue) {
                        result.artworkFile = saveArtwork(data, key: trackID)
                    }
                default:
                    break
                }
            }
        }

        // iTunes 兜底封面
        if result.artworkFile == nil, let title = result.title, !title.isEmpty {
            let artist = result.artist ?? ""
            if let data = await fetchITunesArtwork(title: title, artist: artist) {
                result.artworkFile = saveArtwork(data, key: trackID)
            }
        }
        return result
    }

    // MARK: - 封面缓存

    static var artworkDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func artworkURL(file: String?) -> URL? {
        guard let file, !file.isEmpty else { return nil }
        let url = artworkDir.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func saveArtwork(_ data: Data, key: String) -> String? {
        // 统一转成 JPEG，避免原格式过大
        guard let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        let name = key.replacingOccurrences(of: "/", with: "_") + ".jpg"
        let url = artworkDir.appendingPathComponent(name)
        try? jpeg.write(to: url)
        return name
    }

    // MARK: - iTunes 封面

    private static func fetchITunesArtwork(title: String, artist: String) async -> Data? {
        let term = artist.isEmpty ? title : "\(artist) \(title)"
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            .init(name: "term", value: term),
            .init(name: "media", value: "music"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "1"),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]],
              let art = results.first?["artworkUrl100"] as? String else { return nil }
        let big = art.replacingOccurrences(of: "100x100", with: "600x600")
        guard let artURL = URL(string: big) else { return nil }
        guard let (imgData, _) = try? await URLSession.shared.data(for: URLRequest(url: artURL)) else { return nil }
        return imgData
    }
}
