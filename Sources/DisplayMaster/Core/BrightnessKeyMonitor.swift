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
final class BrightnessKeyMonitor {
    static let shared = BrightnessKeyMonitor()

    /// 一次按键：+1 变亮、-1 变暗。回调在主线程。
    var onStep: ((Int) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastDisabledLogAt: Date?

    /// 累计拦到多少次亮度键（诊断用）
    private(set) var handledCount = 0

    private init() {}

    // MARK: - 权限

    /// 有没有「辅助功能」权限。
    ///
    /// macOS 10.15 起，事件监听（尤其是能修改/吞掉事件的 default tap）必须有它；
    /// 没有的话 `tapCreate` 直接返回 nil，而且**不会**有任何报错。
    static var isTrusted: Bool { AXIsProcessTrusted() }

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

        let mask = CGEventMask(1 << kSystemDefinedEventType.rawValue)
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

        guard type == kSystemDefinedEventType, let ns = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }

        // NX_SYSDEFINED 的载荷塞在 data1 里：
        //   高 16 位 = 媒体键编号，低 16 位里再取第 8~15 位 = 按下(0x0A)/抬起(0x0B)
        let data1 = ns.data1
        let keyType = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A

        guard keyType == NXKeyType.brightnessUp || keyType == NXKeyType.brightnessDown else {
            return Unmanaged.passUnretained(event)   // 音量、播放暂停这些不归我们管
        }

        if isDown {
            handledCount += 1
            let direction = keyType == NXKeyType.brightnessUp ? 1 : -1
            // 立刻派发出去，回调马上返回（见类注释最后一段）
            DispatchQueue.main.async { [weak self] in self?.onStep?(direction) }
        }

        // 按下和抬起都吞：只吞按下的话，系统那边会收到一个没有配对的抬起。
        return nil
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
        return isRunning ? "已接管（累计处理 \(handledCount) 次）" : "未启动（开关关着或启动失败）"
    }
}
