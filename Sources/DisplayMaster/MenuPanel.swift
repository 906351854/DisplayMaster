import AppKit
import CoreGraphics

/// 自绘面板的尺寸与配色。
///
/// 集中放一处是有原因的：菜单里原生项和自绘项会并排出现，
/// 面板宽度、左右留白这些数字必须一起调，否则两边的文字列对不齐。
enum PanelStyle {

    // MARK: 卡片行

    /// 单张卡片的宽度。**卡片是横着排的**：几台显示器就并排几张卡，
    /// 每张卡自带亮度、开启、HiDPI 三个控件 —— 关掉的屏也占一张卡，
    /// 只是「开启」是关着的，而不是被挪到菜单底下去单独列一行。
    static let cardWidth: CGFloat = 196
    /// 一页最多几张卡
    static let maxCardsPerPage = 4
    /// 需要翻页时一页放几张。4 张再加两侧箭头，菜单会宽到 890pt —— 宁可少放一张
    static let maxCardsPerPagePaged = 3
    /// 面板最小宽度。只有一台屏时卡片会被拉宽到这个宽度，底部那些行才不至于比卡片还宽
    static let minWidth: CGFloat = 340
    static let margin: CGFloat = 16
    static let gap: CGFloat = 12
    static let arrowWidth: CGFloat = 18
    /// 上边距。菜单项视图是顶着菜单窗口上沿放的，不留白第一行文字会被圆角切掉
    static let topInset: CGFloat = 8
    static let bottomInset: CGFloat = 10

    // MARK: 卡片内部（自上而下，改一个要连着看下一个）

    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let cardTopInset: CGFloat = 12
    static let thumbHeight: CGFloat = 52
    static let thumbGap: CGFloat = 10
    static let titleHeight: CGFloat = 18
    static let modelHeight: CGFloat = 15
    static let specHeight: CGFloat = 15
    /// 分辨率行与分隔线之间
    static let sectionGap: CGFloat = 10
    /// 分隔线与「亮度」之间
    static let afterDividerGap: CGFloat = 11
    static let brightLabelHeight: CGFloat = 16
    static let sliderRowHeight: CGFloat = 24
    static let toggleRowHeight: CGFloat = 28
    static let cardBottomInset: CGFloat = 11
    /// 滑块右侧留给百分比文字的宽度。设计图上轨道几乎顶到卡片右内边距，
    /// 百分比只占很窄一格，所以这个数别给大 —— 给大了轨道会短一截。
    static let percentWidth: CGFloat = 34

    /// 亮度轨道与圆头。设计图上是一条很细的常规轨道（不是手稿那种粗胶囊），
    /// 5pt 是「看得出是条轨道、又不至于像 iOS 那样厚重」的折中。
    static let trackHeight: CGFloat = 5
    static let knobDiameter: CGFloat = 13

    /// 开关尺寸。按设计图的比例（开关高 ≈ 卡片宽的 0.09）取 18
    static let switchWidth: CGFloat = 30
    static let switchHeight: CGFloat = 18

    static var cardFill: NSColor { NSColor.labelColor.withAlphaComponent(0.06) }
    static var cardStroke: NSColor { NSColor.labelColor.withAlphaComponent(0.12) }
    static var hoverFill: NSColor { NSColor.labelColor.withAlphaComponent(0.11) }
    static var hairline: NSColor { NSColor.labelColor.withAlphaComponent(0.10) }
    static var track: NSColor { NSColor.labelColor.withAlphaComponent(0.16) }
    /// 开关/徽章这类小控件悬停时的浅底
    static var controlHover: NSColor { NSColor.labelColor.withAlphaComponent(0.07) }

    /// 卡片高度：把上面那一串内部尺寸加起来，别再手写一个魔数
    static var cardHeight: CGFloat {
        cardTopInset + thumbHeight + thumbGap
            + titleHeight + modelHeight + specHeight
            + sectionGap + 1 + afterDividerGap
            + brightLabelHeight + sliderRowHeight
            + toggleRowHeight * 2 + cardBottomInset
    }

    /// 一页放几张：超过 4 台才翻页，翻页时一页只放 3 张
    static func perPage(count: Int) -> Int {
        count > maxCardsPerPage ? maxCardsPerPagePaged : maxCardsPerPage
    }

    static func pageCount(count: Int) -> Int {
        max(1, Int(ceil(Double(count) / Double(perPage(count: count)))))
    }

    /// 整个面板（= 卡片行）的宽度。
    /// 注意用**一页放几张**去算，不是显示器总数 —— 6 台屏是一页 3 张分两页，
    /// 按 6 张算宽度会得到 1300pt 那么离谱的菜单。
    static func panelWidth(count: Int) -> CGFloat {
        let n = CGFloat(min(max(count, 1), perPage(count: count)))
        let arrows = pageCount(count: count) > 1 ? arrowWidth * 2 : 0
        let natural = margin * 2 + n * cardWidth + (n - 1) * gap + arrows
        return max(natural, minWidth + arrows)
    }

