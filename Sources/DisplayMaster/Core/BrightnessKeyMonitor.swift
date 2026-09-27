import AppKit
import ApplicationServices
import CoreGraphics

/// 系统定义的「媒体键」事件（`NX_SYSDEFINED` = 14）。
///
/// 亮度键（F1/F2）在**苹果键盘**上不是普通按键：`fnState` 没打开时，它发的是
/// 这种系统事件，普通 `keyDown` 那条路一次都收不到。CoreGraphics 的 `CGEventType`
/// 里没有这个 case，只能按原始值构造。
private let kSystemDefinedEventType = CGEventType(rawValue: 14)!

/// 亮度键在 `NX_SYSDEFINED` 事件里的编号（见 IOKit/hidsystem/ev_keymap.h）
private enum NXKeyType {
    static let brightnessUp = 2
    static let brightnessDown = 3
}

/// 普通按键通道上的 F1 / F2 键码（见 HIToolbox/Events.h 的 `kVK_F1` / `kVK_F2`）。
///
/// 第三方机械键盘的 F 行普遍按**标准功能键**发（按 F1 出来的是 `keyCode=122`），
/// 系统设置里那句「将 F1、F2 等键用作标准功能键」（`com.apple.keyboard.fnState`）
/// 只管苹果键盘，接不了第三方的。所以这条路也要接（2026-09-27 真机实测确认）。
private enum VKKeyCode {
    static let f1: Int64 = 122      // 变暗
    static let f2: Int64 = 120      // 变亮
}

/// 事件回调里唯一允许做的事：**记一笔**（限频 + 异步落盘）。
///
/// **为什么回调里不能直接写日志。** `DisplayManager.ruleLog` 是同步文件 IO
/// （开句柄 → seek → write）。事件回调有硬性时间预算，超了系统就把整个监听停掉；
/// 而**任何一个活动型 tap 被停掉/卡住的那段时间，键盘输入会被系统扣住** ——
/// 用户看到的就是「键盘打不了字」（2026-09-27 撞上，见类注释末尾的复盘）。
///
/// 所以回调里只做「加锁查一次限频表」这点纳秒级的事，字符串与落盘全部扔后台。
private final class TapLogGate {
    private let lock = NSLock()
    private var last: [String: Date] = [:]

    /// 限频通过时异步落一条日志；否则直接丢弃（连字符串都不拼）。
    func log(key: String, minInterval: TimeInterval, _ message: @escaping () -> String) {
        lock.lock()
        if let t = last[key], Date().timeIntervalSince(t) < minInterval {
            lock.unlock()
            return
        }
        last[key] = Date()
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            DisplayManager.shared.ruleLog(message())
        }
    }
}

/// 亮度键监听：把 F1/F2 的「调亮度」意图交给本应用处理。
///
/// ## 两条通道、两种权限模型，别混为一谈
///
/// | 通道 | 谁在用 | 事件类型 | tap 类型 | 能吞事件吗 | 需要哪个权限 |
/// |---|---|---|---|---|---|
/// | 媒体键 | 苹果键盘、部分键盘的多媒体模式 | `NX_SYSDEFINED` type=14 | **活动型** `.defaultTap` | 能 | 辅助功能 |
/// | 普通按键 | 多数第三方机械键盘 | `keyDown` keyCode 122/120 | **只读型** `.listenOnly` | **不能** | 输入监控 |
///
/// ## 为什么普通按键那条必须是「只读型」（这是本文件最重要的设计决定）
///
/// 1.6.3 把 `keyDown / keyUp` 挂进了**活动型** tap，掩码等于「整个键盘流」。
/// 结果是用户报「外接键盘打不了字了」—— 一个活动型 tap 只要回调卡住、
/// 或被系统停用，**全键盘的输入都会被扣住**；而这条通道的全部收益不过是
/// 「少调一次内置屏亮度」（第三方键盘上普通 F1/F2 本来什么也不做）。
///
/// 收益极小、爆炸半径极大 —— 这个交易不该做。`.listenOnly` 按 API 契约
/// **拿不到修改权**，回调返回值被系统忽略，所以从结构上就不可能吞掉任何按键。
/// 这是「用类型系统而不是用小心谨慎来保证安全」。
///
/// 代价（写进文档了）：普通 F1 / F2 会被别的应用同时收到 —— 对这类键盘来说
/// 那是本来就有的行为，不是我们引入的。
///
/// ## 三个必须做对的地方（媒体键通道）
///
/// 1. **回调返回值决定吞不吞**：返回 `nil` 才吞。而**这里的吞键掩码只有
///    `NX_SYSDEFINED` 一种**，物理上碰不到普通按键。
/// 2. **RunLoop 模式必须带 `.commonModes`**：菜单打开或拖动期间主线程跑的是
///    tracking 模式，只挂默认模式的事件源整个期间一次都不会响应。
/// 3. **tap 会被系统单方面停掉**：主线程被占住超过超时上限，系统就发
///    `tapDisabledByTimeout` 停掉它且不报错。收到立刻重新启用；但**连续发生
///    就说明这个进程不适合持有 tap**，那要主动退出接管（见 `noteTapDisabled`），
///    而不是硬撑着让用户的键盘继续受牵连。
///
/// ## 回调里的活必须马上交出去
///
/// 回调只解析按键、立刻 `async` 派发，马上返回；日志走 `TapLogGate`（异步）。
/// 后面真正要做的事（读 DDC、写 DDC、重建句柄）明显可能超时，不能占着回调。
final class BrightnessKeyMonitor {
    static let shared = BrightnessKeyMonitor()

