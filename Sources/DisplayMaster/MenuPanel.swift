import AppKit
import CoreGraphics

/// 自绘面板的尺寸与配色。
///
/// 集中放一处是有原因的：菜单里原生项和自绘项会并排出现，
/// 面板宽度、左右留白这些数字必须一起调，否则两边的文字列对不齐。
enum PanelStyle {
    /// 面板宽度。菜单最终宽度 = max(面板宽, 原生项宽)，所以这里也是菜单的主要宽度来源
    static let width: CGFloat = 372
    /// 左右内边距。取 18 是为了让卡片左边缘和原生菜单项的图标列对齐
    static let margin: CGFloat = 18
    /// 上边距。菜单项视图是顶着菜单窗口上沿放的，不留白第一行文字会被圆角切掉
    static let topInset: CGFloat = 8
    static let bottomInset: CGFloat = 10
    static let gap: CGFloat = 12
    static let cardHeight: CGFloat = 84
    static let nameHeight: CGFloat = 18
    /// 亮度行的高度。要能装下最粗的那枚圆头，不然会被上下裁掉
    static let sliderRowHeight: CGFloat = 34
    static let toggleHeight: CGFloat = 40
    static let arrowWidth: CGFloat = 16
    static let cardRadius: CGFloat = 12
    /// 一页最多几张卡。再多会挤到看不清分辨率，宁可翻页
    static let maxCardsPerPage = 3

    // 亮度行：手稿里是「一枚圆形图标 + 一条明显的粗胶囊」。
    // 三组尺寸必须一起调 —— 圆头比轨道高才会从轨道里"鼓"出来，
    // 轨道太细又会退回成系统滑块的细线，就没了手稿那种量感。
    static let badgeDiameter: CGFloat = 24
    static let trackHeight: CGFloat = 14
    static let knobDiameter: CGFloat = 20
    /// 圆形徽章与轨道之间的间隔
    static let badgeGap: CGFloat = 8

    /// 卡片底色。用 labelColor 而不是写死白色，菜单在浅色/深色下都成立
    static var cardFill: NSColor { NSColor.labelColor.withAlphaComponent(0.06) }
    static var cardStroke: NSColor { NSColor.labelColor.withAlphaComponent(0.12) }
    static var hairline: NSColor { NSColor.labelColor.withAlphaComponent(0.10) }
    static var track: NSColor { NSColor.labelColor.withAlphaComponent(0.18) }
    static var hoverFill: NSColor { NSColor.labelColor.withAlphaComponent(0.13) }

    static func rowHeight(cardCount: Int) -> CGFloat {
        topInset + nameHeight + cardHeight + sliderRowHeight + bottomInset
    }
}