    /// 每张卡在面板里实际拿到的宽度
    static func columnWidth(panelWidth w: CGFloat, count: Int) -> CGFloat {
        let n = CGFloat(max(count, 1))
        let arrows = pageCount(count: count) > 1 ? arrowWidth * 2 : 0
        return (w - margin * 2 - arrows - (n - 1) * gap) / n
    }

    static func rowHeight(cardCount: Int) -> CGFloat { topInset + cardHeight + bottomInset }
}

// MARK: - 基础绘制工具

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

/// 量一行字有多宽。排「名字 + 徽章」这种并排内容时得先知道前半段占多少
func panelTextWidth(_ text: String, font: NSFont) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: font]).width
}

/// 在给定行框里画一行字（垂直居中、可省略）。
///
/// 统一走这一个入口：直接 `draw(at:)` 得自己猜基线，字号一换就偏 —— 卡片里
/// 一行挨一行，差 2pt 就看得出来。
@discardableResult
func panelDrawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor,
                   align: NSTextAlignment = .left,
                   truncating: NSLineBreakMode = .byTruncatingTail) -> CGFloat {
    let para = NSMutableParagraphStyle()
    para.alignment = align
    para.lineBreakMode = truncating
    let attr = NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: para
    ])
    let lineH = ceil(font.ascender - font.descender) + 1
    let top = rect.midY + lineH / 2
    attr.draw(with: NSRect(x: rect.minX, y: top - lineH, width: rect.width, height: lineH),
              options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    return attr.size().width
}

/// 画一枚胶囊标签（「主显示器」徽章、HiDPI 状态块）。返回它占的宽度。
@discardableResult
func panelDrawChip(_ text: String, x: CGFloat, centerY: CGFloat,
                   font: NSFont, textColor: NSColor, fill: NSColor) -> CGFloat {
    let h: CGFloat = 16
    let w = panelTextWidth(text, font: font) + 14
    let rect = NSRect(x: x, y: centerY - h / 2, width: w, height: h)
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2).fill()
    panelDrawText(text, in: NSRect(x: rect.minX + 7, y: rect.minY, width: w - 14, height: h),
                  font: font, color: textColor)
    return w
}

/// 胶囊开关。设计图里「开启」「HiDPI」用的都是它
func panelDrawSwitch(in rect: NSRect, on: Bool, enabled: Bool) {
    let capsule = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2,
                               yRadius: rect.height / 2)
    let base = on ? NSColor.controlAccentColor : PanelStyle.track
    (enabled ? base : base.withAlphaComponent(0.55)).setFill()
    capsule.fill()
    if !on {
        PanelStyle.cardStroke.setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
    }
    let d = rect.height - 4
    let knobRect = NSRect(x: on ? rect.maxX - d - 2 : rect.minX + 2,
                          y: rect.minY + 2, width: d, height: d)
    let knob = NSBezierPath(ovalIn: knobRect)
    (on ? NSColor.white : NSColor.white.withAlphaComponent(0.95)).setFill()
    knob.fill()
    NSColor.black.withAlphaComponent(0.12).setStroke()
    knob.lineWidth = 0.5
    knob.stroke()
}

/// 显示器缩略图里那张「壁纸」：一道渐变 + 一轮太阳 + 两道山。
///
/// 设计图用的是真实屏摄，我们画不出照片，但把「亮着的屏」这个印象画出来就够了 ——
/// 关键是屏幕长宽比要跟着真实分辨率走，带鱼屏一眼就认得出来。
func panelDrawWallpaper(in rect: NSRect, dimmed: Bool) {
    let a: CGFloat = dimmed ? 0.30 : 1
    let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
    let colors = [
        NSColor(srgbRed: 0.58, green: 0.75, blue: 0.96, alpha: a),
        NSColor(srgbRed: 0.40, green: 0.49, blue: 0.86, alpha: a),
        NSColor(srgbRed: 0.22, green: 0.26, blue: 0.55, alpha: a)
    ]
    if let g = NSGradient(colors: colors) { g.draw(in: path, angle: -90) }

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    // 太阳
    let sunR = max(rect.height * 0.13, 1.4)
    let sun = NSBezierPath(ovalIn: NSRect(x: rect.minX + rect.width * 0.62,
                                          y: rect.minY + rect.height * 0.44,
                                          width: sunR * 2, height: sunR * 2))
    NSColor(srgbRed: 0.99, green: 0.83, blue: 0.55, alpha: a).setFill()
    sun.fill()
    // 远山
    let far = NSBezierPath()
    far.move(to: NSPoint(x: rect.minX, y: rect.minY))
    far.line(to: NSPoint(x: rect.minX, y: rect.minY + rect.height * 0.34))
    far.line(to: NSPoint(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.66))
    far.line(to: NSPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.30))
    far.line(to: NSPoint(x: rect.maxX, y: rect.minY + rect.height * 0.58))
    far.line(to: NSPoint(x: rect.maxX, y: rect.minY))
    far.close()
    NSColor(srgbRed: 0.36, green: 0.44, blue: 0.79, alpha: a * 0.9).setFill()
    far.fill()
    // 近山
    let near = NSBezierPath()
    near.move(to: NSPoint(x: rect.minX, y: rect.minY))
    near.line(to: NSPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.46))
    near.line(to: NSPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.16))
    near.line(to: NSPoint(x: rect.maxX, y: rect.minY + rect.height * 0.40))
    near.line(to: NSPoint(x: rect.maxX, y: rect.minY))
    near.close()
    NSColor(srgbRed: 0.20, green: 0.25, blue: 0.52, alpha: a * 0.95).setFill()
    near.fill()
    NSGraphicsContext.restoreGraphicsState()
}

