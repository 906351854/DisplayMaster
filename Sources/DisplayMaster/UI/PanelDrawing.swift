import AppKit
import CoreGraphics

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
///
/// `box` 是留给缩略图的**全部**空间，屏幕最多画到 box 那么宽 ——
/// 卡片右上角被开关簇占掉一块之后，能画多宽由调用方算好传进来，
/// 这里不再自己按比例打折（打两次折屏幕会小得认不出）。
func panelDrawDisplayThumb(in box: NSRect, aspect: CGFloat, isBuiltin: Bool, dimmed: Bool) {
    let a: CGFloat = dimmed ? 0.55 : 1
    // 底座留 5pt 就够：留多了屏和底座之间会露出一道缝，看起来像两个零件掉在一起
    let standH: CGFloat = isBuiltin ? 5 : 10
    let screenH = box.height - standH
    let maxW = box.width
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
