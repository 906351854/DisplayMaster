import AppKit
import CoreGraphics
import IOKit
import IOKit.pwr_mgt

/// 内屏救援的重试与巡检节奏。
///
/// 单独提成顶层类型的原因同 `CommonResolutions`：extension 不能新增存储属性。
private enum BuiltinRestoreTiming {
    /// 重试间隔（秒）。拔线那一刻系统的显示配置还在重建，这时候改配置失败率不低 ——
    /// 而失败的代价是一块黑屏，所以不能试一次就放弃。
    static let backoff: [TimeInterval] = [0.5, 1.0, 2.0, 4.0, 8.0, 15.0]

    /// 巡检间隔。
    ///
    /// 1.4.0 是 60 秒，1.4.1 收到 10 秒：这个功能唯一的硬承诺是「拔线必须亮屏」，
    /// 而通知是有可能不来的（系统正在重建配置、应用刚起来还没注册）。
    /// 一次检查只是问一遍「现在该不该救」，代价远小于让用户对着黑屏等一分钟。
    static let monitorInterval: TimeInterval = 10
}

extension DisplayManager {
    // MARK: - 有外接屏时自动关闭内置屏

    /// 开关本身（持久化）。打开之后，接上外接屏就关掉笔记本内屏，拔掉再开回来。
    var autoDisableBuiltinWhenExternal: Bool {
        get { Self.prefs.bool(forKey: DefaultsKey.autoDisableBuiltinWhenExternal) }
        set { Self.prefs.set(newValue, forKey: DefaultsKey.autoDisableBuiltinWhenExternal) }
    }

    /// 判定规则的输入。
    ///
    /// 特意抽成独立结构体：显示器插拔没法在命令行里模拟，而"拔掉外接屏要把内屏开回来"
    /// 这条分支一旦写错就是一块黑屏。把输入抽出来之后，全部情形都能脱离真实硬件走一遍
    /// （见 `--auto-scenarios`）。
    struct AutoBuiltinInput {
        var switchOn: Bool
        var asleep: Bool
        /// 笔记本是不是合着盖子。
        ///
        /// 合盖时 macOS 会把内屏从显示配置里摘掉（clamshell），得到的状态和
        /// 「内屏被本应用关掉」一模一样。**这时候不能去救**：内屏本来就不会亮
        /// （面板不亮），救援没有收益，而叫醒屏幕的动作在包里就是白白发热。
        /// 开盖会触发一次显示配置变化，那时再救一点不迟。
        var lidClosed: Bool = false
        /// 当前在线的外接屏数量。
        ///
        /// **不算虚拟屏和占位屏**（随航残影之类，见 `isPhantomDisplay`）：
        /// 它们 `CGDisplayIsBuiltin` 返回 0，当成外接屏的话这条规则就永远不触发，
        /// 而用户面前其实一块能看的屏都没有。
        var externalCount: Int
        /// 内屏此刻在不在线
        var builtinOnlineID: CGDirectDisplayID?
        var builtinOnlineName: String = ""
        /// 内屏是不是正被本应用关着
        var builtinDisabledID: CGDirectDisplayID?
        var builtinDisabledName: String = ""
        /// 历史见过的内屏 id（`knownBuiltinIDs`，最近的在前）。只在上面两条都没了的时候用
        var knownBuiltinIDs: [CGDirectDisplayID] = []
    }

    /// 自动规则「打算做什么」。只算不做，菜单提示和命令行诊断共用这一套判定，
    /// 避免出现「诊断说会关、实际却不动」这种两套逻辑打架的情况。
    struct AutoBuiltinPlan {
        enum Kind: Equatable {
            case idle                 // 什么都不用做
            case disableBuiltin       // 该关掉内屏
            case enableBuiltin        // 该把内屏开回来
        }
        let kind: Kind
        let displayID: CGDirectDisplayID?
        let displayName: String
        /// 这么决定的理由，直接是人话，可以原样打印给用户
        let reason: String
        /// 要打开内屏时，按顺序试的候选 id（第一项就是 `displayID`）。
        ///
        /// 为什么要一串而不是一个：内屏的 displayID 会变，而记录和历史都可能过期。
        /// 试不中的 id 只是失败一次，代价远小于「一块屏都开不回来」。
        /// 关内屏时为空 —— 关的时候屏就在眼前，id 必然是准的。
        var candidateIDs: [CGDirectDisplayID] = []

        static func idle(_ reason: String) -> AutoBuiltinPlan {
            AutoBuiltinPlan(kind: .idle, displayID: nil, displayName: "", reason: reason)
        }
    }

