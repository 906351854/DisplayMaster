import Foundation
import CoreGraphics

/// 自动亮度把某台外接屏的亮度改了（菜单开着时滑块就地跟手）。
/// userInfo: displayID (CGDirectDisplayID)、percent (Int 0…100)。
extension Notification.Name {
    static let autoBrightnessDidApply = Notification.Name("dmAutoBrightnessDidApply")
}

/// 外接屏自动亮度：跟随笔记本环境光传感器，同步调节所有外接显示器。
///
/// 传感器数据源见 `AmbientLight` —— macOS 27 收死了第三方直读 ALS 的所有通道，
/// 这里用的是「内置屏 ALC 亮度镜像」：系统随光线调内置屏 → 我们读它的线性亮度
/// → 按曲线映射成外接屏目标亮度 → 走现成的 DDC 节流写入落到每台外接屏。
///
/// 设计要点：
/// - **多台同时调**：一次 tick 里对所有在线外接屏套同一个目标值，逐台写入；
/// - **不与用户打架**：手动拖过滑块后有 6 秒抑制期；关掉开关只停表不回改；
/// - **降级**：内置屏离线（被自动关内屏关掉 / 合盖 / 台式机）或读数失败 →
///   保持当前亮度不动，限频记一条日志，下个 tick 再试 —— 不猜值、不抖动；
/// - **不轰炸 DDC**：死区（目标变化 < 2% 不写）+ 复用 setBrightnessThrottled
///   的写入间隔与失败自愈，2 秒的巡检周期本身就是硬上限。
extension DisplayManager {
    private static let alsTickInterval: TimeInterval = 2.0
    /// 目标亮度下限：外接屏调到极低会出现泛灰/闪烁，压住地板
    private static let alsFloor: Double = 0.12
    /// 死区：目标相对上次应用值的变化小于这个数就不动（避免 DDC 反复微调）
    private static let alsDeadband: Double = 0.02
    /// 手动调节后的抑制期
    private static let alsManualSuppress: TimeInterval = 6.0
    /// 降级日志限频
    private static let alsFailLogInterval: TimeInterval = 300.0

    var autoBrightnessExternals: Bool {
        get { Self.prefs.bool(forKey: DefaultsKey.autoBrightnessExternals) }
        set { Self.prefs.set(newValue, forKey: DefaultsKey.autoBrightnessExternals) }
    }

    /// 开关打开（或启动时已开）就启动巡检。幂等。
    /// 与「有外接屏时自动关闭内置屏」互斥：环境光读数来自内置屏，内屏被关掉
    /// 就永远降级 —— 两个都开等于让两个功能互相拆台，这里强制收敛成一个。
    func startAutoBrightnessMonitor() {
        guard autoBrightnessExternals else { return }
        if autoDisableBuiltinWhenExternal {
            autoDisableBuiltinWhenExternal = false
            ruleLog("自动亮度：与「有外接屏时自动关闭内置屏」互斥，后者已自动关闭（环境光读数需要内屏在线）")
        }
        guard alsTimer == nil else { return }
        // 首个 tick 落在 1 秒后：给 DDC 探测留一点初始化时间
        let t = Timer(timeInterval: Self.alsTickInterval, repeats: true) { [weak self] _ in
            self?.autoBrightnessTick()
        }
        alsTimer = t
        RunLoop.main.add(t, forMode: .common)
        ruleLog("自动亮度：已启动巡检（环境光 → 外接屏亮度，每 \(Int(Self.alsTickInterval)) 秒）")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.autoBrightnessTick()
        }
    }

    func stopAutoBrightnessMonitor() {
        guard let t = alsTimer else { return }
        t.invalidate()
        alsTimer = nil
        alsLastApplied.removeAll()
        ruleLog("自动亮度：已停止（保持各屏当前亮度）")
    }

    /// 用户手动拖了亮度滑块：接下来一小段时间自动亮度别插手。
    func noteManualBrightnessAdjust() {
        alsManualSuppressUntil = Date().addingTimeInterval(Self.alsManualSuppress)
    }

    /// 菜单开关翻转时走这里：落盘 + 起停巡检。
    /// 从这一侧开灯时把「自动关内屏」关掉 —— 同一条互斥规则的另一个方向。
    func setAutoBrightnessExternals(_ on: Bool) {
        autoBrightnessExternals = on
        if on && autoDisableBuiltinWhenExternal {
            autoDisableBuiltinWhenExternal = false
            ruleLog("自动亮度：与「有外接屏时自动关闭内置屏」互斥，后者已自动关闭")
        }
        if on {
            startAutoBrightnessMonitor()
        } else {
            stopAutoBrightnessMonitor()
        }
    }

    private func autoBrightnessTick() {
        guard autoBrightnessExternals else { return }
        let externals = displays(includeModes: false).filter { !$0.isBuiltin }
        guard !externals.isEmpty else { return }
        // 屏幕睡眠中不动手（唤醒后第一轮照常评估）
        guard !displaysAsleep() else { return }
        // 用户刚手动调过：让位
        if let until = alsManualSuppressUntil, Date() < until { return }

        // 环境光代理读数：拿不到就降级 —— 保持现状，限频记日志，下轮再试
        guard let level = AmbientLight.normalizedLevel() else {
            if let last = alsLastFailLog, Date().timeIntervalSince(last) < Self.alsFailLogInterval {
                return
            }
            alsLastFailLog = Date()
            ruleLog("自动亮度：暂读不到环境光（内置屏离线或系统未响应），保持当前亮度")
            return
        }
        alsLastFailLog = nil

        let target = Self.alsFloor + (1.0 - Self.alsFloor) * level
        for d in externals {
            let previous = alsLastApplied[d.id]
            if let previous, abs(target - previous) < Self.alsDeadband { continue }
            alsLastApplied[d.id] = target
            setBrightnessThrottled(d, target)
            let pct = Int((target * 100).rounded())
            // 菜单开着时让滑块跟手（观察者只改 UI，不触发写入动作）
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .autoBrightnessDidApply, object: nil,
                    userInfo: ["displayID": d.id, "percent": pct])
            }
            if previous == nil {
                ruleLog("[自动亮度] 基准写入 \(d.name)(id=\(d.id)) → \(pct)%（环境光 \(Int((level * 100).rounded()))%）")
            } else {
                let delta = Int(((target - previous!) * 100).rounded())
                ruleLog("[自动亮度] \(d.name)(id=\(d.id)) \(Int((previous! * 100).rounded()))% → \(pct)%（\(delta >= 0 ? "+" : "")\(delta)% · 环境光 \(Int((level * 100).rounded()))%）")
            }
        }
    }

    /// 诊断用（--als-test）：只读不写。返回（代理读数，目标值，各外接屏现状）。
    func autoBrightnessDiagnostic() -> (level: Double?, target: Double?, lines: [String]) {
        let level = AmbientLight.normalizedLevel()
        let target = level.map { Self.alsFloor + (1.0 - Self.alsFloor) * $0 }
        var lines: [String] = []
        for d in displays().filter({ !$0.isBuiltin }) {
            let current = brightness(of: d).map { "\(Int(($0 * 100).rounded()))%" } ?? "读不到"
            let last = alsLastApplied[d.id].map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
            lines.append("  \(d.name)(id=\(d.id))  当前 \(current)  上次自动写入 \(last)")
        }
        return (level, target, lines)
    }
}