    /// 一次按键：+1 变亮、-1 变暗。回调在主线程。
    var onStep: ((Int) -> Void)?

    /// 是否接「普通按键通道」的标准 F1 / F2（默认由偏好决定）。
    ///
    /// 关掉只影响「F 行发标准功能键」的键盘，苹果键盘上的媒体键通道照旧。
    var capturesFunctionRow = false

    // MARK: - 两个 tap

    /// 媒体键通道：**活动型**，掩码只有 `NX_SYSDEFINED`。
    private var mediaTap: CFMachPort?
    private var mediaSource: CFRunLoopSource?

    /// 普通按键通道：**只读型**，吞不了任何事件。
    private var keyTap: CFMachPort?
    private var keySource: CFRunLoopSource?

    // MARK: - 状态

    private let logGate = TapLogGate()

    /// 最近若干次「被系统停用」的时刻（看门狗用）
    private var disabledAt: [Date] = []

    /// 保护性自停：判定接管会危害键盘时置位，此后不再自动重试。
    private(set) var autoStopped = false
    private(set) var autoStopReason: String?

    /// 普通按键通道最近一次的失败原因（nil = 正常）
    private(set) var functionRowError: String?

    private(set) var mediaHandled = 0
    private(set) var functionRowHandled = 0

    /// 兼容旧诊断输出
    var handledCount: Int { mediaHandled + functionRowHandled }

    /// 上一次走**媒体键通道**处理亮度键的时间（供两条通道去重）
    private var lastMediaBrightnessAt: Date?

    /// 是否已经接管媒体键通道（主通道）
    var isRunning: Bool { mediaTap != nil }

    /// 普通按键通道是否在跑
    var isFunctionRowRunning: Bool { keyTap != nil }

    /// 还需要再试一次装监听吗（供 3 秒轮询判断，比 `!isRunning` 更准）
    var needsStart: Bool {
        if autoStopped { return false }
        if mediaTap == nil { return true }
        if capturesFunctionRow, keyTap == nil { return true }
        return false
    }

    /// 用户的权限状态（三项是**不同的** TCC 服务，别当成一件事）
    static var isTrusted: Bool { AXIsProcessTrusted() }
    static var hasListenAccess: Bool { CGPreflightListenEventAccess() }
    static var hasPostAccess: Bool { CGPreflightPostEventAccess() }

    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let s = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    private init() {}

    // MARK: - 起停

    /// 装上监听。返回媒体键通道的失败原因（nil = 成功）。
    ///
    /// 两条通道各自独立：媒体键通道失败 = 功能整体不可用；
    /// F 行通道失败 = 苹果键盘照旧可用，只有第三方键盘没反应。
    @discardableResult
    func start() -> String? {
        let mediaErr = startMediaTap()
        functionRowError = capturesFunctionRow ? startFunctionRowTap() : nil
        if mediaErr == nil { autoStopped = false; autoStopReason = nil }
        return mediaErr
    }

