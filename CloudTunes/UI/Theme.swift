import SwiftUI

/// 全局设计变量：汤圆色系 + 自适应浅/深色
enum Theme {
    // 品牌色：汤圆粉 → 暖橘
    static let accent = Color(red: 0.98, green: 0.42, blue: 0.44)
    static let accentWarm = Color(red: 1.00, green: 0.64, blue: 0.36)
    static let accentGradient = LinearGradient(
        colors: [Color(red: 1.00, green: 0.50, blue: 0.46), Color(red: 1.00, green: 0.68, blue: 0.38)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    // 背景与卡片
    static let background = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.055, blue: 0.070, alpha: 1)
            : UIColor(red: 0.965, green: 0.965, blue: 0.975, alpha: 1)
    })
    static let surface = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.115, green: 0.115, blue: 0.135, alpha: 1)
            : UIColor.white
    })
    static let surfaceElevated = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.160, green: 0.160, blue: 0.185, alpha: 1)
            : UIColor(red: 0.985, green: 0.980, blue: 0.985, alpha: 1)
    })
    static let hairline = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.07)
            : UIColor(white: 0, alpha: 0.06)
    })
    static let folderTint = Color(red: 0.38, green: 0.58, blue: 0.98)

    // 尺寸
    static let radius: CGFloat = 18
    static let smallRadius: CGFloat = 12
    static let pagePadding: CGFloat = 16

    static func shadow(_ opacity: Double = 0.08) -> Color { Color.black.opacity(opacity) }
}
