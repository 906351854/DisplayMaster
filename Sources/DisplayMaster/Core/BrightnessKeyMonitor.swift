import AppKit
import ApplicationServices
import CoreGraphics

/// 系统定义的「媒体键」事件。
///
/// 亮度键（F1/F2）**不是**普通按键：`fnState` 没打开时，键盘发的是
/// `NX_SYSDEFINED`(14) 这种系统事件，普通的 `keyDown` 那条路一次都收不到。
/// 想接管它只能建事件监听（event tap）—— 这正是「要接管亮度键就必须申请
/// 辅助功能权限」的原因，躲不掉。CoreGraphics 的 `CGEventType` 里没有这个
/// case，只能按原始值构造。
private let kSystemDefinedEventType = CGEventType(rawValue: 14)!

/// 亮度键在 `NX_SYSDEFINED` 事件里的编号（见 IOKit/hidsystem/ev_keymap.h）
private enum NXKeyType {
    static let brightnessUp = 2
    static let brightnessDown = 3
}

/// 普通按键通道上的 F1 / F2 键码（见 HIToolbox/Events.h 的 `kVK_F1` / `kVK_F2`）。
///
/// **为什么还要管这条路。** 上面那条媒体键通道只对「把 F 行当媒体键发」的键盘有效。
/// 真机上（2026-09-27）实测这台机器的第三方机械键盘**根本不发媒体键事件**：
/// 按 F1 出来的是 `keyCode=122`，按 F2 是 `keyCode=120`，一次 `NX_SYSDEFINED` 都没有。
/// 系统设置里那句「将 F1、F2 等键用作标准功能键」（`com.apple.keyboard.fnState`）
/// 管的是苹果键盘，第三方键盘的 F 行发什么由**键盘固件**决定，拨它没有任何作用。
///
/// 所以这类键盘上的 F1/F2 本来就调不了亮度（系统没接、应用也没接），
/// 想让它生效只剩一条路：连**普通按键**里的这两个键码一起拦。
private enum VKKeyCode {
    static let f1: Int64 = 122      // 变暗
    static let f2: Int64 = 120      // 变亮
}

/// 亮度键监听：拦下 F1/F2 的亮度事件，改由本应用处理。
///
/// 三个必须做对的地方，每一条都有具体的失败样子：
///
/// 1. **回调返回值决定吞不吞**：返回 `nil` 才吞掉。不吞的话系统会同时去调
///    内置屏亮度，一块屏被两方各改一次 —— 表现是「按一下跳两格」。
/// 2. **RunLoop 模式必须带 `.commonModes`**：菜单打开或拖动期间主线程跑的是
///    tracking 模式，只挂默认模式的事件源**整个期间一次都不会响应**。
///    （和 `PanelStyle` 里那条「Timer 必须挂 .common」是同一个坑。）
/// 3. **tap 会被系统单方面停掉**：主线程被占住超过 tap 的超时上限，系统就发
///    `tapDisabledByTimeout` 把它停掉且**不报错** —— 现象是「亮度键突然没反应」。
///    收到就立刻重新启用，并留一条限频日志，否则事后完全查不出来。
///
/// 另外：**回调里的活必须马上交出去异步做**。回调有硬性时间预算，超了就是上面
/// 第 3 条的停用；而我们后面要做的事（读 DDC、写 DDC，失败还会重建句柄）明显
/// 可能超。所以回调只解析按键、立刻 `async` 派发，马上返回。
///
/// **两条输入通道。** 同一个「按 F1」在不同键盘上走的路完全不同，两条都要接：
///
/// | 键盘的 F 行行为 | 发出来的事件 | 由谁处理 |
/// |---|---|---|
/// | 媒体键（苹果键盘默认、部分键盘的多媒体模式） | `NX_SYSDEFINED` keyType=2/3 | 一直处理 |
/// | **标准功能键**（多数第三方机械键盘的出厂状态） | 普通 `keyDown` keyCode=122/120 | 需打开 `capturesFunctionRow` |
///
/// 只接第一条会出现「应用日志写着已接管、权限也齐了、按键就是没反应」——
/// 因为事件压根没走那条通道（2026-09-27 实测撞上，见 `VKKeyCode` 的说明）。
final class BrightnessKeyMonitor {
    static let shared = BrightnessKeyMonitor()

    /// 一次按键：+1 变亮、-1 变暗。回调在主线程。
    var onStep: ((Int) -> Void)?

    /// 是否连「普通按键通道」的标准 F1 / F2 一起接管。
    ///
    /// 由偏好 `brightnessKeysFunctionRow` 决定（默认开）。关掉它只会失去那类键盘的
    /// 支持，媒体键通道照旧 —— 所以关掉不会让苹果键盘上的亮度键失效。
    ///
    /// 代价要说清楚：打开后**普通的 F1 / F2 会被吞掉**，别的应用再也收不到
    /// （带 ⌘ / ⌃ / ⌥ 的组合不受影响，见 `receiveFunctionRow`）。
    var capturesFunctionRow = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastDisabledLogAt: Date?