    /// 判定核心：只吃输入、只吐结论，不碰任何系统状态。所有分支都收在这里。
    static func decide(_ i: AutoBuiltinInput) -> AutoBuiltinPlan {
        // ================= ① 黑屏救援：与开关无关，优先级最高 =================
        // 「没有外接屏 + 内屏也不在线」= 用户面前一块能看的屏都没有。
        //
        // 这里**刻意不检查开关**。开关管的是「有外接屏时要不要顺手关掉内屏」
        // 这个偏好；而此刻的问题不是偏好，是黑屏。1.4.0 及更早把这一整段放在
        // `guard switchOn` 后面，于是还有第二条黑屏路径：开关关着的人，
        // 手动在内屏那张卡上把它关掉（外接屏插着，这是允许的），再拔线 ——
        // 规则只会说一句「开关没打开」，然后就什么都不做了。
        if i.externalCount == 0 {
            if i.builtinOnlineID != nil {
                // 内屏好端端在位，没有故障。**必须在这里就返回**：
                // 掉到下面「有外接屏才关内屏」的逻辑里会把内屏关掉，
                // 那就等于亲手造一次黑屏。
                return .idle("没有外接屏，内屏保持打开")
            }

            // 合盖时内屏不在线是**正常的**（clamshell 把它摘掉了），不是故障。
            // 这里返回之后，开盖会触发配置变化再评估一次，不会漏。
            guard !i.lidClosed else {
                return .idle("合盖状态，内屏不在线属正常，等开盖再说")
            }

            // 内屏的 id 优先取「已关闭」记录（那是本应用关的，最可信），
            // 后面跟上历史见过的内屏 id、名字缓存里像内屏的 id 兜底。
            // 少一层候选，记的那条一旦过期就彻底开不回来了。
            var candidates: [CGDirectDisplayID] = []
            if let id = i.builtinDisabledID { candidates.append(id) }
            for id in i.knownBuiltinIDs where !candidates.contains(id) { candidates.append(id) }

            guard let first = candidates.first else {
                return .idle("没有外接屏，内屏也不在线，且拿不到内屏的 displayID")
            }
            let fromRecord = i.builtinDisabledID != nil
            // 同样刻意**不看 asleep**：屏幕睡眠时不开内屏，用户就真的什么都看不到。
            // 「多亮一块屏」和「面对黑屏」之间只能选前者。
            return AutoBuiltinPlan(
                kind: .enableBuiltin, displayID: first,
                displayName: fromRecord ? i.builtinDisabledName : "内置屏",
                reason: fromRecord
                    ? "没有外接屏了，内屏却不在线 —— 把内屏开回来"
                    : "没有外接屏了，内屏不在线（关闭记录已丢，用记住的内屏 id 兜底）",
                candidateIDs: candidates
            )
        }

        // ================= ② 以下都是「有外接屏」的情况 =================
        guard i.switchOn else { return .idle("开关没打开") }

        // 睡眠时改显示配置系统会拒绝，硬来还会把屏幕平白唤醒，所以等醒过来再说。
        guard !i.asleep else { return .idle("屏幕正在睡眠，不打扰它") }
        guard let id = i.builtinOnlineID else {
            return .idle("外接屏已接入，内屏本来就没开")
        }
        return AutoBuiltinPlan(kind: .disableBuiltin, displayID: id,
                               displayName: i.builtinOnlineName,
                               reason: "已接上 \(i.externalCount) 台外接屏")
    }

    /// 用真实状态拼出输入，交给 `decide`。加 --auto-test 时打印的就是它。
    func autoBuiltinPlan() -> AutoBuiltinPlan {
        let list = displays()
        let builtin = list.first { $0.isBuiltin }
        // 挑「内屏」那条记录：先认 id 与记住的内屏一致的那条，认不到才退回任意一条内置记录。
        // 多这一层是因为记录里可能同时存在被误标的内屏条目（老版本在显示器离线后
        // 查 CGDisplayIsBuiltin 拿到过错误结果），挑错会把外接屏当成内屏去开。
        let record = disabled.first { $0.value.isBuiltin && $0.key == knownBuiltinID }
            ?? disabled.first { $0.value.isBuiltin }

        // 救援时要挨个试的候选：历史内屏 id，再补上名字缓存里像内屏的。
        // 名字缓存排在最后 —— 它是纯启发，只配当最后的兜底。
        var known = knownBuiltinIDs
        for id in Self.builtinIDsFromNameCache() where !known.contains(id) { known.append(id) }

        return Self.decide(AutoBuiltinInput(
            switchOn: autoDisableBuiltinWhenExternal,
            asleep: displaysAsleep(),
            lidClosed: isLidClosed(),
            externalCount: list.filter { !$0.isBuiltin }.count,
            builtinOnlineID: builtin?.id,
            builtinOnlineName: builtin?.name ?? "",
            builtinDisabledID: record?.key,
            builtinDisabledName: record?.value.name ?? "",
            knownBuiltinIDs: known
        ))
    }

