import AppKit
import CoreGraphics

// MARK: - 卡片行

/// 一排显示器卡片。**横向排列**：几台屏就并排几张卡。
///
/// 每张卡自带完整控件（亮度 / 分辨率两条滑块 + 开启 / HiDPI 两枚开关），
/// 所以菜单只有一层 —— 想调哪台屏就在它自己那张卡上调，不用先进去再退出。
/// 被关掉的屏也占一张卡，「开启」显示为关；点一下就在原地开回来。
///
/// 卡片右上角原来放的是一个「···」，点它进详情页。那玩意儿被用户点名不要了：
/// 三个点又小又不好点，而且「点哪算点这三个点」本身就不清楚。
/// 现在那个位置放的是这排卡上最常用的两枚开关（开启 / HiDPI），
/// 详情页改成点卡片主体进（悬停时卡片底色会提亮，给一点反馈）。
final class CardsRowView: NSView {

    struct Card {
        let id: CGDirectDisplayID
        /// 卡片标题。位置感比型号名重要：内置显示器 / 外接显示器 1 / 外接显示器 2
        let title: String
        /// 系统给的型号名，放在标题下面一行
        let model: String
        /// 面板本身的规格「5120 × 2880 · 60 Hz」。
        ///
        /// 刻意用**物理**分辨率：当前逻辑分辨率是下面那条分辨率滑块在说的事，
        /// 这里再写一遍就成了同一句话重复两遍（还偏偏是三行之隔）。
        /// 物理分辨率是一块屏固定不变的属性，两者分工正好。
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

        /// 当前逻辑分辨率，「1680 × 1050」
        let resolution: String
        /// 分辨率滑块上有几档。1 = 只有眼前这一档（关掉的屏就是这样），滑块画成死的
        let resolutionCount: Int
        /// 当前用的是第几档
        let resolutionIndex: Int
        /// 眼前这一档是不是 HiDPI 渲染
        let resolutionHiDPI: Bool

        /// 开发用：把这张卡当作「已关闭」来画。
        ///
        /// 有它才能核对外观 —— 真要看关闭态得把某台屏真的关掉，
        /// 那既打断工作、又多一次开关硬件的风险，不值当。
        func asOff() -> Card {
            Card(id: id, title: title, model: model, spec: spec, isBuiltin: isBuiltin,
                 isMain: false, aspect: aspect, isOn: false, brightness: brightness,
                 note: note, hidpi: hidpi, hidpiAvailable: false,
                 // 关掉的屏读不到模式列表，只剩「关闭前那一档」可显示
                 resolution: resolution, resolutionCount: 1, resolutionIndex: 0,
                 resolutionHiDPI: resolutionHiDPI)
        }
    }

    /// 卡片里可以被点的部位
    enum Part {
        case detail      // 缩略图 / 标题 / 型号 —— 整块卡片主体，点它进详情页
        case toggleOn    // 右上角「开启」开关
        case toggleHiDPI // 右上角「HiDPI」开关
    }

    private struct Layout {
        var card = NSRect.zero
        var thumb = NSRect.zero
        /// 卡片右上角那一簇：上下两枚开关（含各自左边的标签）
        var onRow = NSRect.zero
        var hidpiRow = NSRect.zero
        var title = NSRect.zero
        var model = NSRect.zero
        var spec = NSRect.zero
        var dividerY: CGFloat = 0
        /// 两条控制行。每条都是「标签行 + 滑块行」，
        /// 而且两条的标签、滑块共用同一 x / 同一宽度 —— 对齐就是这么来的
        var brightLabel = NSRect.zero
        var brightSlider = NSRect.zero
        var resLabel = NSRect.zero
        var resSlider = NSRect.zero
        /// 整张卡的头部（缩略图到分隔线）—— 点哪里都算进详情页
        var header = NSRect.zero
    }