    /// 原始事件留痕的限频戳（见 `logRawEvent`）
    private var lastRawLogAt: Date?

    /// 普通按键通道留痕的限频戳（和媒体键通道分开计时，
    /// 否则两条通道会互相把对方的日志限掉，而排查时恰恰要分辨是哪条来的）
    private var lastFnRawLogAt: Date?

    /// 上一次走**媒体键通道**处理亮度键的时间（见 `receiveFunctionRow` 里的去重）
    private var lastMediaBrightnessAt: Date?

    /// 累计拦到多少次亮度键（诊断用）
    private(set) var handledCount = 0

    private init() {}

    // MARK: - 权限

    /// 有没有「辅助功能」权限。
    ///
    /// macOS 10.15 起，事件监听（尤其是能修改/吞掉事件的 default tap）必须有它；
    /// 没有的话 `tapCreate` 直接返回 nil，而且**不会**有任何报错。
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 「输入监控」权限。**和辅助功能是两个不同的 TCC 服务**，这点最容易搞混：
    ///
    /// - 辅助功能（`kTCCServiceAccessibility`）：`AXIsProcessTrusted()` 反映的是它；
    /// - 输入监控（`kTCCServiceListenEvent`）：只监听、不改事件的 tap 需要它。
    ///
    /// 为什么要单独报出来：真机上出现过「辅助功能已给、tap 也建成了、日志写着已接管、
    /// 但按 F1 毫无反应」这一组合（2026-09-27）。那种情况唯一的解释就是
    /// **tap 存在却收不到事件**，而这两个权限的值是仅有的线索。
    static var hasListenAccess: Bool { CGPreflightListenEventAccess() }

    /// 能不能合成事件。`--key-test` 要发假按键，靠的就是它；
    /// 它和「能不能拦到真按键」是两件事，别混着看。
    static var hasPostAccess: Bool { CGPreflightPostEventAccess() }