    func stop() {
        tearDownMediaTap()
        tearDownFunctionRowTap()
    }

    /// 用户重新打开开关时调用：允许再次自动重试（清掉看门狗的判决）。
    func resetAutoStop() {
        autoStopped = false
        autoStopReason = nil
        disabledAt.removeAll()
    }

    private func startMediaTap() -> String? {
        if mediaTap != nil { return nil }
        guard Self.isTrusted else { return "没有辅助功能权限" }

        // ⚠️ 这个掩码**故意只有一个位**：`NX_SYSDEFINED`。
        // 只要它同时含 keyDown/keyUp，这个活动型 tap 就有了扣住整个键盘的能力
        // ——2026-09-27 的「键盘打不了字」就是这么来的。普通按键走只读通道。
        let mask = CGEventMask(1 << kSystemDefinedEventType.rawValue)
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // 活动型：要吞掉媒体亮度键，否则内置屏会被改两次
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<BrightnessKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.receiveMedia(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return "系统拒绝了事件监听（刚授权的话，退出重开应用一次）"
        }

        mediaTap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        mediaSource = src
        // 主线程 + .commonModes：见类注释第 2 条
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return nil
    }

    private func startFunctionRowTap() -> String? {
        if keyTap != nil { return nil }
        guard Self.hasListenAccess else { return "没有「输入监控」权限" }

        // ⚠️ 只读型。返回值会被系统忽略 —— 这正是要的：这条通道**无权**影响输入。
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,          // 改不成 .defaultTap，见类注释
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<BrightnessKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.observeFunctionRow(type: type, event: event)
                return Unmanaged.passUnretained(event)   // 永远放行
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return "系统拒绝了只读监听（需要「输入监控」权限）"
        }

