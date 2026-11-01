import AVKit
import SwiftUI

/// 系统 AirPlay 路由选择按钮。
/// 点一下弹出系统的输出设备列表（Apple TV / HomePod / 蓝牙耳机…），
/// 正在投送时图标会变成高亮色（activeTintColor）。
struct AirPlayRouteButton: UIViewRepresentable {
    var tint: UIColor = .white
    var activeTint: UIColor = UIColor(red: 0.98, green: 0.42, blue: 0.44, alpha: 1) // Theme.accent

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tint
        view.activeTintColor = activeTint
        view.prioritizesVideoDevices = false   // 只列音频输出设备
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tint
        uiView.activeTintColor = activeTint
    }
}