    /// 弹系统授权对话框。
    /// 只在用户主动去拨菜单里那个开关时调用 —— 启动就弹窗是很讨厌的行为。
    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」
    static func openAccessibilitySettings() {
        let s = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    // MARK: - 起停

    var isRunning: Bool { tap != nil }

    /// 装上监听。返回 nil 表示成功，否则是失败原因（人话）。
    func start() -> String? {
        if tap != nil { return nil }
        guard Self.isTrusted else { return "没有辅助功能权限" }

        // 两条通道一起挂：系统定义事件（媒体键）+ 普通按键的按下/抬起。
        // 后者是为「F 行发标准功能键」的键盘准备的（见 VKKeyCode 的说明）；
        // 多挂这两个位不会让回调变忙 —— 系统只送我们登记的这几种类型，
        // 键盘上别的键在回调里第一道判断就被放行了。
        let mask = CGEventMask(1 << kSystemDefinedEventType.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // 必须是 defaultTap：listenOnly 吞不掉事件
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<BrightnessKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.receive(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // 走到了这里，多半是权限刚授权、进程还没拿到（重启应用即可）。
            return "系统拒绝了事件监听（刚授权的话，退出重开应用一次）"
        }

        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        source = src
        // 主线程 + .commonModes：见类注释第 2 条
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return nil
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
    }

    // MARK: - 事件处理

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 被系统停用了：先恢复，再留痕（见类注释第 3 条）
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            logDisabled(type == .tapDisabledByTimeout ? "主线程超时" : "被用户输入停用")
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown || type == .keyUp {
            return receiveFunctionRow(type: type, event: event)
        }

        guard type == kSystemDefinedEventType else {
            return Unmanaged.passUnretained(event)
        }
        guard let ns = NSEvent(cgEvent: event) else {
            logRawEvent("type=14 但 NSEvent 构造失败")
            return Unmanaged.passUnretained(event)
        }

        // NX_SYSDEFINED 的载荷塞在 data1 里：
        //   高 16 位 = 媒体键编号，低 16 位里再取第 8~15 位 = 按下(0x0A)/抬起(0x0B)
        let data1 = ns.data1
        let keyType = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A

        // 原始字段留痕。**这条日志的存在理由**：按键处理成功时全程无日志（只闪一下浮层），
        // 于是「根本没收到事件」和「收到了但没调成」事后完全分不出——
        // 2026-09-27 用户报「权限给了、日志写着已接管、按了没反应」，就卡在这里。
        logRawEvent("keyType=\(keyType) flags=0x\(String(keyFlags, radix: 16))"
                    + " down=\(isDown) data1=0x\(String(data1, radix: 16))")

        guard keyType == NXKeyType.brightnessUp || keyType == NXKeyType.brightnessDown else {
            return Unmanaged.passUnretained(event)   // 音量、播放暂停这些不归我们管
        }

        if isDown {
            handledCount += 1
            lastMediaBrightnessAt = Date()          // 供普通按键通道去重，见 receiveFunctionRow
            let direction = keyType == NXKeyType.brightnessUp ? 1 : -1
            // 立刻派发出去，回调马上返回（见类注释最后一段）
            DispatchQueue.main.async { [weak self] in self?.onStep?(direction) }
        }

        // 按下和抬起都吞：只吞按下的话，系统那边会收到一个没有配对的抬起。
        return nil
    }

    /// 普通按键通道上的 F1 / F2。
    ///
    /// 为什么要有这条路、以及它和媒体键通道的关系，见 `VKKeyCode` 与类注释。
    ///
    /// 三个必须守住的边界：
    /// 1. **带 ⌘ / ⌃ / ⌥ 的不抢**。`⌘F1`、`⌃F2` 这类是别的应用的快捷键，
    ///    抢掉等于把键盘布局改坏 —— 而这不是这个功能的意图（用户要的是「按 F1」）。
    ///    `fn`（`maskSecondaryFn`）不算，按住 fn 再按 F1 一样要生效：
    ///    很多键盘的「多媒体模式」就是 fn+F 行，用户会两种都试。
    /// 2. **抬起也要吞**，和媒体键通道同理，否则系统收到一个没有配对的按下。
    /// 3. **要么两条通道都算，要么都不算**，绝不能一次按键算两次 ——
    ///    表现是「按一下跳两格」，正是类注释第 1 条在防的事情。去重见下。
    private func receiveFunctionRow(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 没打开这个子开关时，一路放行，绝不碰任何普通按键
        guard capturesFunctionRow else { return Unmanaged.passUnretained(event) }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == VKKeyCode.f1 || code == VKKeyCode.f2 else {
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        guard !flags.contains(.maskCommand),
              !flags.contains(.maskControl),
              !flags.contains(.maskAlternate) else {
            return Unmanaged.passUnretained(event)
        }

        let isDown = (type == .keyDown)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        logFunctionRowEvent("keyCode=\(code) \(isDown ? "按下" : "抬起")"
                            + (isRepeat ? "（连发）" : ""))

        // 去重：个别键盘（尤其带厂商驱动的）一次按键会同时发媒体键事件和普通按键事件，
        // 那就会走两条路各调一次。这里只在「媒体键通道刚刚处理过」时让路，
        // 不影响按住不放的连发（连发只查媒体键，不查自己）。
        if let t = lastMediaBrightnessAt, Date().timeIntervalSince(t) < 0.06 {
            return nil
        }

        guard isDown else { return nil }        // 抬起：吞掉即可，不做事
        handledCount += 1
        let direction = (code == VKKeyCode.f2) ? 1 : -1
        DispatchQueue.main.async { [weak self] in self?.onStep?(direction) }
        return nil
    }

    /// 普通按键通道的原始留痕（限频 1 秒）。
    ///
    /// 和媒体键那条分开计时：排查时要一眼看出按键**是从哪条通道来的**，
    /// 共用限频戳会让后到的那条被前一条吃掉。
    private func logFunctionRowEvent(_ msg: String) {
        if let t = lastFnRawLogAt, Date().timeIntervalSince(t) < 1.0 { return }
        lastFnRawLogAt = Date()
        DisplayManager.shared.ruleLog("亮度键·收到（普通按键）\(msg)")
    }

    /// 收到一个系统定义事件时的原始留痕（限频 1 秒）。
    ///
    /// 限频 1 秒的含义：同一次按键的「按下 + 抬起」里，通常只有按下会被写下来 ——
    /// 而按下正是我们需要的。按住不放产生的连发也会被压成每秒一条。
    private func logRawEvent(_ msg: String) {
        if let t = lastRawLogAt, Date().timeIntervalSince(t) < 1.0 { return }
        lastRawLogAt = Date()
        DisplayManager.shared.ruleLog("亮度键·收到 \(msg)")
    }

    private func logDisabled(_ why: String) {
        if let t = lastDisabledLogAt, Date().timeIntervalSince(t) < 60 { return }
        lastDisabledLogAt = Date()
        DisplayManager.shared.ruleLog("亮度键：监听被系统停用（\(why)），已自动恢复"
                                      + "（反复出现说明主线程被长时间占住）")
    }

    /// 自检那一行
    var diagnosticLine: String {
        guard Self.isTrusted else { return "未授权（需要辅助功能权限）" }
        guard isRunning else { return "未启动（开关关着或启动失败）" }
        // 报出「接的是哪条通道」：键盘不同、该看的那条完全不同，
        // 而两种接法在「已接管」这个结论上看不出区别（2026-09-27 的坑）。
        let path = capturesFunctionRow ? "媒体键 + 标准 F1/F2" : "仅媒体键"
        return "已接管（\(path)，累计处理 \(handledCount) 次）"
    }
}