/// 按给定高度**等比**绘制一枚 SF Symbol。
///
/// 必须自己算尺寸：`draw(in:)` 会把图片拉满整个矩形，显示器图形是横向的，
/// 直接给个正方形矩形就会被纵向拉长。
///
/// 颜色必须走 `paletteColors` 烘进图片里，**不能用 `tint.set()` + 模板图**：
/// 模板图在 `draw(in:from:operation:...)` 这条路径上并不吃当前的填充色，
/// 结果是一律画成黑色 —— 深色菜单下卡片图标、太阳、箭头会集体变成黑疙瘩，
/// 而且因为「黑也是能看见的」，很容易一路看着像没问题。
func panelDrawSymbol(_ name: String, height: CGFloat, center: NSPoint, tint: NSColor,
                     weight: NSFont.Weight = .regular) {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
    let config = NSImage.SymbolConfiguration(pointSize: height, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
    guard let image = base.withSymbolConfiguration(config) else { return }
    guard image.size.height > 0, image.size.width > 0 else { return }
    let scale = height / image.size.height
    let size = NSSize(width: image.size.width * scale, height: height)
    image.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height),
               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

// MARK: - 亮度滑块

/// 亮度滑块。
///
/// 为什么要自己画 track / 填充 / 滑块头：系统滑块的填充色**只在 app 处于活跃状态时才画**。
/// 菜单项视图里的活跃态并不可靠 —— 用户看到的就是「外接屏那条亮度条的蓝色丢了，
/// 内屏那条还在」，同一次打开的菜单里两条颜色都不一样。自绘之后颜色由我们自己定，
/// 跟活跃态彻底脱钩。
final class BrightnessSlider: NSSlider {
    /// 松手回调。拖动过程中 NSSlider 只保证「连续动作」，拿不到可靠的松手时机，
    /// 而最后一档亮度必须确保落到显示器上。
    var onRelease: (() -> Void)?
    /// 填充色。这里刻意用一个确定的值，不再交给系统按状态挑
    var fillColor: NSColor = .controlAccentColor

    private var trackHeight: CGFloat { PanelStyle.trackHeight }
    private var knobDiameter: CGFloat { PanelStyle.knobDiameter }

    override func draw(_ dirtyRect: NSRect) {
        guard let cell = cell as? NSSliderCell else { return }
        // 轨道画满整个控件宽度（两端各留 2pt），滑块头的位置仍旧问系统要 ——
        // 系统中把轨道按滑块头尺寸往里缩，那样看起来会比手稿短一截。
        let knob = cell.knobRect(flipped: false)
        let radius = trackHeight / 2
        let trackRect = NSRect(x: 2, y: bounds.midY - radius,
                               width: max(bounds.width - 4, trackHeight), height: trackHeight)
        PanelStyle.track.setFill()
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius)
        trackPath.fill()
        // 描一圈极淡的边：深色菜单下轨道和背景几乎同色，没这圈边就看不出轨道长度
        PanelStyle.cardStroke.setStroke()
        trackPath.lineWidth = 1
        trackPath.stroke()

        // 填充段从轨道左端一直画到滑块头中心
        let filled = max(trackHeight, knob.midX - trackRect.minX)
        let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY, width: filled, height: trackHeight)
        (isEnabled ? fillColor : fillColor.withAlphaComponent(0.45)).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()

        // 轨道左端内嵌的小太阳：手稿里就是这么画的，也是 macOS 控制中心亮度条的惯例。
        // 先画太阳再画圆头 —— 亮度很低、圆头压过来的时候，圆头自然会把它盖住，
        // 不需要额外判断"要不要隐藏"。
        drawTrackSun(in: trackRect, knob: knob)

        let knobRect = NSRect(x: knob.midX - knobDiameter / 2, y: bounds.midY - knobDiameter / 2,
                              width: knobDiameter, height: knobDiameter)
        let kp = NSBezierPath(ovalIn: knobRect)
        NSColor.white.setFill()
        kp.fill()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        kp.lineWidth = 0.5
        kp.stroke()
    }

    /// 轨道左端的那枚小太阳。压在蓝色填充上要够白，压在空轨道上也要看得见，
    /// 所以按圆头的位置挑颜色：填充盖到它头上就用白色，否则用文字色。
    private func drawTrackSun(in trackRect: NSRect, knob: NSRect) {
        let center = NSPoint(x: trackRect.minX + trackRect.height / 2 + 7, y: trackRect.midY)
        let covered = knob.midX > center.x
        let tint = covered ? NSColor.white.withAlphaComponent(0.92)
                           : NSColor.labelColor.withAlphaComponent(0.5)
        panelDrawSymbol("sun.max", height: 10, center: center, tint: tint)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onRelease?()
    }
}

// MARK: - 亮度行左侧的圆形徽章

/// 手稿里每条亮度轨道前面还单独画了一枚圆形图标。它的职责和轨道内的小太阳不同：
/// 那枚是"这段范围有多亮"的刻度，这枚是"这一行调的是亮度"的身份标识，
/// 顺便把当前档位也表达出来（暗 → 小太阳，亮 → 大太阳）。
func panelDrawBrightnessBadge(in rect: NSRect, brightness: Double, dimmed: Bool) {
    let circle = NSBezierPath(ovalIn: rect)
    // 徽章要跟右边的粗轨道分量相当，底子太淡整行就左轻右重、看着像没画完
    NSColor.labelColor.withAlphaComponent(0.16).setFill()
    circle.fill()
    NSColor.labelColor.withAlphaComponent(0.22).setStroke()
    circle.lineWidth = 1
    circle.stroke()

    // 太阳用 labelColor 而不是 secondary —— 小字号下 secondary 一淡就成了一团灰
    let tint = dimmed ? NSColor.tertiaryLabelColor : NSColor.labelColor.withAlphaComponent(0.85)
    panelDrawSymbol(brightness < 0.5 ? "sun.min" : "sun.max",
                    height: 13, center: NSPoint(x: rect.midX, y: rect.midY),
                    tint: tint, weight: .medium)
}