        keyTap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        keySource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return nil
    }

    private func tearDownMediaTap() {
        if let t = mediaTap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = mediaSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        mediaTap = nil
        mediaSource = nil
    }

    private func tearDownFunctionRowTap() {
        if let t = keyTap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = keySource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        keyTap = nil
        keySource = nil
    }

    // MARK: - 媒体键通道（活动型，会吞）

    private func receiveMedia(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            noteTapDisabled(channel: "媒体键", type: type)
            return Unmanaged.passUnretained(event)
        }
        guard type == kSystemDefinedEventType else {
            return Unmanaged.passUnretained(event)
        }
        guard let ns = NSEvent(cgEvent: event) else {
            logGate.log(key: "media-raw", minInterval: 1) { "亮度键·媒体键通道：type=14 但 NSEvent 构造失败" }
            return Unmanaged.passUnretained(event)
        }

        // NX_SYSDEFINED 的载荷塞在 data1 里：
        //   高 16 位 = 媒体键编号，低 16 位里再取第 8~15 位 = 按下(0x0A)/抬起(0x0B)
        let data1 = ns.data1
        let keyType = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A

        // 原始字段留痕。**这条日志的存在理由**：按键处理成功时全程无日志（只闪一下浮层），
        // 于是「根本没收到事件」和「收到了但没调成」事后完全分不出。
        logGate.log(key: "media-raw", minInterval: 1) {
            "亮度键·收到 keyType=\(keyType) flags=0x\(String(keyFlags, radix: 16))"
                + " down=\(isDown) data1=0x\(String(data1, radix: 16))"
        }

        guard keyType == NXKeyType.brightnessUp || keyType == NXKeyType.brightnessDown else {
            return Unmanaged.passUnretained(event)   // 音量、播放暂停这些不归我们管
        }

        if isDown {
            mediaHandled += 1
            lastMediaBrightnessAt = Date()          // 供 F 行通道去重
            let direction = keyType == NXKeyType.brightnessUp ? 1 : -1
            // 立刻派发出去，回调马上返回
            DispatchQueue.main.async { [weak self] in self?.onStep?(direction) }
        }

        // 按下和抬起都吞：只吞按下的话，系统那边会收到一个没有配对的抬起，
        // 而内置屏会被系统自己再改一次（这就是「按一下跳两格」）。
        return nil
    }

    // MARK: - 普通按键通道（只读型，吞不了）

    /// 看一眼是不是标准功能键上的 F1 / F2。**不修改事件**（`.listenOnly` 也改不了）。
    ///
    /// 边界：
    /// 1. 带 ⌘ / ⌃ / ⌥ 的不算（`⌘F1` 是别的应用的快捷键）；
    ///    `fn`（`maskSecondaryFn`）不算修饰键 —— 很多键盘的「多媒体模式」就是 fn+F 行。
    /// 2. **去重**：个别键盘一次按键会同时发媒体键事件和普通按键事件，那会调两次
    ///    （表现为「按一下跳两格」）。媒体键通道刚处理过就让路。
    private func observeFunctionRow(type: CGEventType, event: CGEvent) {
        guard capturesFunctionRow else { return }
        guard type == .keyDown || type == .keyUp else { return }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == VKKeyCode.f1 || code == VKKeyCode.f2 else { return }

        let flags = event.flags
        guard !flags.contains(.maskCommand),
              !flags.contains(.maskControl),
              !flags.contains(.maskAlternate) else { return }

        let isDown = (type == .keyDown)
        // 连发（按住不放）不参与去重窗口，否则按住不放就调不动了
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        logGate.log(key: "fnrow-raw", minInterval: 1) {
            "亮度键·收到（标准功能键）keyCode=\(code) \(isDown ? "按下" : "抬起")"
                + (isRepeat ? "（连发）" : "")
        }

        if let t = lastMediaBrightnessAt, Date().timeIntervalSince(t) < 0.06 { return }

        guard isDown else { return }
        functionRowHandled += 1
        let direction = (code == VKKeyCode.f2) ? 1 : -1
        DispatchQueue.main.async { [weak self] in self?.onStep?(direction) }
    }

    // MARK: - 看门狗

    /// tap 被系统停用。立即恢复；但**60 秒内连停 3 次就主动退出接管**。
    ///
    /// 为什么要主动退：停用/超时意味着有东西在阻塞事件回调，而在这段时间里
    /// **用户的键盘输入会被系统扣住**。宁可失去这个功能，不能连累键盘。
    /// 上一次的教训（1.6.3）就是硬撑着不认输，用户只能靠命令行 `pkill` 自救。
    private func noteTapDisabled(channel: String, type: CGEventType) {
        let why = (type == .tapDisabledByTimeout) ? "主线程超时" : "被用户输入停用"
        let now = Date()
        disabledAt.append(now)
        disabledAt.removeAll { now.timeIntervalSince($0) > 60 }

        if let t = mediaTap { CGEvent.tapEnable(tap: t, enable: true) }
        if let t = keyTap { CGEvent.tapEnable(tap: t, enable: true) }

        let count = disabledAt.count
        logGate.log(key: "disabled", minInterval: 5) {
            "亮度键：\\(channel)通道被系统停用（\(why)），已自动恢复（本次窗口内第 \(count) 次）"
        }

        guard count >= 3 else { return }
        autoStopped = true
        autoStopReason = "60 秒内被停用 \(count) 次（\(why)）"
        stop()
        // 这一条要**同步**写：它是保护性动作，必须落盘可查
        DisplayManager.shared.ruleLog("亮度键：已自动关闭接管以保护键盘 —— \(autoStopReason!)。"
                                      + "菜单里那行开关可手动重试")
    }

    // MARK: - 诊断

    /// 吞键范围（印在自检里，让人一眼看到"这功能碰不到打字"）
    var swallowScope: String {
        if mediaTap == nil { return "未接管（没有监听）" }
        if capturesFunctionRow, keyTap != nil {
            return "仅亮度媒体键（普通按键走只读通道，吞不了）"
        }
        return "仅亮度媒体键"
    }

    /// 自检那一行
    var diagnosticLine: String {
        guard !autoStopped else {
            return "已自动关闭（保护键盘）—— \(autoStopReason ?? "原因不明")"
        }
        guard Self.isTrusted else { return "未授权（需要辅助功能权限）" }
        guard isRunning else { return "未启动（开关关着或启动失败）" }
        var s = "已接管（媒体键 \(mediaHandled) 次"
        if capturesFunctionRow {
            s += keyTap != nil
                ? "，标准 F1/F2 \(functionRowHandled) 次"
                : "，标准 F1/F2 未接：\(functionRowError ?? "未知原因")"
        }
        return s + "）"
    }
}
