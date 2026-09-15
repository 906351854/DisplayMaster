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

    /// 分辨率滑块每一档对应的模式，建菜单时顺手算好。
    ///
    /// 滑块身上只有「下标」——`NSSlider` 没法背一个 `CGDisplayMode` 数组；
    /// 松手那一刻要拿下标换回真正的模式，就得有这张表。它必须和滑块上摆的
    /// 是同一份列表，否则拖到第 7 档会切到别的分辨率上去。
    private var resolutionModes: [CGDirectDisplayID: [CGDisplayMode]] = [:]

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
        // 巡检跟开关无关：它只管「一块能看的屏都没有」这种故障态，
        // 和「有外接屏时要顺手关内屏」这个偏好是两回事（见 applyAutoBuiltinRule）。
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
        resolutionModes.removeAll()
        var cards = cardModels()
        // 开发用：把卡片数凑到指定值，用来核对翻页（真机上凑不出那么多显示器）
        if let fake = debugFakeCardCount, !cards.isEmpty, fake > cards.count {
            let originals = cards
            while cards.count < fake { cards.append(originals[cards.count % originals.count]) }
        }
        // 开发用：把某几张卡当成「已关闭」来画（核对外观用，不碰真实硬件）
        for i in debugForceOffIndices where i >= 0 && i < cards.count {
            cards[i] = cards[i].asOff()
        }
        let panelW = CardsRowView.panelWidth(count: max(cards.count, 1))

        let detailID = settingsDisplayID ?? debugPresetSettingsID
        if let id = detailID, let card = cards.first(where: { $0.id == id }) {
            buildDetailPage(menu, card, panelWidth: panelW)
        } else {
            buildMainPage(menu, cards, panelWidth: panelW)
        }
    }

    /// 主面板：一排显示器卡片（每张卡自带亮度 / 开启 / HiDPI）+ 全局开关 + 底部入口。
    ///
    /// 卡片是**横排**的，而且被关掉的屏同样占一张卡 —— 它的「开启」是关着的，
    /// 点一下就在原地开回来。以前关掉的屏会被挪到菜单底部单独列一行，
    /// 那块屏就从「一排卡片」里消失了，看起来很别扭。
    private func buildMainPage(_ menu: NSMenu, _ cards: [CardsRowView.Card], panelWidth: CGFloat) {
        guard !cards.isEmpty else {
            addDisabled(menu, "未检测到显示器")
            menu.addItem(.separator())
            menu.addItem(autoBuiltinItem(panelWidth: panelWidth))
            menu.addItem(.separator())
            menu.addItem(refreshItem())
            addFooterItems(menu)
            return
        }

        let row = CardsRowView(frame: NSRect(x: 0, y: 0, width: panelWidth,
                                             height: CardsRowView.rowHeight))
        row.configure(cards: cards, keepingPage: cardPage,
                      modes: resolutionModes,
                      sliderTarget: self, sliderAction: #selector(brightnessChanged(_:)),
                      resolutionTarget: self, resolutionAction: #selector(resolutionChanged(_:)))
        row.onSliderRelease = { [weak self] id in self?.flushBrightness(displayID: id) }
        row.onResolutionRelease = { [weak self] id, index in
            self?.applyResolution(displayID: id, index: index)
        }
        let item = NSMenuItem(title: "显示器", action: #selector(cardsRowClicked(_:)),
                              keyEquivalent: "")
        item.target = self
        item.view = row
        menu.addItem(item)
        cardsRow = row
        // 数值标签登记下来，「写入无应答」才能就地显示在卡片上
        sliderLabels = row.valueLabels

        menu.addItem(.separator())
        menu.addItem(autoBuiltinItem(panelWidth: panelWidth))
        menu.addItem(.separator())
        menu.addItem(refreshItem())
        addFooterItems(menu)
    }

    /// 详情页：一张横幅 + 卡片上放不下的那些（完整分辨率列表 / DDC 重检 / 忘记）。
    ///
    /// 亮度、分辨率滑块、开启、HiDPI 都已经在那张屏自己的卡片上了，这里不重复放 ——
    /// 同一个开关出现在两个地方，用户会以为它们是两件事。
    /// 详情页是「补充」，不是「另一套控件」。
    private func buildDetailPage(_ menu: NSMenu, _ card: CardsRowView.Card, panelWidth: CGFloat) {
        let back = NSMenuItem(title: "返回显示器列表", action: #selector(backToMainPage(_:)),
                              keyEquivalent: "")
        back.target = self
        let backView = BackRowView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 30))
        backView.rowWidth = panelWidth
        back.view = backView
        menu.addItem(back)

        let header = DetailHeaderView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 78))
        header.configure(card: card, width: panelWidth)
        let headerItem = NSMenuItem(title: card.title, action: nil, keyEquivalent: "")
        headerItem.view = header
        menu.addItem(headerItem)

        menu.addItem(.separator())
        addAdvancedItems(to: menu, for: card)
        menu.addItem(.separator())
        addFooterItems(menu)
    }

    private func refreshItem() -> NSMenuItem {
        let item = NSMenuItem(title: "重新扫描显示器", action: #selector(doRefresh), keyEquivalent: "r")
        item.target = self
        item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        return item
    }

    /// 底部入口：关于 / 主页 / 退出（两层共用，免得详情页像个死胡同）
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

    // MARK: - 卡片模型

    /// 菜单里那一排卡片。**在线和被关掉的屏一起排**，顺序是
    /// 内屏（不论开关）→ 外接屏（不论开关），编号也按这个顺序给。
    ///
    /// 把两类屏放进同一张列表里是有意的：关掉的屏不该从那一排里消失，
    /// 否则「关掉内屏」之后菜单里就只剩外接屏，看不见自己刚关了什么。
    private func cardModels() -> [CardsRowView.Card] {
        let mgr = DisplayManager.shared
        let list = mgr.displays()
        let disabledSorted = mgr.disabled.sorted { $0.key < $1.key }
        var cards: [CardsRowView.Card] = []
        var externalIndex = 0

        func nextExternalTitle(isBuiltin: Bool) -> String {
            if isBuiltin { return "内置显示器" }
            externalIndex += 1
            return "外接显示器 \(externalIndex)"
        }

        func online(_ d: DisplayItem) -> CardsRowView.Card {
            let brightness = mgr.brightness(of: d)
            let note = brightness == nil
                ? (d.isBuiltin ? "内置屏未提供亮度接口" : (mgr.ddcNote(for: d) ?? "未知原因"))
                : nil
            let hidpi = mgr.isHiDPI(d)
            // 档位表顺手存一份给「松手切模式」用：这里算的和滑块上摆的是同一份，
            // 不然下标对不上，拖到哪一档就切错
            let steps = resolutionSteps(d)
            resolutionModes[d.id] = steps
            return CardsRowView.Card(
                id: d.id,
                title: nextExternalTitle(isBuiltin: d.isBuiltin),
                model: d.name,
                spec: specLine(d),
                isBuiltin: d.isBuiltin,
                isMain: d.isMain,
                aspect: aspect(width: d.logicalWidth, height: d.logicalHeight),
                isOn: true,
                brightness: debugFakeBrightness ?? brightness,
                note: note,
                hidpi: hidpi,
                hidpiAvailable: mgr.hidpiToggle(d) != nil,
                resolution: "\(d.logicalWidth) × \(d.logicalHeight)",
                resolutionCount: steps.count,
                resolutionIndex: steps.firstIndex {
                    $0.width == d.logicalWidth && $0.height == d.logicalHeight
                        && ($0.pixelWidth > $0.width) == hidpi
                } ?? 0,
                resolutionHiDPI: hidpi
            )
        }

        func offline(_ id: CGDirectDisplayID, _ rec: DisabledDisplay) -> CardsRowView.Card {
            CardsRowView.Card(
                id: id,
                title: nextExternalTitle(isBuiltin: rec.isBuiltin),
                model: rec.name,
                spec: rec.specLine,
                isBuiltin: rec.isBuiltin,
                isMain: false,
                aspect: aspect(width: rec.logicalWidth, height: rec.logicalHeight),
                isOn: false,
                brightness: rec.brightness,
                note: rec.brightness == nil ? "关闭前的亮度没有记录" : nil,
                hidpi: rec.hidpi,
                hidpiAvailable: false,
                resolution: "\(rec.logicalWidth) × \(rec.logicalHeight)",
                resolutionCount: 1,
                resolutionIndex: 0,
                resolutionHiDPI: rec.hidpi
            )
        }

        for d in list where d.isBuiltin { cards.append(online(d)) }
        for (id, rec) in disabledSorted where rec.isBuiltin { cards.append(offline(id, rec)) }
        for d in list where !d.isBuiltin { cards.append(online(d)) }
        for (id, rec) in disabledSorted where !rec.isBuiltin { cards.append(offline(id, rec)) }
        return cards
    }

    /// 分辨率滑块上的档位。
    ///
    /// 菜单里那份「常见档位」有三十多档（这台机器上的外接屏实测 36 档），
    /// 做成滑块就是满屏小点、每格 4pt，根本拖不准 —— 那不是滑块该干的事。
    /// 所以滑块只收**和面板原生比例一致**的那些档：一块 16:9 的屏就是
    /// 1024×576 / 1280×720 / … / 3840×2160 这么十来档，
    /// 跟系统设置里那排「更大文字 ↔ 更多空间」是同一个意思。
    ///
    /// 同一逻辑尺寸有 HiDPI 和非 HiDPI 两版时留 HiDPI：同一块屏上总是清晰的那一版
    /// 更合理。真要 1:1 的原始分辨率，详情页里有完整列表。
    ///
    /// 非 private：`--modes` 那条排查命令就是调它打印档位的。
    func resolutionSteps(_ d: DisplayItem) -> [CGDisplayMode] {
        let curated = DisplayManager.shared.uniqueModes(d)
        let native = Double(d.pixelWidth) / Double(max(d.pixelHeight, 1))

        /// 逻辑宽 → 挑中的那一档（比例一致时，宽度就能定位一档）
        var picked: [Int: CGDisplayMode] = [:]
        for m in curated {
            let a = Double(m.width) / Double(max(m.height, 1))
            guard abs(a - native) / native < 0.02 else { continue }
            if let exist = picked[m.width] {
                if m.pixelWidth > exist.pixelWidth { picked[m.width] = m }
            } else {
                picked[m.width] = m
            }
        }
        var steps = picked.values.sorted { $0.width < $1.width }

        // 比例一个都没命中（很冷门的面板）：退回常见档位列表，别让滑块空掉
        if steps.count < 2 {
            var byWidth: [Int: CGDisplayMode] = [:]
            for m in curated where byWidth[m.width] == nil || m.pixelWidth > byWidth[m.width]!.pixelWidth {
                byWidth[m.width] = m
            }
            steps = byWidth.values.sorted { $0.width < $1.width }
        }
        return steps
    }

    /// 面板规格「5120 × 2880 · 60 Hz」。
    ///
    /// 刻意用**物理**分辨率：当前逻辑分辨率由分辨率滑块那一行说，
    /// 这里再说一遍就是同一句话重复两遍（还只隔三行）。
    private func specLine(_ d: DisplayItem) -> String {
        var s = "\(d.pixelWidth) × \(d.pixelHeight)"
        if let hz = CGDisplayCopyDisplayMode(d.id)?.refreshRate, hz >= 1 {
            s += " · \(Int(hz.rounded())) Hz"
        }
        return s
    }

    /// 缩略图里那块屏的长宽比，跟着真实分辨率走 —— 带鱼屏一眼就认得出来
    private func aspect(width: Int, height: Int) -> CGFloat {
        guard width > 0, height > 0 else { return 16.0 / 9.0 }
        return CGFloat(width) / CGFloat(height)
    }

    /// 「有外接屏时自动关闭内置屏」。
    ///
    /// 放在主面板而不是塞进某台显示器的卡片里，是因为它管的是「两台屏之间的关系」，
    /// 不属于任何单独一台屏。
    private func autoBuiltinItem(panelWidth: CGFloat) -> NSMenuItem {
        let on = DisplayManager.shared.autoDisableBuiltinWhenExternal
        let row = ToggleRowView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 40))
        row.configure(title: "有外接屏时自动关闭内置屏",
                      subtitle: "接上外接屏就关掉笔记本内屏，拔掉后自动开回来",
                      on: on, width: panelWidth)
        let mi = NSMenuItem(title: "有外接屏时自动关闭内置屏",
                            action: #selector(toggleAutoBuiltin(_:)), keyEquivalent: "")
        mi.target = self
        mi.state = on ? .on : .off
        mi.view = row
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

    /// 详情页里那些「卡片上放不下」的项：完整分辨率列表 / DDC 重检 / 忘记这台屏。
    ///
    /// 亮度、分辨率滑块、开启（关闭）、HiDPI 都已经在卡片上了，这里刻意不再放一遍 ——
    /// 同一个开关出现在两个地方，用户会以为它们是两件事。
    /// 分辨率下拉是滑块之外的逃生口：滑块只收面板原生比例那一批，
    /// 剩下的（给老游戏用的 640×480 之类）还得有个地方能点到。
    private func addAdvancedItems(to menu: NSMenu, for card: CardsRowView.Card) {
        let mgr = DisplayManager.shared
        let d = mgr.displays().first { $0.id == card.id }

        if let d = d {
            let resItem = NSMenuItem(title: "全部分辨率", action: nil, keyEquivalent: "")
            resItem.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
            resItem.toolTip = "滑块上只放面板原生比例那一批，这里是完整列表"
            resItem.submenu = resolutionSubmenu(for: d)
            menu.addItem(resItem)
        } else {
            let placeholder = NSMenuItem(title: "全部分辨率（这台屏关着，先在卡片上打开它）",
                                         action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            placeholder.image = NSImage(systemSymbolName: "rectangle.on.rectangle",
                                        accessibilityDescription: nil)
            menu.addItem(placeholder)
        }

        // —— 亮度不可控的原因（卡片上写不下全文）——
        if let d = d, let warn = mgr.brightnessWarning(for: d) {
            addDisabled(menu, "   ⚠︎ \(warn)")
        } else if let note = card.note, card.brightness == nil {
            addDisabled(menu, "   ⚠︎ \(note)")
        }

        // 显示器被关掉之后又拔了线，这条记录就永远等不到它回来了 ——
        // 自动清理只认「按 EDID 发现它回来了」，剩下的得让用户能手动收尾。
        if !card.isOn {
            menu.addItem(.separator())
            let forget = NSMenuItem(title: "忘记这台显示器（从列表移除）",
                                    action: #selector(forgetDisplay(_:)), keyEquivalent: "")
            forget.target = self
            forget.representedObject = NSNumber(value: card.id)
            forget.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            menu.addItem(forget)
        }

        // —— 外接屏的 DDC 诊断与重检（卡片上没有，因为它不是「日常会拨的开关」）——
        if let d = d, !d.isBuiltin {
            menu.addItem(.separator())
            let reprobe = NSMenuItem(title: "重新检测 DDC", action: #selector(reprobeDDC(_:)), keyEquivalent: "")
            reprobe.target = self
            reprobe.representedObject = NSNumber(value: d.id)
            reprobe.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            menu.addItem(reprobe)
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
    /// 菜单项的动作拿不到点击坐标，所以用鼠标当前位置反查：点到哪张卡的哪个部位，
    /// 就办哪件事。滑块自己会吃掉鼠标事件，正常拖亮度不会走到这里 ——
    /// 万一走上来了（判定落在滑块上），也不能顺手换页，那是很吓人的行为。
    @objc private func cardsRowClicked(_ sender: NSMenuItem) {
        guard let row = sender.view as? CardsRowView else { return }
        handleCardsHit(row)
    }

    @discardableResult
    private func handleCardsHit(_ row: CardsRowView) -> String {
        switch row.hitAtMouse() {
        case .detail(let id):
            settingsDisplayID = id
            reopenMenu()
            return "卡片 \(id) → 详情页"
        case .toggleOn(let id):
            return toggleDisplayOn(id)
        case .toggleHiDPI(let id):
            return toggleHiDPIBecauseCardClicked(id)
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

    /// 卡片上那个「开启」开关：开着就关掉，关着就打开。
    ///
    /// 关掉一台屏要等系统改完显示配置（最长两秒），期间菜单必须**先收起来**，
    /// 否则菜单就那么挂在那儿不动，看起来像卡死。办完再把菜单弹回来，
    /// 用户看到的就已经是新的状态了。
    @discardableResult
    private func toggleDisplayOn(_ id: CGDirectDisplayID) -> String {
        let mgr = DisplayManager.shared
        isRepaging = true                 // 这次关闭不是「用户关掉菜单」，页面状态要留着
        statusItem.menu?.cancelTracking()

        let wasOn = mgr.displays().contains { $0.id == id }
        let ok: Bool
        if let d = mgr.displays().first(where: { $0.id == id }) {
            ok = mgr.setEnabled(d.id, false, name: d.name)
        } else {
            ok = mgr.setEnabled(id, true)
        }
        reopenMenu()
        let what = wasOn ? "关闭" : "打开"
        return ok ? "\(what)成功" : "\(what)失败（系统拒绝，或这是最后一台屏）"
    }

    /// 卡片上的 HiDPI 开关
    ///
    /// 必须**等菜单彻底收干净**再改显示配置。踩到的坑：菜单项动作一触发菜单就要收，
    /// 如果在收的这一帧里（或者像之前那样，重开菜单的定时器已经排上队、菜单又弹起来了）
    /// 去调 CGDisplaySetDisplayMode，系统会返回 success、配置也确实短暂变过，
    /// 然后**又被还原回去** —— 用户看到的就是「点了 HiDPI 没反应」。
    /// 所以这里挪到 0.25 秒之后再动手，办完才重开菜单。
    @discardableResult
    private func toggleHiDPIBecauseCardClicked(_ id: CGDirectDisplayID) -> String {
        guard let d = DisplayManager.shared.displays().first(where: { $0.id == id }) else {
            return "这台屏是关着的，HiDPI 切不了"
        }
        isRepaging = true
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let ok = DisplayManager.shared.toggleHiDPI(d)
            if !ok { NSSound.beep() }
            self.reopenMenu()
        }
        return "HiDPI 已切换"
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

    // MARK: - 分辨率滑块

    /// 拖动中：只把数字改掉，**不切模式**。
    /// 切一次模式屏幕要黑一下、窗口还要重排，边拖边切屏幕上就是一片频闪。
    @objc private func resolutionChanged(_ sender: PanelSlider) {
        lastDragAt = Date()          // 拖动期间不重建菜单（时间戳会自己过期）
        let id = CGDirectDisplayID(sender.tag)
        cardsRow?.previewResolution(id: id, index: Int(sender.doubleValue.rounded()))
    }

    /// 松手：真正切过去。
    ///
    /// 和 HiDPI 那条路一样，必须**等菜单收干净再动手**：在菜单收尾那一帧里改显示配置，
    /// 系统会返回成功、配置也确实短暂变过，然后又被还原回去 —— 用户看到的就是
    /// 「拖了没反应」。切模式本来就要黑屏一下，菜单挂在那儿只会让人以为卡住了，
    /// 索性先收起来、切完再弹回来。
    private func applyResolution(displayID id: CGDirectDisplayID, index: Int) {
        let modes = resolutionModes[id] ?? []
        guard index >= 0, index < modes.count else { return }
        let mode = modes[index]

        // 拖回原来那一档（或者只是点了一下滑块头）就当作没动过 ——
        // 没必要为一次「原地踏步」把菜单收起来再弹回去
        if let d = DisplayManager.shared.displays().first(where: { $0.id == id }),
           isCurrent(d, mode) {
            return
        }

        isRepaging = true
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if !DisplayManager.shared.setMode(id, mode) { NSSound.beep() }
            self.reopenMenu()
        }
    }

    /// 这一档是不是这块屏现在正在用的那一档。
    /// 必须同时比对「逻辑尺寸 + 渲染倍率」，否则 HiDPI 和非 HiDPI 会认成同一档。
    private func isCurrent(_ d: DisplayItem, _ m: CGDisplayMode) -> Bool {
        m.width == d.logicalWidth && m.height == d.logicalHeight
            && (m.pixelWidth > m.width) == DisplayManager.shared.isHiDPI(d)
    }

    /// 把一条「已关闭」记录丢掉（显示器早就拔线了，不可能再回来）
    @objc private func forgetDisplay(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        DisplayManager.shared.forgetDisabled(CGDirectDisplayID(n.uint32Value))
        settingsDisplayID = nil
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
            // 保险起见再调一次：万一启动时还认不出内屏（没有任何 id 记录），
            // 那会儿巡检没跑起来；现在可能已经认出来了。
            mgr.startSafetyMonitor()
            mgr.applyAutoBuiltinRule(force: true, source: "开关打开")
        } else {
            // 关掉开关**不停巡检**：巡检只管「一块能看的屏都没有」这个故障态，
            // 和这个偏好无关。关掉开关的人照样可能黑屏（内屏是外接屏插着的时候
            // 手动关的），停了巡检就等于把那类人交给黑屏。
            mgr.ruleLog("开关关闭（不再主动关内屏；黑屏救援照旧生效）")
        }
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
    ///
    /// 卡片按**部位**分别报点：同一张卡上「主体」「开启」「HiDPI」是三个不同的动作，
    /// 只报卡片中心的话，自测点下去永远落在「进详情页」上，那两枚开关就等于没测。
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
                let perPage = PanelStyle.perPage(count: cards.cards.count)
                lines.append("卡片行  中心 (\(cx), \(cy))  共 \(cards.cards.count) 张  "
                             + "第 \(cards.page + 1)/\(cards.pages) 页  面板宽 \(Int(cards.bounds.width))")
                for i in 0..<cards.cards.count where i / perPage == cards.page {
                    let c = cards.cards[i]
                    lines.append("   卡片[\(i)]「\(c.title)」\(c.isOn ? "开" : "关")  \(c.spec)")
                    for part in [CardsRowView.Part.detail, .toggleOn, .toggleHiDPI] {
                        lines.append("      \(Self.partLabel(part))  " + cards.warpMouseTo(index: i, part: part))
                    }
                }
            case is ToggleRowView:
                lines.append("自动关内屏开关行  中心 (\(cx), \(cy))")
            case is BackRowView:
                lines.append("返回行  中心 (\(cx), \(cy))")
            case is DetailHeaderView:
                lines.append("详情横幅  中心 (\(cx), \(cy))")
            default:
                lines.append("其它自绘行 中心 (\(cx), \(cy))")
            }
        }
        return lines.isEmpty ? "没找到自绘行" : lines.joined(separator: "\n")
    }

    static func partLabel(_ part: CardsRowView.Part) -> String {
        switch part {
        case .detail: return "卡片主体"
        case .toggleOn: return "开启    "
        case .toggleHiDPI: return "HiDPI   "
        }
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

    /// 开发用：模拟「点了第 n 张卡的某个部位」。
    ///
    /// 为什么不能直接合成鼠标点击：发 CGEvent 需要辅助功能授权，发出去会被丢掉，
    /// 什么都没发生还看不出原因。所以改成「移动真实光标 + 直接走动作」——
    /// 命中判定读的就是真实光标位置，除了事件传递这一段，链路其余部分都是真的。
    @discardableResult
    func debugClickCard(_ index: Int, part: CardsRowView.Part = .detail) -> String {
        guard let row = cardsRow else { return "没有卡片行" }
        guard index >= 0, index < row.cards.count else { return "卡片下标越界（共 \(row.cards.count) 张）" }
        let moved = row.warpMouseTo(index: index, part: part)
        let title = row.cards[index].title
        let result = handleCardsHit(row)
        return "\(moved)；「\(title)」\(Self.partLabel(part)) → \(result)"
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

    /// 开发用：把光标移到第 n 张卡的某个部位上（不点击），用来看悬停高亮
    @discardableResult
    func debugHoverCard(_ index: Int, part: CardsRowView.Part = .detail) -> String {
        guard let row = cardsRow else { return "没有卡片行" }
        guard index >= 0, index < row.cards.count else { return "卡片下标越界" }
        return row.warpMouseTo(index: index, part: part) + "；「\(row.cards[index].title)」"
    }

    /// 开发用：走一遍「在这张卡上把分辨率滑块拖到第 n 档、松手」那条链路。
    ///
    /// 为什么不能只调 `applyResolution`：那条链路上真正容易错的是「滑块上的下标
    /// → 档位表里的模式」这一步 —— 两边算的要是同一份列表才行，差一档就会切到
    /// 隔壁的分辨率上去，而且看起来「能切」，不容易发现。所以这里连拖动中的
    /// 文字更新一起跑，只是不合成真实鼠标事件。
    @discardableResult
    func debugDragResolution(card: Int, step: Int) -> String {
        if cardsRow == nil { build(NSMenu()) }      // 离线自测时菜单还没建过
        guard let row = cardsRow else { return "没有卡片行" }
        guard card >= 0, card < row.cards.count else { return "卡片下标越界" }
        row.previewResolution(id: row.cards[card].id, index: step)
        let text = row.resLabels[row.cards[card].id]?.stringValue ?? "?"
        let steps = resolutionModes[row.cards[card].id]?.count ?? 0
        applyResolution(displayID: row.cards[card].id, index: step)
        return "「\(row.cards[card].title)」分辨率滑块 → 第 \(step) 档（共 \(steps) 档，"
            + "数值显示 \(text)）"
    }

    /// 开发用：把卡片数量凑到 n 张，用来看翻页（真机上凑不出那么多显示器）
    var debugFakeCardCount: Int?
    /// 开发用：把这几张卡画成「已关闭」状态，用来核对关闭态的样式
    var debugForceOffIndices: [Int] = []
    /// 开发用：强制把亮度画成这个值（0…1），用来核对滑块两端到底到没到底
    var debugFakeBrightness: Double?

    /// 开发用：菜单里有没有卡片行（用来判断菜单到底建起来没有）
    var debugCardsRow: CardsRowView? { cardsRow }
}
