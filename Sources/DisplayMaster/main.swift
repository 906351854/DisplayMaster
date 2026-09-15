import AppKit

func ddcStateLine() -> String {
    var parts: [String] = []
    parts.append("服务数 \(DDC.shared.externalCount)")
    parts.append("连续失败 \(DDC.shared.consecutiveFailures)")
    if DDC.shared.isCoolingDown { parts.append("冷却中(剩 \(DDC.shared.cooldownRemaining)s)") }
    parts.append("诊断「\(DDC.shared.lastDiagnosis)」")
    if DDC.shared.recoveryCount > 0 {
        parts.append("自愈 \(DDC.shared.recoveryCount) 次（最近：\(DDC.shared.lastRecoveryReason)）")
    }
    if !DDC.shared.lastRawReply.isEmpty { parts.append("末次应答 [\(DDC.shared.lastRawReply)]") }
    return parts.joined(separator: "  ")
}

/// 已关闭显示器记录的摘要，用于自检/回归测试打印
func disabledLine() -> String {
    let dm = DisplayManager.shared
    guard !dm.disabled.isEmpty else { return "（空）" }
    return dm.disabled.sorted { $0.key < $1.key }
        .map { "\($0.value.name)(id=\($0.key) \($0.value.isBuiltin ? "内置" : "外接")"
             + " edid=\($0.value.vendor)/\($0.value.model)/\($0.value.serial))" }
        .joined(separator: ", ")
}

/// 打印自动规则最近的运行记录。
///
/// 这个功能出问题时用户看到的是一块黑屏，而黑屏状态下没法打开菜单排查 ——
/// 所以诊断入口（以及给用户贴出来用的 `--auto-log`）必须能把记录翻出来。
func printRecentRuleLog(_ lines: Int = 30) {
    let dm = DisplayManager.shared
    let tail = dm.recentRuleLog(lines: lines)
    print("")
    print("--- 自动规则日志（最近 \(lines) 条）---")
    print("文件: \(dm.ruleLogPath)")
    if tail.isEmpty {
        print("（还没有记录）")
    } else {
        tail.forEach { print($0) }
    }
    print("---")
}

