import AppKit
import CoreGraphics

extension NSScreen {
    /// 按 displayID 找对应的 NSScreen（浮层要显示在目标那块屏上）
    static func of(displayID: CGDirectDisplayID) -> NSScreen? {
        for s in screens {
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDirectDisplayID(n.uint32Value) == displayID else { continue }
            return s
        }
        return nil
    }
}

/// 调亮度的提示浮层。
///
/// **这不是锦上添花，是吞事件的必要配套。** 亮度键被我们拦下来之后，
/// 系统的 HUD 不会再出现 —— 用户按了键只看到屏幕亮了一点，不知道现在第几档、
/// 也不知道刚才那一下到底调的是哪台屏（多屏时尤其要紧）。
///
/// 背景是**自己画的**，不用 `NSVisualEffectView`：
/// 原本用 `.hudWindow` 材质并假定它恒为暗色，实测在 macOS 26（Tahoe）上不成立 ——
/// Tahoe 的材质改成了浅色玻璃，白色内容直接糊在浅底上，几乎看不见
/// （2026-09-25 截图核对时抓到的）。自己画一层深色底在这件事上是更稳的选择：
/// 深浅主题、各代系统下表现一致，不依赖 Apple 改材质。
final class BrightnessOSD {
    static let shared = BrightnessOSD()

    private var window: NSWindow?
    private var view: BrightnessOSDView?
    private var hideWork: DispatchWorkItem?

    private static let size = NSSize(width: 214, height: 52)
    /// 显示多久（每按一下都重新计时）
    private static let visibleDuration: TimeInterval = 0.9
    /// 距屏幕上沿的距离
    private static let topGap: CGFloat = 88

    private init() {}

    /// 显示一次。`percent == nil` 时显示 `note`（读不到 / 不可控）。
    func show(percent: Int?, note: String?, direction: Int, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let w = ensureWindow()
        let origin = NSPoint(x: screen.frame.midX - Self.size.width / 2,
                             y: screen.frame.maxY - Self.size.height - Self.topGap)
        w.setFrame(NSRect(origin: origin, size: Self.size), display: false)

        view?.percent = percent
        view?.note = note
        view?.direction = direction
        view?.needsDisplay = true

        hideWork?.cancel()
        w.alphaValue = 1
        // orderFrontRegardless：应用不是前台时也要显示（调亮度时用户通常不在本应用里）
        w.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: work)
    }

    /// 开发用：`--shot-osd` 拿它来截图核对排版
    var debugWindow: NSWindow? { window }

    private func fadeOut() {        guard let w = window, w.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            w.animator().alphaValue = 0
        }, completionHandler: { w.orderOut(nil) })
    }

    private func ensureWindow() -> NSWindow {
        if let w = window { return w }

        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        // 全屏应用之上也得看得见（调亮度正是全屏看片时最常发生的事）
        w.level = .screenSaver
        w.ignoresMouseEvents = true        // 绝不能挡住点击
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                .stationary, .ignoresCycle]
        w.isReleasedWhenClosed = false

        let effect = NSView(frame: NSRect(origin: .zero, size: Self.size))
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        let v = BrightnessOSDView(frame: NSRect(origin: .zero, size: Self.size))
        v.autoresizingMask = [.width, .height]
        effect.addSubview(v)
        w.contentView = effect

        window = w
        view = v
        return w
    }
}

/// 浮层内容：图标 + 进度条 + 百分比（或一行说明）
final class BrightnessOSDView: NSView {
    var percent: Int?
    var note: String?
    /// +1 / -1，只用来决定图标往哪边指
    var direction: Int = 1

    private let inset: CGFloat = 14
    private let iconBox: CGFloat = 20
    private let iconGap: CGFloat = 9
    private let percentWidth: CGFloat = 40
    private let barHeight: CGFloat = 6

    override func draw(_ dirtyRect: NSRect) {
        // 深色底自己画（理由见 BrightnessOSD 类注释）。既然底一定是深的，
        // 内容就一律用白色系 —— 不跟随明暗主题，省掉一整类「浅色桌面上看不清」的问题。
        NSColor(white: 0.11, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()

        let primary = NSColor.white.withAlphaComponent(0.95)
        let trackColor = NSColor.white.withAlphaComponent(0.26)

        let symbol: String
        if note != nil {
            symbol = "exclamationmark.triangle.fill"
        } else {
            symbol = direction > 0 ? "sun.max.fill" : "sun.min.fill"
        }

        // —— 图标 ——
        var x = inset
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [primary]))
            let icon = img.withSymbolConfiguration(cfg) ?? img
            let s = icon.size
            icon.draw(in: NSRect(x: x, y: (bounds.height - s.height) / 2,
                                 width: s.width, height: s.height),
                      from: .zero, operation: .sourceOver, fraction: 1)
        }
        x += iconBox + iconGap

        if let note {
            // 读不到时不给进度条 —— 画一条空轨道会被当成「亮度是 0」
            let text = NSAttributedString(string: note, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5),
                .foregroundColor: primary
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
            return
        }

        let pct = max(0, min(100, percent ?? 0))
        let barWidth = bounds.width - x - percentWidth - inset
        let barY = (bounds.height - barHeight) / 2

        // —— 轨道 ——
        let track = NSBezierPath(roundedRect: NSRect(x: x, y: barY, width: barWidth, height: barHeight),
                                 xRadius: barHeight / 2, yRadius: barHeight / 2)
        trackColor.setFill()
        track.fill()

        // —— 已填充部分。最低留一点宽度：0% 时整条空着像是坏了 ——
        let fillWidth = max(barHeight, barWidth * CGFloat(pct) / 100)
        let fill = NSBezierPath(roundedRect: NSRect(x: x, y: barY, width: fillWidth, height: barHeight),
                                xRadius: barHeight / 2, yRadius: barHeight / 2)
        primary.setFill()
        fill.fill()

        // —— 百分比 ——
        let text = NSAttributedString(string: "\(pct)%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: primary
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.width - inset - size.width,
                              y: (bounds.height - size.height) / 2))
    }
}
