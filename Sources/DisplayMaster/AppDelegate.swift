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
/// 之所以要子类，是因为拖动过程中 NSSlider 只保证「连续动作」，
/// 拿不到可靠的「松手」时机，而最后一档亮度必须确保落到显示器上。
final class BrightnessSlider: NSSlider {
    var onRelease: (() -> Void)?

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onRelease?()
    }
}

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = Self.menuBarIcon()
            b.toolTip = "\(AppInfo.name) — 显示器开关 / 亮度 / HiDPI / 分辨率"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        registerSystemObservers()

        // 亮度写入失败时，就在滑块那一行后面显示「无应答」，而不是让用户对着没反应的滑块干瞪眼
        DisplayManager.shared.onBrightnessWriteResult = { [weak self] id, ok in
            self?.showWriteResult(id, ok)
        }
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

        for (index, d) in list.enumerated() {
            // 显示器标题本身就是二级菜单的入口（HiDPI / 分辨率 / 关闭 / DDC）
            let header = NSMenuItem(title: Self.title(for: d), action: nil, keyEquivalent: "")
            header.image = NSImage(systemSymbolName: d.isBuiltin ? "laptopcomputer" : "display",
                                   accessibilityDescription: nil)
            header.submenu = settingsSubmenu(for: d)
            menu.addItem(header)

            // 亮度滑块直接放在一级菜单，省掉「展开一层才能调亮度」的麻烦
            menu.addItem(brightnessItem(for: d))

            // 通道不正常时把原因直接列在滑块下面 —— 用户才不会对着没反应的滑块反复拖
            if let warn = DisplayManager.shared.brightnessWarning(for: d) {
                addDisabled(menu, "   ⚠︎ \(warn)")
            }

            if index < list.count - 1 { menu.addItem(.separator()) }
        }

        // 被本 app 关闭的显示器 —— 系统已查不到它们，靠这里提供重新打开入口
        for (id, rec) in DisplayManager.shared.disabled.sorted(by: { $0.key < $1.key }) {
            let mi = NSMenuItem(title: "\(rec.name)   （已关闭，点击重新打开）",
                                action: #selector(enableDisplay(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = NSNumber(value: id)
            mi.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
            menu.addItem(mi)
        }

        if list.isEmpty && DisplayManager.shared.disabled.isEmpty {
            addDisabled(menu, "未检测到显示器")
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "重新扫描显示器", action: #selector(doRefresh), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(refreshItem)

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

    /// 显示器标题：名称 + 当前逻辑分辨率 + HiDPI 标记 + 内置/主屏
    private static func title(for d: DisplayItem) -> String {
        var tail = "\(d.logicalWidth)×\(d.logicalHeight)"
        if d.pixelWidth > d.logicalWidth { tail += " HiDPI" }
        var tags: [String] = []
        if d.isBuiltin { tags.append("内置") }
        if d.isMain { tags.append("主屏") }
        if !tags.isEmpty { tail += "  ·  " + tags.joined(separator: " / ") }
        return "\(d.name)  —  \(tail)"
    }

    /// 显示器的二级菜单：HiDPI 开关 / 分辨率 / 关闭 / DDC 诊断
    private func settingsSubmenu(for d: DisplayItem) -> NSMenu {
        let sub = NSMenu()

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
        sub.addItem(hi)

        // —— 分辨率 ——
        let resItem = NSMenuItem(title: "分辨率", action: nil, keyEquivalent: "")
        resItem.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
        resItem.submenu = resolutionSubmenu(for: d)
        sub.addItem(resItem)

        // —— 关闭 ——
        sub.addItem(.separator())
        let off = NSMenuItem(title: "关闭此显示器", action: #selector(disableDisplay(_:)), keyEquivalent: "")
        off.target = self
        off.representedObject = NSNumber(value: d.id)
        off.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        sub.addItem(off)

        // —— 外接屏的 DDC 诊断与重检 ——
        if !d.isBuiltin {
            sub.addItem(.separator())
            let reprobe = NSMenuItem(title: "重新检测 DDC", action: #selector(reprobeDDC(_:)), keyEquivalent: "")
            reprobe.target = self
            reprobe.representedObject = NSNumber(value: d.id)
            reprobe.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            sub.addItem(reprobe)

            if let warn = DisplayManager.shared.brightnessWarning(for: d) {
                addDisabled(sub, "   ⚠︎ \(warn)")
            }
        }

        return sub
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

    /// 一级菜单里那行亮度滑块；不可控时降级成一行说明
    private func brightnessItem(for d: DisplayItem) -> NSMenuItem {
        let item = NSMenuItem()
        // 自定义视图会把标题遮住，但留着它 VoiceOver 才念得出来
        item.title = "\(d.name) 亮度"
        if let value = DisplayManager.shared.brightness(of: d) {
            item.view = brightnessView(for: d, value: value)
        } else {
            let note = d.isBuiltin ? "该屏未提供亮度接口"
                                   : (DisplayManager.shared.ddcNote(for: d) ?? "未知原因")
            item.view = unavailableView("亮度不可控：\(note)")
        }
        return item
    }

    private func addDisabled(_ menu: NSMenu, _ title: String) {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        menu.addItem(mi)
    }

    private func brightnessView(for d: DisplayItem, value: Double) -> NSView {
        let w: CGFloat = 268, h: CGFloat = 30
        let box = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        // 左侧缩进，让滑块在视觉上归到上面那台显示器名下
        let icon = NSImageView(frame: NSRect(x: 20, y: 6, width: 17, height: 17))
        icon.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        box.addSubview(icon)

        let slider = BrightnessSlider(value: value * 100, minValue: 0, maxValue: 100,
                                      target: self, action: #selector(brightnessChanged(_:)))
        slider.frame = NSRect(x: 43, y: 4, width: 172, height: 22)
        slider.isContinuous = true
        slider.tag = Int(d.id)
        slider.onRelease = { [weak slider] in
            guard let slider = slider else { return }
            self.lastDragAt = nil
            self.flushBrightness(displayID: CGDirectDisplayID(slider.tag))
        }
        box.addSubview(slider)

        let label = NSTextField(labelWithString: "\(Int((value * 100).rounded()))%")
        label.frame = NSRect(x: 221, y: 7, width: 42, height: 17)
        label.tag = 999
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        box.addSubview(label)
        sliderLabels[d.id] = label

        return box
    }

    /// 亮度不可控时的占位行，缩进与滑块对齐
    private func unavailableView(_ text: String) -> NSView {
        let w: CGFloat = 268, h: CGFloat = 24
        let box = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 20, y: 3, width: w - 28, height: 17)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        box.addSubview(label)
        return box
    }

    // MARK: - 动作

    @objc private func brightnessChanged(_ sender: NSSlider) {
        let id = CGDirectDisplayID(sender.tag)
        guard let d = DisplayManager.shared.displays().first(where: { $0.id == id }) else { return }

        lastDragAt = Date()          // 拖动期间不重建菜单（时间戳会自己过期）
        let percent = sender.doubleValue
        if let label = sender.superview?.viewWithTag(999) as? NSTextField {
            label.stringValue = "\(Int(percent.rounded()))%"
            label.textColor = .secondaryLabelColor
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

    /// 构建一遍菜单并把层级打印出来。供 `--dump-menu` 使用：
    /// 菜单是懒加载的，不打开就不会构建，这个方法让「菜单能不能建起来」变成可测的。
    func debugMenuDump() -> String {
        let menu = NSMenu()
        build(menu)
        var lines: [String] = []
        for item in menu.items {
            if item.isSeparatorItem { lines.append("  ─────────────"); continue }
            var note = ""
            if item.view != nil { note += "  [自定义视图]" }
            if !item.isEnabled { note += "  [禁用]" }
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
}