/// 显示器缩略图：外接屏画「屏 + 支架」，内置屏画「屏 + 底座」。
func panelDrawDisplayThumb(in box: NSRect, aspect: CGFloat, isBuiltin: Bool, dimmed: Bool) {
    let a: CGFloat = dimmed ? 0.55 : 1
    // 底座留 5pt 就够：留多了屏和底座之间会露出一道缝，看起来像两个零件掉在一起
    let standH: CGFloat = isBuiltin ? 5 : 10
    let screenH = box.height - standH
    let maxW = box.width * 0.62
    let screenW = min(screenH * max(1.1, min(aspect, 3.2)), maxW)
    let screenRect = NSRect(x: box.minX, y: box.minY + standH,
                            width: screenW, height: screenH)

    // 屏（外壳 + 壁纸）
    let bezel = NSBezierPath(roundedRect: screenRect, xRadius: 2.5, yRadius: 2.5)
    NSColor.labelColor.withAlphaComponent(0.35 * a).setFill()
    bezel.fill()
    let inner = screenRect.insetBy(dx: 1.6, dy: 1.6)
    panelDrawWallpaper(in: inner, dimmed: dimmed)

    if isBuiltin {
        // 笔记本底座：比屏略宽的一条
        let baseW = screenW * 1.08
        let baseX = screenRect.midX - baseW / 2
        let base = NSBezierPath(roundedRect: NSRect(x: baseX, y: box.minY,
                                                    width: baseW, height: 3.4),
                                xRadius: 1.7, yRadius: 1.7)
        NSColor.labelColor.withAlphaComponent(0.45 * a).setFill()
        base.fill()
        // 屏幕顶部的刘海，一眼认得出是笔记本
        let notch = NSBezierPath(roundedRect: NSRect(x: screenRect.midX - 3.2,
                                                     y: screenRect.maxY - 2.6,
                                                     width: 6.4, height: 1.8),
                                 xRadius: 0.9, yRadius: 0.9)
        NSColor.labelColor.withAlphaComponent(0.55 * a).setFill()
        notch.fill()
    } else {
        // 支架：细颈 + 底座
        let neck = NSBezierPath(rect: NSRect(x: screenRect.midX - 1.5, y: box.minY + 3.4,
                                             width: 3, height: 5.6))
        NSColor.labelColor.withAlphaComponent(0.40 * a).setFill()
        neck.fill()
        let footW = screenW * 0.42
        let foot = NSBezierPath(roundedRect: NSRect(x: screenRect.midX - footW / 2, y: box.minY + 1,
                                                    width: footW, height: 2.8),
                                xRadius: 1.4, yRadius: 1.4)
        NSColor.labelColor.withAlphaComponent(0.45 * a).setFill()
        foot.fill()
    }
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
        let radius = trackHeight / 2
        let trackRect = NSRect(x: 1, y: bounds.midY - radius,
                               width: max(bounds.width - 2, trackHeight), height: trackHeight)

        // 滑块头的位置：**问系统要比例，位置自己算**。
        // 直接用 cell.knobRect 会踩坑 —— 系统把轨道按它自己的圆头尺寸往里缩，
        // 我们的轨道比它长，照搬它的坐标就会出现「拖到头了轨道还剩一截没填满」。
        let sysKnob = cell.knobRect(flipped: false)
        let bar = cell.barRect(flipped: false)
        let t: CGFloat = bar.width > 0
            ? max(0, min(1, (sysKnob.midX - bar.minX) / bar.width))
            : CGFloat(doubleValue / (maxValue - minValue))
        let travel = max(trackRect.width - knobDiameter, 1)
        let knobX = trackRect.minX + knobDiameter / 2 + travel * t

        PanelStyle.track.setFill()
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius)
        trackPath.fill()
        // 描一圈极淡的边：深色菜单下轨道和背景几乎同色，没这圈边就看不出轨道长度
        PanelStyle.cardStroke.setStroke()
        trackPath.lineWidth = 1
        trackPath.stroke()

        // 填充段从轨道左端一直画到滑块头中心
        let filled = max(trackHeight, knobX - trackRect.minX)
        let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY, width: filled, height: trackHeight)
        (isEnabled ? fillColor : fillColor.withAlphaComponent(0.35)).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()

        let knobRect = NSRect(x: knobX - knobDiameter / 2, y: bounds.midY - knobDiameter / 2,
                              width: knobDiameter, height: knobDiameter)
        let kp = NSBezierPath(ovalIn: knobRect)
        (isEnabled ? NSColor.white : NSColor.white.withAlphaComponent(0.7)).setFill()
        kp.fill()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        kp.lineWidth = 0.5
        kp.stroke()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onRelease?()
    }
}

