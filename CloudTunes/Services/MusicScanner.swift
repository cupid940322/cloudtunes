import Foundation

/// 音乐文件识别与文件名解析
enum MusicScanner {
    /// iOS AVPlayer 原生可播的音频扩展名（ape/ogg/wma/opus 等原生不支持，暂不收录）
    static let audioExtensions: Set<String> = [
        "mp3", "flac", "m4a", "aac", "wav", "aiff", "aif", "alac",
    ]

    static func isAudioFile(_ name: String) -> Bool {
        guard let ext = name.split(separator: ".").last else { return false }
        return audioExtensions.contains(ext.lowercased())
    }

    /// 从目录列表中筛出音频文件
    static func filterAudio(_ files: [CloudFile]) -> [CloudFile] {
        files.filter { !$0.isFolder && isAudioFile($0.name) }
    }

    /// "周杰伦 - 晴天.mp3" → ("周杰伦", "晴天")；无分隔符则整体作为标题
    static func parseArtist(_ filename: String) -> String? {
        let base = (filename as NSString).deletingPathExtension
        guard let range = base.range(of: " - ") ?? base.range(of: " – ") ?? base.range(of: "_") else { return nil }
        let artist = String(base[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return artist.isEmpty ? nil : artist
    }

    static func parseTitle(_ filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        if let range = base.range(of: " - ") ?? base.range(of: " – ") {
            let title = String(base[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return base
    }
}
