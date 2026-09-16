import AppKit
import CoreGraphics

extension AppDelegate {
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
}
