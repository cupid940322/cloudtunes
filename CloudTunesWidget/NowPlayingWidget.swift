import WidgetKit
import SwiftUI

// MARK: - 时间线

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let info: WidgetBridge.Snapshot?
    let cover: UIImage?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        entry()
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let e = entry()
        // 每 15 分钟自动重建一次时间线；换歌/暂停时 App 会主动 reload
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [e], policy: .after(next)))
    }

    private func entry() -> NowPlayingEntry {
        let info = WidgetBridge.load()
        var cover: UIImage?
        if let url = WidgetBridge.coverURL() {
            cover = UIImage(contentsOfFile: url.path)
        }
        return NowPlayingEntry(date: Date(), info: info, cover: cover)
    }
}

// MARK: - Widget 声明

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlayingWidget", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("汤圆云音盒")
        .description("正在播放 + 快捷入口。中尺寸：左边正在播放，右边我喜欢的音乐和随机播放")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct CloudTunesWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
    }
}

// MARK: - 视图

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family

    private var info: WidgetBridge.Snapshot? { entry.info }

    var body: some View {
        Group {
            switch family {
            case .systemLarge: largeLayout
            case .systemSmall: smallLayout
            default:           mediumLayout
            }
        }
        .widgetBackground()
        .widgetURL(URL(string: "cloudtunes://open"))
    }

    // MARK: 小尺寸：封面 + 正在播放

    private var smallLayout: some View {
        VStack(spacing: 6) {
            coverThumb(size: 68, corner: 15)

            HStack(spacing: 4) {
                Circle()
                    .fill(info?.isPlaying == true ? Color.green : Color.secondary.opacity(0.6))
                    .frame(width: 5, height: 5)
                Text(info == nil ? "未在播放" : (info!.isPlaying ? "正在播放" : "已暂停"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text(info?.title ?? "汤圆云音盒")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(info?.artist ?? "点按打开播放器")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 中尺寸（对标网易云音乐）：左封面卡 + 右两个功能区

    private var mediumLayout: some View {
        HStack(spacing: 12) {
            Link(destination: Self.link("player")) {
                NowCoverCard(info: info, cover: entry.cover)
            }

            VStack(spacing: 10) {
                Link(destination: Self.link("favorites")) {
                    FunctionButton(icon: "heart.fill", title: "我喜欢的音乐")
                }
                Link(destination: Self.link("shuffle")) {
                    FunctionButton(icon: "shuffle", title: "随机播放")
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 大尺寸：正在播放条 + 2×2 功能区

    private var largeLayout: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                coverThumb(size: 58, corner: 13)
                VStack(alignment: .leading, spacing: 3) {
                    Text(info?.title ?? "还没有播放")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(info?.artist ?? "点下面的按钮开始听歌")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(info?.isPlaying == true ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 5, height: 5)
                        Text(info == nil ? "未在播放" : (info!.isPlaying ? "正在播放" : "已暂停"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 0.5)

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Link(destination: Self.link("favorites")) {
                        FunctionButton(icon: "heart.fill", title: "我喜欢的音乐", height: 52)
                    }
                    Link(destination: Self.link("recent")) {
                        FunctionButton(icon: "clock", title: "最近播放", height: 52)
                    }
                }
                HStack(spacing: 10) {
                    Link(destination: Self.link("shuffle")) {
                        FunctionButton(icon: "shuffle", title: "随机播放", height: 52)
                    }
                    Link(destination: Self.link("resume")) {
                        FunctionButton(icon: "play.circle.fill", title: "继续播放", height: 52)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 通用小件

    private static func link(_ host: String) -> URL {
        URL(string: "cloudtunes://\(host)") ?? URL(string: "cloudtunes://open")!
    }

    /// 封面（没有就用 App 图标虚化做占位），调用方负责 frame
    @ViewBuilder
    private func coverThumb(size: CGFloat, corner: CGFloat) -> some View {
        if let cover = entry.cover {
            Color.clear
                .overlay { Image(uiImage: cover).resizable().scaledToFill() }
                .clipped()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        } else if let icon = WidgetTheme.appIcon {
            Color.clear
                .overlay { Image(uiImage: icon).resizable().scaledToFill() }
                .clipped()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(Color.white.opacity(0.15))
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: max(14, size * 0.28)))
                        .foregroundStyle(.white.opacity(0.95))
                }
        } else {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.black.opacity(0.08))
                .frame(width: size, height: size)
                .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
        }
    }
}

// MARK: - 中尺寸左侧封面卡（对标网易云「每日推荐」卡）

/// 封面填满整张卡，左下角浮层显示状态与歌名；没在播时用 App 图标虚化 + 音符
private struct NowCoverCard: View {
    let info: WidgetBridge.Snapshot?
    let cover: UIImage?

    private var statusText: String {
        info == nil ? "汤圆云音盒" : (info!.isPlaying ? "正在播放" : "已暂停")
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.white.opacity(0.5))

            if let cover {
                Color.clear
                    .overlay { Image(uiImage: cover).resizable().scaledToFill() }
                    .clipped()
            } else if let icon = WidgetTheme.appIcon {
                Color.clear
                    .overlay { Image(uiImage: icon).resizable().scaledToFill() }
                    .clipped()
                    .overlay(Color.white.opacity(0.18))
                Image(systemName: "music.note")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LinearGradient(colors: [Color(red: 0.98, green: 0.62, blue: 0.52),
                                        Color(red: 0.95, green: 0.45, blue: 0.38)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            LinearGradient(colors: [Color.clear, Color.black.opacity(0.58)],
                           startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(info?.isPlaying == true ? Color.green : Color.white.opacity(0.85))
                        .frame(width: 5, height: 5)
                    Text(statusText)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                }
                Text(info?.title ?? "打开播放器")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let artist = info?.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                }
            }
            .padding(9)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 功能按钮（网易云胶囊样式：浅色卡 + 品牌色圆底图标 + 深色文字）

private struct FunctionButton: View {
    let icon: String
    let title: String
    var height: CGFloat = 48

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 0.92, green: 0.42, blue: 0.34))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.9), in: Circle())
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.80))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Color.white.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: height > 44 ? 15 : 14, style: .continuous))
    }
}

// MARK: - 背景（App 图标虚化）

private enum WidgetTheme {
    /// App 图标：打包进小组件资源的 widget-icon.png
    static let appIcon: UIImage? = UIImage(named: "widget-icon")

    /// 背景 = 图标放大虚化 + 提亮，得到温暖的品牌色调，深色文字可读
    static var background: some View {
        GeometryReader { geo in
            ZStack {
                if let icon = appIcon {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 28)
                        .overlay(Color.white.opacity(0.45))
                } else {
                    LinearGradient(colors: [Color(red: 1.00, green: 0.88, blue: 0.82),
                                            Color(red: 0.99, green: 0.76, blue: 0.70)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }
        .clipped()
    }
}

/// iOS 17 起系统要求小组件用 containerBackground API（否则画廊里会显示
/// 「Please adopt containerBackground API」警示）。这里做版本兼容：
/// iOS 17+ 走标准 API，iOS 16 退回普通 background。
struct WidgetBackgroundModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(for: .widget) { WidgetTheme.background }
        } else {
            content.background(WidgetTheme.background)
        }
    }
}

extension View {
    func widgetBackground() -> some View {
        modifier(WidgetBackgroundModifier())
    }
}
