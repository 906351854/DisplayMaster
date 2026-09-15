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

/// 菜单里的亮度滑块。
/// 拖动过程中 NSSlider 只保证「连续动作」，拿不到可靠的「松手」时机，
/// 而最后一档亮度必须确保落到显示器上 —— 这个子类在 BrightnessSlider 里，
/// 挪到 MenuPanel.swift 了（那边同时接管了它的绘制）。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    /// 最近一次滑块拖动事件的时间。
    ///
    /// 这里刻意记时间而不是用布尔量：拖动期间禁止重建菜单是必要的（否则正在拖的
    /// 滑块会被整个换掉），但布尔量一旦因为某次收不到 mouseUp 而卡住 true，
    /// 菜单就**再也不会重建** —— 表现为显示器开回来了、菜单里却还显示旧状态。
    /// 记时间可以让这个状态自己过期。
    private var lastDragAt: Date?
    private var isDraggingSlider: Bool {
        guard let t = lastDragAt else { return false }
        return Date().timeIntervalSince(t) < 1.5
    }
    /// 当前菜单里的亮度数值标签，用于就地显示「写入无应答」
    private var sliderLabels: [CGDirectDisplayID: NSTextField] = [:]

    /// 第二页：正在看哪台显示器的详情。nil = 主面板
    private var settingsDisplayID: CGDirectDisplayID?
    /// 卡片分页页码
    private var cardPage = 0
    /// 正在「换页重开菜单」。
    ///
    /// 菜单的换页是「关掉再打开」（菜单项动作一触发，菜单必然关闭），
    /// 而 menuDidClose 里要把页面状态复位。没有这个标记的话，
    /// 换页时状态会被自己清掉，重开之后又回到主面板。
    private var isRepaging = false

    /// 开发用：让 `--shot-menu` / `--dump-menu` 直接把菜单开在某台屏的详情页
    var debugPresetSettingsID: CGDirectDisplayID?

    /// 当前菜单里的卡片行。重建菜单时更新，换页与命中判定都靠它
    private weak var cardsRow: CardsRowView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()

        registerSystemObservers()

        // 亮度写入失败时，就在滑块那一行后面显示「无应答」，而不是让用户对着没反应的滑块干瞪眼
        DisplayManager.shared.onBrightnessWriteResult = { [weak self] id, ok in
            self?.showWriteResult(id, ok)
        }

        // 开关是持久化的：应用重启后，如果外接屏早就接着，规则也该照常生效。
        // 延后两秒，等显示器和 DDC 都就绪了再判断。
        let mgr = DisplayManager.shared
        mgr.ruleLog("应用启动（版本 \(AppInfo.version)，自动关内屏开关"
                    + "\(mgr.autoDisableBuiltinWhenExternal ? "已打开" : "未打开")）")
        // 巡检只在开关打开时真的跑起来（内部会自己判断）
        mgr.startSafetyMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            mgr.applyAutoBuiltinRule(force: true, source: "启动检查")
        }
    }

    /// 建状态栏图标与菜单。
    /// 独立成方法是为了让 `--shot-menu` 能只拿外观、不背副作用（不启动巡检、不跑自动规则）——
    /// 截图工具要是顺手把用户的显示器关了，那就很难解释了。
    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = Self.menuBarIcon()
            b.toolTip = "\(AppInfo.name) — 显示器开关 / 亮度 / HiDPI / 分辨率"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// 开发用：装上状态栏图标（供截图/结构打印），不启动任何后台行为
    func debugInstallStatusItem() {
        installStatusItem()
    }

    /// 开发用：拿到状态栏按钮，好把菜单弹在该弹的地方
    var debugStatusButton: NSStatusBarButton? { statusItem?.button }

    /// 开发用：把菜单弹出来。给 `--shot-menu` 用，返回后调用方负责截屏与退出。
    func debugPopUpMenu() {
        guard let button = statusItem.button else { return }
        statusItem.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 6), in: button)
    }

    /// 监听屏幕配置变化。
    ///
    /// 关键场景：**显示器睡眠唤醒后，DDC 的 I²C 通道会哑掉** —— 句柄还在、
    /// 也不报错，但读不出也写不进，表现就是「亮度滑块还在，拖了却没反应」。
    /// 收到这些通知就标记通道待重建，用户根本不需要知道「重新检测 DDC」这个按钮。
    private func registerSystemObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            ws.addObserver(self, selector: #selector(screenConfigChanged(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenConfigChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screenConfigChanged(_ note: Notification) {
        DisplayManager.shared.screenConfigurationChanged()
    }

    /// 就地反馈亮度写入结果（不重建菜单也能看到）
    private func showWriteResult(_ id: CGDirectDisplayID, _ ok: Bool) {
        guard let label = sliderLabels[id] else { return }
        if ok {
            label.textColor = .secondaryLabelColor
            return
        }
        label.stringValue = "无应答"
        label.textColor = .systemRed
        label.isHidden = false
    }

    // 每次打开菜单都重建，保证状态实时
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !isDraggingSlider else { return }
        DisplayManager.shared.refresh()
        build(menu)
    }

    /// 菜单一关，任何拖动都已经结束了 —— 顺手把状态复位（配合时间戳双重保险）
    func menuDidClose(_ menu: NSMenu) {
        lastDragAt = nil
        sliderLabels.removeAll()
        // 换页时菜单也会先关一次，这次不算「用户关掉了菜单」，页面状态得留着
        if isRepaging {
            isRepaging = false
        } else {
            settingsDisplayID = nil
            cardPage = 0
        }
    }

    /// 换个页面重新打开菜单。
    ///
    /// 菜单项的动作一触发，菜单必然关闭，所以「页内跳转」只能做成关掉再打开。
    /// 延迟一点点是为了等上一条菜单彻底收干净 —— 紧接着 popUp 会被系统直接忽略。
    private func reopenMenu() {
        isRepaging = true
        // 换页的这一刻菜单必须先是关着的：真实路径上菜单项动作本身就会关掉菜单，
        // 但从自测里直接调动作时它不会，这里显式收一下，两种情况才等价
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.statusItem.menu?.popUp(positioning: nil,
                                        at: NSPoint(x: 0, y: button.bounds.minY - 6), in: button)
        }
    }

    /// 菜单栏图标：优先用打包进 Resources 的单色 template 图，
    /// 取不到就退回 SF Symbol（例如直接跑 .build 里的裸二进制时）。
    private static func menuBarIcon() -> NSImage? {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        var foundAny = false
        for name in ["MenuBarIcon", "MenuBarIcon@2x", "MenuBarIcon@3x"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = NSSize(width: 18, height: 18)
            image.addRepresentation(rep)
            foundAny = true
        }
        if foundAny {
            image.isTemplate = true      // 让系统按菜单栏明暗自动反色
            return image
        }
        let fallback = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: AppInfo.name)
        fallback?.isTemplate = true
        return fallback
    }

    // MARK: - 菜单构建

    private func build(_ menu: NSMenu) {
        menu.removeAllItems()
        let list = DisplayManager.shared.displays()
        let detailID = settingsDisplayID ?? debugPresetSettingsID

        if let id = detailID, let d = list.first(where: { $0.id == id }) {
            buildDetailPage(menu, d)
        } else {
            buildMainPage(menu, list)
        }
    }

    /// 主面板：一排显示器卡片（每张卡下面就是它自己的亮度条）+ 全局开关 + 底部入口
    private func buildMainPage(_ menu: NSMenu, _ list: [DisplayItem]) {
        var models = list.map { cardModel(for: $0) }
        // 开发用：把卡片数量凑到指定值，用来核对翻页（真实机器上凑不出 4 台屏）
        if let fake = debugFakeCardCount, !models.isEmpty, fake > models.count {
            while models.count < fake { models.append(models[models.count % max(list.count, 1)]) }
        }
        let cards = CardsRowView(frame: NSRect(x: 0, y: 0, width: PanelStyle.width,
                                               height: PanelStyle.rowHeight(cardCount: models.count)))
        cards.configure(cards: models, keepingPage: cardPage,
                        sliderTarget: self, sliderAction: #selector(brightnessChanged(_:)))
        cards.onSliderRelease = { [weak self] id in self?.flushBrightness(displayID: id) }
        let cardsItem = NSMenuItem(title: "显示器", action: #selector(cardsRowClicked(_:)),
                                   keyEquivalent: "")
        cardsItem.target = self
        cardsItem.view = cards
        menu.addItem(cardsItem)
        cardsRow = cards
        // 数值标签登记下来，「写入无应答」才能就地显示在卡片上
        sliderLabels = cards.valueLabels

        // 被本 app 关闭的显示器 —— 系统已查不到它们，靠这里提供重新打开入口
        for (id, rec) in DisplayManager.shared.disabled.sorted(by: { $0.key < $1.key }) {
            let mi = NSMenuItem(title: rec.name, action: #selector(enableDisplay(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = NSNumber(value: id)
            let row = ReopenRowView(frame: NSRect(x: 0, y: 0, width: PanelStyle.width, height: 30))
            row.configure(name: rec.name)
            mi.view = row
            menu.addItem(mi)
        }

        if list.isEmpty && DisplayManager.shared.disabled.isEmpty {
            addDisabled(menu, "未检测到显示器")
        }

        menu.addItem(.separator())
        menu.addItem(autoBuiltinItem())
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "重新扫描显示器", action: #selector(doRefresh), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(refreshItem)

        addFooterItems(menu)
    }

    /// 详情页：单台显示器的一张卡片 + HiDPI / 分辨率 / 关闭 / DDC。
    ///
    /// 做成独立一页而不是二级菜单，是因为二级菜单挂不上自绘卡片 ——
    /// 视图项在菜单里不会因为鼠标悬停就展开子菜单（实测），
    /// 所以「点卡片 → 换页」是唯一能既保住图形化又不丢功能的做法。
    private func buildDetailPage(_ menu: NSMenu, _ d: DisplayItem) {
        let back = NSMenuItem(title: "返回显示器列表", action: #selector(backToMainPage(_:)),
                              keyEquivalent: "")
        back.target = self
        let backView = BackRowView(frame: NSRect(x: 0, y: 0, width: PanelStyle.width, height: 30))
        back.view = backView
        menu.addItem(back)

        let detail = DisplayDetailView(frame: NSRect(x: 0, y: 0, width: PanelStyle.width, height: 108))
        detail.configure(card: cardModel(for: d), sliderTarget: self,
                         sliderAction: #selector(brightnessChanged(_:)))
        detail.onSliderRelease = { [weak self] id in self?.flushBrightness(displayID: id) }
        let detailItem = NSMenuItem(title: d.name, action: nil, keyEquivalent: "")
        detailItem.view = detail
        menu.addItem(detailItem)

        // 详情页的亮度数字是画在卡片上的，没有单独控件；登记一个不显示的替身，
        // 写入失败时依旧能走到「无应答」那条路径上（只是不显示文字）
        if detail.slider != nil {
            let label = NSTextField(labelWithString: "")
            label.isHidden = true
            sliderLabels[d.id] = label
        }

        menu.addItem(.separator())
        addSettingsItems(to: menu, for: d)
        menu.addItem(.separator())
        addFooterItems(menu)
    }

    /// 底部入口：关于 / 主页 / 退出（两页共用，免得详情页像个死胡同）
    private func addFooterItems(_ menu: NSMenu) {
        let about = NSMenuItem(title: "关于 \(AppInfo.name)", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(about)

        let repo = NSMenuItem(title: "打开项目主页", action: #selector(openRepo), keyEquivalent: "")
        repo.target = self
        repo.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        menu.addItem(repo)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 \(AppInfo.name)",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// DisplayItem → 卡片模型。菜单和自检都走这里，保证两边说的是同一件事
    private func cardModel(for d: DisplayItem) -> CardsRowView.Card {
        let mgr = DisplayManager.shared
        var res = "\(d.logicalWidth)×\(d.logicalHeight)"
        if d.pixelWidth > d.logicalWidth { res += " HiDPI" }
        let brightness = mgr.brightness(of: d)
        let note = brightness == nil
            ? (d.isBuiltin ? "未提供亮度接口" : (mgr.ddcNote(for: d) ?? "未知原因"))
            : nil
        return CardsRowView.Card(id: d.id, name: d.name, isBuiltin: d.isBuiltin, isMain: d.isMain,
                                 resolution: res, brightness: brightness, note: note)
    }

    /// 一级菜单里的全局开关：接上外接屏就自动关掉笔记本内屏。
    ///
    /// 放在一级菜单而不是塞进某台显示器的详情页里，是因为它管的是「两台屏之间的关系」，
    /// 不属于任何单独一台屏。
    private func autoBuiltinItem() -> NSMenuItem {
        let on = DisplayManager.shared.autoDisableBuiltinWhenExternal
        let row = ToggleRowView(frame: NSRect(x: 0, y: 0, width: PanelStyle.width, height: 40))
        row.configure(title: "有外接屏时自动关闭内置屏",
                      subtitle: "接上外接屏就关掉笔记本内屏，拔掉后自动开回来",
                      on: on)
        let mi = NSMenuItem(title: "有外接屏时自动关闭内置屏",
                            action: #selector(toggleAutoBuiltin(_:)), keyEquivalent: "")
        mi.target = self
        mi.state = on ? .on : .off
        mi.view = row
        mi.image = NSImage(systemSymbolName: "laptopcomputer.slash", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)
        mi.toolTip = "接上外接显示器就关掉笔记本内屏，拔掉后自动开回来"
        return mi
    }

    private func resolutionSubmenu(for d: DisplayItem) -> NSMenu {
        let menu = NSMenu()
        let showAll = DisplayManager.shared.showAllResolutions
        let modes = DisplayManager.shared.uniqueModes(d, includeAll: showAll)
        if modes.isEmpty { addDisabled(menu, "没有可切换的分辨率") }

        let hidpiNow = DisplayManager.shared.isHiDPI(d)
        for m in modes {
            let isHiDPI = m.pixelWidth > m.width
            let mi = NSMenuItem(title: "\(m.width)×\(m.height)" + (isHiDPI ? "  HiDPI" : ""),
                                action: #selector(selectMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = ModeRef(display: d.id, mode: m)
            // 必须同时比对「逻辑尺寸 + 渲染倍率」，否则 HiDPI 与非 HiDPI 两项会同时打勾
            mi.state = (m.width == d.logicalWidth && m.height == d.logicalHeight && isHiDPI == hidpiNow)
                ? .on : .off
            menu.addItem(mi)
        }

        // 显示器 EDID 常把缩放档位按 32 像素步长枚举出一两百个，默认折叠掉
        let hidden = DisplayManager.shared.hiddenModeCount(d)
        if hidden > 0 || showAll {
            menu.addItem(.separator())
            let t = NSMenuItem(title: showAll ? "只显示常用分辨率" : "显示所有分辨率",
                               action: #selector(toggleAllResolutions(_:)), keyEquivalent: "")
            t.target = self
            t.state = showAll ? .on : .off
            t.toolTip = showAll ? "回到常见档位列表" : "还有 \(hidden) 项被折叠"
            t.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
            menu.addItem(t)
        }
        return menu
    }

    /// 单台显示器的设置项：HiDPI 开关 / 分辨率 / 关闭 / DDC 诊断
    private func addSettingsItems(to menu: NSMenu, for d: DisplayItem) {
        // —— HiDPI 开关 ——
        let hi = NSMenuItem(title: "HiDPI 高清渲染", action: #selector(toggleHiDPI(_:)), keyEquivalent: "")
        hi.target = self
        hi.representedObject = NSNumber(value: d.id)
        hi.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        hi.state = DisplayManager.shared.isHiDPI(d) ? .on : .off
        if let toggle = DisplayManager.shared.hidpiToggle(d) {
            // 没有同分辨率变体时会切到最接近的档位，标题里先说清楚，避免点下去才发现分辨率变了
            if !toggle.sameResolution {
                hi.title = "HiDPI 高清渲染（将切到 \(toggle.target.width)×\(toggle.target.height)）"
            }
        } else {
            hi.isEnabled = false
            hi.title = "HiDPI 高清渲染（该屏不支持）"
        }
        menu.addItem(hi)

        // —— 分辨率 ——
        let resItem = NSMenuItem(title: "分辨率", action: nil, keyEquivalent: "")
        resItem.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
        resItem.submenu = resolutionSubmenu(for: d)
        menu.addItem(resItem)

        // —— 关闭 ——
        menu.addItem(.separator())
        let off = NSMenuItem(title: "关闭此显示器", action: #selector(disableDisplay(_:)), keyEquivalent: "")
        off.target = self
        off.representedObject = NSNumber(value: d.id)
        off.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(off)

        // —— 外接屏的 DDC 诊断与重检 ——
        if !d.isBuiltin {
            let reprobe = NSMenuItem(title: "重新检测 DDC", action: #selector(reprobeDDC(_:)), keyEquivalent: "")
            reprobe.target = self
            reprobe.representedObject = NSNumber(value: d.id)
            reprobe.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            menu.addItem(reprobe)

            if let warn = DisplayManager.shared.brightnessWarning(for: d) {
                addDisabled(menu, "   ⚠︎ \(warn)")
            }
        }
    }

    private func addDisabled(_ menu: NSMenu, _ title: String) {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        menu.addItem(mi)
    }

    // MARK: - 动作

    /// 卡片行被点击。
    ///
    /// 菜单项的动作拿不到点击坐标，所以用鼠标当前位置反查：点到哪张卡就开哪台的详情页，
    /// 点到翻页箭头就翻页。滑块自己会吃掉鼠标事件，正常拖亮度不会走到这里 ——
    /// 万一走上来了（判定落在滑块上），也不能顺手换页，那是很吓人的行为。
    @objc private func cardsRowClicked(_ sender: NSMenuItem) {
        guard let row = sender.view as? CardsRowView else { return }
        handleCardsHit(row)
    }

    @discardableResult
    private func handleCardsHit(_ row: CardsRowView) -> String {
        switch row.hitAtMouse() {
        case .card(let id):
            settingsDisplayID = id
            reopenMenu()
            return "卡片 \(id) → 详情页"
        case .pagePrev:
            cardPage = max(0, cardPage - 1)
            reopenMenu()
            return "上一页"
        case .pageNext:
            cardPage += 1
            reopenMenu()
            return "下一页"
        case .slider:
            return "落在滑块上（不换页）"
        case .none:
            return "没命中任何卡片"
        }
    }

    /// 从详情页回到主面板
    @objc private func backToMainPage(_ sender: NSMenuItem) {
        settingsDisplayID = nil
        reopenMenu()
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        let id = CGDirectDisplayID(sender.tag)
        guard let d = DisplayManager.shared.displays().first(where: { $0.id == id }) else { return }

        lastDragAt = Date()          // 拖动期间不重建菜单（时间戳会自己过期）
        let percent = sender.doubleValue
        if let label = sliderLabels[id] {
            label.stringValue = "\(Int(percent.rounded()))%"
            label.textColor = .secondaryLabelColor
            label.isHidden = false
        }

        // 节流写入：拖动中最多每 100ms 一次 I²C，避免把显示器写死
        DisplayManager.shared.setBrightnessThrottled(d, percent / 100)
    }

    /// 松手后把最后一档数值真正落到显示器（节流会吞掉末尾几次）
    private func flushBrightness(displayID: CGDirectDisplayID) {
        guard let d = DisplayManager.shared.displays().first(where: { $0.id == displayID }) else { return }
        DisplayManager.shared.flushBrightness(d)
    }

    @objc private func toggleHiDPI(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        let id = CGDirectDisplayID(n.uint32Value)
        guard let d = DisplayManager.shared.displays().first(where: { $0.id == id }),
              DisplayManager.shared.toggleHiDPI(d) else {
            NSSound.beep()
            return
        }
    }

    @objc private func disableDisplay(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        let id = CGDirectDisplayID(n.uint32Value)
        let name = DisplayManager.shared.displays().first(where: { $0.id == id })?.name ?? "显示器"
        if !DisplayManager.shared.setEnabled(id, false, name: name) {
            NSSound.beep()   // 失败（例如这是最后一台）时提醒
        }
    }

    @objc private func enableDisplay(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        // 这一行也是自绘视图，点击是我们自己转过来的，菜单不会自动关，得显式收一下
        sender.menu?.cancelTracking()
        if !DisplayManager.shared.setEnabled(CGDirectDisplayID(n.uint32Value), true) {
            NSSound.beep()
        }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ModeRef else { return }
        if !DisplayManager.shared.setMode(ref.display, ref.mode) { NSSound.beep() }
    }

    @objc private func reprobeDDC(_ sender: NSMenuItem) {
        DisplayManager.shared.forceReprobeDDC()
    }

    @objc private func toggleAllResolutions(_ sender: NSMenuItem) {
        DisplayManager.shared.showAllResolutions.toggle()
        // 列表本身已经建好，就地改不划算 —— 收起菜单，下次打开就是新的列表
        sender.menu?.cancelTracking()
    }

    @objc private func doRefresh() {
        // 用户主动要求重扫 —— 顺带解除 DDC 冷却并重建句柄
        DisplayManager.shared.forceReprobeDDC()
    }

    /// 切换「有外接屏时自动关闭内置屏」。
    /// 打开时立刻按当前情况办一次：拨开开关的这一刻，外接屏可能早就接着了。
    @objc private func toggleAutoBuiltin(_ sender: NSMenuItem) {
        let mgr = DisplayManager.shared
        mgr.autoDisableBuiltinWhenExternal.toggle()

        // 先收菜单：紧接着要等系统改显示配置，菜单挂在那儿会显得卡住
        sender.menu?.cancelTracking()

        if mgr.autoDisableBuiltinWhenExternal {
            mgr.startSafetyMonitor()
            mgr.applyAutoBuiltinRule(force: true, source: "开关打开")
        } else {
            mgr.stopSafetyMonitor()
            mgr.ruleLog("开关关闭（不主动把内屏打开 —— 用户可能正想让内屏保持关着）")
        }
        // 关掉开关时不主动把内屏打开 —— 用户可能正想让内屏保持关着
    }

    @objc private func showAbout() {
        NSApp.activate()
        let credits = NSMutableAttributedString(
            string: "开源显示器控制工具\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )
        credits.append(NSAttributedString(
            string: AppInfo.repoURL,
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .link: URL(string: AppInfo.repoURL)!]
        ))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.bundleVersion,
            .version: "",
            .credits: credits
        ])
    }

    @objc private func openRepo() {
        guard let url = URL(string: AppInfo.repoURL) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 自检辅助

    /// 开发用：把菜单弹出来，并把每个可点行在**屏幕坐标**里的位置打出来。
    ///
    /// 为什么要这么个东西：菜单只在弹着的时候才有窗口，坐标又受多屏排列影响，
    /// 靠截屏去量「卡片中心大概在哪」误差能到几十点，合成点击就会落空 ——
    /// 而落空的表现是「菜单关掉、什么都没发生」，跟「这一行本来就不能点」长得一样，
    /// 排查时很容易把人带偏。让 app 自己算，点起来才是确定的。
    ///
    /// 注意 `popUp` 是**同步阻塞**的：它会一直跑菜单的跟踪循环，直到菜单关闭才返回。
    /// 所以这里必须分两步 —— 先用 `async` 把菜单弹起来，再靠挂在 `.eventTracking`
    /// 模式上的定时器回来打印（菜单跟踪期间，`.default` 模式下的定时器根本不会触发）。
    func debugPopUpAndReportHits() {
        let menu = NSMenu()
        build(menu)
        statusItem.menu = menu
        guard let button = statusItem.button else { print("没有状态栏按钮"); return }

        let report = Timer(timeInterval: 0.7, repeats: false) { [weak self] _ in
            guard let self else { return }
            print(self.debugHitPoints(menu))
            fflush(stdout)
        }
        RunLoop.main.add(report, forMode: .eventTracking)
        RunLoop.main.add(report, forMode: .default)

        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 6), in: button)
        }
    }

    /// 把 `menu` 里每个自绘行的中心点换算成屏幕坐标（原点左上，跟 CGEvent 一致）
    func debugHitPoints(_ menu: NSMenu) -> String {
        var lines: [String] = []
        for item in menu.items {
            guard let view = item.view, let window = view.window,
                  let b = CardsRowView.windowBounds(window) else { continue }
            let inWin = view.convert(view.bounds, to: nil)
            let cx = Int(b.origin.x + inWin.midX)
            let cy = Int(b.origin.y + b.height - inWin.midY)

            switch view {
            case let cards as CardsRowView:
                lines.append("卡片行  中心 (\(cx), \(cy))  共 \(cards.cards.count) 张  第 \(cards.page + 1)/\(cards.pages) 页")
                for i in 0..<cards.cards.count where i / PanelStyle.maxCardsPerPage == cards.page {
                    lines.append("   卡片[\(i)]  " + cards.warpMouseToCard(i))
                }
            case is ToggleRowView:
                lines.append("开关行  中心 (\(cx), \(cy))")
            case is BackRowView:
                lines.append("返回行  中心 (\(cx), \(cy))")
            case is ReopenRowView:
                lines.append("已关闭行 中心 (\(cx), \(cy))")
            default:
                lines.append("其它自绘行 中心 (\(cx), \(cy))")
            }
        }
        return lines.isEmpty ? "没找到自绘行" : lines.joined(separator: "\n")
    }

    /// 构建一遍菜单并把层级打印出来。供 `--dump-menu` 使用：
    /// 菜单是懒加载的，不打开就不会构建，这个方法让「菜单能不能建起来」变成可测的。
    func debugMenuDump() -> String {
        let menu = NSMenu()
        build(menu)
        var lines: [String] = []
        lines.append((settingsDisplayID ?? debugPresetSettingsID) != nil ? "  【详情页】" : "  【主面板】")
        for item in menu.items {
            if item.isSeparatorItem { lines.append("  ─────────────"); continue }
            var note = ""
            if item.view != nil { note += "  [自绘 \(Int(item.view!.frame.width))×\(Int(item.view!.frame.height))]" }
            if !item.isEnabled { note += "  [禁用]" }
            if item.submenu != nil { note += "  [子菜单]" }
            lines.append("  \(item.state == .on ? "◉" : "○") \(item.title)\(note)")
            guard let sub = item.submenu else { continue }
            for s in sub.items {
                if s.isSeparatorItem { lines.append("      ──────"); continue }
                lines.append("      \(s.state == .on ? "◉" : "○") \(s.title)" + (s.isEnabled ? "" : "  [禁用]"))
                guard let deep = s.submenu else { continue }
                let real = deep.items.filter { !$0.isSeparatorItem }
                for x in real.prefix(4) {
                    lines.append("          · \(x.title)" + (x.state == .on ? "  ← 当前" : ""))
                }
                if real.count > 4 { lines.append("          · …共 \(real.count) 项") }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 把菜单弹出来（开发用，给 `--shot-menu` 截屏）。返回 false 表示状态栏图标没建起来。
    @discardableResult
    func debugPresentMenu() -> Bool {
        guard statusItem?.button != nil else { return false }
        debugPopUpMenu()
        return true
    }

    /// 开发用：模拟「点了第 n 张卡」。
    ///
    /// 为什么不能直接合成鼠标点击：发 CGEvent 需要辅助功能授权，沙箱里发出去就被丢掉，
    /// 什么都没发生还看不出原因。所以改成「移动真实光标 + 直接走动作」——
    /// 命中判定读的就是真实光标位置，除了事件传递这一段，链路其余部分都是真的。
    @discardableResult
    func debugClickCard(_ index: Int) -> String {
        guard let row = cardsRow else { return "没有卡片行" }
        guard index >= 0, index < row.cards.count else { return "卡片下标越界（共 \(row.cards.count) 张）" }
        let moved = row.warpMouseToCard(index)
        let hit = headingForCard(index)
        let result = handleCardsHit(row)
        return "\(moved)；「\(hit)」→ \(result)"
    }

    private func headingForCard(_ index: Int) -> String {
        guard let row = cardsRow, index < row.cards.count else { return "?" }
        return row.cards[index].name
    }

    /// 开发用：当前是不是在详情页
    var debugIsDetailPage: Bool { (settingsDisplayID ?? debugPresetSettingsID) != nil }

    /// 开发用：模拟点「返回显示器列表」
    @discardableResult
    func debugClickBack() -> String {
        guard settingsDisplayID != nil || debugPresetSettingsID != nil else { return "本来就在主面板" }
        settingsDisplayID = nil
        debugPresetSettingsID = nil
        reopenMenu()
        return "已请求返回主面板"
    }

    /// 开发用：把光标移到第 n 张卡上（不点击），用来看悬停高亮
    @discardableResult
    func debugHoverCard(_ index: Int) -> String {
        guard let row = cardsRow else { return "没有卡片行" }
        guard index >= 0, index < row.cards.count else { return "卡片下标越界" }
        return row.warpMouseToCard(index) + "；「\(row.cards[index].name)」"
    }

    /// 开发用：把卡片数量凑到 n 张，用来看翻页（真机上凑不出那么多显示器）
    var debugFakeCardCount: Int?

    /// 开发用：菜单里有没有卡片行（用来判断菜单到底建起来没有）
    var debugCardsRow: CardsRowView? { cardsRow }
}
