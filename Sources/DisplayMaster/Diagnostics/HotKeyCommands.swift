import AppKit

/// 亮度键诊断：`--hotkey-status` / `--brightness-scenarios`
///
/// 这个功能是**最难人工复现**的那一类 —— 要人去按键盘，而按键这一步恰好是最容易
/// 坏的一环（权限、tap 被停用、键码解析、目标屏判定）。所以留两条命令：
///
///   - `--hotkey-status`：一眼看清权限、监听装没装上、接管的是哪条通道；
///   - `--brightness-scenarios`：步进算法是纯函数，用构造用例把它钉住
///     （0 和 1 两端最容易写错），不碰硬件也不碰键盘，任何时候都能复跑。
///
/// ## 定稿时删掉的几条调试工具（要加之前先看这里）
///
/// 功能跑通前临时加过四条命令。它们要回答的问题现在都已经固化进实现，
/// 留着只会让每一次「按了没反应」都被当成首次遇到，还得先学会一堆工具再开始查：
///
/// | 删掉的 | 当时要回答的问题 | 现在的答案（在哪儿） |
/// |---|---|---|
/// | `--sniff` | 按 F1 时键盘发的是媒体键还是普通按键？ | 两种都接（BrightnessKeyMonitor 的两条通道） |
/// | `--key-test` / `--send-key` | 不靠人按键能不能把整条链跑通？ | 真按一下 F1 更快，也不必引入「合成事件」权限这个概念 |
/// | `--key-audit` | 监听有没有能力改键盘事件？ | 普通按键走 `.listenOnly`，**按 API 契约就改不了** |
///
/// 一句话：**能固化成设计的，不要固化成工具。** 工具会腐坏，设计不会。

// MARK: - 状态

