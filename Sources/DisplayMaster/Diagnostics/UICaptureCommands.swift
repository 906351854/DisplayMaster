import AppKit

// 菜单结构自检：走一遍菜单构建路径并打印层级
// 用法: DisplayMaster --dump-menu [--page2 <displayID>]
func runDumpMenu() {
    _ = NSApplication.shared
    // 刻意不调 applicationDidFinishLaunching —— 那会创建状态栏图标，
    // 在没有运行循环的进程里会一直等下去。
    let delegate = AppDelegate()
    delegate.debugPresetSettingsID = debugPage2Arg()
    print("=== \(AppInfo.name) 菜单结构 ===")
    print(delegate.debugMenuDump())
    exit(0)
}

// 用法: DisplayMaster --hits
//   把菜单弹出来，再把每个可点行的屏幕坐标打出来（自测合成点击时用来精确命中）
func runHits() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    delegate.debugPresetSettingsID = debugPage2Arg()
    delegate.debugInstallStatusItem()
    app.delegate = delegate
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        // 菜单留着别关：打印完就退出的话菜单会跟着收掉，外面就没得点了
        delegate.debugPopUpAndReportHits()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(0) }
    }
    app.run()
    exit(0)          // 定时器里已 exit(0)，这一行只是让函数没有落空路径
}

// 菜单截图：把真实菜单弹出来截屏，用来核对自绘面板的外观。
//
// 需要它是因为菜单只存在于屏幕合成里，视图的离屏渲染（cacheDisplay）拿不到
// 活力材质和实时状态 —— 之前就是靠这个才发现「滑块蓝色丢失」只在特定状态下出现。
// 用法: DisplayMaster --shot-menu <out.png> [--page2 <displayID>] [--click-card <n>]
//   --click-card 会在截屏前先模拟点一下第 n 张卡，用来验证「点卡片 → 换详情页」这条链路
/// 把亮度浮层截下来，核对图标 / 进度条 / 百分比有没有对齐、有没有被裁掉。
///
/// 浮层是**看不见的那类 UI**：它只在按亮度键的一瞬间出现 0.9 秒，
/// 开发时想「多看一眼」根本没有机会。所以必须有个命令能把它定住并截图 ——
/// 否则排版错了只能靠用户反馈。
///
/// 用法: --shot-osd <out.png> [--percent 62] [--down] [--note 文案]
func runShotOSD() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--shot-osd"), i + 1 < args.count else {
        print("用法: DisplayMaster --shot-osd <out.png> [--percent 62] [--down] [--note 文案]")
        exit(2)
    }
    let out = args[i + 1]
    var pct: Int? = 62
    if let p = args.firstIndex(of: "--percent"), p + 1 < args.count, let v = Int(args[p + 1]) {
        pct = v
    }
    // --note 用来核对「读不到亮度」那条降级文案（那时不该画进度条）
    var note: String?
    if let n = args.firstIndex(of: "--note"), n + 1 < args.count {
        note = args[n + 1]
        pct = nil
    }
    let dir = args.contains("--down") ? -1 : 1

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        BrightnessOSD.shared.show(percent: pct, note: note, direction: dir, on: NSScreen.main)
        // 浮层 0.9 秒后自动淡出，这 0.35 秒是「已经画完、还没开始淡」的窗口
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let w = BrightnessOSD.shared.debugWindow,
                  let infos = CGWindowListCopyWindowInfo([.optionIncludingWindow],
                                                         CGWindowID(w.windowNumber)) as? [[String: Any]],
                  let bd = infos.first?["kCGWindowBounds"] as? [String: CGFloat],
                  let x = bd["X"], let y = bd["Y"], let ww = bd["Width"], let hh = bd["Height"] else {
                print("没找到浮层窗口"); exit(1)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o",
                           "-R\(Int(x - 6)),\(Int(y - 6)),\(Int(ww + 12)),\(Int(hh + 12))", out]
            try? p.run()
            p.waitUntilExit()
            print("已保存 \(out)   浮层 \(Int(ww))×\(Int(hh))"
                  + "   内容：\(note ?? "\(pct ?? 0)% \(dir > 0 ? "变亮" : "变暗")")")
            exit(0)
        }
    }
    app.run()
    exit(0)
}