    /// 按候选顺序把内屏开回来。返回是否真的开了。
    ///
    /// 候选是一个列表而不是一个 id：记录和历史都可能过期，而这条路的另一端
    /// 是「用户一块能看的屏都没有」。第一个候选（关闭记录里那条）几乎总是对的，
    /// 后面的只是保险 —— 试不中的 id 不对应任何显示器，只会干脆地失败。
    private func openBuiltin(plan: AutoBuiltinPlan, source: String) -> Bool {
        var ids = plan.candidateIDs
        if ids.isEmpty, let one = plan.displayID { ids = [one] }
        guard !ids.isEmpty else { return false }

        for (n, id) in ids.enumerated() {
            if setEnabled(id, true) {
                ruleLog("[\(source)] 已打开 \(plan.displayName)(id=\(id)) —— \(plan.reason)")
                return true
            }
            // 最后一个失败没必要再刷一行，下面统一报
            if n + 1 < ids.count {
                ruleLog("[\(source)] 候选 id=\(id) 没开成，换下一个（共 \(ids.count) 个）")
            }
        }
        ruleLog("[\(source)] \(ids.count) 个候选都没开成（\(plan.reason)）")
        return false
    }

    /// 按规则办事。
    ///
    /// - Parameters:
    ///   - force: true 时忽略「外接屏有没有刚变化过」这一层，直接把当前该做的做掉
    ///     （用户刚打开开关、应用刚启动、或巡检时用）。
    ///   - source: 谁触发的。只进日志，事后对时间线用。
    /// - Returns: 真的改动了显示配置才返回 true。
    @discardableResult
    func applyAutoBuiltinRule(force: Bool = false, source: String = "未标注") -> Bool {
        let plan = autoBuiltinPlan()

        // ---- 该把内屏开回来：不设任何前置条件，**也不看开关** ----
        // 这不是「用户的一个动作」，而是一个必须修好的故障状态：用户面前没有屏幕，
        // 也没法打开菜单去点「重新扫描显示器」，只能等人来救。所以只要判定要开，
        // 每一次评估都真去开一次，失败就重试。
        //
        // 不看开关是 1.4.1 改的，见 `decide` 里那段：开关关着的人手动关掉内屏再拔线，
        // 同样会黑屏。开关管的是偏好，不是要不要救人。
        if plan.kind == .enableBuiltin {
            lastExternalPresent = displays().contains { !$0.isBuiltin }
            if openBuiltin(plan: plan, source: source) { return true }
            scheduleBuiltinRestore(step: 0)
            return false
        }

        guard autoDisableBuiltinWhenExternal else {
            lastExternalPresent = nil       // 开关关了就别留着旧记忆，免得下次打开时误判
            return false
        }

        // ---- 其余情况：屏幕睡眠时一律按兵不动，而且**不更新记忆** ----
        // 不更新记忆这点很关键：假设接上外接屏的那一刻屏幕正好睡着，若把这轮记成
        // 「已处理」，醒来后 prev == hasExternal，就再也没人去关内屏了。
        if displaysAsleep() {
            if force { ruleLog("[\(source)] 屏幕睡眠中，本轮跳过") }
            return false
        }

        let hasExternal = displays().contains { !$0.isBuiltin }
        let prev = lastExternalPresent
        lastExternalPresent = hasExternal

        // 关内屏只在外接屏「刚接上」的那一下动手，平时保持安静 ——
        // 这样用户临时把内屏开回来干活，不会被规则立刻打回去。
        let edge = force || prev == nil || prev != hasExternal
        guard edge else { return false }
        if force, plan.kind == .idle {
            ruleLog("[\(source)] 检查完毕，无需动作（\(plan.reason)）")
            return false
        }
        guard plan.kind == .disableBuiltin, let id = plan.displayID else { return false }

        let ok = setEnabled(id, false, name: plan.displayName)
        ruleLog("[\(source)] "
                + (ok ? "已关闭 \(plan.displayName)(id=\(id))" : "关闭 \(plan.displayName)(id=\(id)) 失败")
                + " —— \(plan.reason)")
        return ok
    }

