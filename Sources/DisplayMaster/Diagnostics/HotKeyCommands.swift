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

/// 发一个「普通按键」的 F1 / F2（`keyCode=122/120`）。
///
/// 和上面那个媒体键版本是**两条完全不同的通道**：这个走的是普通键盘事件，
/// 只有打开了「接管标准功能键 F1 / F2」的实例才该有反应。用来验证那条路 ——
/// 否则「第三方键盘按 F1 没反应」这件事只能靠人按住键去试。
///
/// ⚠️ 副作用要说清楚：合成的是**真的 F1/F2 按键**，除了我们，别的应用也可能收到
/// （合成事件不像我们的 tap 那样只给自己看）。所以它只用来做诊断，别放进常规流程。
/// 同样需要「合成事件」（PostEvent）权限。
private func postFunctionKey(_ vk: CGKeyCode, down: Bool) {
    guard let src = CGEventSource(stateID: .hidSystemState),
          let ev = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: down) else { return }
    ev.post(tap: .cghidEventTap)
}

// MARK: - 状态

/// 当前这份二进制的签名身份与 CDHash。
///
/// 为什么值得报出来：辅助功能授权在系统里是**按签名身份记账**的。广告签名
/// （ad-hoc）的应用，其「代码要求」里含 cdhash，而 **cdhash 每次重新构建都会变** ——
/// 于是对系统来说，「你昨天授过权」的那份二进制和现在跑的这份是两个应用，
/// 授权自然不生效。报出这两项，才能和系统设置里那条记录对上（或对不上）。
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
    print("合成事件权限  : " + (BrightnessKeyMonitor.hasPostAccess ? "✓ 已授权" : "✗ 未授权")
          + "    ← 只影响 --key-test")
    print("这份二进制    : " + codeSignSummary())
    // 真的试着装一次。「开关开着」和「监听真能建起来」是两件事：
    // 只看开关的话，权限或 tap 的问题会被笼统说成「退出重开应用」，没法定位。
    //
    // ⚠️ 子开关要**先推给监听**再 start()：诊断进程没有走过 `applyBrightnessKeysSetting`，
    // 不推的话 `start()` 根本不会去建 F 行通道，状态行就会把它误报成
    // 「缺输入监控权限」—— 一个「没试过」被写成「试过但失败」（2026-09-27 踩到）。
    BrightnessKeyMonitor.shared.capturesFunctionRow = mgr.brightnessKeysFunctionRow
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

// MARK: - 只发送（用来测别的进程能不能拦到）

/// 发一个合成亮度键，**自己不监听**。
///
/// 存在理由：判断「事件监听到底工作没有」本来只能靠人按键盘，但有一个纯自动的办法——
/// 往系统里投一个合成按键，然后看**另一个进程**（真正在跑的应用）的日志里有没有
/// 「亮度键·收到」。这比请人按键快得多，也不受人手差异干扰。
///
/// `--key-test` 干不了这件事：它自己也起了一个 tap，会把事件截在自己那里，
/// 于是「收到」只能证明它自己好，证明不了别的进程。
func runSendBrightnessKey() {
    _ = NSApplication.shared
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--send-key"), i + 1 < args.count else {
        print("用法：--send-key up|down|f1|f2")
        print("  up / down  发媒体键通道的亮度键（苹果键盘那条路）")
        print("  f1 / f2    发普通按键通道的标准 F1 / F2（多数第三方键盘那条路）")
        exit(1)
    }
    let dir = args[i + 1].lowercased()
    guard dir == "up" || dir == "down" || dir == "f1" || dir == "f2" else {
        print("方向只能是 up / down / f1 / f2")
        exit(1)
    }

    let isFunctionRow = (dir == "f1" || dir == "f2")
    print("=== 发送合成\(isFunctionRow ? "标准功能键 F1 / F2" : "媒体亮度键")（\(dir)）===")
    print("辅助功能权限  : " + (BrightnessKeyMonitor.isTrusted ? "✓" : "✗"))
    print("合成事件权限  : " + (BrightnessKeyMonitor.hasPostAccess ? "✓" : "✗ —— 发不出去"))

    if isFunctionRow {
        // 122 = F1（变暗）、120 = F2（变亮），见 BrightnessKeyMonitor.VKKeyCode
        let vk: CGKeyCode = (dir == "f1") ? 122 : 120
        postFunctionKey(vk, down: true)
        usleep(60_000)
        postFunctionKey(vk, down: false)
        print("已发送（按下 + 抬起，keyCode=\(vk)）")
        print("")
        print("判读：应用日志里应出现「亮度键·收到（普通按键）keyCode=\(vk)」。")
        print("  没有 → 多半是「接管标准功能键 F1 / F2」这一项关着（菜单里第二行开关）")
        print("  有，但亮度没变 → 问题在目标屏或写入，看有没有「调不动」那条")
    } else {
        // 2 = 变亮、3 = 变暗（见 BrightnessKeyMonitor 里的 NXKeyType）
        postBrightnessKey(dir == "up" ? 2 : 3, down: true)
        usleep(60_000)
        postBrightnessKey(dir == "up" ? 2 : 3, down: false)
        print("已发送（按下 + 抬起）")
        print("")
        print("判读：去看**应用自己的日志**里有没有「亮度键·收到」——")
        print("  有 → 应用的监听是好的，能收到事件；问题在按键来源或调节环节")
        print("  无 → 监听建起来了但收不到事件（多半是缺「输入监控」权限）")
    }
    exit(0)
}