/// 跑一个外部命令（同步等待），供唤醒测试用
@discardableResult
func runTool(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// 命令行入口对应的可执行文件路径，用于打印用法提示
let exeHint = "\(AppInfo.name).app/Contents/MacOS/DisplayMaster"

// 自检模式：不开 GUI，直接验证枚举 / 分辨率 / HiDPI / 亮度四条路径
// 用法: Display Master.app/Contents/MacOS/DisplayMaster --selftest
if CommandLine.arguments.contains("--selftest") {
    _ = NSApplication.shared          // 建立与 window server 的连接，保证 NSScreen 可用
    let dm = DisplayManager.shared
    print("=== \(AppInfo.name) \(AppInfo.bundleVersion) 自检 ===")
    print("私有 API 可用:")
    print("  CGSConfigureDisplayEnabled : \(PrivateAPI.shared.configureDisplayEnabled != nil ? "✓" : "✗")")
    print("  DisplayServicesGetBrightness : \(PrivateAPI.shared.getBrightness != nil ? "✓" : "✗")")
    print("  DisplayServicesSetBrightness : \(PrivateAPI.shared.setBrightness != nil ? "✓" : "✗")")
    print("  DDC(IOAVService)              : \(DDC.shared.isAvailable ? "✓" : "✗")")
    print("  DDC 状态                      : \(ddcStateLine())")
    print("  DDC 原始诊断 (VCP 0x10): \(DDC.shared.diagnoseRaw(0, 0x10))")
    print("  DDC 扫描日志:")
    for line in DDC.shared.scanLog { print("    · \(line)") }
    print("")
    let list = dm.displays()
    print("检测到 \(list.count) 台显示器")
    for d in list {
        print("── \(d.name)")
        print("   id=\(d.id)  内置=\(d.isBuiltin)  主屏=\(d.isMain)")
        print("   逻辑分辨率 \(d.logicalWidth)×\(d.logicalHeight)   物理像素 \(d.pixelWidth)×\(d.pixelHeight)")
        print("   分辨率菜单 常显 \(dm.uniqueModes(d).count) 项 / 完整 \(dm.uniqueModes(d, includeAll: true).count) 项")
        if let toggle = dm.hidpiToggle(d) {
            let t = toggle.target
            print("   HiDPI：当前\(dm.isHiDPI(d) ? "已开启" : "已关闭")"
                  + " → 目标 \(t.width)×\(t.height) 物理 \(t.pixelWidth)×\(t.pixelHeight)"
                  + (toggle.sameResolution ? "（同分辨率换倍率）" : "（无同分辨率变体，取最接近档位）"))
        } else {
            print("   HiDPI：当前\(dm.isHiDPI(d) ? "已开启" : "已关闭")，该屏没有相反的渲染倍率，不可切换")
        }
        if let b = dm.brightness(of: d) {
            print("   当前亮度 \(Int((b * 100).rounded()))%  (可读写)")
            if let warn = dm.brightnessWarning(for: d) { print("   ⚠️ \(warn)") }
        } else {
            let note = dm.ddcNote(for: d)
            print("   亮度：不可控" + (note.map { "  —— \($0)" } ?? ""))
        }
    }
    print("")
    print("被本应用关闭、等待重新打开的显示器: \(disabledLine())")
    exit(0)
}

// 分辨率滑块上有哪些档位。
//
// 为什么值得单独一条命令：滑块上那份档位和详情页里那份完整列表**不是同一份**。
// 滑块只收「跟面板原生比例一致」的那十来档，不然满屏小点、每格 4pt，根本拖不准。
// 出问题时第一件要确认的就是「这块屏到底有几档、当前是第几档」。
// 用法: DisplayMaster --modes
if CommandLine.arguments.contains("--modes") {
    _ = NSApplication.shared
    let dm = DisplayManager.shared
    let delegate = AppDelegate()
    print("=== \(AppInfo.name) 分辨率滑块档位 ===")
    for d in dm.displays() {
        let steps = delegate.resolutionSteps(d)
        print("── \(d.name) (id=\(d.id))  \(d.isBuiltin ? "内置" : "外接")"
              + "  当前 \(d.logicalWidth)×\(d.logicalHeight)"
              + "  \(dm.isHiDPI(d) ? "HiDPI" : "非 HiDPI")  共 \(steps.count) 档")
        for (i, m) in steps.enumerated() {
            let hidpi = m.pixelWidth > m.width
            let cur = (m.width == d.logicalWidth && m.height == d.logicalHeight
                       && hidpi == dm.isHiDPI(d)) ? "  ← 当前" : ""
            print("   [\(i)] \(m.width)×\(m.height)\(hidpi ? " HiDPI" : "")"
                  + "  物理 \(m.pixelWidth)×\(m.pixelHeight)  \(Int(m.refreshRate))Hz\(cur)")
        }
    }
    exit(0)
}

// HiDPI 切换测试：默认只报告，加 --apply 才真的切（切换时屏幕会黑一下再回来）
// 用法: DisplayMaster --hidpi-test [--apply] [--all]
if CommandLine.arguments.contains("--hidpi-test") {
    _ = NSApplication.shared
    let apply = CommandLine.arguments.contains("--apply")
    let all = CommandLine.arguments.contains("--all")
    let dm = DisplayManager.shared

    print("=== \(AppInfo.name) HiDPI 切换测试 \(apply ? "(实际切换)" : "(仅报告，加 --apply 才会真的切)") ===")
    var tested = 0
    for d in dm.displays() {
        if !all && !d.isBuiltin { continue }        // 默认只测内置屏，避免外接主屏闪黑
        tested += 1
        print("── \(d.name) (id=\(d.id))")
        print("   当前 \(d.logicalWidth)×\(d.logicalHeight)  物理 \(d.pixelWidth)×\(d.pixelHeight)"
              + "  \(dm.isHiDPI(d) ? "HiDPI" : "非 HiDPI")")
        guard let toggle = dm.hidpiToggle(d) else {
            print("   该屏没有相反的渲染倍率，跳过")
            continue
        }
        let t = toggle.target
        print("   目标 \(t.width)×\(t.height)  物理 \(t.pixelWidth)×\(t.pixelHeight)"
              + (toggle.sameResolution ? "  （同分辨率换倍率）" : "  （无同分辨率变体，取最接近档位）"))
        guard apply else { continue }

        let originalLogical = d.logicalWidth, originalPixel = d.pixelWidth
        guard dm.setMode(d.id, t) else { print("   ✗ 切换失败"); continue }
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let now = dm.displays().first(where: { $0.id == d.id })
        let ok = now.map { $0.logicalWidth == t.width && $0.pixelWidth == t.pixelWidth } ?? false
        let nowText = now.map { "\($0.logicalWidth)×\($0.logicalHeight) 物理 \($0.pixelWidth)×\($0.pixelHeight)" } ?? "读不到"
        print("   切换后 \(nowText)" + (ok ? "   ✓ 生效" : "   ✗ 未生效"))

        // 恢复原模式
        if let back = dm.uniqueModes(d, includeAll: true).first(where: {
            $0.width == originalLogical && $0.pixelWidth == originalPixel
        }) {
            _ = dm.setMode(d.id, back)
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            let restored = dm.displays().first(where: { $0.id == d.id })
            print("   已恢复 \(restored.map { "\($0.logicalWidth)×\($0.logicalHeight) 物理 \($0.pixelWidth)×\($0.pixelHeight)" } ?? "读不到")")
        } else {
            print("   ⚠️ 找不到原模式，请手动恢复")
        }
    }
    if tested == 0 { print("没有匹配的显示器（试加 --all）") }
    exit(0)
}

// DDC 端到端测试：读 → 写一个明显不同的值 → 复读验证 → 恢复原值
// 用法: DisplayMaster --ddc-test [--force] [--drain]
if CommandLine.arguments.contains("--ddc-test") {
    _ = NSApplication.shared
    let force = CommandLine.arguments.contains("--force")
    let drain = CommandLine.arguments.contains("--drain")
    DDC.shared.drainReplyAfterWrite = drain
    if force { DDC.shared.forceReprobe() }

    print("=== \(AppInfo.name) DDC 端到端测试 ===")
    print("写后取应答: \(drain ? "开" : "关")   \(ddcStateLine())")
    print("原始诊断: \(DDC.shared.diagnoseRaw(0, 0x10))")
    print("")

    guard let ext = DisplayManager.shared.displays().first(where: { !$0.isBuiltin }) else {
        print("✗ 没有外接显示器，测试结束")
        exit(1)
    }
    print("目标显示器: \(ext.name) (id=\(ext.id))")

    guard let before = DDC.shared.readVCP(0, 0x10, force: true) else {
        print("✗ 第一步失败：读不到 VCP 0x10 —— 显示器当前不应答，无法继续")
        print("  诊断: \(DDC.shared.lastDiagnosis)")
        print("  末次应答: [\(DDC.shared.lastRawReply)]")
        exit(2)
    }
    let cur = Double(before.cur) / Double(before.max)
    print("1) 当前亮度 \(before.cur)/\(before.max) = \(Int((cur * 100).rounded()))%")

    let target = cur > 0.5 ? cur - 0.2 : cur + 0.2
    print("2) 写入目标 \(Int((target * 100).rounded()))% ...")
    let (wrote, back) = DDC.shared.writeAndVerify(0, target)
    let backText = back.map { "\(Int(($0 * 100).rounded()))%" } ?? "读不到"
    print("   写入\(wrote ? "被接受" : "失败")   复读=\(backText)")
    if let b = back, abs(b - target) < 0.06 {
        print("   判定: ✓ 亮度真的变了（写入生效）")
    } else if wrote {
        print("   判定: ✗ 写入被接受但亮度没变（显示器忽略了写命令）")
    } else {
        print("   判定: ✗ 写命令根本没发出去")
    }

    print("3) 恢复原值 \(Int((cur * 100).rounded()))% ...")
    let (restored, back2) = DDC.shared.writeAndVerify(0, cur)
    let back2Text = back2.map { "\(Int(($0 * 100).rounded()))%" } ?? "读不到"
    print("   恢复\(restored ? "被接受" : "失败")   复读=\(back2Text)")
    print("")
    print("最终状态: \(ddcStateLine())")
    exit(0)
}

// DDC 拖动压力测试：模拟滑块拖动的高频调用，验证节流能扛住、不会把显示器写死
// 用法: DisplayMaster --ddc-storm
if CommandLine.arguments.contains("--ddc-storm") {
    _ = NSApplication.shared
    DDC.shared.forceReprobe()
    print("=== \(AppInfo.name) DDC 拖动压力测试 ===")
    guard let ext = DisplayManager.shared.displays().first(where: { !$0.isBuiltin }) else {
        print("✗ 没有外接显示器，测试结束"); exit(1)
    }
    guard let before = DDC.shared.readVCP(0, 0x10, force: true) else {
        print("✗ 起始读取失败（\(DDC.shared.lastDiagnosis)），测试终止"); exit(2)
    }
    let orig = Double(before.cur) / Double(before.max)
    print("起始亮度 \(Int((orig * 100).rounded()))%")

    print("模拟拖动：100 次连续调用，间隔 15ms（比人手拖动还密）")
    let t0 = Date()
    for i in 0..<100 {
        let phase = Double(i % 20) / 20.0
        let v = 0.55 + 0.25 * sin(phase * Double.pi)     // 55% ~ 80% 来回晃
        DisplayManager.shared.setBrightnessThrottled(ext, v)
        usleep(15_000)
    }
    print("  调用完成，耗时 \(String(format: "%.2f", Date().timeIntervalSince(t0)))s（实际 I²C 写入被节流到约 1/100ms）")
    DisplayManager.shared.flushBrightness(ext)
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))

    print("压力后连读 3 次，验证通道没被写死：")
    var alive = 0
    for i in 1...3 {
        if let r = DDC.shared.readVCP(0, 0x10, force: true) {
            alive += 1
            print("  第\(i)次 ✓ \(r.cur)/\(r.max) = \(Int((Double(r.cur) / Double(r.max) * 100).rounded()))%")
        } else {
            print("  第\(i)次 ✗ 无应答（\(DDC.shared.lastDiagnosis)）")
        }
        usleep(150_000)
    }

    print("恢复原值 \(Int((orig * 100).rounded()))% ... \(DDC.shared.setBrightness(0, orig) ? "已写入" : "写入失败")")
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    if let r = DDC.shared.readVCP(0, 0x10, force: true) {
        print("复读 \(r.cur)/\(r.max)  诊断「\(DDC.shared.lastDiagnosis)」")
    }
    print(alive == 3 ? "判定: ✓ 通道扛住了高频写入" : "判定: ✗ 通道在压力下失联")
    exit(0)
}

