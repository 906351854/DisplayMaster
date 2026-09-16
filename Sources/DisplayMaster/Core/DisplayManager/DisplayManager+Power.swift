import AppKit
import CoreGraphics
import IOKit
import IOKit.pwr_mgt

extension DisplayManager {
    // MARK: - 开关显示器

    /// 打开 / 关闭一台显示器。
    ///
    /// 这里刻意**不相信 API 的返回值，只相信观测结果**。踩过的两个坑：
    ///
    ///   1. `CGCompleteDisplayConfiguration` 可能返回失败，但显示配置其实已经生效
    ///      —— 屏幕亮了，代码却以为没成功，于是「已关闭」记录留着不删，
    ///      菜单里就一直多一张灰卡片。
    ///   2. 显示器重新上线时系统会分配**新的 displayID**，按旧 id 记账永远对不上。
    ///
    /// 所以：动作发出去之后轮询在线列表，按「原 id 上线」或「出现了新的显示器」来判定，
    /// 判定成功就把记录删掉；失败则保留入口让用户还能再点一次。
    @discardableResult
    func setEnabled(_ id: CGDirectDisplayID, _ on: Bool, name: String = "", force: Bool = false) -> Bool {
        guard PrivateAPI.shared.configureDisplayEnabled != nil else { return false }

        // 安全保护：绝不允许关掉最后一台，否则用户会面对全黑。
        // force 只给命令行诊断用（要复现「外接屏消失」就得能关掉当前唯一在线的屏）。
        if !on, !force, onlineIDs().count <= 1 { return false }

        // 屏幕睡着的时候系统会拒绝改显示配置（实测 CGCompleteDisplayConfiguration
        // 直接返回 1014，而不是 0）。用户既然能点到菜单，人就在机器前 ——
        // 先把屏幕唤醒，这既是符合预期的行为，也是让这次操作能生效的前提。
        let wasAsleep = displaysAsleep()
        if wasAsleep { wakeDisplays() }

        let before = onlineIDs()
        // 关闭之前先把这些记下来 —— 一旦关掉，这几个查询就全部取不到了。
        // 「是不是内屏」也必须在这时候问：显示器离线后 CGDisplayIsBuiltin 会返回垃圾值，
        // 实测外接屏会被判成内置屏，而内屏的标记正是「拔线后把谁开回来」的唯一依据。
        let hw = hardwareID(id)
        let wasBuiltin = CGDisplayIsBuiltin(id) != 0

        // 关闭前的快照（见 DisabledDisplay 里那一段）：屏幕一下线，分辨率、亮度、
        // HiDPI 状态就全都查不到了，而菜单里那张卡还得把它们显示出来。
        var snapshot: DisabledDisplay?
        if !on {
            let item = displays().first { $0.id == id }
            let mode = CGDisplayCopyDisplayMode(id)
            snapshot = DisabledDisplay(
                name: name.isEmpty ? "显示器" : name,
                vendor: hw.vendor, model: hw.model, serial: hw.serial,
                isBuiltin: wasBuiltin,
                logicalWidth: item?.logicalWidth ?? mode?.width ?? 0,
                logicalHeight: item?.logicalHeight ?? mode?.height ?? 0,
                pixelWidth: item?.pixelWidth ?? mode?.pixelWidth ?? 0,
                pixelHeight: item?.pixelHeight ?? mode?.pixelHeight ?? 0,
                refreshRate: mode?.refreshRate ?? 0,
                brightness: item.flatMap { brightness(of: $0) },
                hidpi: item.map { isHiDPI($0) } ?? false
            )
        }

        var applied = commitDisplayConfiguration(id, on)
        if !applied && wasAsleep {
            // 唤醒本身要花点时间，等它真醒过来再补一次
            _ = waitUntil({ !self.displaysAsleep() }, timeout: 2.5)
            applied = commitDisplayConfiguration(id, on)
        }

        if on {
            if waitForDisplayOnline(id, hardware: hw, before: before) {
                disabled.removeValue(forKey: id)
                reconcileDisabled()
                saveDisabled()
                return true
            }
            // 没观测到上线：记录保留，用户还能再点一次
            return applied
        }

        // 关闭：同样以观测为准 —— 没真的关掉就不该记成「已关闭」
        if waitUntil({ !self.onlineIDs().contains(id) }, timeout: 2.0) {
            disabled[id] = snapshot ?? DisabledDisplay(name: name.isEmpty ? "显示器" : name,
                                                       vendor: hw.vendor, model: hw.model,
                                                       serial: hw.serial, isBuiltin: wasBuiltin)
            saveDisabled()
            return true
        }
        return false
    }