// MARK: - 键盘事件嗅探

/// 监听**所有**键盘事件并打印（只监听，不拦截、不改动任何东西）。
///
/// 为什么非要有它：真机上「按 F1 没反应」至少有两种来源完全不同的原因——
///
///   1. 键盘发的是**媒体键事件**（`NX_SYSDEFINED`）——该拦却没收着；
///   2. 键盘把 F1 当**标准功能键**发（`keyCode 122`）——压根没走媒体键通道。
///
/// 这两者的修法正好相反（前者查监听，后者要换判据），而用**第三方机械键盘**时
/// 第 2 种极常见：F 行发什么由**键盘固件**决定，系统设置里那句
/// 「将 F1、F2 等键用作标准功能键」（`com.apple.keyboard.fnState`）
/// **只对苹果键盘有效**，对着第三方键盘拨它没有任何作用（2026-09-27 实测怀疑点）。
///
/// 判读：按 F1 时如果打出的是 `普通按键 keyCode=122`，就是第 2 种 ——
/// 媒体键那条路一次都不会有事件，再怎么查监听都是白费。
///
/// 注意：这是 `.listenOnly`，不吞事件，所以不会影响你正常用键盘。
/// 唯一的盲区——如果应用自己的 tap 正在工作并吞掉了媒体键事件，
/// 这里就看不到那条媒体键路径（那反而说明拦截是好的）。
func runSniffKeys() {
    _ = NSApplication.shared
    let args = CommandLine.arguments
    var seconds = 30.0
    if let i = args.firstIndex(of: "--sniff"), i + 1 < args.count, let v = Double(args[i + 1]) {
        seconds = min(max(v, 5), 120)
    }

    print("=== 键盘事件嗅探（\(Int(seconds)) 秒，只监听、不拦截）===")
    print("输入监控权限  : " + (BrightnessKeyMonitor.hasListenAccess ? "✓" : "✗ —— 可能建不起来"))
    print("")
    print("这 \(Int(seconds)) 秒里请依次按：F1、F2、fn+F1、fn+F2（别打字，打字会刷屏）")
    print("每按一下就冒一行。下面开始：")
    print("")

    // 10=keyDown 11=keyUp 12=flagsChanged 14=systemDefined
    let mask: CGEventMask = (1 << 10) | (1 << 11) | (1 << 12) | (1 << 14)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,                 // 只看，不动
        eventsOfInterest: mask,
        callback: { _, type, event, _ in
            sniffDescribe(type: type, event: event)
            return Unmanaged.passUnretained(event)
        },
        userInfo: nil
    ) else {
        print("✗ 建不起监听 —— 多半是缺「输入监控」权限")
        exit(1)
    }

    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        print("")
        print("（嗅探结束）")
        exit(0)
    }
    CFRunLoopRun()
}