// 菜单结构自检：走一遍菜单构建路径并打印层级
// 用法: DisplayMaster --dump-menu [--page2 <displayID>]
if CommandLine.arguments.contains("--dump-menu") {
    _ = NSApplication.shared
    // 刻意不调 applicationDidFinishLaunching —— 那会创建状态栏图标，
    // 在没有运行循环的进程里会一直等下去。
    let delegate = AppDelegate()
    delegate.debugPresetSettingsID = debugPage2Arg()
    print("=== \(AppInfo.name) 菜单结构 ===")
    print(delegate.debugMenuDump())
    exit(0)
}

// 菜单截图：把真实菜单弹出来截屏，用来核对自绘面板的外观。
//
// 需要它是因为菜单只存在于屏幕合成里，视图的离屏渲染（cacheDisplay）拿不到
// 活力材质和实时状态 —— 之前就是靠这个才发现「滑块蓝色丢失」只在特定状态下出现。
// 用法: DisplayMaster --shot-menu <out.png> [--page2 <displayID>] [--click-card <n>]
//   --click-card 会在截屏前先模拟点一下第 n 张卡，用来验证「点卡片 → 换详情页」这条链路
// 用法: DisplayMaster --hits
//   把菜单弹出来，再把每个可点行的屏幕坐标打出来（自测合成点击时用来精确命中）
if CommandLine.arguments.contains("--hits") {
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
}

if CommandLine.arguments.contains("--shot-menu") {
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

// 直接把某台显示器的 HiDPI 开关拨一次，并把推导出的目标模式打出来。
//
// 为什么单独留一条命令：HiDPI 切换要看「当前逻辑尺寸 / 备选档位 / 目标模式」三样东西，
// 而菜单里只有一枚开关，出问题时光看开关根本不知道它想切到哪去。
// 用法: DisplayMaster --hidpi-toggle <displayID>
if CommandLine.arguments.contains("--hidpi-toggle") {
    _ = NSApplication.shared
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--hidpi-toggle"), i + 1 < args.count, let v = UInt32(args[i + 1]) else {
        print("用法: DisplayMaster --hidpi-toggle <displayID>")
        exit(2)
    }
    let dm = DisplayManager.shared
    guard let d = dm.displays().first(where: { $0.id == CGDirectDisplayID(v) }) else {
        print("✗ 找不到在线显示器 \(v)"); exit(1)
    }
    print("显示器 「\(d.name)」 当前 \(d.logicalWidth)x\(d.logicalHeight) px \(d.pixelWidth)x\(d.pixelHeight)  HiDPI=\(dm.isHiDPI(d))")
    guard let toggle = dm.hidpiToggle(d) else {
        print("✗ 推不出目标模式（该屏没有相反的渲染倍率）"); exit(1)
    }
    print("目标 \(toggle.target.width)x\(toggle.target.height) px \(toggle.target.pixelWidth)x\(toggle.target.pixelHeight)"
          + "  同分辨率换倍率=\(toggle.sameResolution)")
    print(dm.toggleHiDPI(d) ? "✓ 已切换" : "✗ 切换失败")
    let after = CGDisplayCopyDisplayMode(d.id)
    print("切换后 \(after?.width ?? 0)x\(after?.height ?? 0) px \(after?.pixelWidth ?? 0)x\(after?.pixelHeight ?? 0)")
    exit(0)
}

/// 卡片里那个部位：body（卡片主体，进详情页）/ on（开启开关）/ hidpi（HiDPI 开关）
func parseCardPart(_ s: String) -> CardsRowView.Part {
    switch s {
    case "on": return .toggleOn
    case "hidpi": return .toggleHiDPI
    default: return .detail
    }
}

