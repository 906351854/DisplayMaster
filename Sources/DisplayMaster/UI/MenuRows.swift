import AppKit
import CoreGraphics

// MARK: - 全局开关行

/// 「有外接屏时自动关闭内置屏」那一行。
///
/// 开关由我们自己画：自己画能保证在任何状态下都长得一样，顺带整行都可以点
/// （点击来源同样是菜单项的动作）。
final class ToggleRowView: NSView {
    private(set) var isOn = false
    private(set) var title = ""
    private(set) var subtitle: String?

    /// 面板宽度。卡片行会随显示器台数变宽，底部这些行得跟着走，否则右端的开关对不齐
    var rowWidth: CGFloat = PanelStyle.minWidth

    func configure(title: String, subtitle: String?, on: Bool, width: CGFloat) {
        self.title = title
        self.subtitle = subtitle
        self.isOn = on
        self.rowWidth = width
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let hasSub = subtitle != nil
        let textY = hasSub ? bounds.midY + 1 : bounds.midY - 8

        let attr = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ])
        attr.draw(at: NSPoint(x: PanelStyle.margin, y: textY))
        if let sub = subtitle {
            NSAttributedString(string: sub, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]).draw(at: NSPoint(x: PanelStyle.margin, y: textY - 14))
        }

        let sw = NSRect(x: rowWidth - PanelStyle.margin - PanelStyle.switchWidth,
                        y: bounds.midY - PanelStyle.switchHeight / 2,
                        width: PanelStyle.switchWidth, height: PanelStyle.switchHeight)
        panelDrawSwitch(in: sw, on: isOn, enabled: true)
    }

    // MARK: 点击

    override func mouseDown(with event: NSEvent) {
        // 吃掉按下，等抬起再把 action 转给菜单项（见 panelForwardClick）
    }

    override func mouseUp(with event: NSEvent) {
        panelForwardClick(from: self, at: convert(event.locationInWindow, from: nil))
    }
}

// MARK: - 返回行（详情页用）

/// 详情页顶部的「返回」行。整个菜单两层，返回放最上面，符合系统菜单的惯例
/// （Wi-Fi、蓝牙那些菜单也是这么做的）。
final class BackRowView: NSView {
    var title = "返回显示器列表"
    var rowWidth: CGFloat = PanelStyle.minWidth

    override func draw(_ dirtyRect: NSRect) {
        panelDrawSymbol("chevron.backward", height: 11,
                        center: NSPoint(x: PanelStyle.margin + 4, y: bounds.midY),
                        tint: .controlAccentColor)
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.controlAccentColor
        ]).draw(at: NSPoint(x: PanelStyle.margin + 14, y: bounds.midY - 8))
    }

    // MARK: 点击

    override func mouseDown(with event: NSEvent) {
        // 吃掉按下，等抬起再把 action 转给菜单项（见 panelForwardClick）
    }

    override func mouseUp(with event: NSEvent) {
        panelForwardClick(from: self, at: convert(event.locationInWindow, from: nil))
    }
}

// MARK: - 详情页顶部信息

/// 详情页顶部那张横幅：缩略图 + 名字 + 面板规格 + 当前正在用的那一档。
///
/// 这里**不再重复**放亮度条、分辨率滑块和开关 —— 那些已经在那张屏自己的卡片上了。
/// 详情页只负责「卡片上放不下的东西」：完整分辨率列表、DDC 重检、忘记。
final class DetailHeaderView: NSView {

    private var card: CardsRowView.Card?
    var rowWidth: CGFloat = PanelStyle.minWidth

    func configure(card: CardsRowView.Card, width: CGFloat) {
        self.card = card
        self.rowWidth = width
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let card = card else { return }
        let rect = NSRect(x: PanelStyle.margin, y: 4,
                          width: rowWidth - 2 * PanelStyle.margin, height: bounds.height - 8)
        let path = NSBezierPath(roundedRect: rect, xRadius: PanelStyle.cardRadius,
                                yRadius: PanelStyle.cardRadius)
        PanelStyle.cardFill.setFill()
        path.fill()
        PanelStyle.cardStroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let dim = !card.isOn
        panelDrawDisplayThumb(in: NSRect(x: rect.minX + PanelStyle.cardPadding,
                                         y: rect.midY - PanelStyle.thumbHeight / 2,
                                         width: 62, height: PanelStyle.thumbHeight),
                              aspect: card.aspect, isBuiltin: card.isBuiltin, dimmed: dim)

        let textX = rect.minX + PanelStyle.cardPadding + 74
        let textW = rect.maxX - PanelStyle.cardPadding - textX
        panelDrawText(card.title, in: NSRect(x: textX, y: rect.midY + 14, width: textW, height: 17),
                      font: .systemFont(ofSize: 13, weight: .semibold),
                      color: dim ? .tertiaryLabelColor : .labelColor)
        panelDrawText(card.model, in: NSRect(x: textX, y: rect.midY - 2, width: textW, height: 15),
                      font: .systemFont(ofSize: 10.5), color: .secondaryLabelColor)
        // 当前这一档 + 面板规格。卡片上这两样分在两处（滑块行 / 规格行），
        // 这里干脆并成一行，一眼能对上「现在多大、面板多大」
        panelDrawText("当前 " + card.resolution + (card.resolutionHiDPI ? " HiDPI" : "")
                      + "  ·  面板 " + card.spec,
                      in: NSRect(x: textX, y: rect.midY - 20, width: textW, height: 14),
                      font: .systemFont(ofSize: 9.5), color: .tertiaryLabelColor)
    }
}