/// 菜单项里的自绘视图，要自己把点击转成菜单动作。
///
/// AppKit 只在菜单项**没有**自定义视图的时候才代发 action：一旦给 `item.view` 挂了视图，
/// 这一下点击就整个交给视图，菜单不再管。于是所有「看着能点」的自绘行全都点不动 ——
/// 点卡片不进详情页、点开关不切换、只有滑块还能拖（NSSlider 自己处理鼠标）。
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

/// 一排显示器卡片。**横向排列**：几台屏就并排几张卡。
///
/// 每张卡自带完整控件（亮度 / 开启 / HiDPI），所以菜单只有一层 ——
/// 想调哪台屏就在它自己那张卡上调，不用先进去再退出。
/// 被关掉的屏也占一张卡，「开启」显示为关；点一下就在原地开回来。
final class CardsRowView: NSView {

    struct Card {
        let id: CGDirectDisplayID
        /// 卡片标题。位置感比型号名重要：内置显示器 / 外接显示器 1 / 外接显示器 2
        let title: String
        /// 系统给的型号名，放在标题下面一行
        let model: String
        /// 「2560 × 1440 · 60 Hz」
        let spec: String
        let isBuiltin: Bool
        let isMain: Bool
        /// 缩略图里屏幕的比例（宽/高），跟着真实分辨率走
        let aspect: CGFloat
        /// 这台屏现在是不是开着
        let isOn: Bool
        /// 当前亮度 0...1。nil = 这台屏的亮度不可控
        let brightness: Double?
        /// 亮度不可控时的原因
        let note: String?
        let hidpi: Bool
        /// 这台屏支不支持 HiDPI 切换
        let hidpiAvailable: Bool

        /// 开发用：把这张卡当作「已关闭」来画。
        ///
        /// 有它才能核对外观 —— 真要看关闭态得把某台屏真的关掉，
        /// 那既打断工作、又多一次开关硬件的风险，不值当。
        func asOff() -> Card {
            Card(id: id, title: title, model: model, spec: spec, isBuiltin: isBuiltin,
                 isMain: false, aspect: aspect, isOn: false, brightness: brightness,
                 note: note, hidpi: hidpi, hidpiAvailable: false)
        }
    }

    /// 卡片里可以被点的部位
    enum Part {
        case detail      // 缩略图 / 标题 / ··· —— 都算「进这张卡的详细设置」
        case toggleOn    // 「开启」开关
        case toggleHiDPI // 「HiDPI」开关
    }

    private struct Layout {
        var card = NSRect.zero
        var thumb = NSRect.zero
        var dots = NSRect.zero
        var title = NSRect.zero
        var model = NSRect.zero
        var spec = NSRect.zero
        var dividerY: CGFloat = 0
        var brightLabel = NSRect.zero
        var sliderRow = NSRect.zero
        var onRow = NSRect.zero
        var hidpiRow = NSRect.zero
        /// 整张卡的头部（缩略图到分隔线）—— 点哪里都算进详情页
        var header = NSRect.zero
    }

    private(set) var cards: [Card] = []
    private(set) var page = 0
    private(set) var pages = 1
    private(set) var sliders: [BrightnessSlider] = []
    /// 每台屏的亮度数值标签，供「写入无应答」就地把数字换成提示
    private(set) var valueLabels: [CGDirectDisplayID: NSTextField] = [:]

    private var layouts: [Layout] = []
    private var prevArrow = NSRect.zero
    private var nextArrow = NSRect.zero
    /// 鼠标停在哪张卡上
    private var hoveredCard: Int?
    /// 鼠标停在这张卡的哪个部位（开关要单独高亮，不然看不出能点）
    private var hoveredPart: Part?

    override var isFlipped: Bool { false }

    /// 面板要的整行高度
    static var rowHeight: CGFloat { PanelStyle.rowHeight(cardCount: 1) }
    static func panelWidth(count: Int) -> CGFloat { PanelStyle.panelWidth(count: count) }

