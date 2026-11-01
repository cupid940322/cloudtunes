import AVFoundation
import Combine

/// 监听当前音频输出口，判断是不是正在用 AirPlay 投送。
/// 播放页据此提示用户「AirPlay 只传声音，想看歌词要用屏幕镜像」。
@MainActor
final class AudioRouteMonitor: ObservableObject {
    static let shared = AudioRouteMonitor()

    /// 当前输出是不是 AirPlay（Apple TV / HomePod / 支持 AirPlay 的音箱）
    @Published private(set) var isAirPlay = false
    /// 输出设备名，如「客厅」「Apple TV」
    @Published private(set) var outputName: String = ""

    private var cancellable: AnyCancellable?

    private init() {
        refresh()
        cancellable = NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
    }

    private func refresh() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        isAirPlay = outputs.contains { $0.portType == .airPlay }
        outputName = outputs.first?.portName ?? ""
    }
}
