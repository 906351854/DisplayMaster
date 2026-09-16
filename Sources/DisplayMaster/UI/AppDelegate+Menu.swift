import AppKit
import CoreGraphics

extension AppDelegate {
    // MARK: - 菜单构建

    func build(_ menu: NSMenu) {
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
}
