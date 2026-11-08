import ActivityKit
import SwiftUI
import WidgetKit

/// 锁屏 / 灵动岛的滚动歌词卡片。
///
/// 说明：这是 iOS 16.1 起才有的「实时活动」，跟桌面小组件是两个不同机制——
/// 小组件靠时间线刷新（最快分钟级），歌词要跟着播放走，只能用它。
/// 更新由 App 主动推送（`Activity.update`），每换一句推一次，不需要 APNs。
@available(iOS 16.1, *)
struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LockScreenLyricsView(state: context.state)
                .activityBackgroundTint(Color(red: 0.075, green: 0.075, blue: 0.09))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        Image(systemName: "music.note")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accent)
                        Text(context.state.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.line.isEmpty ? "♪" : context.state.line)
                            .font(.system(size: 15, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if !context.state.nextLine.isEmpty {
                            Text(context.state.nextLine)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
            } compactTrailing: {
                // 灵动岛很窄，能塞下几个字就几个字
                Text(context.state.line.isEmpty ? "♪" : context.state.line)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 62)
            } minimal: {
                Image(systemName: "music.note")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .keylineTint(accent)
        }
    }

    private var accent: Color { Color(red: 1.0, green: 0.52, blue: 0.46) }
}

// MARK: - 锁屏卡片

@available(iOS 16.1, *)
private struct LockScreenLyricsView: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            headerRow

            VStack(alignment: .leading, spacing: 3) {
                Text(state.line.isEmpty ? "♪" : state.line)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .multilineTextAlignment(.leading)
                if !state.nextLine.isEmpty {
                    Text(state.nextLine)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            progressBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var headerRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "music.note")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.52, blue: 0.46))
            Text(state.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            if !state.artist.isEmpty {
                Text("· \(state.artist)")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var progressBar: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule()
                        .fill(Color(red: 1.0, green: 0.52, blue: 0.46))
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 3)

            HStack(spacing: 0) {
                Text(Self.timeText(state.position))
                Spacer()
                Text(Self.timeText(state.duration))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var fraction: CGFloat {
        guard state.duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, state.position / state.duration)))
    }

    private static func timeText(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