    // MARK: - 打开内屏失败后的重试

    /// 只做「黑屏救援」这一件事，别的一概不碰 —— 守护进程（--rescue-daemon）专用。
    ///
    /// 完整规则（applyAutoBuiltinRule）里还有「有外接屏时关掉内屏」这个**偏好**，
    /// 那是 GUI 应用的事：GUI 没运行就不该有人去关屏。守护进程是最后一道保险，
    /// 它的职责清单里只有一条：用户面前一块屏都没有时，把内屏开回来。
    /// 这个动作是幂等的 —— 内屏已经在线时判定就是 idle，天然和 GUI 的规则不冲突。
    @discardableResult
    func rescueBuiltinIfNeeded(source: String) -> Bool {
        let plan = autoBuiltinPlan()
        guard plan.kind == .enableBuiltin else { return false }
        if openBuiltin(plan: plan, source: source) { return true }
        scheduleBuiltinRestore(step: 0)
        return false
    }

    private func scheduleBuiltinRestore(step: Int) {
        if step == 0 { restoreChain += 1 }
        let myChain = restoreChain

        guard step < BuiltinRestoreTiming.backoff.count else {
            ruleLog("重试 \(BuiltinRestoreTiming.backoff.count) 次仍未成功，交给巡检继续兜底")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + BuiltinRestoreTiming.backoff[step]) { [weak self] in
            // 不检查开关：重试只可能是在救内屏（见 applyAutoBuiltinRule 开头）
            guard let self, myChain == self.restoreChain else { return }
            // 重新判定：也许这期间内屏已经被系统或用户打开了
            let plan = self.autoBuiltinPlan()
            guard plan.kind == .enableBuiltin else {
                self.ruleLog("重试前复查：内屏已不需要打开，停止重试")
                return
            }
            // 换下一轮时照样把所有候选过一遍 —— id 变了也能认出来
            if self.openBuiltin(plan: plan, source: "重试第 \(step + 1) 次") { return }
            self.scheduleBuiltinRestore(step: step + 1)
        }
    }

    // MARK: - 低频兜底巡检

    /// 低频兜底巡检。
    ///
    /// 正常的触发点是「配置变化」通知，但通知有丢的可能（系统正在切换配置、
    /// 应用刚启动还没注册、或者干脆没发）。而这个功能失效的代价是黑屏，
    /// 所以再加一层兜底：每 10 秒看一眼，**只有真的处于「没有外接屏、内屏却不在线」
    /// 这个故障态时才动手**，其余时候这次检查什么也不做。
    ///
    /// 1.4.1 起不再要求「自动关内屏」开关打开 —— 救援和那个偏好是两回事
    /// （见 `decide`），关着开关的人一样可能黑屏。只在机器根本没有内屏
    /// （Mac mini / Studio 这类）时才不装这个定时器。
    func startSafetyMonitor() {
        guard safetyTimer == nil, !knownBuiltinIDs.isEmpty else { return }
        let t = Timer(timeInterval: BuiltinRestoreTiming.monitorInterval, repeats: true) { [weak self] _ in
            // 先过一道廉价初筛：内屏只要还在在线列表里，就绝不可能需要救援，
            // 连模式列表都不用枚举（`displays()` 那一步不便宜）。
            guard let self, self.maybeNeedsRescue() else { return }
            guard self.autoBuiltinPlan().kind == .enableBuiltin else { return }
            self.applyAutoBuiltinRule(force: true, source: "巡检")
        }
        // .common 模式：菜单跟踪、拖动期间也照常触发（默认模式会被菜单卡住）
        RunLoop.main.add(t, forMode: .common)
        safetyTimer = t
    }

    /// 巡检的初筛：内屏在线 → 一定不需要救援。只看在线列表，不看模式列表。
    ///
    /// 顺带把「合盖」也挡在这里。合盖时内屏会被 clamshell 摘掉，状态看着像故障，
    /// 但那不是故障 —— 见 `isLidClosed`。
    private func maybeNeedsRescue() -> Bool {
        if onlineIDs().contains(where: { CGDisplayIsBuiltin($0) != 0 }) { return false }
        return !isLidClosed()
    }

    // 这里刻意**没有** stopSafetyMonitor：1.4.1 起巡检和「自动关内屏」开关无关，
    // 关了开关也要继续跑（关掉开关的人一样可能黑屏）。
    // 将来真要加，请先想清楚「谁来替那类用户兜底」。
}