    // MARK: 配置

    func configure(cards: [Card], keepingPage: Int,
                   sliderTarget: AnyObject?, sliderAction: Selector) {
        self.cards = cards
        subviews.forEach { $0.removeFromSuperview() }
        sliders.removeAll()
        valueLabels.removeAll()
        layouts.removeAll()

        pages = PanelStyle.pageCount(count: cards.count)
        page = min(max(keepingPage, 0), pages - 1)

        let panelW = bounds.width
        let perPage = PanelStyle.perPage(count: cards.count)
        let start = page * perPage
        let visible = Array(cards[start..<min(start + perPage, cards.count)])
        let count = max(visible.count, 1)
        let showArrows = pages > 1

        layouts = (0..<count).map { _ in Layout() }
        let colW = PanelStyle.columnWidth(panelWidth: panelW, count: count)
        let lead = PanelStyle.margin + (showArrows ? PanelStyle.arrowWidth : 0)

        for (i, card) in visible.enumerated() {
            let x = lead + CGFloat(i) * (colW + PanelStyle.gap)
            let l = makeLayout(x: x, width: colW)
            layouts[i] = l

            if let b = card.brightness, card.isOn {
                let slider = BrightnessSlider(value: b * 100, minValue: 0, maxValue: 100,
                                              target: sliderTarget, action: sliderAction)
                slider.isContinuous = true
                slider.tag = Int(card.id)
                slider.fillColor = .controlAccentColor
                slider.onRelease = { [weak self, weak slider] in
                    guard let slider = slider else { return }
                    self?.onSliderRelease?(CGDirectDisplayID(slider.tag))
                }
                slider.frame = NSRect(x: l.sliderRow.minX, y: l.sliderRow.minY,
                                      width: l.sliderRow.width - PanelStyle.percentWidth,
                                      height: l.sliderRow.height)
                addSubview(slider)
                sliders.append(slider)
            } else if let b = card.brightness, !card.isOn {
                // 关掉的屏：亮度条照画（显示关闭前的档位），但拖不动 ——
                // 往一块关着的屏写亮度只会白白敲 I²C
                let slider = BrightnessSlider(value: b * 100, minValue: 0, maxValue: 100,
                                              target: nil, action: nil)
                slider.isEnabled = false
                slider.fillColor = .controlAccentColor
                slider.frame = NSRect(x: l.sliderRow.minX, y: l.sliderRow.minY,
                                      width: l.sliderRow.width - PanelStyle.percentWidth,
                                      height: l.sliderRow.height)
                addSubview(slider)
                sliders.append(slider)
            }

            // 亮度百分比。滑块右侧那一小格就是它的位置。
            let pct = card.brightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
            let label = NSTextField(labelWithString: pct)
            label.frame = NSRect(x: l.sliderRow.maxX - PanelStyle.percentWidth,
                                 y: l.sliderRow.midY - 7,
                                 width: PanelStyle.percentWidth, height: 14)
            label.alignment = .right
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = card.isOn ? .secondaryLabelColor : .tertiaryLabelColor
            addSubview(label)
            valueLabels[card.id] = label
        }

        if showArrows {
            // 箭头往里收 4pt：贴着 x=2 放会被菜单窗口的圆角切掉半个
            prevArrow = NSRect(x: 4, y: bounds.midY - 12,
                               width: PanelStyle.arrowWidth, height: 24)
            nextArrow = NSRect(x: panelW - 4 - PanelStyle.arrowWidth, y: bounds.midY - 12,
                               width: PanelStyle.arrowWidth, height: 24)
        } else {
            prevArrow = .zero
            nextArrow = .zero
        }
    }

