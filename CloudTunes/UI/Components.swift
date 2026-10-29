import SwiftUI
import UIKit

// MARK: - 封面缓存（降采样，避免长列表滚动卡顿）

final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 300
    }

    func image(named: String?, target: CGFloat) -> UIImage? {
        guard let named, !named.isEmpty else { return nil }
        let pixelKey = "\(named)@\(Int(target))" as NSString
        if let img = cache.object(forKey: pixelKey) { return img }
        guard let url = MetadataScraper.artworkURL(file: named),
              let img = downsample(url: url, maxPixel: target * UIScreen.main.scale) else { return nil }
        cache.setObject(img, forKey: pixelKey)
        return img
    }

    private func downsample(url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel * 1.4,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - 封面视图

struct CoverView: View {
    let file: String?
    var size: CGFloat
    var corner: CGFloat = 12
    var showsShadow = false

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: showsShadow ? Theme.shadow(0.18) : .clear,
                    radius: showsShadow ? 14 : 0,
                    x: 0, y: showsShadow ? 7 : 0)
    }

    @ViewBuilder
    private var content: some View {
        if let img = ArtworkCache.shared.image(named: file, target: size) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [Theme.surfaceElevated, Theme.hairline],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: max(12, size * 0.28), weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// 兼容旧调用的缩略图
struct ArtworkThumb: View {
    let file: String?
    var size: CGFloat = 44
    var corner: CGFloat = 6

    var body: some View {
        CoverView(file: file, size: size, corner: corner)
    }
}

// MARK: - 正在播放指示器

struct PlayingIndicator: View {
    var color: Color = Theme.accent
    @State private var animating = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: animating ? CGFloat(6 + i * 4) : CGFloat(12 - i * 3))
                    .animation(.easeInOut(duration: 0.42 + Double(i) * 0.13)
                        .repeatForever(autoreverses: true), value: animating)
            }
        }
        .frame(width: 14, height: 16, alignment: .bottom)
        .onAppear { animating = true }
    }
}

// MARK: - 区块标题

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.bold))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
    }
}

// MARK: - 空状态

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.accentGradient).frame(width: 86, height: 86).opacity(0.14)
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
            }
            Text(title).font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 22).padding(.vertical, 11)
                        .background(Theme.accentGradient, in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - 细进度条

struct ThinProgressBar: View {
    var value: Double
    var height: CGFloat = 4
    var tint: LinearGradient = Theme.accentGradient

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

// MARK: - 圆角卡片背景

extension View {
    func cardBackground(corner: CGFloat = Theme.radius, padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}
