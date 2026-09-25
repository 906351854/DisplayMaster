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
        guard direction != 0, let d = displayUnderMouse() else { return nil }

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

        return BrightnessKeyOutcome(item: d, percent: Int((next * 100).rounded()), note: nil)
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
    func logKeyFailure(_ note: String, display d: DisplayItem) {
        if let t = lastKeyFailLogAt, Date().timeIntervalSince(t) < 300 { return }
        lastKeyFailLogAt = Date()
        ruleLog("亮度键：\(d.name)(id=\(d.id)) 调不动 —— \(note)")
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
            ruleLog("亮度键：已接管 F1 / F2（按鼠标所在的那台屏调，一次 \(Int(Self.brightnessKeyStep * 100))%）")
        }
        return nil
    }

    /// 菜单里那行开关下面的状态说明。
    ///
    /// 文案要短：这一行画在 `ToggleRowView` 的副标题位置上，可用宽度只有
    /// 面板宽 - 两侧留白 - 开关簇（一台屏时约 271pt），10.5pt 差不多 25 个汉字
    /// 就到头了 —— 超了会被右边裁掉，而「被裁掉的后半句恰好是解决办法」是最亏的。
    func brightnessKeysStateLine() -> String {
        guard brightnessKeysEnabled else {
            return "关着 —— F1 / F2 交回系统原样"
        }
        guard BrightnessKeyMonitor.isTrusted else {
            return "需要「辅助功能」权限 —— 点这里授权"
        }
        return BrightnessKeyMonitor.shared.isRunning
            ? "已接管 —— 按鼠标所在的那台屏调"
            : "已授权，但监听没装上 —— 重开应用"
    }
}
