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
        .map { "\($0.value.name)(id=\($0.key) edid=\($0.value.vendor)/\($0.value.model)/\($0.value.serial))" }
        .joined(separator: ", ")
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
// 用法: DisplayMaster --dump-menu
if CommandLine.arguments.contains("--dump-menu") {
    _ = NSApplication.shared
    // 刻意不调 applicationDidFinishLaunching —— 那会创建状态栏图标，
    // 在没有运行循环的进程里会一直等下去。
    let delegate = AppDelegate()
    print("=== \(AppInfo.name) 菜单结构 ===")
    print(delegate.debugMenuDump())
    exit(0)
}

// 开关显示器回归测试：验证 1.0.1 修掉的那个 bug
// —— 打开一台已关闭的显示器之后，菜单里不该还留着「点击重新打开」的入口。
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
    print("4) 菜单里还会显示「点击重新打开」吗 : "
          + (dm.disabled.isEmpty ? "✓ 不会（记录已清空）" : "✗ 会 —— 残留 \(disabledLine())"))
    let pass = backOnline && dm.disabled.isEmpty
    print(pass ? "判定: ✓ 通过" : "判定: ✗ 失败")
    exit(pass ? 0 : 3)
}

// 显示器睡眠 → 唤醒 回归测试：验证 DDC 通道能自动重建
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
