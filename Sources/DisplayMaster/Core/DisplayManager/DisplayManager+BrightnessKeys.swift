import AppKit
import CoreGraphics

/// 一次亮度键调整的结果（给浮层显示用）
struct BrightnessKeyOutcome {
    let item: DisplayItem
    /// 新亮度百分比；nil = 这台屏读不到亮度
    let percent: Int?
    /// 读不到时的人话说明
    let note: String?
}

extension DisplayManager {
    /// 一次按键的幅度：16 档。
    /// 和 macOS 原生亮度键的手感一致（从最暗按满 16 下到头）。
    static let brightnessKeyStep: Double = 1.0 / 16.0

    /// 「亮度键接管」开关（持久化）。
    ///
    /// 默认**开**：这个功能是用户主动要装的，装好就该能用。
    /// 没授权辅助功能时它其实是「装了不生效」—— 菜单里会明说需要授权，
    /// 而不是假装正常（见 `brightnessKeysStateLine()`）。
    var brightnessKeysEnabled: Bool {
        get {
            // 用 object(forKey:) 而不是 bool(forKey:)：后者分不清
            // 「从没设过」和「明确关掉了」，而这个开关默认必须是开。
            Self.prefs.object(forKey: DefaultsKey.brightnessKeys) as? Bool ?? true
        }
        set { Self.prefs.set(newValue, forKey: DefaultsKey.brightnessKeys) }
    }

    /// 「F1 / F2 是标准功能键时也接管」开关（持久化，默认**开**）。
    ///
    /// **为什么默认开。** 多数第三方键盘（机械键盘、非苹果外接键盘）把 F 行按
    /// 标准功能键发：按 F1 出来的是 `keyCode=122` 而不是媒体键事件。这类键盘的
    /// F1/F2 本来就调不了任何东西（系统没接、别的应用也不接），
    /// 默认关掉的话，用户装完仍然是「按了没反应」—— 正是这个功能最容易被误判成坏掉的地方。
    ///
    /// 代价很小：普通 F1 / F2 会被**同时**交给本应用和别的应用 —— 这条通道是只读监听，
    /// 按 API 契约就吞不了键。谁要是希望 F1 / F2 完全留给别的应用（终端、IDE 的功能键），
    /// 把菜单里那行关掉即可，媒体键通道照旧工作。
    var brightnessKeysFunctionRow: Bool {
        get {
            Self.prefs.object(forKey: DefaultsKey.brightnessKeysFunctionRow) as? Bool ?? true
        }
        set { Self.prefs.set(newValue, forKey: DefaultsKey.brightnessKeysFunctionRow) }
    }

    // MARK: - 目标屏

    /// 鼠标所在的那台显示器。
    ///
    /// `NSEvent.mouseLocation` 和 `NSScreen.frame` 都是「全局坐标、原点在主屏
    /// 左下角」，可以直接比。判不出来（鼠标落在我们没枚举到的条目上）就退回
    /// 主屏 —— 与系统原生亮度键「只管主显示器」的语义一致，不会出现按了没反应。
    func displayUnderMouse() -> DisplayItem? {
        let p = NSEvent.mouseLocation
        let list = displays(includeModes: false)
        for s in NSScreen.screens {
            guard s.frame.contains(p),
                  let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let d = list.first(where: { $0.id == CGDirectDisplayID(num.uint32Value) })
            else { continue }
            return d
        }
        return list.first(where: { $0.isMain }) ?? list.first(where: { !$0.isBuiltin }) ?? list.first
    }

    // MARK: - 走一步

    /// 按一次亮度键：找鼠标所在那台屏，从它当前亮度走一步。
    ///
    /// 写入走 `setBrightnessThrottled`，沿用滑块那套 I²C 节流（100ms）——
    /// 按住不放时按键事件可以到每秒几十次，直接写就是把显示器写死的经典做法。
    /// 节流会吞掉中间值，但末尾值一定会落到屏上。
    @discardableResult
    func stepBrightnessByKey(direction: Int) -> BrightnessKeyOutcome? {
        guard direction != 0 else { return nil }
        guard let d = displayUnderMouse() else {
            // 拦到键却一台屏都定位不到 —— 必须留痕，否则与「压根没拦到键」同为空白，
            // 而这两者的修法完全不同（一个是屏幕枚举，一个是事件拦截）。
            logKeyFailure("拦到了亮度键，但一台在线显示器都定位不到", display: nil)
            return nil
        }

        guard let base = brightnessBaseForKeyStep(of: d) else {
            let note = d.isBuiltin ? "内置屏亮度读不到" : (ddcNote(for: d) ?? "亮度读不到")
            logKeyFailure(note, display: d)
            return BrightnessKeyOutcome(item: d, percent: nil, note: note)
        }

        let next = Self.steppedBrightness(from: base, direction: direction)
        setBrightnessThrottled(d, next)
        keyStepLastValue[d.id] = (next, Date())
        // 手动调过就让自动亮度让位，否则两秒后它就把这一下抹平了
        noteManualBrightnessAdjust()

        // 成功也留一条痕（限频）。理由和 logKeyFailure 相反、但同样重要：
        // 这条链有五个环节（收到事件 → 拦到按键 → 找到屏 → 读出基准 → 写入），
        // 只在失败时留痕的话，「成功」和「压根没走到这里」在日志上长得一样。
        logKeyStep(d, from: base, to: next)

        return BrightnessKeyOutcome(item: d, percent: Int((next * 100).rounded()), note: nil)
    }