    /// 算一张卡里所有元素的位置。全部从卡片上沿往下推，尺寸改动只需改 PanelStyle。
    private func makeLayout(x: CGFloat, width colW: CGFloat) -> Layout {
        var l = Layout()
        let cardH = PanelStyle.cardHeight
        l.card = NSRect(x: x, y: PanelStyle.bottomInset, width: colW, height: cardH)
        let cw = colW - PanelStyle.cardPadding * 2
        let left = l.card.minX + PanelStyle.cardPadding
        var top = l.card.maxY - PanelStyle.cardTopInset

        l.thumb = NSRect(x: left, y: top - PanelStyle.thumbHeight,
                         width: cw, height: PanelStyle.thumbHeight)
        top -= PanelStyle.thumbHeight + PanelStyle.thumbGap

        l.title = NSRect(x: left, y: top - PanelStyle.titleHeight, width: cw,
                         height: PanelStyle.titleHeight)
        top -= PanelStyle.titleHeight
        l.model = NSRect(x: left, y: top - PanelStyle.modelHeight, width: cw,
                         height: PanelStyle.modelHeight)
        top -= PanelStyle.modelHeight
        l.spec = NSRect(x: left, y: top - PanelStyle.specHeight, width: cw,
                        height: PanelStyle.specHeight)
        top -= PanelStyle.specHeight

        top -= PanelStyle.sectionGap
        l.dividerY = top
        top -= 1 + PanelStyle.afterDividerGap
        // 头部可点区 = 分隔线以上整块（缩略图、名字、型号、分辨率都在里面）
        l.header = NSRect(x: l.card.minX, y: l.dividerY, width: l.card.width,
                          height: l.card.maxY - l.dividerY)

        l.brightLabel = NSRect(x: left, y: top - PanelStyle.brightLabelHeight, width: cw,
                               height: PanelStyle.brightLabelHeight)
        top -= PanelStyle.brightLabelHeight
        l.sliderRow = NSRect(x: left, y: top - PanelStyle.sliderRowHeight, width: cw,
                             height: PanelStyle.sliderRowHeight)
        top -= PanelStyle.sliderRowHeight

        l.onRow = NSRect(x: l.card.minX, y: top - PanelStyle.toggleRowHeight, width: colW,
                         height: PanelStyle.toggleRowHeight)
        top -= PanelStyle.toggleRowHeight
        l.hidpiRow = NSRect(x: l.card.minX, y: top - PanelStyle.toggleRowHeight, width: colW,
                            height: PanelStyle.toggleRowHeight)

        // 「···」放在缩略图那一行的右端
        l.dots = NSRect(x: l.card.maxX - PanelStyle.cardPadding - 24,
                        y: l.thumb.maxY - 22, width: 24, height: 22)
        return l
    }

    /// 松手后把最后一档亮度落到显示器上
    var onSliderRelease: ((CGDirectDisplayID) -> Void)?

    // MARK: 命中判定

    enum Hit {
        case detail(CGDirectDisplayID)
        case toggleOn(CGDirectDisplayID)
        case toggleHiDPI(CGDirectDisplayID)
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
        let perPage = PanelStyle.perPage(count: cards.count)
        // 滑块优先：拖亮度绝不能被当成「点开设置」
        for slider in sliders where slider.frame.insetBy(dx: -2, dy: -5).contains(point) {
            return .slider
        }
        for (i, l) in layouts.enumerated() {
            guard i + page * perPage < cards.count else { continue }
            let card = cards[page * perPage + i]
            // 开关最先判：它们压在卡片边缘上，别被「整块卡都是详情」的判定吃掉
            if l.onRow.contains(point) { return .toggleOn(card.id) }
            if l.hidpiRow.contains(point) { return .toggleHiDPI(card.id) }
            if l.header.contains(point) { return .detail(card.id) }
        }
        return .none
    }

    /// 光标移到某张卡的某个部位。开发自测用它精确命中：
    /// 命中判定读的就是真实光标位置，这样测出来的才是真链路。
    @discardableResult
    func warpMouseTo(index: Int, part: Part = .detail) -> String {
        let perPage = PanelStyle.perPage(count: cards.count)
        let first = page * perPage
        guard index >= first, index - first < layouts.count, let window = window else {
            return "光标没挪（不在当前页或窗口不在）"
        }
        let l = layouts[index - first]
        let rect: NSRect
        switch part {
        case .detail: rect = l.dots
        case .toggleOn: rect = l.onRow
        case .toggleHiDPI: rect = l.hidpiRow
        }
        let inWindow = convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        guard let bounds = Self.windowBounds(window) else { return "拿不到窗口坐标" }
        // 屏幕坐标换算一律走窗口的 CG bounds：Cocoa 全局坐标的原点跟 CG 的不一定重合
        // （多屏排列时差得过 30pt 都有过），差一点点就挪到菜单外面去了
        let point = CGPoint(x: bounds.origin.x + inWindow.x,
                            y: bounds.origin.y + bounds.height - inWindow.y)
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        // 光标是硬挪过去的，系统**不会**补一个 mouseMoved 事件，所以悬停态得自己摆上：
        // 否则截图里永远是「没有悬停」的样子，这个自测点也就等于没测。
        applyHover(card: index - first, part: part)
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
        let perPage = PanelStyle.perPage(count: cards.count)
        let start = page * perPage
        for (i, l) in layouts.enumerated() {
            guard start + i < cards.count else { continue }
            drawCard(cards[start + i], layout: l, index: i)
        }
        if pages > 1 { drawPager() }
    }