// 走一遍「在卡片上拖分辨率滑块并松手」这条链路，然后报告各屏现在的模式。
//
// 为什么值得留一条命令：滑块上只有「第几档」，档位表在 app 这边，
// 两边差一档就会切到隔壁的分辨率 —— 而且照样「能切成功」，肉眼很难发现。
// 用法: DisplayMaster --drag-res <卡片下标> <档位下标>
if CommandLine.arguments.contains("--drag-res") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--drag-res"), i + 2 < args.count,
          let card = Int(args[i + 1]), let step = Int(args[i + 2]) else {
        print("用法: DisplayMaster --drag-res <卡片下标> <档位下标>")
        exit(2)
    }
    let delegate = AppDelegate()
    delegate.debugInstallStatusItem()
    app.delegate = delegate
    DispatchQueue.main.async {
        print(delegate.debugDragResolution(card: card, step: step))
        fflush(stdout)
        // 切模式要等系统改完配置（第 0.25 秒才动手），留够时间再看结果。
        // 定时器必须同时挂到 .eventTracking：切完模式菜单会被弹回来，
        // 那时跑的是菜单的跟踪循环，只挂 .default 的话这个定时器永远不会触发
        // —— 表现就是命令挂住不退出（第一次写就是这么挂的）。
        let done = Timer(timeInterval: 3.5, repeats: false) { _ in
            print("--- 各屏当前模式 ---")
            for d in DisplayManager.shared.displays() {
                print("   \(d.name): \(d.logicalWidth)×\(d.logicalHeight)"
                      + "  物理 \(d.pixelWidth)×\(d.pixelHeight)"
                      + "  \(DisplayManager.shared.isHiDPI(d) ? "HiDPI" : "非 HiDPI")")
            }
            exit(0)
        }
        RunLoop.main.add(done, forMode: .eventTracking)
        RunLoop.main.add(done, forMode: .default)
    }
    app.run()
    exit(0)
}

/// 解析 `--page2 <displayID>`（菜单截图/结构打印用）
func debugPage2Arg() -> CGDirectDisplayID? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--page2"), i + 1 < args.count, let v = UInt32(args[i + 1]) else {
        return nil
    }
    return CGDirectDisplayID(v)
}

// 直接用 displayID 开关一台显示器。
//
// 为什么需要它：菜单里那个开关是「点一下」的交互，写自动化脚本使不上；而一旦
// 把某台屏关掉、记录又因为别的原因丢了，就只剩这条路能把它开回来。
// 这台机器上没有第二个屏幕可看时，这是唯一的救生索。
// 用法: DisplayMaster --display-on <id>  |  --display-off <id>
if CommandLine.arguments.contains("--display-on") || CommandLine.arguments.contains("--display-off") {
    _ = NSApplication.shared
    let args = CommandLine.arguments
    let turnOn = args.contains("--display-on")
    let flag = turnOn ? "--display-on" : "--display-off"
    guard let i = args.firstIndex(of: flag), i + 1 < args.count, let v = UInt32(args[i + 1]) else {
        print("用法: DisplayMaster \(flag) <displayID>")
        exit(2)
    }
    let id = CGDirectDisplayID(v)
    let dm = DisplayManager.shared
    let name = dm.displays().first(where: { $0.id == id })?.name
        ?? dm.disabled[id]?.name ?? "显示器"
    print("\(turnOn ? "打开" : "关闭") id=\(id) 「\(name)」 ...")
    // force：诊断场景必须真的能执行（包括关掉当前唯一在线的那台，那正是要复现的情形）
    let ok = dm.setEnabled(id, turnOn, name: name, force: !turnOn)
    print(ok ? "✓ 已\(turnOn ? "打开" : "关闭")" : "✗ 没生效")
    print("在线: " + dm.displays().map { "\($0.id)" }.joined(separator: ","))
    print("已关闭记录: " + dm.disabled.keys.sorted().map { "\($0)" }.joined(separator: ","))
    exit(ok ? 0 : 1)
}

// 开关显示器回归测试：验证 1.0.1 修掉的那个 bug
// —— 打开一台已关闭的显示器之后，「已关闭」记录必须被清掉，
//    否则菜单里会一直多出一张灰着的卡。
// 用法: DisplayMaster --toggle-test [--external]   （默认拿内置屏做靶子，外接屏不动）
if CommandLine.arguments.contains("--toggle-test") {
    _ = NSApplication.shared
    let dm = DisplayManager.shared
    print("=== \(AppInfo.name) 开关显示器回归测试 ===")
    let list = dm.displays()
    guard list.count >= 2 else {
        print("✗ 当前只有 \(list.count) 台显示器，跳过（绝不允许拿最后一台做实验）")
        exit(1)
    }
    let useExternal = CommandLine.arguments.contains("--external")
    guard let d = (useExternal ? list.first(where: { !$0.isBuiltin }) : list.first(where: { $0.isBuiltin })) else {
        print("✗ 找不到目标显示器（试加 --external）")
        exit(1)
    }
    print("目标: \(d.name)  id=\(d.id)  内置=\(d.isBuiltin)")
    print("0) 关闭前 · 在线 \(list.count) 台 · 已关闭记录 \(disabledLine())")

    print("1) 关闭 ...")
    guard dm.setEnabled(d.id, false, name: d.name) else {
        print("   ✗ 关闭未生效（保持原状，没动它）")
        exit(2)
    }
    print("   ✓ 已关闭 · 在线 \(dm.displays().count) 台 · 已关闭记录 \(disabledLine())")

    print("2) 打开 ...")
    let ok = dm.setEnabled(d.id, true)
    // 多给几秒：NSScreen 的列表更新比 CoreGraphics 慢，需要把运行循环转起来
    for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
    print("   setEnabled 返回 \(ok ? "true" : "false")")

    var onlineCount: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &onlineCount)
    var onlineIDs = [CGDirectDisplayID](repeating: 0, count: Int(max(onlineCount, 1)))
    CGGetOnlineDisplayList(onlineCount, &onlineIDs, &onlineCount)
    let online = Array(onlineIDs.prefix(Int(onlineCount)))
    let after = dm.displays()
    let backOnline = online.contains(d.id)
    let backVisible = after.contains { $0.id == d.id }

    print("3) 复核:")
    print("   CoreGraphics 在线列表 : \(online)" + (backOnline ? "   ✓ 含 \(d.id)" : "   ✗ 不含 \(d.id)"))
    print("   NSScreen 可见列表     : " + after.map { "\($0.name)(\($0.id))" }.joined(separator: ", ")
          + (backVisible ? "   ✓" : "   （NSScreen 更新较慢，稍后自会补上）"))
    print("4) 菜单里还会多一张灰卡片吗 : "
          + (dm.disabled.isEmpty ? "✓ 不会（记录已清空）" : "✗ 会 —— 残留 \(disabledLine())"))
    let pass = backOnline && dm.disabled.isEmpty
    print(pass ? "判定: ✓ 通过" : "判定: ✗ 失败")
    exit(pass ? 0 : 3)
}