/// 菜单项里的自绘视图，要自己把点击转成菜单动作。
///
/// AppKit 只在菜单项**没有**自定义视图的时候才代发 action：一旦给 `item.view` 挂了视图，
/// 这一下点击就整个交给视图，菜单不再管。于是所有「看着能点」的自绘行全都点不动 ——
/// 点卡片不进详情页、点开关不切换、点返回不回去，只有滑块还能拖（NSSlider 自己处理鼠标）。
/// 实测确认：点开关那一行，菜单不关、开关也不动。
///
/// 所以统一下面这一套：按下时先吃掉事件 —— 不这么做的话，菜单会在按下的瞬间
/// 就自己关掉，根本轮不到抬起；抬起时再把 action 转交给菜单项。
/// `point` 传视图坐标，落在自己身上才算数（按下后又拖出去松手应当作废）。
func panelForwardClick(from view: NSView, at point: NSPoint) {
    guard view.bounds.contains(point) else { return }
    guard let item = view.enclosingMenuItem, let action = item.action else { return }
    NSApp.sendAction(action, to: item.target, from: item)
}



// MARK: - 卡片行

/// 一行显示器卡片：一台屏一张卡，卡片下方是它自己的亮度条。
///
/// 整个卡片行是**一个菜单项**，点击由 AppKit 走正常的菜单动作 —— 视图自己去接管鼠标
/// 在菜单里并不可靠（菜单的跟踪循环把鼠标事件当选择处理），所以点击落到哪张卡上，
/// 由动作里反查鼠标位置来决定。
final class CardsRowView: NSView {

    struct Card {
        let id: CGDirectDisplayID
        let name: String
        let isBuiltin: Bool
        let isMain: Bool
        let resolution: String
        let brightness: Double?
        /// 亮度不可控时的原因（外面那圈说明文字）
        let note: String?
    }

    private(set) var cards: [Card] = []
    private(set) var page = 0
    private(set) var pages = 1
    private(set) var sliders: [BrightnessSlider] = []
    /// 每台屏的亮度数值标签，供「写入无应答」就地把数字换成提示
    private(set) var valueLabels: [CGDirectDisplayID: NSTextField] = [:]

    private var cardRects: [NSRect] = []
    private var nameRects: [NSRect] = []
    private var slotRects: [NSRect] = []
    /// 每张卡前面那枚圆形亮度徽章的位置；窄卡片下是 .zero（不画）
    private var badgeRects: [NSRect] = []
    private var prevArrow = NSRect.zero
    private var nextArrow = NSRect.zero
    private var hoveredCard: Int?

    override var isFlipped: Bool { false }

    // MARK: 配置

