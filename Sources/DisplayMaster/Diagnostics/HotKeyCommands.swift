import AppKit

/// 亮度键诊断：`--hotkey-status` / `--key-test` / `--brightness-scenarios`
///
/// 为什么值得单独写三条命令：这个功能是**最难人工复现**的那一类 ——
/// 要人去按键盘，而按键这一步恰好是最容易坏的一环（权限、tap 被停用、
/// 键码解析、目标屏判定）。等用户报「按了没反应」再查，你根本分不清是
/// 没拦到键、拦到了没找到屏、还是找到了写不进去。所以：
///   - 状态：一眼看清权限与监听装没装上；
///   - 端到端：程序自己发一个假按键，把整条链（拦截 → 目标屏 → DDC 写入）
///     跑一遍，并且**测完把亮度还原**；
///   - 边界：步进算法是纯函数，用构造用例把它钉住（0 和 1 两端最容易写错）。

// MARK: - 合成一个亮度键事件

/// 发一个「系统定义」的亮度键事件。
///
/// 载荷格式和真键盘发出来的完全一样（见 BrightnessKeyMonitor 里的解析）：
/// 高 16 位是媒体键编号，第 8~15 位是按下(0x0A)/抬起(0x0B)。
/// 注意这本身也要求辅助功能权限 —— 所以「发送失败」和「拦截失败」得分开报，
/// 否则会把权限问题误判成逻辑问题。
private func postBrightnessKey(_ keyType: Int, down: Bool) {
    let flags = down ? 0x0A : 0x0B
    let data1 = (keyType << 16) | (flags << 8)
    guard let ev = NSEvent.otherEvent(with: .systemDefined,
                                      location: .zero,
                                      modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: 0,
                                      context: nil,
                                      subtype: 8,
                                      data1: data1,
                                      data2: -1) else { return }
    ev.cgEvent?.post(tap: .cghidEventTap)
}

// MARK: - 状态

func runHotKeyStatus() {
    _ = NSApplication.shared
    let mgr = DisplayManager.shared
    print("=== 亮度键 · 状态 ===")
    print("开关（偏好）  : " + (mgr.brightnessKeysEnabled ? "已打开" : "未打开"))
    print("辅助功能权限  : " + (BrightnessKeyMonitor.isTrusted ? "✓ 已授权" : "✗ 未授权"))
    // 真的试着装一次。「开关开着」和「监听真能建起来」是两件事：
    // 只看开关的话，权限或 tap 的问题会被笼统说成「退出重开应用」，没法定位。
    let startErr = BrightnessKeyMonitor.shared.start()
    print("尝试装监听    : " + (startErr == nil ? "✓ 建成（事件监听可用）" : "✗ \(startErr!)"))
    print("状态说明      : " + mgr.brightnessKeysStateLine())
    if let d = mgr.displayUnderMouse() {
        let b = mgr.brightness(of: d).map { "\(Int(($0 * 100).rounded()))%" } ?? "读不到"
        print("鼠标所在屏    : \(d.name)(id=\(d.id))\(d.isBuiltin ? " 内置" : " 外接")  当前亮度 \(b)")
        print("下一步        : 按一次 F1 → \(Int((DisplayManager.steppedBrightness(from: mgr.brightnessBaseForKeyStep(of: d) ?? 0.5, direction: 1) * 100).rounded()))%")
    } else {
        print("鼠标所在屏    : 找不到（当前没有在线显示器？）")
    }
    print("")
    print("提示：没接管时 F1 / F2 仍是系统原生行为（只调内置屏），不会报错。")
    BrightnessKeyMonitor.shared.stop()
    exit(0)
}

// MARK: - 端到端