// 显示器睡眠 → 唤醒 回归测试：验证 DDC 通道能自动重建
// 自动关闭内置屏的规则诊断：默认只报告会做什么，加 --apply 才真的执行一次
// 用法: DisplayMaster --auto-test [--apply] [--on|--off]
if CommandLine.arguments.contains("--auto-test") {
    _ = NSApplication.shared
    let dm = DisplayManager.shared
    let apply = CommandLine.arguments.contains("--apply")

    print("=== \(AppInfo.name) 自动关闭内置屏 · 规则诊断 ===")

    if CommandLine.arguments.contains("--on") { dm.autoDisableBuiltinWhenExternal = true }
    if CommandLine.arguments.contains("--off") { dm.autoDisableBuiltinWhenExternal = false }
    DisplayManager.debugHideExternals = CommandLine.arguments.contains("--fake-no-external")

    print("开关         : \(dm.autoDisableBuiltinWhenExternal ? "已打开" : "未打开")")
    if DisplayManager.debugHideExternals {
        print("              ⚠︎ --fake-no-external 生效：外接屏一律当成占位屏，"
              + "模拟「拔线后只剩随航残影」")
    }
    let list = dm.displays()
    print("在线显示器   : \(list.count) 台")
    for d in list {
        print("   · \(d.isBuiltin ? "内置" : "外接")  \(d.name)  id=\(d.id)")
    }
    print("已关闭记录   : \(disabledLine())")
    print("记住的内屏   : " + (dm.knownBuiltinID.map { "id=\($0)" } ?? "（还没见过）"))
    let virtuals = dm.detectedVirtualDisplayIDs()
    print("虚拟屏排除   : " + (virtuals.isEmpty ? "无"
                                        : virtuals.map { "id=\($0)" }.joined(separator: ", ")))
    let phantoms = dm.detectedPhantomDisplays()
    print("占位屏排除   : " + (phantoms.isEmpty ? "无"
                                        : phantoms.map { "id=\($0.id)「\($0.name)」" }
                                            .joined(separator: ", ")))
    print("屏幕睡眠     : " + (dm.debugDisplaysAsleep() ? "是" : "否")
          + "    合盖: " + (dm.isLidClosed() ? "是" : "否"))
    print("--- 在线显示器原始属性 ---")
    for id in dm.debugOnlineIDs() {
        let v = CGDisplayVendorNumber(id)
        let m = CGDisplayModelNumber(id)
        print("   id=\(id) vendor=\(v) \(DisplayManager.fourCCString(v))"
              + "  model=\(m) \(DisplayManager.fourCCString(m))"
              + "  判为虚拟屏=\(DisplayManager.isVirtualDisplay(id, nsName: nil, hasNSScreen: true))")
    }

    let plan = dm.autoBuiltinPlan()
    let idText = plan.displayID.map { "\($0)" } ?? "-"
    switch plan.kind {
    case .idle:           print("规则判定     : 不动")
    case .disableBuiltin: print("规则判定     : 关闭 \(plan.displayName) (id=\(idText))")
    case .enableBuiltin:  print("规则判定     : 打开 \(plan.displayName) (id=\(idText))")
    }
    print("理由         : \(plan.reason)")
    if plan.kind == .enableBuiltin {
        print("救援候选     : " + (plan.candidateIDs.isEmpty ? "（空，救不回来）"
              : plan.candidateIDs.map { "id=\($0)" }.joined(separator: " → ")))
    }
    print("日志文件     : \(dm.ruleLogPath)")

    guard apply else {
        printRecentRuleLog(15)
        print("")
        print("（仅报告。要真的执行一次，加 --apply）")
        exit(0)
    }

    print("")
    print("执行 ...")
    let changed = dm.applyAutoBuiltinRule(force: true, source: "命令行 --apply")
    print("执行结果     : " + (changed ? "✓ 改动了显示配置" : "没有需要改动的地方"))
    for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
    print("执行后在线   : " + dm.displays().map { "\($0.name)(\($0.isBuiltin ? "内置" : "外接"))" }
                              .joined(separator: ", "))
    print("执行后记录   : \(disabledLine())")
    printRecentRuleLog(10)

    // 测试用：把刚关掉的内屏开回来，免得留下一块关着的屏幕没人管。
    // 用裸二进制跑的时候 defaults 与 .app 不共享，菜单里不会出现恢复入口，
    // 所以这一步是必需的。
    if CommandLine.arguments.contains("--restore"), let (id, rec) = dm.disabled.first(where: { $0.value.isBuiltin }) {
        print("")
        print("恢复：打开 \(rec.name) ...")
        print("           : " + (dm.setEnabled(id, true) ? "✓ 已恢复" : "✗ 恢复失败"))
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
        print("恢复后在线   : " + dm.displays().map { "\($0.name)" }.joined(separator: ", "))
        print("恢复后记录   : \(disabledLine())")
    }
    exit(0)
}

// 只打印自动规则的运行记录，不查询、不改动任何状态。
// 排查「拔了外接屏内屏没亮」时，这个的输出基本就能定论。
// 用法: DisplayMaster --auto-log [条数，默认 80]
if CommandLine.arguments.contains("--auto-log") {
    _ = NSApplication.shared
    let args = CommandLine.arguments
    var n = 80
    if let i = args.firstIndex(of: "--auto-log"), i + 1 < args.count, let v = Int(args[i + 1]) { n = v }
    printRecentRuleLog(n)
    exit(0)
}

// 直接开关指定的 displayID。
//
// 存在的理由：这个功能最关键的场景是「拔掉外接屏」，而真机上没法为了测试反复拔线。
// 用它把当前唯一在线的屏强制关掉，就能复现「外接屏消失」那一瞬间，观察规则的反应。
// --force 会绕过「不许关掉最后一台」的保护，所以只在确认能把屏幕开回来时用。
// 用法: DisplayMaster --set-display <displayID> on|off [--force]
if CommandLine.arguments.contains("--set-display") {
    _ = NSApplication.shared
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--set-display"), i + 2 < args.count,
          let raw = UInt32(args[i + 1]) else {
        print("用法: DisplayMaster --set-display <displayID> on|off [--force]")
        exit(2)
    }
    let id = CGDirectDisplayID(raw)
    let on = args[i + 2].lowercased() == "on"
    let force = args.contains("--force")
    let dm = DisplayManager.shared
    let name = dm.displays().first { $0.id == id }?.name ?? "显示器 \(id)"
    let ok = dm.setEnabled(id, on, name: name, force: force)
    print("\(on ? "打开" : "关闭") \(name)(id=\(id)) → \(ok ? "成功" : "失败")")
    for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
    print("当前在线: " + dm.displays().map { "\($0.name)\($0.isBuiltin ? "(内置)" : "")" }
                               .joined(separator: ", "))
    exit(ok ? 0 : 1)
}