    private(set) var cards: [Card] = []
    private(set) var page = 0
    private(set) var pages = 1
    private(set) var sliders: [PanelSlider] = []
    /// 每台屏的亮度数值标签，供「写入无应答」就地把数字换成提示
    private(set) var valueLabels: [CGDirectDisplayID: NSTextField] = [:]
    /// 分辨率数值标签。拖动时实时改的就是它（还不到真的切模式的时候）
    private(set) var resLabels: [CGDirectDisplayID: NSTextField] = [:]
    /// 分辨率数值左边那枚「HiDPI」小字
    private(set) var resHiLabels: [CGDirectDisplayID: NSTextField] = [:]
    /// 每台屏的档位列表：拖动时要把下标翻回「1680 × 1050」这种文字
    private var resolutionModes: [CGDirectDisplayID: [CGDisplayMode]] = [:]

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
                   modes: [CGDirectDisplayID: [CGDisplayMode]],
                   sliderTarget: AnyObject?, sliderAction: Selector,
                   resolutionTarget: AnyObject?, resolutionAction: Selector) {
        self.cards = cards
        self.resolutionModes = modes
        subviews.forEach { $0.removeFromSuperview() }
        sliders.removeAll()
        valueLabels.removeAll()
        resLabels.removeAll()
        resHiLabels.removeAll()
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

            // —— 亮度：滑块 + 标签行右端那个百分比 ——
            addBrightnessSlider(card, l, target: sliderTarget, action: sliderAction)
            let pct = card.brightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
            let label = NSTextField(labelWithString: pct)
            label.frame = NSRect(x: l.brightLabel.maxX - PanelStyle.percentWidth,
                                 y: l.brightLabel.midY - 7,
                                 width: PanelStyle.percentWidth, height: 14)
            label.alignment = .right
            label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            label.textColor = card.isOn ? .secondaryLabelColor : .tertiaryLabelColor
            addSubview(label)
            valueLabels[card.id] = label

            // —— 分辨率：滑块 + 数值 + （HiDPI 时）那枚小字 ——
            addResolutionSlider(card, l, target: resolutionTarget, action: resolutionAction)
            addResolutionLabels(card, l)
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

    /// 亮度滑块。关掉的屏也画一条（显示关闭前的档位），但拖不动 ——
    /// 往一块关着的屏写亮度只会白白敲 I²C。
    private func addBrightnessSlider(_ card: Card, _ l: Layout,
                                     target: AnyObject?, action: Selector) {
        guard let b = card.brightness else { return }   // 亮度不可控：那一行改写成原因
        let slider = PanelSlider(value: b * 100, minValue: 0, maxValue: 100,
                                 target: card.isOn ? target : nil,
                                 action: card.isOn ? action : nil)
        slider.isEnabled = card.isOn
        slider.isContinuous = true
        slider.tag = Int(card.id)
        slider.fillColor = .controlAccentColor
        slider.onRelease = { [weak self, weak slider] in
            guard let slider, card.isOn else { return }
            self?.onSliderRelease?(CGDirectDisplayID(slider.tag))
        }
        slider.frame = l.brightSlider
        addSubview(slider)
        sliders.append(slider)
    }

    /// 分辨率滑块。
    ///
    /// 档位是离散的，所以点刻度 + `allowsTickMarkValuesOnly`：拖着一格一格跳，
    /// 不会停在两档中间。切模式要黑屏一下，所以**只在松手时真的切**（见 onResolutionRelease）。
    private func addResolutionSlider(_ card: Card, _ l: Layout,
                                     target: AnyObject?, action: Selector) {
        let count = max(card.resolutionCount, 1)
        let usable = card.isOn && count > 1
        let slider = PanelSlider(value: Double(max(0, min(card.resolutionIndex, count - 1))),
                                 minValue: 0, maxValue: Double(count - 1),
                                 target: usable ? target : nil,
                                 action: usable ? action : nil)
        slider.showsTicks = true
        slider.isEnabled = usable
        slider.tag = Int(card.id)
        slider.fillColor = .controlAccentColor
        if count > 1, count <= 20 {
            slider.numberOfTickMarks = count
            slider.allowsTickMarkValuesOnly = true
        }
        slider.onRelease = { [weak self, weak slider] in
            guard let slider, usable else { return }
            self?.onResolutionRelease?(CGDirectDisplayID(slider.tag),
                                       Int(slider.doubleValue.rounded()))
        }
        slider.frame = l.resSlider
        addSubview(slider)
        sliders.append(slider)
    }

    private func addResolutionLabels(_ card: Card, _ l: Layout) {
        let mark = NSTextField(labelWithString: "HiDPI")
        mark.frame = NSRect(x: l.resLabel.maxX - PanelStyle.resValueWidth
                                - PanelStyle.hidpiMarkWidth - 5,
                            y: l.resLabel.midY - 7,
                            width: PanelStyle.hidpiMarkWidth, height: 14)
        mark.alignment = .right
        mark.font = .systemFont(ofSize: 9.5, weight: .medium)
        mark.textColor = card.isOn ? .controlAccentColor : .tertiaryLabelColor
        mark.isHidden = !card.resolutionHiDPI
        addSubview(mark)
        resHiLabels[card.id] = mark

        let value = NSTextField(labelWithString: card.resolution)
        value.frame = NSRect(x: l.resLabel.maxX - PanelStyle.resValueWidth,
                             y: l.resLabel.midY - 7,
                             width: PanelStyle.resValueWidth, height: 14)
        value.alignment = .right
        value.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        value.textColor = card.isOn ? .secondaryLabelColor : .tertiaryLabelColor
        addSubview(value)
        resLabels[card.id] = value
    }

    /// 拖动中：只改字，不切模式。切一次黑屏一下，边拖边切屏幕会闪成频闪灯
    func previewResolution(id: CGDirectDisplayID, index: Int) {
        let modes = resolutionModes[id] ?? []
        guard index >= 0, index < modes.count else { return }
        let m = modes[index]
        resLabels[id]?.stringValue = "\(m.width) × \(m.height)"
        resHiLabels[id]?.isHidden = !(m.pixelWidth > m.width)
    }

    /// 算一张卡里所有元素的位置。全部从卡片上沿往下推，尺寸改动只需改 PanelStyle。
    private func makeLayout(x: CGFloat, width colW: CGFloat) -> Layout {
        var l = Layout()
        let cardH = PanelStyle.cardHeight
        l.card = NSRect(x: x, y: PanelStyle.bottomInset, width: colW, height: cardH)
        let cw = colW - PanelStyle.cardPadding * 2
        let left = l.card.minX + PanelStyle.cardPadding
        var top = l.card.maxY - PanelStyle.cardTopInset

        // 缩略图得给右上角那一簇开关让位：缩略图的宽度就是「整幅内容宽 - 开关簇 - 间隙」
        let cluster = PanelStyle.switchClusterWidth
        l.thumb = NSRect(x: left, y: top - PanelStyle.thumbHeight,
                         width: max(cw - cluster - 10, 40), height: PanelStyle.thumbHeight)
        top -= PanelStyle.thumbHeight + PanelStyle.thumbGap

        // 右上角：开启 / HiDPI 上下两枚，整簇垂直居中在缩略图那一行里
        let clusterH = PanelStyle.switchRowHeight * 2 + PanelStyle.switchRowGap
        let clusterTop = l.thumb.maxY - (PanelStyle.thumbHeight - clusterH) / 2
        let clusterX = l.card.maxX - PanelStyle.cardPadding - cluster
        l.onRow = NSRect(x: clusterX, y: clusterTop - PanelStyle.switchRowHeight,
                         width: cluster, height: PanelStyle.switchRowHeight)
        l.hidpiRow = NSRect(x: clusterX, y: clusterTop - clusterH,
                            width: cluster, height: PanelStyle.switchRowHeight)

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

        // 两条控制行：几何完全一样，只是往下挪一格
        l.brightLabel = NSRect(x: left, y: top - PanelStyle.controlLabelHeight, width: cw,
                               height: PanelStyle.controlLabelHeight)
        top -= PanelStyle.controlLabelHeight
        l.brightSlider = NSRect(x: left, y: top - PanelStyle.controlSliderHeight, width: cw,
                                height: PanelStyle.controlSliderHeight)
        top -= PanelStyle.controlSliderHeight + PanelStyle.controlRowGap

        l.resLabel = NSRect(x: left, y: top - PanelStyle.controlLabelHeight, width: cw,
                            height: PanelStyle.controlLabelHeight)
        top -= PanelStyle.controlLabelHeight
        l.resSlider = NSRect(x: left, y: top - PanelStyle.controlSliderHeight, width: cw,
                             height: PanelStyle.controlSliderHeight)
        return l
    }

    /// 松手后把最后一档亮度落到显示器上
    var onSliderRelease: ((CGDirectDisplayID) -> Void)?
    /// 松手后才真的切分辨率（下标，不是模式 —— 模式表在 app 那边）
    var onResolutionRelease: ((CGDirectDisplayID, Int) -> Void)?

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
            // 开关最先判：它们在卡片右上角，别被「整块卡都是详情」的判定吃掉。
            // 判定范围往外放 3pt：开关那一簇本身只有 20pt 高，手指落点很少正中
            if l.onRow.insetBy(dx: -3, dy: -1).contains(point) { return .toggleOn(card.id) }
            if l.hidpiRow.insetBy(dx: -3, dy: -1).contains(point) { return .toggleHiDPI(card.id) }
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
        // 「进详情页」的热区是整块卡片头部，取标题行最左边那一小段当落点：
        // 它一定在头部里，又一定在右上角开关簇的左边
        case .detail: rect = NSRect(x: l.title.minX, y: l.title.minY,
                                    width: 26, height: l.title.height)
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
        // 悬停在卡片主体（= 进详情页的热区）时把底色提亮一点。
        // 右上角那三个点去掉之后，「这块能点」就靠这一点反馈了。
        let lit = cardHovered && (hoveredPart == nil || hoveredPart == .detail)
        (lit ? PanelStyle.hoverFill : PanelStyle.cardFill).setFill()
        path.fill()
        PanelStyle.cardStroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        panelDrawDisplayThumb(in: l.thumb, aspect: card.aspect,
                              isBuiltin: card.isBuiltin, dimmed: dim)

        // 右上角：开启 / HiDPI。这两枚开关原来占着卡片底部两整行，
        // 现在挪到「···」腾出来的位置，卡片一下子矮了两行。
        drawSwitchRow(l.onRow, title: "开启", on: card.isOn,
                      labelColor: dim ? .secondaryLabelColor : .labelColor,
                      enabled: true, highlighted: cardHovered && hoveredPart == .toggleOn)

        // HiDPI 三种状态各有各的样子：
        //   开着且支持   → 开关是开的
        //   开着但不支持 → 开关是关的、整行压灰（点它只会响一声）
        //   这台屏被关掉 → 整行压灰
        //   上次是不是 HiDPI 由下面分辨率那一行的「HiDPI」小字说，别在这儿重复
        let hidpiUsable = card.isOn && card.hidpiAvailable
        drawSwitchRow(l.hidpiRow, title: "HiDPI", on: hidpiUsable && card.hidpi,
                      labelColor: dim ? .tertiaryLabelColor : .labelColor,
                      enabled: hidpiUsable,
                      highlighted: cardHovered && hoveredPart == .toggleHiDPI)

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

        // 型号 / 面板规格（物理分辨率 · 刷新率）
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

        // 两条控制行。右端的数值和整条滑块都是子视图，这里只画左边那半截：
        // 小图标 + 名称。两行的图标、名称、数值都对齐在同一批 x 上。
        drawControlLabel(l.brightLabel, symbol: "sun.max", title: "亮度",
                         valueWidth: PanelStyle.percentWidth,
                         color: dim ? .tertiaryLabelColor : .secondaryLabelColor)
        drawControlLabel(l.resLabel, symbol: "aspectratio", title: "分辨率",
                         valueWidth: PanelStyle.resValueWidth + PanelStyle.hidpiMarkWidth + 5,
                         color: dim ? .tertiaryLabelColor : .secondaryLabelColor)

        // 亮度不可控时，把原因写在滑块的位置上（写不下就省略，详情页里有全文）
        if card.brightness == nil {
            panelDrawText("⚠︎ " + (card.note ?? "亮度不可控"), in: l.brightSlider,
                          font: .systemFont(ofSize: 9.5), color: .secondaryLabelColor)
        }
    }

    /// 控制行的左半截：一枚小图标 + 名称。右端留给数值（那是子视图，会盖在上面）
    private func drawControlLabel(_ row: NSRect, symbol: String, title: String,
                                  valueWidth: CGFloat, color: NSColor) {
        panelDrawSymbol(symbol, height: 11,
                        center: NSPoint(x: row.minX + 5.5, y: row.midY), tint: color)
        panelDrawText(title, in: NSRect(x: row.minX + 16, y: row.minY,
                                        width: max(row.width - 16 - valueWidth - 4, 10),
                                        height: row.height),
                      font: .systemFont(ofSize: 10.5), color: color)
    }

    /// 一行「开关 + 名称」。开关贴右端、名称右对齐到开关左边 ——
    /// 上下两行这样排，两枚开关才会严格对齐在同一条竖线上。
    private func drawSwitchRow(_ row: NSRect, title: String, on: Bool, labelColor: NSColor,
                               enabled: Bool, highlighted: Bool) {
        if highlighted {
            PanelStyle.controlHover.setFill()
            NSBezierPath(roundedRect: row.insetBy(dx: -5, dy: 0),
                         xRadius: 7, yRadius: 7).fill()
        }
        let sw = NSRect(x: row.maxX - PanelStyle.switchWidth,
                        y: row.midY - PanelStyle.switchHeight / 2,
                        width: PanelStyle.switchWidth, height: PanelStyle.switchHeight)
        panelDrawSwitch(in: sw, on: on, enabled: enabled)
        let labelRight = sw.minX - PanelStyle.switchLabelGap
        panelDrawText(title, in: NSRect(x: row.minX, y: row.minY,
                                        width: max(labelRight - row.minX, 10),
                                        height: row.height),
                      font: PanelStyle.switchLabelFont,
                      color: enabled ? labelColor : labelColor.withAlphaComponent(0.6),
                      align: .right)
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