    func configure(cards: [Card], keepingPage: Int,
                   sliderTarget: AnyObject?, sliderAction: Selector) {
        self.cards = cards
        self.page = keepingPage
        subviews.forEach { $0.removeFromSuperview() }
        sliders.removeAll()
        valueLabels.removeAll()
        cardRects.removeAll()
        nameRects.removeAll()
        slotRects.removeAll()
        badgeRects.removeAll()

        pages = max(1, Int(ceil(Double(cards.count) / Double(PanelStyle.maxCardsPerPage))))
        page = min(max(page, 0), pages - 1)

        let showArrows = pages > 1
        let left = PanelStyle.margin + (showArrows ? PanelStyle.arrowWidth : 0)
        let right = PanelStyle.width - PanelStyle.margin - (showArrows ? PanelStyle.arrowWidth : 0)
        let start = page * PanelStyle.maxCardsPerPage
        let visible = Array(cards[start..<min(start + PanelStyle.maxCardsPerPage, cards.count)])
        let count = max(visible.count, 1)
        let colW = (right - left - PanelStyle.gap * CGFloat(count - 1)) / CGFloat(count)

        let top = PanelStyle.bottomInset + PanelStyle.sliderRowHeight + PanelStyle.cardHeight
        for (i, card) in visible.enumerated() {
            let x = left + CGFloat(i) * (colW + PanelStyle.gap)
            let slot = NSRect(x: x, y: 0, width: colW, height: PanelStyle.rowHeight(cardCount: count))
            slotRects.append(slot)
            nameRects.append(NSRect(x: x, y: top, width: colW, height: PanelStyle.nameHeight))
            cardRects.append(NSRect(x: x, y: PanelStyle.bottomInset + PanelStyle.sliderRowHeight,
                                    width: colW, height: PanelStyle.cardHeight))

            // 亮度行：左边一枚圆形徽章，右边是粗胶囊轨道；不可控时整行改成一句说明。
            // 卡片窄到放不下徽章时（三张一页、或者带翻页箭头）就只留轨道 ——
            // 轨道左端本来就嵌了一枚小太阳，少了徽章也还认得出这行是干什么的。
            if card.brightness != nil {
                let showBadge = colW >= 132
                let lead = showBadge ? PanelStyle.badgeDiameter + PanelStyle.badgeGap : 0
                let rowY = PanelStyle.bottomInset + (PanelStyle.sliderRowHeight - PanelStyle.badgeDiameter) / 2
                badgeRects.append(showBadge
                    ? NSRect(x: x, y: rowY, width: PanelStyle.badgeDiameter, height: PanelStyle.badgeDiameter)
                    : .zero)

                let slider = BrightnessSlider(value: (card.brightness ?? 0) * 100,
                                              minValue: 0, maxValue: 100,
                                              target: sliderTarget, action: sliderAction)
                slider.isContinuous = true
                slider.tag = Int(card.id)
                slider.fillColor = .controlAccentColor
                slider.onRelease = { [weak self, weak slider] in
                    guard let slider = slider else { return }
                    self?.onSliderRelease?(CGDirectDisplayID(slider.tag))
                }
                slider.frame = NSRect(x: x + lead, y: PanelStyle.bottomInset,
                                      width: colW - lead - 2, height: PanelStyle.sliderRowHeight)
                addSubview(slider)
                sliders.append(slider)
            } else {
                badgeRects.append(.zero)
            }

            // 卡片右上角的亮度数值。卡片太窄时会和居中的图形挤在一起，那就先藏着 ——
            // 亮度本来就有更直观的表达（滑块的位置），拖动时数字也会立刻出现。
            let label = NSTextField(labelWithString: card.brightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
            label.frame = NSRect(x: cardRects[i].maxX - 8 - 48, y: cardRects[i].maxY - 8 - 13,
                                 width: 48, height: 13)
            label.alignment = .right
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = .tertiaryLabelColor
            label.isHidden = card.brightness == nil || colW < 140
            addSubview(label)
            valueLabels[card.id] = label
        }

        if showArrows {
            let cy = PanelStyle.bottomInset + PanelStyle.sliderRowHeight + PanelStyle.cardHeight / 2
            prevArrow = NSRect(x: 2, y: cy - 9, width: PanelStyle.arrowWidth, height: 18)
            nextArrow = NSRect(x: PanelStyle.width - 2 - PanelStyle.arrowWidth, y: cy - 9,
                               width: PanelStyle.arrowWidth, height: 18)
        } else {
            prevArrow = .zero
            nextArrow = .zero
        }
    }

    /// 松手后把最后一档亮度落到显示器上
    var onSliderRelease: ((CGDirectDisplayID) -> Void)?

    // MARK: 命中判定

    enum Hit {
        case card(CGDirectDisplayID)
        case pagePrev
        case pageNext
        case slider
        case none
    }

    /// 用鼠标当前位置反查点到了什么。
    /// 菜单项的动作是从 AppKit 过来的，拿不到点击坐标，只能这样反查。
    func hitAtMouse() -> Hit {
        guard let window = window else { return .none }
        let inWindow = window.convertFromScreen(NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        return hit(convert(inWindow, from: nil))
    }

    func hit(_ point: NSPoint) -> Hit {
        if prevArrow != .zero, prevArrow.insetBy(dx: -4, dy: -6).contains(point), page > 0 {
            return .pagePrev
        }
        if nextArrow != .zero, nextArrow.insetBy(dx: -4, dy: -6).contains(point), page < pages - 1 {
            return .pageNext
        }
        // 滑块优先：拖亮度绝不能被当成「点开设置」
        for slider in sliders where slider.frame.insetBy(dx: -2, dy: -4).contains(point) {
            return .slider
        }
        for (i, rect) in slotRects.enumerated() where rect.contains(point) {
            return .card(cards[page * PanelStyle.maxCardsPerPage + i].id)
        }
        return .none
    }

    /// 开发用：把真实光标移到第 n 张卡的中心。
    /// 换页自测靠它 —— 命中判定读的就是真实光标位置，这样测出来的才是真链路。
    @discardableResult
    func warpMouseToCard(_ index: Int) -> String {
        let first = page * PanelStyle.maxCardsPerPage
        guard index >= first, index - first < slotRects.count, let window = window else {
            return "光标没挪（下标越界或窗口不在）"
        }
        let rect = slotRects[index - first]
        let inWindow = convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        guard let bounds = Self.windowBounds(window) else { return "拿不到窗口坐标" }
        // 屏幕坐标换算一律走窗口的 CG bounds：Cocoa 全局坐标的原点跟 CG 的不一定重合
        // （多屏排列时差得过 30pt 都有过），差一点点就挪到菜单外面去了
        let point = CGPoint(x: bounds.origin.x + inWindow.x,
                            y: bounds.origin.y + bounds.height - inWindow.y)
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        return "光标 → \(Int(point.x)),\(Int(point.y))  窗口CG \(bounds) 窗口Cocoa \(window.frame)"
    }

    /// 窗口在 CG 全局坐标里的位置（原点在左上）
    static func windowBounds(_ window: NSWindow) -> CGRect? {
        guard let infos = CGWindowListCopyWindowInfo([.optionIncludingWindow],
                                                     CGWindowID(window.windowNumber)) as? [[String: Any]],
              let bd = infos.first?["kCGWindowBounds"] as? [String: CGFloat],
              let x = bd["X"], let y = bd["Y"], let w = bd["Width"], let h = bd["Height"] else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        let start = page * PanelStyle.maxCardsPerPage
        for i in slotRects.indices {
            let card = cards[start + i]
            drawName(card, in: nameRects[i])
            drawCard(card, in: cardRects[i], hovered: hoveredCard == i)
            if card.brightness != nil {
                if badgeRects[i] != .zero {
                    panelDrawBrightnessBadge(in: badgeRects[i],
                                             brightness: card.brightness ?? 0,
                                             dimmed: false)
                }
            } else {
                drawNote(card.note ?? "亮度不可控", in: cardRects[i])
            }
        }
        if pages > 1 { drawPager() }
    }

    private func drawName(_ card: Card, in rect: NSRect) {
        var text = card.name
        if card.isMain { text += "  ·  主屏" }
        // 名字宁可中间省略：卡片窄的时候，末尾被截掉的往往是「Display」这种关键信息
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingMiddle
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para
        ])
        attr.draw(with: NSRect(x: rect.minX, y: rect.minY + 2, width: rect.width, height: 15),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawCard(_ card: Card, in rect: NSRect, hovered: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: PanelStyle.cardRadius,
                                yRadius: PanelStyle.cardRadius)
        (hovered ? PanelStyle.hoverFill : PanelStyle.cardFill).setFill()
        path.fill()
        PanelStyle.cardStroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        // 显示器图形：用系统符号，笔记本/外接一眼能分出来 —— 手稿里也是这么画的
        panelDrawSymbol(card.isBuiltin ? "laptopcomputer" : "display",
                        height: 34, center: NSPoint(x: rect.midX, y: rect.minY + 60),
                        tint: .labelColor)

        let res = NSAttributedString(string: card.resolution, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        let resSize = res.size()
        res.draw(in: NSRect(x: rect.midX - resSize.width / 2, y: rect.minY + 13,
                            width: resSize.width, height: 14))
    }

    private func drawNote(_ text: String, in cardRect: NSRect) {
        let attr = NSAttributedString(string: "⚠︎ " + text, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        let line = NSRect(x: cardRect.minX, y: 6, width: cardRect.width, height: 26)
        attr.draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawPager() {
        let tint = NSColor.secondaryLabelColor
        for (rect, name, enabled) in [(prevArrow, "chevron.left", page > 0),
                                      (nextArrow, "chevron.right", page < pages - 1)] {
            guard rect != .zero else { continue }
            panelDrawSymbol(name, height: 11, center: NSPoint(x: rect.midX, y: rect.midY),
                            tint: enabled ? tint : tint.withAlphaComponent(0.3))
        }
        if pages > 1 {
            let text = "\(page + 1)/\(pages)"
            let attr = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor
            ])
            attr.draw(at: NSPoint(x: PanelStyle.width - PanelStyle.margin - 22,
                                  y: PanelStyle.bottomInset - 8))
        }
    }

    // MARK: 悬停

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = slotRects.firstIndex { $0.contains(point) }
        if index != hoveredCard {
            hoveredCard = index
            // 悬停在哪张卡上就亮出哪张卡的亮度数字，移开就收起来
            let start = page * PanelStyle.maxCardsPerPage
            for (i, rect) in slotRects.enumerated() where rect != .zero {
                guard start + i < cards.count else { continue }
                if let label = valueLabels[cards[start + i].id] {
                    label.isHidden = (i != index) && rect.width < 140
                }
            }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredCard != nil { hoveredCard = nil; needsDisplay = true }
    }

    // MARK: 点击

    override func mouseDown(with event: NSEvent) {
        // 特意什么都不做：让菜单别在按下的瞬间自己关掉，等抬起再决定
    }

    override func mouseUp(with event: NSEvent) {
        panelForwardClick(from: self, at: convert(event.locationInWindow, from: nil))
    }
}

// MARK: - 已关闭显示器的重新打开行

/// 「XX（已关闭）」那一行。
///
/// 这条本来是个原生菜单项，但它的标题太长（名字 + 一段中文说明），
/// 会把整张菜单**撑得比自绘面板还宽** —— 卡片只有 372pt，菜单却到 420pt，
/// 右边空出一大块，图形化的面板看起来就像没对齐。
/// 改成自绘之后宽度锁死在面板宽度上，名字再长也只是中间省略。
final class ReopenRowView: NSView {
    private(set) var name = ""

    func configure(name: String) {
        self.name = name
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let iconY = bounds.midY
        panelDrawSymbol("display", height: 14,
                        center: NSPoint(x: PanelStyle.margin + 7, y: iconY),
                        tint: .secondaryLabelColor)

        let hint = "已关闭 · 点此重开"
        let hintAttr = NSAttributedString(string: hint, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor
        ])
        let hintW = hintAttr.size().width
        hintAttr.draw(at: NSPoint(x: PanelStyle.width - PanelStyle.margin - hintW,
                                  y: bounds.midY - 7))

        let nameX = PanelStyle.margin + 20
        NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ]).draw(with: NSRect(x: nameX, y: bounds.midY - 8,
                             width: PanelStyle.width - PanelStyle.margin - hintW - 10 - nameX,
                             height: 17),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: 点击

    override func mouseDown(with event: NSEvent) {
        // 吃掉按下，等抬起再把 action 转给菜单项（见 panelForwardClick）
    }

    override func mouseUp(with event: NSEvent) {
        panelForwardClick(from: self, at: convert(event.locationInWindow, from: nil))
    }
}

// MARK: - 全局开关行

/// 「有外接屏时自动关闭内置屏」那一行。
///
/// 开关由我们自己画：手稿里就是个胶囊 + 圆钮，自己画能保证在任何状态下都长得一样，
/// 顺带整行都可以点（点击来源同样是菜单项的动作）。
final class ToggleRowView: NSView {
    private(set) var isOn = false
    private(set) var title = ""
    private(set) var subtitle: String?

