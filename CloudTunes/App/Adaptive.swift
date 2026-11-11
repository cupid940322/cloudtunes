import SwiftUI
import UIKit

/// 大屏（iPad）适配的几个公共常量与修饰器。
///
/// 判断「是否 iPad」为什么要看 size class：iPad 开分屏 / 台前调度时窗口可能很窄，
/// 这时候按键面式布局排才不挤。所以统一用 `isPadRegular` = 设备是 iPad 且宽度是 regular。
enum Adaptive {
    static var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// 主内容区最大宽度：iPad 上别让列表和文字贴着两边拉得太开
    static let contentMaxWidth: CGFloat = 900

    /// 播放页宽到这个阈值就切「左封面 / 右歌词+控件」的分栏布局
    static let widePlayerThreshold: CGFloat = 700

    /// 专辑墙每列的最小宽度（列数由可用宽度自动算）
    static let albumColumnMin: CGFloat = 150
    static let albumColumnMax: CGFloat = 220
}

extension View {
    /// 内容限宽居中。iPhone 上等同于不生效，iPad 横屏时避免一行文字拉太宽。
    func readableWidth(_ maxWidth: CGFloat = Adaptive.contentMaxWidth) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}