    private func drawCard(_ card: Card, layout l: Layout, index: Int) {
        let dim = !card.isOn
        let cardHovered = hoveredCard == index
        let path = NSBezierPath(roundedRect: l.card, xRadius: PanelStyle.cardRadius,
                                yRadius: PanelStyle.cardRadius)
        (cardHovered && hoveredPart == nil ? PanelStyle.hoverFill : PanelStyle.cardFill).setFill()
        path.fill()
        PanelStyle.cardStroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        // 缩略图。宽卡片时屏幕能画大一点，但别大过一半宽度
        panelDrawDisplayThumb(in: l.thumb, aspect: card.aspect,
                              isBuiltin: card.isBuiltin, dimmed: dim)

        // 「···」：整张卡唯一的「进去」入口，所以给它一块明显的悬停底
        drawDots(in: l.dots, highlighted: cardHovered && hoveredPart == .detail)

        // 标题 + 「主显示器」徽章
        let nameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let nameColor = dim ? NSColor.tertiaryLabelColor : NSColor.labelColor
        let chipW = card.isMain ? panelTextWidth("主显示器", font: .systemFont(ofSize: 9.5, weight: .medium)) + 14 : 0
        let nameMax = l.title.width - (chipW > 0 ? chipW + 6 : 0)
        let nameW = min(panelTextWidth(card.title, font: nameFont), nameMax)
        panelDrawText(card.title, in: NSRect(x: l.title.minX, y: l.title.minY,
                                             width: nameMax, height: l.title.height),
                      font: nameFont, color: nameColor)
        if card.isMain {
            panelDrawChip("主显示器", x: l.title.minX + nameW + 6, centerY: l.title.midY,
                          font: .systemFont(ofSize: 9.5, weight: .medium),
                          textColor: .controlAccentColor,
                          fill: NSColor.controlAccentColor.withAlphaComponent(0.16))
        }

        // 型号 / 分辨率·刷新率
        panelDrawText(card.model, in: l.model, font: .systemFont(ofSize: 10.5),
                      color: dim ? .tertiaryLabelColor : .secondaryLabelColor)
        panelDrawText(card.spec, in: l.spec, font: .systemFont(ofSize: 10.5),
                      color: dim ? .tertiaryLabelColor : .secondaryLabelColor)

        // 分隔线：设计图上把「这台屏是什么」和「怎么调它」分开
        PanelStyle.hairline.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: l.card.minX + PanelStyle.cardPadding, y: l.dividerY))
        line.line(to: NSPoint(x: l.card.maxX - PanelStyle.cardPadding, y: l.dividerY))
        line.lineWidth = 1
        line.stroke()

        // 亮度行的标签：小太阳 + 「亮度」
        panelDrawSymbol("sun.max", height: 12,
                        center: NSPoint(x: l.brightLabel.minX + 6, y: l.brightLabel.midY),
                        tint: dim ? .tertiaryLabelColor : .secondaryLabelColor)
        panelDrawText("亮度", in: NSRect(x: l.brightLabel.minX + 17, y: l.brightLabel.minY,
                                         width: l.brightLabel.width - 17,
                                         height: l.brightLabel.height),
                      font: .systemFont(ofSize: 10.5),
                      color: dim ? .tertiaryLabelColor : .secondaryLabelColor)

        // 亮度不可控时，把原因写在滑块的位置上（写不下就省略，详情页里有全文）
        if card.brightness == nil {
            panelDrawText("⚠︎ " + (card.note ?? "亮度不可控"), in: l.sliderRow,
                          font: .systemFont(ofSize: 9.5), color: .secondaryLabelColor)
        }

        drawToggleRow(l.onRow, title: "开启", on: card.isOn,
                      onColor: dim ? .secondaryLabelColor : .labelColor,
                      enabled: true, highlighted: cardHovered && hoveredPart == .toggleOn)

        // HiDPI 行。三种状态各有各的样子：
        //   开着且支持 → 开关是开的，标签是强调色
        //   开着但不支持 → 开关是关的，标签写「不支持」
        //   这台屏被关掉了 → 整行变灰；开关按「不可操作」画成关的，
        //     上次到底是不是 HiDPI 交给右边那枚标签去说（记录里存着）
        let hidpiUsable = card.isOn && card.hidpiAvailable
        let labelW = panelTextWidth("HiDPI", font: .systemFont(ofSize: 11))
        drawToggleRow(l.hidpiRow, title: "HiDPI", on: hidpiUsable && card.hidpi,
                      onColor: dim ? .tertiaryLabelColor : .labelColor,
                      enabled: hidpiUsable,
                      highlighted: cardHovered && hoveredPart == .toggleHiDPI)
        let chipText = (card.isOn && !card.hidpiAvailable)
            ? "不支持" : (card.hidpi ? "HiDPI" : "标准")
        panelDrawChip(chipText,
                      x: l.hidpiRow.minX + PanelStyle.cardPadding + PanelStyle.switchWidth + 8 + labelW + 6,
                      centerY: l.hidpiRow.midY,
                      font: .systemFont(ofSize: 9.5, weight: .medium),
                      textColor: hidpiUsable && card.hidpi
                          ? .controlAccentColor
                          : (dim ? .tertiaryLabelColor : .secondaryLabelColor),
                      fill: hidpiUsable && card.hidpi
                          ? NSColor.controlAccentColor.withAlphaComponent(0.16)
                          : NSColor.labelColor.withAlphaComponent(0.07))
    }

    /// 一行「开关 + 标题」。开关和标题一起算可点区域（见 hit）
    private func drawToggleRow(_ row: NSRect, title: String, on: Bool, onColor: NSColor,
                               enabled: Bool, highlighted: Bool) {
        if highlighted {
            PanelStyle.controlHover.setFill()
            NSBezierPath(roundedRect: row.insetBy(dx: PanelStyle.cardPadding - 6, dy: 1),
                         xRadius: 7, yRadius: 7).fill()
        }
        let sw = NSRect(x: row.minX + PanelStyle.cardPadding,
                        y: row.midY - PanelStyle.switchHeight / 2,
                        width: PanelStyle.switchWidth, height: PanelStyle.switchHeight)
        panelDrawSwitch(in: sw, on: on, enabled: enabled)
        panelDrawText(title, in: NSRect(x: sw.maxX + 8, y: row.minY,
                                        width: row.width - sw.width - PanelStyle.cardPadding * 2 - 10,
                                        height: row.height),
                      font: .systemFont(ofSize: 11),
                      color: enabled ? onColor : onColor.withAlphaComponent(0.6))
    }

    private func drawDots(in rect: NSRect, highlighted: Bool) {
        if highlighted {
            PanelStyle.controlHover.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        let d: CGFloat = 2.6, gap: CGFloat = 3.4
        let total = d * 3 + gap * 2
        let y = rect.midY - d / 2
        var x = rect.midX - total / 2
        NSColor.secondaryLabelColor.setFill()
        for _ in 0..<3 {
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d)).fill()
            x += d + gap
        }
    }

    private func drawPager() {
        let tint = NSColor.secondaryLabelColor
        for (rect, name, enabled) in [(prevArrow, "chevron.left", page > 0),
                                      (nextArrow, "chevron.right", page < pages - 1)] {
            guard rect != .zero else { continue }
            panelDrawSymbol(name, height: 11, center: NSPoint(x: rect.midX, y: rect.midY),
                            tint: enabled ? tint : tint.withAlphaComponent(0.3))
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
        let (card, part) = hoverTarget(at: convert(event.locationInWindow, from: nil))
        applyHover(card: card, part: part)
    }

    private func hoverTarget(at point: NSPoint) -> (Int?, Part?) {
        let perPage = PanelStyle.perPage(count: cards.count)
        for (i, l) in layouts.enumerated() {
            guard page * perPage + i < cards.count else { continue }
            if l.onRow.contains(point) { return (i, .toggleOn) }
            if l.hidpiRow.contains(point) { return (i, .toggleHiDPI) }
            if l.header.contains(point) { return (i, .detail) }
            if l.card.contains(point) { return (i, nil) }
        }
        return (nil, nil)
    }

    private func applyHover(card: Int?, part: Part?) {
        if card != hoveredCard || part != hoveredPart {
            hoveredCard = card
            hoveredPart = part
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredCard != nil || hoveredPart != nil {
            hoveredCard = nil
            hoveredPart = nil
            needsDisplay = true
        }
    }

    // MARK: 点击

    override func mouseDown(with event: NSEvent) {
        // 特意什么都不做：让菜单别在按下的瞬间自己关掉，等抬起再决定
    }

    override func mouseUp(with event: NSEvent) {
        panelForwardClick(from: self, at: convert(event.locationInWindow, from: nil))
    }
}

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

/// 详情页顶部那张横幅：缩略图 + 名字 + 分辨率 + （亮度不可控时的）原因。
///
/// 这里**不再重复**放亮度条和开关 —— 那些已经在那张屏自己的卡片上了。
/// 详情页只负责「卡片上放不下的东西」：分辨率列表、关闭、DDC 重检、忘记。
final class DetailHeaderView: NSView {

    private var card: CardsRowView.Card?
    private var note: String?
    var rowWidth: CGFloat = PanelStyle.minWidth

    func configure(card: CardsRowView.Card, width: CGFloat) {
        self.card = card
        self.note = card.note
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
        panelDrawText(card.title, in: NSRect(x: textX, y: rect.midY + 10, width: textW, height: 17),
                      font: .systemFont(ofSize: 13, weight: .semibold),
                      color: dim ? .tertiaryLabelColor : .labelColor)
        panelDrawText(card.model + "  ·  " + card.spec,
                      in: NSRect(x: textX, y: rect.midY - 8, width: textW, height: 15),
                      font: .systemFont(ofSize: 10.5), color: .secondaryLabelColor)
        if let note = note {
            panelDrawText("⚠︎ " + note, in: NSRect(x: textX, y: rect.midY - 24, width: textW, height: 14),
                          font: .systemFont(ofSize: 9.5), color: .systemOrange)
        }
    }
}