// 自动规则的判定自测：用构造出来的场景把所有分支走一遍，完全不接触真实显示器
// 用法: DisplayMaster --auto-scenarios
if CommandLine.arguments.contains("--auto-scenarios") {
    typealias Input = DisplayManager.AutoBuiltinInput
    typealias Kind = DisplayManager.AutoBuiltinPlan.Kind

    // 「拔掉外接屏要把内屏开回来」这条最要紧：写错的代价是用户面对一块黑屏。
    // 真机上没法随便插拔线，所以用构造场景把它钉住。
    let cases: [(name: String, input: Input, expect: Kind, expectID: CGDirectDisplayID?)] = [
        ("开关关闭 · 有外接屏 · 内屏在线",
         Input(switchOn: false, asleep: false, externalCount: 1,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         .idle, nil),

        ("屏幕睡眠 · 有外接屏 · 内屏在线",
         Input(switchOn: true, asleep: true, externalCount: 1,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         .idle, nil),

        ("接上 1 台外接屏 · 内屏在线",
         Input(switchOn: true, asleep: false, externalCount: 1,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         .disableBuiltin, 1),

        ("接上 2 台外接屏 · 内屏在线",
         Input(switchOn: true, asleep: false, externalCount: 2,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         .disableBuiltin, 1),

        ("有外接屏 · 内屏已经关了（不该重复操作）",
         Input(switchOn: true, asleep: false, externalCount: 1,
               builtinDisabledID: 1, builtinDisabledName: "内置屏"),
         .idle, nil),

        ("拔掉外接屏 · 内屏被本应用关着（必须开回来）",
         Input(switchOn: true, asleep: false, externalCount: 0,
               builtinDisabledID: 1, builtinDisabledName: "内置屏"),
         .enableBuiltin, 1),

        ("拔掉外接屏 · 内屏一直开着",
         Input(switchOn: true, asleep: false, externalCount: 0,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         .idle, nil),

        // 这条是 1.1.1 补的：关闭记录本身有可能丢了（用户手动开过一次内屏、
        // 系统重建过配置）。记录一没，旧逻辑就以为自己没关过、什么都不做，
        // 而用户面对的是一块黑屏 —— 所以必须能靠记住的内屏 id 兜住。
        ("拔掉外接屏 · 内屏不在线 · 关闭记录丢了（靠记住的内屏 id 兜底）",
         Input(switchOn: true, asleep: false, externalCount: 0, knownBuiltinIDs: [7]),
         .enableBuiltin, 7),

        // 屏幕睡眠时不开内屏，用户就真的什么都看不到。黑屏优先于「不打扰」。
        ("拔掉外接屏 · 内屏不在线 · 屏幕正在睡眠（照样救）",
         Input(switchOn: true, asleep: true, externalCount: 0,
               builtinDisabledID: 1, builtinDisabledName: "内置屏"),
         .enableBuiltin, 1),

        ("拔掉外接屏 · 内屏不在线 · 连内屏 id 都拿不到（只能交给系统）",
         Input(switchOn: true, asleep: false, externalCount: 0),
         .idle, nil),

        // 1.4.1：上面那条「拔掉外接屏就把内屏开回来」之所以整晚没生效，
        // 是因为外接屏数量算成了 1 —— 那块「屏」是随航断掉之后的残影。
        // 判定本身没问题，问题在喂给它的输入；这里把「喂对了」这个前提钉住。
        ("拔掉外接屏 · 只有随航残影在线（残影不计入外接屏 → 照样救）",
         Input(switchOn: true, asleep: false, externalCount: 0,
               builtinDisabledID: 1, builtinDisabledName: "内置屏"),
         .enableBuiltin, 1),

        // ---- 1.4.1：救援不再受开关限制，以及一条必须守住的边界 ----
        // 开关关着的人同样会黑屏：外接屏插着的时候手动关掉内屏是允许的
        // （那会儿还有外接屏可看），拔了线就一块屏不剩。旧代码在这一格只
        // 回一句「开关没打开」，然后就什么都不做。
        ("开关关着 · 拔掉外接屏 · 内屏被关着（照样必须救）",
         Input(switchOn: false, asleep: false, externalCount: 0,
               builtinDisabledID: 1, builtinDisabledName: "内置屏"),
         .enableBuiltin, 1),

        ("开关关着 · 有外接屏 · 内屏在线（尊重开关，不动）",
         Input(switchOn: false, asleep: false, externalCount: 1,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         .idle, nil),

        // 这条是防「亲手造黑屏」的回归：没有外接屏时**绝不能**走到关内屏那一支。
        // 救援分支必须在「内屏在线」时就返回，而不是往下掉。
        ("没有外接屏 · 内屏在线（绝不能反过来把内屏关掉）",
         Input(switchOn: true, asleep: false, externalCount: 0,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         .idle, nil),

        // ---- 1.4.1：合盖不是故障 ----
        // 合盖之后 macOS 会把内屏从显示配置里摘掉（clamshell），得到的正是
        // 「内屏不在线」这个状态 —— 和「内屏被关掉了」长得一模一样。
        // 但合盖时内屏本来就不会亮（面板不亮），去开它没有任何收益，
        // 而 setEnabled 会先声明一次用户活动把屏幕叫醒：电脑装包里的时候
        // 每 10 秒来一次，就是白白发热。开盖会触发配置变化，那时再救不迟。
        ("合盖 · 没有外接屏 · 内屏不在线（clamshell 正常状态，别去惊动它）",
         Input(switchOn: true, asleep: false, lidClosed: true, externalCount: 0,
               builtinDisabledID: 1, builtinDisabledName: "内置屏"),
         .idle, nil),

        ("合盖 · 没有外接屏 · 内屏不在线 · 开关也没开（同样不动）",
         Input(switchOn: false, asleep: false, lidClosed: true, externalCount: 0,
               builtinDisabledID: 1, builtinDisabledName: "内置屏"),
         .idle, nil),

        // 合盖时不做救援，但**开盖之后必须立刻救**（这是上面那条的配套保证）
        ("合盖 + 没有外接屏 · 开盖之后（同样的状态，救）",
         Input(switchOn: true, asleep: false, lidClosed: false, externalCount: 0,
               builtinDisabledID: 1, builtinDisabledName: "内置屏"),
         .enableBuiltin, 1),

        // 合盖时若内屏仍在位，一样什么都不用做
        ("合盖 · 没有外接屏 · 内屏在线（不动）",
         Input(switchOn: true, asleep: false, lidClosed: true, externalCount: 0,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         .idle, nil),
    ]

    print("=== 自动关闭内置屏 · 判定自测（构造场景，不接触真实显示器）===")
    var failed = 0
    for c in cases {
        let plan = DisplayManager.decide(c.input)
        let ok = plan.kind == c.expect && plan.displayID == c.expectID
        if !ok { failed += 1 }
        let kindText: String
        switch plan.kind {
        case .idle:           kindText = "不动"
        case .disableBuiltin: kindText = "关闭 \(plan.displayName)"
        case .enableBuiltin:  kindText = "打开 \(plan.displayName)"
        }
        print("\(ok ? "✓" : "✗") \(c.name)")
        print("      判定 \(kindText)  ——  \(plan.reason)")
    }
    // ---- 虚拟屏识别 ----
    // 系统在「所有真实屏都不可用」时会造一台虚拟屏，它 CGDisplayIsBuiltin 返回 0。
    // 不认出来就会被当成「外接屏还接着」，规则干脆不触发，而用户面对的是黑屏。
    // 取值参照实测（macOS 26.6）：vendor/model = 0x756E6B6E / 0x76657274，即 'unkn'/'vert'。
    let vs: [(name: String, vendor: UInt32, model: UInt32, nsName: String?,
              hasScreen: Bool, expect: Bool)] = [
        // 这里用**实测到的原始整数**，不靠手写四字符码 —— 上一版把 'virt'
        // 误写成 'vert'，判据就静默失效了，而所有用手写常量的用例还是全绿。
        ("虚拟屏：实测原始整数 vendor=1970170734 model=1986622068（'unkn'/'virt'）",
         1970170734, 1986622068, "", true, true),
        ("虚拟屏：同上，但 NSScreen 里没有这条", 1970170734, 1986622068, nil, false, true),
        ("虚拟屏：model 换成 'vert' 也要认（兼容字串变化）", 1970170734, 1986359924, "", true, true),
        ("真实外接屏：Mi Monitor 实测 EDID 25001/10145", 25001, 10145, "Mi Monitor", true, false),
        ("真实内屏：实测 EDID 1552/41032", 1552, 41032, "Built-in Retina Display", true, false),
        ("没名字 + EDID 全 0（兜底判为虚拟屏）", 0, 0, "", true, true),
        ("没名字但有 EDID（真实屏，不算虚拟）", 1234, 5678, "", true, false),
        ("EDID 全 0 但有名字（真实屏，不算虚拟）", 0, 0, "某显示器", true, false),
    ]
    // ---- 救援候选 id ----
    // 救援能不能成，取决于这个列表：记录里那条最可信，排第一；历史 id 跟上补齐、去重。
    // 只要列表里有对的那个，哪怕它的位置靠后也能救回来（打开时按顺序挨个试）。
    let cands: [(name: String, input: Input, expect: [CGDirectDisplayID])] = [
        ("记录 + 历史都有：记录排第一，历史去重后跟上",
         Input(switchOn: true, asleep: false, externalCount: 0,
               builtinDisabledID: 3, knownBuiltinIDs: [1, 3, 7]),
         [3, 1, 7]),
        ("只有历史 id（关闭记录丢了）",
         Input(switchOn: true, asleep: false, externalCount: 0, knownBuiltinIDs: [1, 7]),
         [1, 7]),
        ("什么都没有 → 拿不到候补，只能交给系统",
         Input(switchOn: true, asleep: false, externalCount: 0),
         []),
        ("有外接屏时不需要候选（关内屏的 id 就在眼前）",
         Input(switchOn: true, asleep: false, externalCount: 1,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         []),
    ]
    print("")
    print("--- 救援候选 id ---")
    for c in cands {
        let got = DisplayManager.decide(c.input).candidateIDs
        let ok = got == c.expect
        if !ok { failed += 1 }
        print("\(ok ? "✓" : "✗") \(c.name)  →  [" + got.map { String($0) }.joined(separator: ", ") + "]")
    }

    print("")
    print("--- 虚拟屏识别 ---")
    for c in vs {
        let got = DisplayManager.isVirtualDisplay(vendor: c.vendor, model: c.model,
                                                  nsName: c.nsName, hasNSScreen: c.hasScreen)
        let ok = got == c.expect
        if !ok { failed += 1 }
        print("\(ok ? "✓" : "✗") \(c.name)  →  \(got ? "判为虚拟屏" : "真实屏")")
    }

    // ---- 占位屏识别 ----
    // 1.4.1：随航 / 隔空播放断掉之后，系统会在在线列表里留下一条残影，
    // 它 CGDisplayIsBuiltin 返回 0、虚拟屏判据也认不出来，于是被当成「外接屏还接着」，
    // 规则整晚按 idle 处理，用户面对黑屏。这里把每一条判据都钉住。
    // 名字那一列用**实测到的原文**：zed 这台机器上 displayNames 里留下的就是「 (AirPlay)」
    // —— 注意开头的空格，设备名是空的。
    let ps: [(name: String, dispName: String, vendor: UInt32, model: UInt32,
              lw: Int, lh: Int, expect: Bool)] = [
        ("随航残影：名字实测为「 (AirPlay)」（设备名是空的）",
         " (AirPlay)", 0, 0, 1920, 1080, true),
        ("同上，但 EDID 读到了东西（名字就够判）",
         " (AirPlay)", 1234, 5678, 1920, 1080, true),
        ("随航全名 Sidecar Display (AirPlay)",
         "Sidecar Display (AirPlay)", 0, 0, 2732, 2048, true),
        ("中文名「隔空播放」",
         "隔空播放", 0, 0, 1920, 1080, true),
        ("没有名字的外接屏（连缓存都丢了）+ 读不到 EDID",
         "外接显示器 35", 0, 0, 1920, 1080, true),
        ("有 EDID 但报不出任何模式（渲染不出东西）",
         "某某牌显示器", 1234, 5678, 0, 0, true),
        ("真实外接屏：Mi Monitor 实测 EDID 25001/10145",
         "Mi Monitor", 25001, 10145, 2560, 1440, false),
        ("真实内屏：实测 EDID 1552/41032",
         "Built-in Retina Display", 1552, 41032, 1680, 1050, false),
    ]
    print("")
    print("--- 占位屏识别 ---")
    for c in ps {
        let got = DisplayManager.isPhantomDisplay(name: c.dispName, vendor: c.vendor,
                                                  model: c.model,
                                                  logicalWidth: c.lw, logicalHeight: c.lh)
        let ok = got == c.expect
        if !ok { failed += 1 }
        print("\(ok ? "✓" : "✗") \(c.name)  →  \(got ? "判为占位屏（不计入外接屏）" : "真实屏")")
    }

    print("")
    if failed == 0 {
        print("全部 \(cases.count + cands.count + vs.count + ps.count) 条通过")
    } else {
        print("✗ \(failed)/\(cases.count + cands.count + vs.count + ps.count) 条不符合预期")
    }
    exit(failed == 0 ? 0 : 1)
}

// 用法: DisplayMaster --wake-test [--sleep 6]
if CommandLine.arguments.contains("--wake-test") {
    _ = NSApplication.shared
    let dm = DisplayManager.shared
    print("=== \(AppInfo.name) 睡眠唤醒回归测试 ===")
    guard let ext = dm.displays().first(where: { !$0.isBuiltin }) else {
        print("✗ 没有外接显示器，跳过"); exit(1)
    }
    print("目标: \(ext.name)  id=\(ext.id)")
    print("0) 基线 · \(ddcStateLine())")
    let baseline = DDC.shared.readVCP(0, 0x10, force: true)
    print("   基线读数: " + (baseline.map { "\($0.cur)/\($0.max)" } ?? "✗ 读不到"))
    guard baseline != nil else {
        print("✗ 基线就失败，显示器当前不正常，先修好再测"); exit(2)
    }

    var sleepSec = 6
    if let i = CommandLine.arguments.firstIndex(of: "--sleep"),
       i + 1 < CommandLine.arguments.count, let v = Int(CommandLine.arguments[i + 1]) { sleepSec = v }

    print("1) 让显示器睡下去 ...")
    runTool("/usr/bin/pmset", ["displaysleepnow"])
    RunLoop.main.run(until: Date().addingTimeInterval(Double(sleepSec)))
    print("   已睡眠 \(sleepSec)s")

    print("2) 唤醒（模拟用户动鼠标）...")
    runTool("/usr/bin/caffeinate", ["-u", "-t", "2"])
    RunLoop.main.run(until: Date().addingTimeInterval(3.0))
    print("   已唤醒")

    print("3) 唤醒后直接读（模拟旧版本的行为，预期失败）...")
    let afterWake = DDC.shared.readVCP(0, 0x10)
    print("   " + (afterWake.map { "读到 \($0.cur)/\($0.max) —— 通道还活着，本次没复现（也是个好结果）" }
                  ?? "✗ 读不到 —— 通道确实哑了（这就是那个 bug 的现场）"))
    print("   \(ddcStateLine())")

    print("4) 走自动自愈路径（app 收到唤醒通知后做的正是这件事）...")
    dm.screenConfigurationChanged()
    RunLoop.main.run(until: Date().addingTimeInterval(3.0))
    let healed = DDC.shared.readVCP(0, 0x10)
    print("   " + (healed.map { "✓ 读到 \($0.cur)/\($0.max) —— 通道已恢复" } ?? "✗ 仍然读不到"))
    print("   \(ddcStateLine())")

    let pass = healed != nil
    print(pass ? "判定: ✓ 通过（唤醒后自动恢复可用）" : "判定: ✗ 失败（需要人工介入）")
    exit(pass ? 0 : 4)
}

// DDC 自愈回归测试：伪造「通道哑掉」，验证读/写都能自己救回来
// 用法: DisplayMaster --ddc-recover-test
if CommandLine.arguments.contains("--ddc-recover-test") {
    _ = NSApplication.shared
    let dm = DisplayManager.shared
    print("=== \(AppInfo.name) DDC 自愈回归测试 ===")
    guard let ext = dm.displays().first(where: { !$0.isBuiltin }) else {
        print("✗ 没有外接显示器，测试结束"); exit(1)
    }
    print("目标: \(ext.name) (id=\(ext.id))")

    guard let base = DDC.shared.readVCP(0, 0x10, force: true) else {
        print("✗ 基线读取失败（\(DDC.shared.lastDiagnosis)），显示器当前不正常"); exit(2)
    }
    let orig = Double(base.cur) / Double(base.max)
    print("0) 基线亮度 \(Int((orig * 100).rounded()))% · \(ddcStateLine())")

    print("1) 伪造「通道哑掉」：丢掉句柄 + 进入失败冷却 ...")
    DDC.shared.debugSimulateStaleChannel()
    print("   \(ddcStateLine())")

    print("2) 直接读（非 force，模拟菜单打开时读亮度）...")
    let afterRead = DDC.shared.brightness(0)
    let readOK = afterRead != nil
    print("   " + (afterRead.map { "✓ 自愈后读到 \(Int(($0 * 100).rounded()))%" } ?? "✗ 仍读不到"))
    print("   \(ddcStateLine())")

    print("3) 写亮度（模拟拖滑块）...")
    DDC.shared.debugSimulateStaleChannel()
    let target = orig > 0.5 ? orig - 0.15 : orig + 0.15
    let wrote = dm.setBrightness(ext, target)
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    let back = DDC.shared.readVCP(0, 0x10, force: true).map { Double($0.cur) / Double($0.max) }
    print("   写入\(wrote ? "成功" : "失败")   复读=\(back.map { "\(Int(($0 * 100).rounded()))%" } ?? "读不到")")
    let writeOK = wrote && back != nil && abs((back ?? 0) - target) < 0.06

    print("4) 恢复原值 \(Int((orig * 100).rounded()))% ...")
    _ = DDC.shared.setBrightness(0, orig)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    print("   \(ddcStateLine())")

    let pass = readOK && writeOK
    print(pass ? "判定: ✓ 通过（通道哑掉后能自动恢复，无需人工点「重新检测 DDC」）"
               : "判定: ✗ 失败（自愈没能救回来）")
    exit(pass ? 0 : 3)
}

// 菜单栏常驻工具：无 Dock 图标
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