/// 嗅探回调的打印。必须是顶层函数：C 函数指针不能捕获上下文。
private func sniffDescribe(type: CGEventType, event: CGEvent) {
    var line: String
    switch type.rawValue {
    case 10, 11:
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let down = type.rawValue == 10
        line = "\(down ? "按下" : "抬起") · 普通按键 keyCode=\(code)"
        if code == 122 { line += "   ★ 这是标准 F1，不是媒体键" }
        if code == 120 { line += "   ★ 这是标准 F2，不是媒体键" }
        if code == 63 { line += "   ★ fn 键" }
    case 12:
        let f = event.flags
        line = "修饰键变化 flags=0x\(String(f.rawValue, radix: 16))"
        if f.contains(.maskSecondaryFn) { line += "  含 fn" }
    case 14:
        guard let ns = NSEvent(cgEvent: event) else {
            line = "系统定义事件（NSEvent 构造失败）"
            break
        }
        let d1 = ns.data1
        let kt = (d1 & 0xFFFF0000) >> 16
        let fl = d1 & 0x0000FFFF
        let down = ((fl & 0xFF00) >> 8) == 0x0A
        line = "\(down ? "按下" : "抬起") · 系统定义事件 keyType=\(kt)"
        switch kt {
        case 2: line += "（亮度 +）  ★ 正是我们在拦的"
        case 3: line += "（亮度 −）  ★ 正是我们在拦的"
        case 0: line += "（音量 +）"
        case 1: line += "（音量 −）"
        case 7: line += "（静音）"
        default: line += "（未分类）"
        }
        line += "  flags=0x\(String(fl, radix: 16))"
    default:
        line = "type=\(type.rawValue)"
    }
    print("  \(line)")
    fflush(stdout)
}

// MARK: - 只读性审计：自证「这个功能碰不到打字」

/// 尾部探针的记录函数。必须是顶层函数（C 函数指针不能捕获上下文）。
private func auditProbeRecord(type: CGEventType, event: CGEvent, sink: Locked<[String]>) {
    if type.rawValue == 14 {
        guard let ns = NSEvent(cgEvent: event) else { return }
        let kt = (ns.data1 & 0xFFFF0000) >> 16
        sink.value.append("媒体键 keyType=\(kt)")
    } else if type.rawValue == 10 || type.rawValue == 11 {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        sink.value.append("普通按键 keyCode=\(code)")
    }
}

