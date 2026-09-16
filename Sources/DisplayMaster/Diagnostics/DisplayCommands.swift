import AppKit

// 分辨率滑块上有哪些档位。
//
// 为什么值得单独一条命令：滑块上那份档位和详情页里那份完整列表**不是同一份**。
// 滑块只收「跟面板原生比例一致」的那十来档，不然满屏小点、每格 4pt，根本拖不准。
// 出问题时第一件要确认的就是「这块屏到底有几档、当前是第几档」。
// 用法: DisplayMaster --modes
func runModes() {
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
func runHiDPITest() {
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

// 直接把某台显示器的 HiDPI 开关拨一次，并把推导出的目标模式打出来。
//
// 为什么单独留一条命令：HiDPI 切换要看「当前逻辑尺寸 / 备选档位 / 目标模式」三样东西，
// 而菜单里只有一枚开关，出问题时光看开关根本不知道它想切到哪去。
// 用法: DisplayMaster --hidpi-toggle <displayID>
func runHiDPIToggle() {
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

// 走一遍「在卡片上拖分辨率滑块并松手」这条链路，然后报告各屏现在的模式。
//
// 为什么值得留一条命令：滑块上只有「第几档」，档位表在 app 这边，
// 两边差一档就会切到隔壁的分辨率 —— 而且照样「能切成功」，肉眼很难发现。
// 用法: DisplayMaster --drag-res <卡片下标> <档位下标>
func runDragResolution() {
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

// 直接用 displayID 开关一台显示器。
//
// 为什么需要它：菜单里那个开关是「点一下」的交互，写自动化脚本使不上；而一旦
// 把某台屏关掉、记录又因为别的原因丢了，就只剩这条路能把它开回来。
// 这台机器上没有第二个屏幕可看时，这是唯一的救生索。
// 用法: DisplayMaster --display-on <id>  |  --display-off <id>
func runDisplayOnOff() {
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
func runToggleTest() {
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

    // 走和 app 内部同一份在线列表实现，别在这里另抄一遍两遍式调用
    let online = DisplayManager.onlineDisplayList()
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

// 直接开关指定的 displayID。
//
// 存在的理由：这个功能最关键的场景是「拔掉外接屏」，而真机上没法为了测试反复拔线。
// 用它把当前唯一在线的屏强制关掉，就能复现「外接屏消失」那一瞬间，观察规则的反应。
// --force 会绕过「不许关掉最后一台」的保护，所以只在确认能把屏幕开回来时用。
// 用法: DisplayMaster --set-display <displayID> on|off [--force]
func runSetDisplay() {
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

