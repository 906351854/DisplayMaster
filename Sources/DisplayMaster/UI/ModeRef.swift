import AppKit
import CoreGraphics

/// 把「显示器 + 目标模式」打包进菜单项
final class ModeRef: NSObject {
    let display: CGDirectDisplayID
    let mode: CGDisplayMode
    init(display: CGDirectDisplayID, mode: CGDisplayMode) {
        self.display = display
        self.mode = mode
    }
}