/// 自证「接管不会弄坏键盘」。
///
/// **为什么要有这条命令。** 这个功能唯一可能伤到用户的地方不是亮度，而是
/// 「事件监听有没有权力改键盘事件」。2026-09-27 撞过一次：把 `keyDown/keyUp`
/// 挂进活动型 tap 之后，用户报「外接键盘打不了字」，而事后只能靠命令行
/// `pkill` 自救 —— 那种事故不该依赖有人记得小心，而该有一条机器能反复跑的检查。
///
/// **做法。** 在我们自己的两条 tap **之后**（尾部）再挂一个只读探针，然后投三种
/// 合成事件，看探针能看到哪些。我们若吞了某个事件，探针就看不到它 ——
/// 于是「到底吞了什么」从口头承诺变成可观测事实：
///
/// | 投出去的事件 | 探针应当 | 说明 |
/// |---|---|---|
/// | 普通按键（keyCode 105 = F13） | **看到** | 普通按键没被吞 → 打字不受影响 |
/// | 标准 F1（keyCode 122） | **看到** | 我们不吞普通按键通道的 F1 |
/// | 亮度媒体键（keyType=3） | **看不到** | 仍被我们拦下，否则内置屏会被系统改两次 |
///
/// 用 F13 而不是字母做「普通按键」样本：事件类型完全一样，但 F13 不产生任何输入，
/// 审计不该往用户当前聚焦的窗口里打字。
func runKeyAudit() {
    _ = NSApplication.shared
    let monitor = BrightnessKeyMonitor.shared
    monitor.capturesFunctionRow = DisplayManager.shared.brightnessKeysFunctionRow
    monitor.onStep = nil            // 只审计，不动用户的屏幕

    print("=== 亮度键 · 只读性审计 ===")
    print("把「不会弄坏键盘」变成可复跑的断言，而不是靠事后回想。")
    print("")

    if let err = monitor.start() {
        print("我们的监听    : ✗ \(err)")
        print("（下面的结论无意义：监听都没装上）")
        exit(1)
    }
    print("我们的监听    : 媒体键通道=\(monitor.isRunning ? "在" : "不在")"
          + "   普通按键通道=\(monitor.isFunctionRowRunning ? "在" : "不在")")
    print("吞键范围      : \(monitor.swallowScope)")
    print("")

    let observed = Locked([String]())
    let mask = CGEventMask(1 << 14) | CGEventMask(1 << 10) | CGEventMask(1 << 11)
    guard let probe = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .tailAppendEventTap,        // 挂在我们后面：我们吞掉的它看不到
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: { _, type, event, refcon in
            if let refcon {
                let sink = Unmanaged<Locked<[String]>>.fromOpaque(refcon).takeUnretainedValue()
                auditProbeRecord(type: type, event: event, sink: sink)
            }
            return Unmanaged.passUnretained(event)
        },
        userInfo: Unmanaged.passUnretained(observed).toOpaque()
    ) else {
        print("尾部探针      : ✗ 建不起来（缺「输入监控」权限，读不到就别下结论）")
        monitor.stop()
        exit(1)
    }
    let probeSrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, probe, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), probeSrc, .commonModes)
    CGEvent.tapEnable(tap: probe, enable: true)

    print("投入合成事件：")
    print("  1) 普通按键 keyCode=105（F13，不产生任何输入）")
    postFunctionKey(105, down: true); postFunctionKey(105, down: false)
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    print("  2) 标准 F1 keyCode=122")
    postFunctionKey(122, down: true); postFunctionKey(122, down: false)
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    print("  3) 亮度媒体键（NX_SYSDEFINED keyType=3）")
    let handledBefore = monitor.mediaHandled
    postBrightnessKey(3, down: true); postBrightnessKey(3, down: false)
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))

    let got = observed.value
    let weGotMedia = monitor.mediaHandled > handledBefore
    let sawPlain = got.contains { $0.contains("105") }
    let sawF1 = got.contains { $0.contains("122") }
    let leakedMedia = got.contains { $0.contains("keyType=3") }

    print("")
    print("探针在尾部看到：\(got.isEmpty ? "（什么都没看到）" : got.joined(separator: "、"))")
    print("")
    print("判定：")
    print("  普通按键不被吞（打字不受影响）: " + (sawPlain ? "✓ 通过" : "✗ 失败 —— 有东西吞掉了普通按键"))
    print("  标准 F1 不被吞（别的应用照旧收到）: " + (sawF1 ? "✓ 通过" : "✗ 失败"))
    let mediaVerdict = (weGotMedia && !leakedMedia) ? "✓ 通过"
        : (weGotMedia ? "✗ 失败 —— 我们没拦住，漏给系统了（内置屏会被改两次）"
                      : "✗ 失败 —— 我们压根没收到（监听没生效）")
    print("  亮度媒体键被我们拦下          : " + mediaVerdict)

    let allPass = sawPlain && sawF1 && weGotMedia && !leakedMedia
    print("")
    print(allPass ? "总结：✓ 全部通过 —— 接管只碰亮度键，碰不到键盘。"
                  : "总结：✗ 有项目不通过，别把这个版本发出去。")

    CGEvent.tapEnable(tap: probe, enable: false)
    CFRunLoopRemoveSource(CFRunLoopGetMain(), probeSrc, .commonModes)
    monitor.stop()
    exit(allPass ? 0 : 1)
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