    /// 亮度键成功调了一次的留痕（限频 2 秒，避免按住不放刷屏）。
    func logKeyStep(_ d: DisplayItem, from: Double, to: Double) {
        if let t = lastKeyStepLogAt, Date().timeIntervalSince(t) < 2 { return }
        lastKeyStepLogAt = Date()
        ruleLog("亮度键：\(d.name)(id=\(d.id)) \(Int((from * 100).rounded()))%"
                + " → \(Int((to * 100).rounded()))%（已请求写入）")
    }

    /// 步进用的基准亮度。
    ///
    /// 不能直接拿 `brightness(of:)` 连按：外接屏那条路在**写入被节流推迟**时，
    /// 读回来的还是上一档的缓存值 —— 第二下算出的目标和第一下一样，
    /// 表现就是「按住不放，亮度不涨」。所以优先用「我们刚请求写入的值」，
    /// 超过 1.5 秒没有新按键才回落到真读 ——
    /// 这样既能连按，也能反映出别人（显示器物理按键、系统）改过的亮度。
    func brightnessBaseForKeyStep(of d: DisplayItem) -> Double? {
        if let rec = keyStepLastValue[d.id], Date().timeIntervalSince(rec.at) < 1.5 {
            return rec.value
        }
        return brightness(of: d)
    }

    /// 亮度键调不动某台屏时的限频日志。
    ///
    /// 必须留痕：否则「按了亮度键没反应」在事后来看是**完全静默**的 ——
    /// 分不清是没拦到键、拦到了但没找到目标屏、还是找到了但通道哑了。
    func logKeyFailure(_ note: String, display d: DisplayItem?) {
        if let t = lastKeyFailLogAt, Date().timeIntervalSince(t) < 300 { return }
        lastKeyFailLogAt = Date()
        let who = d.map { "\($0.name)(id=\($0.id))" } ?? "没有任何在线显示器"
        ruleLog("亮度键：\(who) 调不动 —— \(note)")
    }

    /// 纯函数：走一步并夹到 0…1。
    /// 抽出来是为了能脱离硬件跑边界用例（见 `--brightness-scenarios`）。
    static func steppedBrightness(from current: Double, direction: Int) -> Double {
        max(0, min(1, current + Double(direction) * brightnessKeyStep))
    }

    // MARK: - 开关与状态

    /// 按开关状态起停监听。幂等，返回 nil 表示成功，否则是失败原因。
    @discardableResult
    func applyBrightnessKeysSetting(log: Bool = true) -> String? {
        let monitor = BrightnessKeyMonitor.shared
        // 子开关要在起表**之前**推给监听：起表时它已经按这个值决定接不接普通按键。
        // 单独改这一项时也走这里（已经跑着的话 start() 会直接返回，值照样生效）。
        monitor.respondsToFunctionRow = brightnessKeysFunctionRow
        guard brightnessKeysEnabled else {
            let was = monitor.isRunning
            monitor.stop()
            if log, was { ruleLog("亮度键：已交回系统（F1 / F2 只调内置屏）") }
            return nil
        }
        let wasRunning = monitor.isRunning
        if let err = monitor.start() {
            if log { ruleLog("亮度键：未接管 —— \(err)") }
            return err
        }
        if log, !wasRunning {
            // 把「接的是哪条通道」写进日志：键盘不同、该看的那条完全不同，
            // 而这两种情况在「已接管」这个结论上长得一样（2026-09-27 的坑）。
            let path = monitor.isFunctionRowRunning
                ? "媒体键 + 标准 F1/F2（普通按键走只读通道，影响不到打字）"
                : "仅媒体键通道"
            ruleLog("亮度键：已接管 F1 / F2（\(path)，按鼠标所在的那台屏调，"
                    + "一次 \(Int(Self.brightnessKeyStep * 100))%）")
        }
        // F 行通道单独失败必须说出来：否则「苹果键盘能用、机械键盘不能」会被当成
        // 同一个故障，而两者的修法完全不同（一个是授权，一个是换通道）。
        // 只在这个原因**变化**时报一次 —— 轮询每 3 秒都会走到这里。
        if log {
            if let fr = monitor.functionRowError {
                if fr != lastFunctionRowErrorLogged {
                    lastFunctionRowErrorLogged = fr
                    ruleLog("亮度键：标准 F1/F2 通道没接上 —— \(fr)")
                }
            } else {
                lastFunctionRowErrorLogged = nil
            }
        }
        return nil
    }

