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
        .description("显示正在播放的歌曲，并提供我喜欢的音乐、最近播放、随机播放、继续播放等快捷入口")
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
        .widgetBackground(cover: entry.cover)
        .widgetURL(URL(string: "cloudtunes://open"))
    }

    // MARK: 小尺寸：封面 + 歌名（整个组件点按打开播放页）

    private var smallLayout: some View {
        VStack(spacing: 7) {
            coverThumb(size: 74, corner: 12)

            Text(info?.title ?? "汤圆云音盒")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(info?.artist ?? "点按打开播放器")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
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
                coverThumb(size: 58, corner: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(info?.title ?? "还没有播放")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(info?.artist ?? "点下面的按钮开始听歌")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(info?.isPlaying == true ? Color.green : Color.white.opacity(0.55))
                            .frame(width: 5, height: 5)
                        Text(info == nil ? "未在播放" : (info!.isPlaying ? "正在播放" : "已暂停"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(Color.white.opacity(0.16))
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

    /// 封面（没有就给品牌占位），调用方负责 frame
    @ViewBuilder
    private func coverThumb(size: CGFloat, corner: CGFloat) -> some View {
        if let cover = entry.cover {
            Color.clear
                .overlay { Image(uiImage: cover).resizable().scaledToFill() }
                .clipped()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.white.opacity(0.14))
                .frame(width: size, height: size)
                .overlay { Image(systemName: "music.note").foregroundStyle(.white.opacity(0.7)) }
        }
    }
}

// MARK: - 中尺寸左侧封面卡

/// 对标网易云小组件左侧的封面卡：封面 + 底部歌名浮层；没在播时显示品牌
private struct NowCoverCard: View {
    let info: WidgetBridge.Snapshot?
    let cover: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.white.opacity(0.10))

            if let cover {
                Color.clear
                    .overlay { Image(uiImage: cover).resizable().scaledToFill() }
                    .clipped()
            } else {
                LinearGradient(colors: [Color(red: 0.36, green: 0.30, blue: 0.46),
                                        Color(red: 0.18, green: 0.17, blue: 0.28)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            LinearGradient(colors: [Color.clear, Color.black.opacity(0.62)],
                           startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(info?.isPlaying == true ? Color.green : Color.white.opacity(0.7))
                        .frame(width: 5, height: 5)
                    Text(info == nil ? "汤圆云音盒" : (info!.isPlaying ? "正在播放" : "已暂停"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                Text(info?.title ?? "打开播放器")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 功能按钮

/// 参照网易云「我喜欢的音乐 / 私人漫游」的胶囊按钮
private struct FunctionButton: View {
    let icon: String
    let title: String
    var height: CGFloat = 40

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.18), in: Circle())
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Color.white.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: height > 44 ? 14 : 12, style: .continuous))
    }
}

// MARK: - 背景

/// iOS 17 起系统要求小组件用 containerBackground API（否则画廊里会显示
/// 「Please adopt containerBackground API」警示）。这里做版本兼容：
/// iOS 17+ 走标准 API，iOS 16 退回普通 background。
struct WidgetBackgroundModifier: ViewModifier {
    let cover: UIImage?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(for: .widget) { Self.background(cover: cover) }
        } else {
            content.background(Self.background(cover: cover))
        }
    }

    /// 背景：封面放大模糊 + 压暗；无封面时用品牌渐变
    static func background(cover: UIImage?) -> some View {
        ZStack {
            if let cover {
                GeometryReader { geo in
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 30)
                        .opacity(0.6)
                }
                .clipped()
            } else {
                LinearGradient(colors: [Color(red: 0.32, green: 0.26, blue: 0.42),
                                        Color(red: 0.16, green: 0.15, blue: 0.24)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Color.black.opacity(0.22)
        }
    }
}

extension View {
    func widgetBackground(cover: UIImage?) -> some View {
        modifier(WidgetBackgroundModifier(cover: cover))
    }
}