    /// 提交一次「启用/禁用」显示配置。
    /// 返回值**不可信**：屏幕睡眠时会报 1014、配置却可能已经生效；反过来也可能报成功而没生效。
    /// 所以调用方一律用在线列表复核。
    private func commitDisplayConfiguration(_ id: CGDirectDisplayID, _ on: Bool) -> Bool {
        guard let fn = PrivateAPI.shared.configureDisplayEnabled else { return false }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg else { return false }
        if fn(c, id, on) != 0 {
            CGCancelDisplayConfiguration(c)
            return false
        }
        return CGCompleteDisplayConfiguration(c, .forSession) == .success
    }

    /// 是否有显示器正睡着
    func displaysAsleep() -> Bool {
        onlineIDs().contains { CGDisplayIsAsleep($0) != 0 }
    }

    /// 诊断用：是否有显示器正睡着
    func debugDisplaysAsleep() -> Bool { displaysAsleep() }

    /// 笔记本是不是合着盖子。
    ///
    /// 这个判断只为一件事：**合盖时不要去「救」内屏**。
    ///
    /// 合盖之后 macOS 会把内屏从显示配置里摘掉（clamshell），于是「内屏不在线」
    /// 这个状态和「内屏被本应用关掉了」长得一模一样。要是不加区分地去开它：
    /// 合盖时内屏本来就不会亮（面板不亮），救援**一点收益都没有**；
    /// 而 `setEnabled` 发现屏幕睡着时会先声明一次用户活动把它叫醒 ——
    /// 电脑装进包里的时候这样每 10 秒来一次，就是白白发热耗电。
    ///
    /// 反过来也安全：开盖会触发一次显示配置变化，那时再救一点不迟；
    /// 通知万一丢了，还有下一次巡检兜着。
    ///
    /// 台式机（Mac mini / Studio / iMac）没有这个属性，读不到就是没合盖。
    func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                 IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(service,
                                                        "AppleClamshellState" as CFString,
                                                        kCFAllocatorDefault, 0) else { return false }
        return (prop.takeRetainedValue() as? NSNumber)?.boolValue ?? false
    }

    /// 唤醒睡眠中的显示器（声明一次用户活动，等价于用户动了下鼠标）
    @discardableResult
    private func wakeDisplays(holdFor seconds: TimeInterval = 3) -> Bool {
        var assertionID: IOPMAssertionID = 0
        let r = IOPMAssertionDeclareUserActivity("\(AppInfo.name) 唤醒屏幕" as CFString,
                                                 kIOPMUserActiveLocal, &assertionID)
        guard r == kIOReturnSuccess else { return false }
        defer { if assertionID != 0 { IOPMAssertionRelease(assertionID) } }
        return waitUntil({ !self.displaysAsleep() }, timeout: seconds)
    }

    /// 等「打开」真正生效。三种判定都算成功：
    /// 原 id 上线 / 出现了新的 displayID / 新 id 的 EDID 与记录的相符。
    private func waitForDisplayOnline(_ id: CGDirectDisplayID,
                                      hardware: (vendor: UInt32, model: UInt32, serial: UInt32),
                                      before: Set<CGDirectDisplayID>) -> Bool {
        waitUntil({
            let now = self.onlineIDs()
            if now.contains(id) { return true }
            let fresh = now.subtracting(before)
            guard !fresh.isEmpty else { return false }
            // 记录了硬件信息的（新格式）：必须 EDID 对得上才算
            if hardware.vendor != 0 || hardware.model != 0 {
                for f in fresh {
                    let h = self.hardwareID(f)
                    if h.vendor == hardware.vendor && h.model == hardware.model
                        && (hardware.serial == 0 || h.serial == hardware.serial) {
                        return true
                    }
                }
                return false
            }
            // 没有硬件信息（1.0.x 的旧记录）：只多出一台就认为就是它
            return fresh.count == 1
        }, timeout: 2.5)
    }

    /// 轮询等待条件成立。用 RunLoop 让步而不是 sleep：
    /// 切换显示器期间系统要处理一堆 window server 事件，纯 sleep 会把菜单卡住。
    func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        }
        return predicate()
    }
}