    // MARK: - 授权后自动接管

    /// 每 3 秒看一眼：开关开着、但监听还没装上，就再试一次。
    ///
    /// **为什么必须有这个轮询。** 授权这个动作发生在**别的进程**里（系统设置），
    /// 我们的应用完全不知情。原来只有两个重试点 —— 应用被激活、打开菜单 ——
    /// 而用户去系统设置拨开关这一路，回来未必会开菜单。于是「授权了却没反应」
    /// 成了这个功能最容易被报的一种故障：两边都在等对方（2026-09-25 实测撞上）。
    ///
    /// 没授权时**什么都不做**，连日志都不打 —— 所以正常状态下这个轮询是完全安静的；
    /// 一旦用户在设置里拨开开关，最多 3 秒后就自动接管并留一条日志。
    ///
    /// 定时器必须挂 `.commonModes`：菜单打开/拖动期间主线程跑的是 tracking 模式，
    /// 只挂默认模式的定时器整个期间一次都不会响（和事件源、菜单刷新同一个坑）。
    func startBrightnessKeyWatcher() {
        guard keyWatchTimer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.retryBrightnessKeysIfNeeded()
        }
        RunLoop.main.add(t, forMode: .common)
        keyWatchTimer = t
    }

    /// 轮询的一步。抽出来是为了诊断命令能手动触发一次，不必等 3 秒。
    func retryBrightnessKeysIfNeeded() {
        guard brightnessKeysEnabled else { return }
        // `needsStart` 而不是 `!isRunning`：媒体键通道装上了、但 F 行通道因为缺
        // 「输入监控」没装上，也算没装齐 —— 那种情况下用户会去补授权，
        // 而我们得在他补完之后自动接上（这是这个轮询存在的全部理由）。
        guard BrightnessKeyMonitor.shared.needsStart else { return }
        // 没授权就静默等待：这里每 3 秒都会走一遍，打日志会刷屏，
        // 而且「还没授权」是用户已知的状态，不值得反复说。
        guard BrightnessKeyMonitor.isTrusted else { return }
        applyBrightnessKeysSetting()
    }

    func stopBrightnessKeyWatcher() {
        keyWatchTimer?.invalidate()
        keyWatchTimer = nil
    }

    /// 菜单里那行开关下面的状态说明。
    ///
    /// 文案要短：这一行画在 `ToggleRowView` 的副标题位置上，可用宽度只有
    /// 面板宽 - 两侧留白 - 开关簇（一台屏时约 271pt），10.5pt 差不多 25 个汉字
    /// 就到头了 —— 超了会被右边裁掉，而「被裁掉的后半句恰好是解决办法」是最亏的。
    func brightnessKeysStateLine() -> String {
        let m = BrightnessKeyMonitor.shared
        guard brightnessKeysEnabled else {
            return "关着 —— F1 / F2 交回系统原样"
        }
        // 看门狗主动退出接管时要说清楚「是我们自己退的」，而不是让用户
        // 在一堆「已授权却没用」里猜（1.6.3 的教训：接管硬撑着不认输，
        // 用户的键盘被连累，事后只能靠命令行自救）。
        if m.autoStopped {
            return "已自动关闭（保护键盘）—— 点这里重试"
        }
        guard BrightnessKeyMonitor.isTrusted else {
            return "需要「辅助功能」权限 —— 点这里授权"
        }
        guard m.isRunning else {
            return "已授权，但监听没装上 —— 点这里重试"
        }
        if brightnessKeysFunctionRow, !m.isFunctionRowRunning, m.functionRowError != nil {
            // 只有**确实尝试过、并且失败了**才这么说。判据是 functionRowError 非空：
            // 它为空而通道不在，只可能是「压根没把子开关推给监听」—— 那只出现在
            // 诊断进程里（2026-09-27 自检就因此误报成「缺输入监控权限」）。
            return "标准 F1/F2 需「输入监控」权限"
        }
        return "已接管 —— 按鼠标所在的那台屏调"
    }
}
