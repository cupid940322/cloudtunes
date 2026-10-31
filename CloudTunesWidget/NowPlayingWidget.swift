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
        .configurationDisplayName("正在播放")
        .description("显示汤圆云音盒正在播放的歌曲、封面与进度")
        .supportedFamilies([.systemSmall, .systemMedium])
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

    var body: some View {
        Group {
            if let info = entry.info {
                NowPlayingContent(info: info, cover: entry.cover)
            } else {
                emptyView
            }
        }
        .widgetURL(URL(string: "cloudtunes://open"))
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.house")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("汤圆云音盒")
                .font(.subheadline.weight(.semibold))
            Text("播放的歌曲会显示在这里")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NowPlayingContent: View {
    let info: WidgetBridge.Snapshot
    let cover: UIImage?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        ZStack {
            // 背景：封面放大模糊
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

            if family == .systemSmall {
                smallLayout
            } else {
                mediumLayout
            }
        }
    }

    // 小尺寸：封面 + 标题 + 歌手
    private var smallLayout: some View {
        VStack(spacing: 8) {
            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.14))
                    .frame(width: 76, height: 76)
                    .overlay { Image(systemName: "music.note").foregroundStyle(.white.opacity(0.7)) }
            }

            Text(info.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(info.artist)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)

            if info.isPlaying {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.system(size: 9, weight: .semibold))
                    Text("正在播放")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.85))
            } else {
                Text("已暂停")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 中尺寸：左封面 + 右信息 + 进度
    private var mediumLayout: some View {
        HStack(spacing: 14) {
            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.14))
                    .frame(width: 96, height: 96)
                    .overlay { Image(systemName: "music.note").foregroundStyle(.white.opacity(0.7)) }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(info.isPlaying ? Color.green : Color.white.opacity(0.55))
                        .frame(width: 6, height: 6)
                    Text(info.isPlaying ? "正在播放" : "已暂停")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }

                Text(info.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(info.artist)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)

                Spacer(minLength: 2)

                // 进度条（时间会自动走，直到下次刷新）
                VStack(alignment: .leading, spacing: 3) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.25))
                            Capsule().fill(.white)
                                .frame(width: geo.size.width * min(1, max(0, progressFraction)))
                        }
                    }
                    .frame(height: 4)

                    HStack {
                        liveTimeText
                        Spacer()
                        Text("\(info.index)/\(info.total)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressFraction: Double {
        guard info.duration > 0 else { return 0 }
        return min(1, max(0, info.position / info.duration))
    }

    /// 正在播放时时间会自动走；暂停则显示定格时间
    @ViewBuilder
    private var liveTimeText: some View {
        if info.isPlaying, info.duration > 0 {
            let start = entry.date.addingTimeInterval(-info.position)
            let end = entry.date.addingTimeInterval(info.duration - info.position)
            Text(timerInterval: start...end, countsDown: false)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
        } else {
            Text(info.position.formattedTime)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

private extension TimeInterval {
    var formattedTime: String {
        guard self.isFinite, self >= 0 else { return "0:00" }
        let m = Int(self) / 60
        let s = Int(self) % 60
        return String(format: "%d:%02d", m, s)
    }
}