func runShotMenu() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--shot-menu"), i + 1 < args.count else {
        print("用法: DisplayMaster --shot-menu <out.png> [--page2 <displayID>] [--click-card <n>]")
        exit(2)
    }
    let out = args[i + 1]
    var clickCard: Int?
    if let c = args.firstIndex(of: "--click-card"), c + 1 < args.count, let v = Int(args[c + 1]) {
        clickCard = v
    }
    let clickBack = args.contains("--click-back")
    let delegate = AppDelegate()
    delegate.debugPresetSettingsID = debugPage2Arg()
    if let f = args.firstIndex(of: "--fake-cards"), f + 1 < args.count, let v = Int(args[f + 1]) {
        delegate.debugFakeCardCount = v
    }
    // --fake-off 0,2 ：把第 0、2 张卡画成「已关闭」，用来核对关闭态样式
    if let f = args.firstIndex(of: "--fake-off"), f + 1 < args.count {
        delegate.debugForceOffIndices = args[f + 1].split(separator: ",").compactMap { Int($0) }
    }
    // --fake-bright 0|100 ：把亮度强制画成这个百分比，用来核对滑块到底能不能滑到两端
    if let f = args.firstIndex(of: "--fake-bright"), f + 1 < args.count, let v = Double(args[f + 1]) {
        delegate.debugFakeBrightness = v / 100
    }
    // --click-part on|hidpi|body ：配合 --click-card 指定点这张卡的哪个部位
    var clickPart: CardsRowView.Part = .detail
    if let c = args.firstIndex(of: "--click-part"), c + 1 < args.count {
        clickPart = parseCardPart(args[c + 1])
    }
    var hoverPart: CardsRowView.Part = .detail
    if let h = args.firstIndex(of: "--hover-part"), h + 1 < args.count {
        hoverPart = parseCardPart(args[h + 1])
    }
    var hoverCard: Int?
    if let hv = args.firstIndex(of: "--hover-card"), hv + 1 < args.count, let v = Int(args[hv + 1]) {
        hoverCard = v
    }
    delegate.debugInstallStatusItem()          // 只装外观，不启动巡检、不跑自动规则
    app.delegate = delegate

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        let needsClick = clickCard != nil || clickBack || hoverCard != nil
        // 定时器要同时挂到 eventTracking 上：菜单跟踪期间跑的是那个模式
        let capture = Timer(timeInterval: needsClick ? 2.6 : 1.5, repeats: false) { _ in
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.height > 80 }),
                  let infos = CGWindowListCopyWindowInfo([.optionIncludingWindow],
                                                         CGWindowID(w.windowNumber)) as? [[String: Any]],
                  let bd = infos.first?["kCGWindowBounds"] as? [String: CGFloat],
                  let x = bd["X"], let y = bd["Y"], let ww = bd["Width"], let hh = bd["Height"] else {
                print("没找到菜单窗口"); exit(1)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o",
                           "-R\(Int(x - 8)),\(Int(y - 8)),\(Int(ww + 16)),\(Int(hh + 16))", out]
            try? p.run()
            p.waitUntilExit()
            print("已保存 \(out)   菜单 \(Int(ww))×\(Int(hh))")
            print("当前页面：\(delegate.debugIsDetailPage ? "详情页" : "主面板")")
            exit(0)
        }
        RunLoop.main.add(capture, forMode: .eventTracking)
        RunLoop.main.add(capture, forMode: .default)

        if let index = clickCard {
            let click = Timer(timeInterval: 1.4, repeats: false) { _ in
                print("模拟点击：\(delegate.debugClickCard(index, part: clickPart))")
            }
            RunLoop.main.add(click, forMode: .eventTracking)
            RunLoop.main.add(click, forMode: .default)
        }
        if let index = hoverCard {
            let hover = Timer(timeInterval: 1.4, repeats: false) { _ in
                print("悬停：\(delegate.debugHoverCard(index, part: hoverPart))")
            }
            RunLoop.main.add(hover, forMode: .eventTracking)
            RunLoop.main.add(hover, forMode: .default)
        }
        if clickBack {
            let click = Timer(timeInterval: 1.4, repeats: false) { _ in
                print("模拟点击返回：\(delegate.debugClickBack())")
            }
            RunLoop.main.add(click, forMode: .eventTracking)
            RunLoop.main.add(click, forMode: .default)
        }
        delegate.debugPopUpMenu()
    }
    app.run()
    exit(0)
}