func runBrightnessKeyTest() {
    _ = NSApplication.shared
    let mgr = DisplayManager.shared
    print("=== 亮度键 · 端到端自测 ===")
    print("说明：本命令**会真的改亮度**，结束时还原。")

    guard let target = mgr.displayUnderMouse() else {
        print("✗ 找不到目标屏（没有在线显示器）")
        exit(1)
    }
    print("目标屏        : \(target.name)(id=\(target.id))\(target.isBuiltin ? " 内置" : " 外接")")
    print("辅助功能权限  : " + (BrightnessKeyMonitor.isTrusted ? "✓ 已授权" : "✗ 未授权（下面多半会失败，但那是权限问题）"))

    guard let before = mgr.brightness(of: target) else {
        print("✗ 这台屏亮度读不到，测不了（先跑 --selftest 看 DDC 那一行）")
        exit(1)
    }
    print("测试前亮度    : \(Int((before * 100).rounded()))%")

    // 装上监听（和真实运行同一条路）
    if let err = BrightnessKeyMonitor.shared.start() {
        print("装上监听      : ✗ \(err)")
        exit(1)
    }
    print("装上监听      : ✓ 已接管")

    let seen = Locked(0)
    BrightnessKeyMonitor.shared.onStep = { direction in
        seen.value += 1
        print("   ↳ 拦到按键 direction=\(direction)")
        _ = mgr.stepBrightnessByKey(direction: direction)
    }

    // 发一个假的「亮度减」，再发抬起
    print("发送合成按键  : 亮度减（DOWN）")
    postBrightnessKey(3, down: true)
    postBrightnessKey(3, down: false)
    // 跑一会儿 RunLoop，让 tap 的回调与派发真正执行
    RunLoop.current.run(until: Date().addingTimeInterval(0.9))

    let after = mgr.brightness(of: target)
    print("")
    print("拦到按键次数  : \(seen.value)  " + (seen.value > 0 ? "✓ 监听工作正常" : "✗ 一次都没拦到"))
    if seen.value == 0 {
        print("  可能原因：① 没授权（权限）② 合成事件没发出去（也要权限）③ 主线程没在跑 RunLoop")
    }
    if let after {
        let beforePct = Int((before * 100).rounded())
        let afterPct = Int((after * 100).rounded())
        print("测试后亮度    : \(afterPct)%  （\(afterPct - beforePct >= 0 ? "+" : "")\(afterPct - beforePct)）")
        print("期望          : 约 -\(Int(DisplayManager.brightnessKeyStep * 100))% 左右（一次 1/16）")

        // 还原：诊断命令不该把用户的屏幕留在改过的状态
        print("")
        print("还原亮度 ...")
        _ = mgr.setBrightness(target, before)
        // 节流表里可能还压着刚才那个值，先清掉再等一次写入间隔
        mgr.flushBrightness(target)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let restored = mgr.brightness(of: target).map { Int(($0 * 100).rounded()) } ?? -1
        print("还原结果      : \(restored)%  " + (restored == beforePct ? "✓ 与测试前一致" : "⚠︎ 与测试前不同（\(beforePct)%）"))
    } else {
        print("测试后亮度    : 读不到（通道可能刚被写坏，跑一次 --ddc-recover-test）")
    }

    BrightnessKeyMonitor.shared.stop()
    exit(0)
}

// MARK: - 步进边界用例

/// 线程里累加用的最小盒子（RunLoop 回调里改外层的 var 会有捕获歧义）
final class Locked<T> {
    var value: T
    init(_ v: T) { value = v }
}

func runBrightnessScenarios() {
    typealias DM = DisplayManager
    // 步长 1/16 = 6.25%
    let cases: [(name: String, from: Double, dir: Int, expect: Double)] = [
        ("中间值 · 变亮", 0.5, 1, 0.5625),
        ("中间值 · 变暗", 0.5, -1, 0.4375),

        // 两端是最容易写错的地方：夹不住就会越界，OSD 上会显示成 106% 这种数
        ("最亮 · 再变亮（必须夹住）", 1.0, 1, 1.0),
        ("最暗 · 再变暗（必须夹住）", 0.0, -1, 0.0),
        ("接近最亮 · 一步跨过上限", 0.97, 1, 1.0),
        ("接近最暗 · 一步跨过下限", 0.03, -1, 0.0),

        // 从 0 按满 16 下必须正好到 1（步长与档位数量对不上的话，会出现
        // 「到家了还差一格」或者「没到家就顶死」，手感上很别扭）
        ("从 0 连按 16 下", 0.0, 16, 1.0),
        ("从 1 连按 16 下", 1.0, -16, 0.0),

        ("方向为 0（不动）", 0.375, 0, 0.375),
        ("1/16 的整点不漂移", 0.0625, -1, 0.0),
    ]

    print("=== 亮度键 · 步进用例（纯函数，不接触显示器）===")
    var pass = 0
    for c in cases {
        // 连按 n 下 = 重复走 n 步
        var got = c.from
        let steps = max(1, abs(c.dir))
        for _ in 0..<steps {
            got = DM.steppedBrightness(from: got, direction: c.dir == 0 ? 0 : (c.dir > 0 ? 1 : -1))
        }
        let ok = abs(got - c.expect) < 1e-9
        if ok { pass += 1 }
        print("\(ok ? "✓" : "✗") \(c.name)  →  \(fmt(got))  (期望 \(fmt(c.expect)))")
    }
    print("")
    print("通过 \(pass)/\(cases.count)")
    if pass != cases.count { exit(1) }
    exit(0)
}

private func fmt(_ v: Double) -> String {
    String(format: "%.4f（%d%%）", v, Int((v * 100).rounded()))
}
