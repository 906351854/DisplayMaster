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
        // 每次调用都重算，别让上一次的结果留在那儿骗调用方
        lastEnableWasRejected = false
        lastEnableFailureDetail = nil
        guard PrivateAPI.shared.configureDisplayEnabled != nil else {
            lastEnableFailureDetail = "私有符号 CGSConfigureDisplayEnabled 取不到"
            return false
        }

        // 安全保护：绝不允许关掉最后一台，否则用户会面对全黑。
        // force 只给命令行诊断用（要复现「外接屏消失」就得能关掉当前唯一在线的屏）。
        if !on, !force, onlineIDs().count <= 1 {
            lastEnableFailureDetail = "拒绝关闭最后一台在线显示器"
            return false
        }

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
            let item = displays(includeModes: false).first { $0.id == id }
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

        var outcome = commitDisplayConfiguration(id, on)
        if !outcome.isApplied {
            // 先声明一次用户活动把屏幕叫醒，再补提交一次。
            //
            // ⚠️ 这里刻意**不再**用 `wasAsleep` 当条件。`displaysAsleep()` 只查
            // **在线**的那些屏，而救援场景恰恰是「在线列表为空」——那时它恒为 false，
            // 于是**最需要唤醒的场合反而永远不会唤醒**。2026-09-18 那次连续 15 小时
            // 开不回内屏，最可疑的就是卡在这一环：屏幕睡着 → 窗口服务器拒绝改配置
            // → 没人叫醒它 → 下一次还是拒绝。
            //
            // 打开/关闭显示器这个动作本身已经表达了「有人想要一块亮着的屏」，
            // 唤醒它没有副作用；而失败一次就放弃的代价可能是一整块黑屏。
            if wakeDisplays(holdFor: 2.5) {
                outcome = commitDisplayConfiguration(id, on)
            }
        }

        if on {
            // 窗口服务器**当场拒绝**了这个 id（在它眼里这根本不是一台显示器，
            // 配置已被 CGCancelDisplayConfiguration 撤销）→ 没有可等的对象。
            //
            // 这一条不是微优化：`waitForDisplayOnline` 会按 2.5 秒轮询在线列表，
            // 期间 RunLoop 每 80ms 醒一次，进程完全进不了空闲。救援逻辑在
            // 「内屏已经不可能开回来」的状态下会反复走到这里（2026-09-18 那次
            // 92 分钟试了 944 次），那点「反正也不占 CPU」的等待就是异常耗电的来源。
            if outcome.isRejected, !onlineIDs().contains(id) {
                lastEnableWasRejected = true
                lastEnableFailureDetail = "\(outcome.rejectReason ?? "被窗口服务器拒绝")；"
                    + "拒绝时在线 [\(Self.idList(onlineIDs()))]"
                return false
            }
            if waitForDisplayOnline(id, hardware: hw, before: before) {
                disabled.removeValue(forKey: id)
                reconcileDisabled()
                saveDisabled()
                return true
            }
            // 没观测到上线：记录保留，用户还能再点一次
            lastEnableFailureDetail = "提交\(outcome.isApplied ? "成功" : "报错")但在 2.5 秒内"
                + "没观测到 id=\(id) 上线；此刻在线 [\(Self.idList(onlineIDs()))]"
            return outcome.isApplied
        }

        // 关闭：同样以观测为准 —— 没真的关掉就不该记成「已关闭」
        if waitUntil({ !self.onlineIDs().contains(id) }, timeout: 2.0) {
            disabled[id] = snapshot ?? DisabledDisplay(name: name.isEmpty ? "显示器" : name,
                                                       vendor: hw.vendor, model: hw.model,
                                                       serial: hw.serial, isBuiltin: wasBuiltin)
            saveDisabled()
            return true
        }
        lastEnableFailureDetail = "提交后 2 秒内 id=\(id) 仍在线 [\(Self.idList(onlineIDs()))]"
        return false
    }

    /// 提交一次「启用/禁用」显示配置的结果。
    ///
    /// 分三档而不是 Bool：这三种情况对调用方的意义完全不同。
    ///   - `applied`：窗口服务器收下并回成功。
    ///   - `maybeApplied`：收下了但 `CGCompleteDisplayConfiguration` 报错 ——
    ///     这条路的返回值本来就不可信（屏幕睡眠时报 1014 而配置其实生效了），
    ///     所以还得靠观测在线列表来定。
    ///   - `rejected`：当场拒绝，配置已被 `CGCancelDisplayConfiguration` 撤销，
    ///     什么都没发生，也没有可等的对象。带上原因字符串 —— 这个字段是
    ///     「事后能定位」和「事后只能猜」的分界线。
    private enum CommitOutcome {
        case applied
        case maybeApplied
        case rejected(String)

        var isApplied: Bool { if case .applied = self { return true }; return false }
        var isRejected: Bool { if case .rejected = self { return true }; return false }
        var rejectReason: String? { if case .rejected(let r) = self { return r }; return nil }
    }

    /// 诊断用：把一组 id 排成稳定的一行，方便日志比对。
    static func idList(_ ids: Set<CGDirectDisplayID>) -> String {
        ids.isEmpty ? "无" : ids.sorted().map(String.init).joined(separator: ",")
    }

    private func commitDisplayConfiguration(_ id: CGDirectDisplayID, _ on: Bool) -> CommitOutcome {
        guard let fn = PrivateAPI.shared.configureDisplayEnabled else {
            return .rejected("私有符号 CGSConfigureDisplayEnabled 取不到")
        }
        var cfg: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&cfg)
        guard begin == .success, let c = cfg else {
            return .rejected("CGBeginDisplayConfiguration 失败（CGError \(begin.rawValue)）")
        }
        let r = fn(c, id, on)
        if r != 0 {
            CGCancelDisplayConfiguration(c)
            return .rejected("CGSConfigureDisplayEnabled(id=\(id), on=\(on)) 返回 \(r)")
        }
        let done = CGCompleteDisplayConfiguration(c, .forSession)
        if done != .success {
            return .maybeApplied
        }
        return .applied
    }

    /// 是否有显示器正睡着
    func displaysAsleep() -> Bool {
        onlineIDs().contains { CGDisplayIsAsleep($0) != 0 }
    }

    /// 诊断用：是否有显示器正睡着
    func debugDisplaysAsleep() -> Bool { displaysAsleep() }

    /// 显示器（背光）此刻是不是亮着。
    ///
    /// 这个信号专为「黑屏救援该不该动手」准备（见 `AutoBuiltinInput.screenLit`）。
    /// 它的价值在于**不依赖显示器在不在线** —— 而最需要判断的那一刻，在线列表
    /// 恰恰是空的（只剩占位屏）：
    ///
    /// - `displaysAsleep()` 只遍历在线屏，列表空时恒答「没睡」，正好答反。
    /// - `CGDisplayIsAsleep(已知 id)` 也不行：不在列表里的 id 返回的是垃圾值，
    ///   实测 id=4/5 同时报 `builtin=Y main=Y asleep=Y`（自相矛盾），内屏 id=1
    ///   被关闭时则一律报 n。这条路 2026-09-19 实测排除。
    /// - `IOPMCopyAssertionsStatus()` 的 `PreventUserIdleSystemSleep` 计数也不行，
    ///   熄屏时它仍是 1（另有来源）。
    /// - `AppleCLCD2` 的 `IOPowerManagement.CurrentPowerState` 也不行，
    ///   熄屏时两台都还是 1。
    ///
    /// 唯一能和「熄屏」逐条对齐的是 powerd 的内部断言：屏幕亮着时它持有
    /// `"Powerd - Prevent sleep while display is on"`（type 为 PreventUserIdleSystemSleep），
    /// 熄屏那一刻释放。2026-09-19 本机核对 `pmset -g log`：该断言每一次 `Released`
    /// 都精确落在 `Display is turned off` 的同一秒，5 次全中（含自然熄屏与强制熄屏）。
    ///
    /// - Returns: `.lit` 亮着 / `.dark` 熄着 / `.unreadable(原因)` 读不到（判定应退回时间门槛）
    func screenIsLit() -> ScreenLight {
        var raw: Unmanaged<CFDictionary>?
        let ret = IOPMCopyAssertionsByProcess(&raw)
        guard ret == kIOReturnSuccess else {
            return .unreadable("IOPMCopyAssertionsByProcess 返回 \(ret)")
        }
        // 用 NSDictionary / NSArray 遍历，不用 `as? [NSNumber: [[String: Any]]]` ——
        // 后者在守护进程上下文里实测桥接不出结果（同一二进制在命令行里却可以）。
        guard let byProcess = raw?.takeRetainedValue() as NSDictionary? else {
            return .unreadable("返回值不是字典")
        }
        let wanted = kIOPMAssertionTypePreventUserIdleSystemSleep as String
        var seen = 0
        for (_, value) in byProcess {
            guard let list = value as? NSArray else { continue }
            for case let entry as NSDictionary in list {
                seen += 1
                guard (entry["AssertType"] as? String) == wanted else { continue }
                // 断言名是 Apple 硬编码的英文，不随系统语言变（本机日志是中文格式，
                // 断言名仍是英文）。这里宽松匹配 "display"，免得将来措辞微调就整个失效。
                let name = (entry["AssertName"] as? String) ?? ""
                if name.lowercased().contains("display") { return .lit }
            }
        }
        // 一条断言都看不到 = 这个上下文根本没连上 powerd，**绝不能当成「熄着」**：
        // 「熄着」会直接否决救援，一旦把连不上误判成熄着，「拔线必亮」就没了。
        // 正常时这里至少能看到几个常驻进程的断言（本机常态是 Electron 那条）。
        guard seen > 0 else {
            return .unreadable("断言列表为空（似乎连不上 powerd），此判据不可信")
        }
        return .dark
    }

    /// 诊断用：屏幕此刻的状态
    func debugScreenIsLit() -> ScreenLight { screenIsLit() }

    /// 诊断用：把屏幕状态写成一句人话（进日志、进自检）
    func describeScreenLight() -> String {
        switch screenIsLit() {
        case .lit:  return "屏幕亮着"
        case .dark: return "屏幕熄着"
        case .unreadable(let why): return "读不到（\(why)）—— 判定会退回时间门槛"
        }
    }

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
    ///
    /// ⚠️ 在线列表为空时**不能**拿 `displaysAsleep()` 的返回值当判据：它只查在线的
    /// 那些屏，一台都没有时恒为 false —— 也就是「没睡」。而「内屏被关着 + 外接屏
    /// 也掉了」正是最需要唤醒的时候，这时候答「没睡」等于永远不唤醒。
    /// 所以分两路：有屏可查就等 `CGDisplayIsAsleep` 转 false；没屏可查就给一个
    /// 固定的短等待 —— 声明用户活动之后系统需要一两秒才真正把屏幕点起来。
    @discardableResult
    private func wakeDisplays(holdFor seconds: TimeInterval = 3) -> Bool {
        var assertionID: IOPMAssertionID = 0
        let r = IOPMAssertionDeclareUserActivity("\(AppInfo.name) 唤醒屏幕" as CFString,
                                                 kIOPMUserActiveLocal, &assertionID)
        guard r == kIOReturnSuccess else { return false }
        defer { if assertionID != 0 { IOPMAssertionRelease(assertionID) } }
        if onlineIDs().isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(min(1.5, seconds)))
            return true
        }
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
    ///
    /// 步长 250ms 是权衡过的：一次等待最长 2.5 秒，80ms 的步长意味着**每次**改显示配置
    /// 都要唤醒进程 31 次 —— 而「打开内屏」失败时这条路会被走一遍又一遍（见
    /// `rescueGateAllowsAttempt`），空转的唤醒次数就是活动监视器里的能耗。
    /// 250ms 下同样一次等待只醒 10 次，而「成功」最坏也只晚 0.17 秒被发现，
    /// 相对 2.5 秒的预算可以忽略。
    func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return predicate()
    }
}
