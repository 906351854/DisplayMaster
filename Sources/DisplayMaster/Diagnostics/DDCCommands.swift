import AppKit

// DDC 端到端测试：读 → 写一个明显不同的值 → 复读验证 → 恢复原值
// 用法: DisplayMaster --ddc-test [--force] [--drain]
func runDDCTest() {
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
func runDDCStorm() {
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

// 显示器睡眠 → 唤醒 回归测试：验证 DDC 通道能自动重建
// 用法: DisplayMaster --wake-test [--sleep 6]
func runWakeTest() {
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
func runDDCRecoverTest() {
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