/// 当前这份二进制的签名身份与 CDHash。
///
/// 为什么值得报出来：辅助功能授权在系统里是**按签名身份记账**的。广告签名
/// （ad-hoc）的应用，其「代码要求」里含 cdhash，而 **cdhash 每次重新构建都会变** ——
/// 于是对系统来说，「你昨天授过权」的那份二进制和现在跑的这份是两个应用，
/// 授权自然不生效。构建脚本已改用证书签名来根治，这条命令用来在必要时**证伪**它。
private func codeSignSummary() -> String {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    p.arguments = ["-dvvv", exe]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe          // codesign -d 的输出在 stderr
    do { try p.run() } catch { return "读不到（\(error.localizedDescription)）" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""

    var cdhash = "?"
    var who = "ad-hoc（没有稳定身份，重装即失效）"
    var sawLeaf = false
    for raw in text.split(separator: "\n") {
        let line = String(raw)
        if line.hasPrefix("CDHash=") { cdhash = String(line.dropFirst(7).prefix(16)) }
        // Authority 会按 证书 → 中间证书 → 根证书 的顺序**依次**出现，
        // 取最后一个会得到「Apple Root CA」这种毫无信息量的答案 —— 要第一个。
        else if line.hasPrefix("Authority="), !sawLeaf {
            who = String(line.dropFirst(10))
            sawLeaf = true
        }
    }
    return "\(who)   cdhash=\(cdhash)"
}

func runHotKeyStatus() {
    _ = NSApplication.shared
    let mgr = DisplayManager.shared
    print("=== 亮度键 · 状态 ===")
    print("开关（偏好）  : " + (mgr.brightnessKeysEnabled ? "已打开" : "未打开"))
    // ⚠️ 这一行在命令行里**不可信**：TCC 会把权限算到父进程（终端/工具）头上，
    // 父进程有权限时这里就会显示「已授权」，而由 launchd 拉起的真实实例读不到。
    // 真实状态只能看应用自己的日志（启动时会留一条）。
    print("辅助功能权限  : " + (BrightnessKeyMonitor.isTrusted ? "✓ 已授权" : "✗ 未授权")
          + "    ⚠︎ 命令行进程的结论不可信，以应用日志为准")
    // 输入监控与辅助功能是**两个不同的 TCC 服务**，缺哪个的症状都是「按了没反应」。
    // 分开报出来，才不至于把「tap 建了却收不到事件」笼统归到权限没给。
    print("输入监控权限  : " + (BrightnessKeyMonitor.hasListenAccess ? "✓ 已授权" : "✗ 未授权")
          + "    ← 缺它会「tap 建成但收不到按键」")
    print("这份二进制    : " + codeSignSummary())
    // 真的试着装一次。「开关开着」和「监听真能建起来」是两件事：
    // 只看开关的话，权限或 tap 的问题会被笼统说成「退出重开应用」，没法定位。
    //
    // ⚠️ 子开关要**先推给监听**再 start()：诊断进程没有走过 `applyBrightnessKeysSetting`，
    // 不推的话 `start()` 根本不会去建 F 行通道，状态行就会把它误报成
    // 「缺输入监控权限」—— 一个「没试过」被写成「试过但失败」（2026-09-27 踩到）。
    BrightnessKeyMonitor.shared.respondsToFunctionRow = mgr.brightnessKeysFunctionRow
    let startErr = BrightnessKeyMonitor.shared.start()
    print("尝试装监听    : " + (startErr == nil ? "✓ 建成（事件监听可用）" : "✗ \(startErr!)"))
    print("状态说明      : " + mgr.brightnessKeysStateLine())
    // 单独报「接了哪条通道」：键盘不同，该看的那条完全不同，而两种状态都写着
    // 「已接管」。第三方键盘不发媒体键事件，这一项关着就等于按了没反应。
    print("接管通道      : " + (mgr.brightnessKeysFunctionRow
                                ? "媒体键 + 标准 F1/F2"
                                : "仅媒体键（第三方键盘的 F1/F2 会没反应）"))
    // 吞键范围要单独报：这是**唯一可能弄坏键盘**的地方，而「已接管」这三个字
    // 看不出它到底有没有能力修改键盘事件（2026-09-27 的「键盘打不了字」）。
    print("吞键范围      : " + BrightnessKeyMonitor.shared.swallowScope)
    if let fr = BrightnessKeyMonitor.shared.functionRowError {
        print("F 行通道失败  : " + fr + "    ← 补「输入监控」授权后 3 秒内自动接上")
    }
    if BrightnessKeyMonitor.shared.autoStopped {
        print("自动保护      : 已主动退出接管（\(BrightnessKeyMonitor.shared.autoStopReason ?? "原因不明")）")
    }
    if let d = mgr.displayUnderMouse() {
        let b = mgr.brightness(of: d).map { "\(Int(($0 * 100).rounded()))%" } ?? "读不到"
        print("鼠标所在屏    : \(d.name)(id=\(d.id))\(d.isBuiltin ? " 内置" : " 外接")  当前亮度 \(b)")
        // F1 是变暗、F2 是变亮（别把文案写反 —— 屏幕正好在 100% 时按 F2 不会有任何变化，
        // 那一幕很容易被当成「功能坏了」）。
        let base = mgr.brightnessBaseForKeyStep(of: d) ?? 0.5
        let down = Int((DisplayManager.steppedBrightness(from: base, direction: -1) * 100).rounded())
        let up = Int((DisplayManager.steppedBrightness(from: base, direction: 1) * 100).rounded())
        print("按一下会变成  : F1（变暗）→ \(down)%    F2（变亮）→ \(up)%")
    } else {
        print("鼠标所在屏    : 找不到（当前没有在线显示器？）")
    }
    print("")
    print("提示：没接管时 F1 / F2 仍是系统原生行为（只调内置屏），不会报错。")
    if !BrightnessKeyMonitor.isTrusted {
        print("")
        print("授权怎么看：系统设置 → 隐私与安全性 → 辅助功能 → 找到 Display Master，")
        print("           **确认那一行的开关是打开的**。")
        print("           列表里有条目 ≠ 已经授权 —— 条目只是因为弹过一次授权引导才出现，")
        print("           开关没拨开就等于没授权（2026-09-25 那次「权限也给了却没反应」就这个）。")
    }
    BrightnessKeyMonitor.shared.stop()
    exit(0)
}

// MARK: - 步进边界用例

/// 步进算法是纯函数，这里是它的边界用例。
///
/// 留下它的理由：不碰硬件、不碰键盘、不占权限，任何时候都能复跑 ——
/// 而 0 和 1 两端是这个算法最容易写错的地方（夹不住就会在浮层上显示 106%）。
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