    func configure(title: String, subtitle: String?, on: Bool) {
        self.title = title
        self.subtitle = subtitle
        self.isOn = on
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

        // 胶囊开关
        let w: CGFloat = 40, h: CGFloat = 23
        let box = NSRect(x: PanelStyle.width - PanelStyle.margin - w,
                         y: bounds.midY - h / 2, width: w, height: h)
        let capsule = NSBezierPath(roundedRect: box, xRadius: h / 2, yRadius: h / 2)
        (isOn ? NSColor.controlAccentColor : PanelStyle.track).setFill()
        capsule.fill()
        if !isOn {
            PanelStyle.cardStroke.setStroke()
            capsule.lineWidth = 1
            capsule.stroke()
        }
        let knobD = h - 4
        let knobX = isOn ? box.maxX - knobD - 2 : box.minX + 2
        let knob = NSBezierPath(ovalIn: NSRect(x: knobX, y: box.minY + 2, width: knobD, height: knobD))
        NSColor.white.setFill()
        knob.fill()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        knob.lineWidth = 0.5
        knob.stroke()
    }

    // MARK: 点击

    override func mouseDown(with event: NSEvent) {
        // 吃掉按下，等抬起再把 action 转给菜单项（见 panelForwardClick）
    }

    override func mouseUp(with event: NSEvent) {
        panelForwardClick(from: self, at: convert(event.locationInWindow, from: nil))
    }
}

// MARK: - 返回行（第二页用）

/// 详情页顶部的「返回」行。整个菜单就两层，返回放最上面，符合系统菜单的惯例
/// （Wi-Fi、蓝牙那些菜单也是这么做的）。
final class BackRowView: NSView {
    var title = "返回显示器列表"

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

// MARK: - 单台屏的详情卡（第二页用）

/// 第二页顶部那张横版卡片：图标、名字、分辨率、亮度条一次给全，
/// 让用户调分辨率的时候不用退回去也能顺手改亮度。
final class DisplayDetailView: NSView {

