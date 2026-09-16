import AppKit
import CoreGraphics

// MARK: - 面板滑块（亮度 / 分辨率共用）

/// 菜单卡片里的滑块。亮度和分辨率共用同一个类 —— 两条轨道要长得一模一样，
/// 「对齐」这件事才有保证；分成两个类迟早会各画各的。
///
/// 为什么要自己画 track / 填充 / 滑块头：系统滑块的填充色**只在 app 处于活跃状态时才画**。
/// 菜单项视图里的活跃态并不可靠 —— 用户看到的就是「外接屏那条亮度条的蓝色丢了，
/// 内屏那条还在」，同一次打开的菜单里两条颜色都不一样。自绘之后颜色由我们自己定，
/// 跟活跃态彻底脱钩。
final class PanelSlider: NSSlider {
    /// 松手回调。备用通道 —— 主通道在动作事件里（见 isReleaseEvent）。
    ///
    /// 为什么说是备用：NSSlider 的 cell 在拖动时会自建事件循环，mouseUp 被它
    /// 自己消费掉，**视图的 mouseUp(with:) 收不到**。试验台实测（合成按下-拖动-
    /// 松手三连）：拖完整段，mouseUp 被调次数是 0。所以真正可靠的松手信号是
    /// 动作事件自带的事件类型 —— 松手那一下 action 会带着 .leftMouseUp 来。
    /// 这里留着，是给「哪天 AppKit 换了投递方式」留的一条后路；
    /// 就算两条都响，下游也是幂等的（原地切模式会被 isCurrent 挡掉）。
    var onRelease: (() -> Void)?

    /// 这次 action 是不是松手触发的。
    ///
    /// 前提：cell 的动作掩码里放行了 .leftMouseUp（建滑块时用 sendAction(on:)
    /// 设过）。拖动过程中 action 带的是 .leftMouseDragged，松手那一下是
    /// .leftMouseUp —— NSApp.currentEvent 在 action 里就是当次事件，实测如此。
    var isReleaseEvent: Bool { NSApp.currentEvent?.type == .leftMouseUp }
    /// 填充色。这里刻意用一个确定的值，不再交给系统按状态挑
    var fillColor: NSColor = .controlAccentColor
    /// 在轨道上把每一档点出来（分辨率滑块用）
    var showsTicks = false

    private var trackHeight: CGFloat { PanelStyle.trackHeight }
    private var knobDiameter: CGFloat { PanelStyle.knobDiameter }

    override func draw(_ dirtyRect: NSRect) {
        let radius = trackHeight / 2
        let trackRect = NSRect(x: 1, y: bounds.midY - radius,
                               width: max(bounds.width - 2, trackHeight), height: trackHeight)

        // 滑块头的位置：**只认数值，别去问系统要坐标**。
        //
        // 这里踩过一个很直接的坑。原先是用 cell.knobRect / cell.barRect 反推比例，
        // 结果滑块头怎么拖都到不了两端 —— 总差 6.5pt，正好是圆头半径：
        // 系统把轨道按它自己的圆头尺寸往里缩过，数值到 min/max 时 knobRect 落在
        // barRect 内缩 kd/2 的位置上，反推出来的 t 只能是 0.03…0.97。
        // 用户的原话是「左右都不可以滑到底」。
        // 比例 = （数值 - 下限）/ 区间，本来就是一个除法，自己算，两端才真的到得了。
        let t = maxValue > minValue
            ? max(0, min(1, (doubleValue - minValue) / (maxValue - minValue)))
            : 0
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

        if showsTicks { drawTicks(trackRect: trackRect, travel: travel, knobX: knobX) }

        let knobRect = NSRect(x: knobX - knobDiameter / 2, y: bounds.midY - knobDiameter / 2,
                              width: knobDiameter, height: knobDiameter)
        let kp = NSBezierPath(ovalIn: knobRect)
        (isEnabled ? NSColor.white : NSColor.white.withAlphaComponent(0.7)).setFill()
        kp.fill()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        kp.lineWidth = 0.5
        kp.stroke()
    }

    /// 每一档在轨道上点一颗小圆点。
    ///
    /// 和滑块头同一套位置公式 —— 位置都是「数值的线性函数」，所以只要刻度按
    /// 平均分点，吸附到哪一档，滑块头就正好停在哪颗点上。
    private func drawTicks(trackRect: NSRect, travel: CGFloat, knobX: CGFloat) {
        let n = Int((maxValue - minValue).rounded()) + 1
        // 档位太多就不点了（点出来是一排糊在一起的砂纸），也说明这份列表不该做成滑块
        guard n > 1, n <= 20 else { return }
        let r = PanelStyle.tickDiameter / 2
        for i in 0..<n {
            let x = trackRect.minX + PanelStyle.knobDiameter / 2
                + travel * CGFloat(i) / CGFloat(n - 1)
            let color = x <= knobX ? NSColor.white.withAlphaComponent(0.6)
                                   : NSColor.labelColor.withAlphaComponent(0.22)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - r, y: bounds.midY - r,
                                        width: r * 2, height: r * 2)).fill()
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // 备用通道：cell 跟踪期间这条不会被调（见 onRelease 的注释），
        // 万一哪条路径真把 mouseUp 投递进来了，别浪费它。
        onRelease?()
    }
}