    private(set) var slider: BrightnessSlider?
    private var note: String?
    private var card: CardsRowView.Card?
    private var badgeRect = NSRect.zero

    func configure(card: CardsRowView.Card, sliderTarget: AnyObject?, sliderAction: Selector) {
        self.card = card
        self.note = card.note
        subviews.forEach { $0.removeFromSuperview() }
        slider = nil
        badgeRect = .zero
        if card.brightness != nil {
            let lead = PanelStyle.badgeDiameter + PanelStyle.badgeGap
            let rowY: CGFloat = 4
            badgeRect = NSRect(x: PanelStyle.margin,
                               y: rowY + (PanelStyle.sliderRowHeight - PanelStyle.badgeDiameter) / 2,
                               width: PanelStyle.badgeDiameter, height: PanelStyle.badgeDiameter)
            let s = BrightnessSlider(value: (card.brightness ?? 0) * 100, minValue: 0, maxValue: 100,
                                     target: sliderTarget, action: sliderAction)
            s.isContinuous = true
            s.tag = Int(card.id)
            s.frame = NSRect(x: PanelStyle.margin + lead, y: rowY,
                             width: PanelStyle.width - 2 * PanelStyle.margin - lead - 2,
                             height: PanelStyle.sliderRowHeight)
            s.onRelease = { [weak self, weak s] in
                guard let s = s else { return }
                self?.onSliderRelease?(CGDirectDisplayID(s.tag))
            }
            addSubview(s)
            slider = s
        }
        needsDisplay = true
    }

    var onSliderRelease: ((CGDirectDisplayID) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        guard let card = card else { return }
        let rect = NSRect(x: PanelStyle.margin, y: 44,
                          width: PanelStyle.width - 2 * PanelStyle.margin,
                          height: bounds.height - 52)
        let path = NSBezierPath(roundedRect: rect, xRadius: PanelStyle.cardRadius,
                                yRadius: PanelStyle.cardRadius)
        PanelStyle.cardFill.setFill()
        path.fill()
        PanelStyle.cardStroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        panelDrawSymbol(card.isBuiltin ? "laptopcomputer" : "display",
                        height: 34, center: NSPoint(x: rect.minX + 30, y: rect.midY),
                        tint: .labelColor)

        let textX = rect.minX + 58
        NSAttributedString(string: card.name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]).draw(with: NSRect(x: textX, y: rect.midY + 1, width: rect.width - 70, height: 17),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        var tags = [card.resolution]
        if card.isBuiltin { tags.append("内置") }
        if card.isMain { tags.append("主屏") }
        NSAttributedString(string: tags.joined(separator: "  ·  "), attributes: [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: note == nil ? NSColor.secondaryLabelColor : NSColor.systemOrange
        ]).draw(with: NSRect(x: textX, y: rect.midY - 15, width: rect.width - 70, height: 14),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        if note != nil {
            panelDrawSymbol("exclamationmark.triangle.fill", height: 11,
                            center: NSPoint(x: rect.maxX - 14, y: rect.midY),
                            tint: .systemOrange)
        }
        if card.brightness != nil, badgeRect != .zero {
            // 亮度的两端图标和主面板保持一致，免得两个页面像两个软件
            panelDrawBrightnessBadge(in: badgeRect, brightness: card.brightness ?? 0, dimmed: false)
        }
    }
}
