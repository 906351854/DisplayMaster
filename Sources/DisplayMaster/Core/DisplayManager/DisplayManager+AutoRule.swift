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

    /// 「同一份输入**又**失败了一次」时用的短重试链。
    ///
    /// 为什么和上面那条不一样：链上每一次重试都要付一次 `setEnabled` 的完整代价 ——
    /// 失败那条路会在 `waitForDisplayOnline` 里按 2.5 秒轮询在线列表（实测：对一台
    /// 开不回来的显示器执行一次「打开」耗时 2.6~2.8 秒，期间 RunLoop 每 80ms 醒一次，
    /// 进程完全进不了空闲）。拉满 6 次 = 白烧 15 秒。
    ///
    /// 而这一档的情形是「输入一点没变，上一次刚刚失败」——
    /// 2026-09-18 那次 92 分钟 944 次失败，绝大多数就是这条链在重复同一个必定失败的
    /// 显示 id，也是活动监视器里 743 的 12 小时电源的直接来源。
    /// 首次失败仍然拿完整链（拔线那一刻配置还在重建，值得多试几下）。
    static let repeatBackoff: [TimeInterval] = [1.0, 3.0]

    /// 巡检间隔。
    ///
    /// 1.4.0 是 60 秒，1.4.1 收到 10 秒：这个功能唯一的硬承诺是「拔线必须亮屏」，
    /// 而通知是有可能不来的（系统正在重建配置、应用刚起来还没注册）。
    /// 一次检查只是问一遍「现在该不该救」，代价远小于让用户对着黑屏等一分钟。
    static let monitorInterval: TimeInterval = 10

    /// 连续失败后的退避阶梯（秒）。见 `rescueGateAllowsAttempt`。
    ///
    /// 只对「输入一点没变、上一次又失败了」的轮次生效。真变化（插拔、开关盖、
    /// 睡眠唤醒）会先把指纹改掉，进而立刻放行 —— 硬承诺不受影响。
    static let failBackoff: [TimeInterval] = [15, 30, 60, 300]

    /// 周期巡检最多连跳几次，跳满就强制完整复算一轮（10 秒一次 → 至少每分钟算一次）。
    ///
    /// 为什么要留这道口子而不是「输入一样就永远跳过」：指纹是「在线集合 + 睡眠 +
    /// 合盖」，而**同一份在线集合内部**也可能发生对判定有意义的变化 —— 最典型的是
    /// 外接屏刚插上时 EDID 还读不出来、被 `isPhantomDisplay` 判成占位屏，几百毫秒后
    /// EDID 可读了又变回真实屏。那一下指纹没变，但「要不要关内屏」的答案变了。
    /// 60 秒的兜底延迟对这条路径可以接受（它不涉及黑屏），省下的开销却是 6 倍。
    static let maxPeriodicSkips = 5
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
        let list = displays(includeModes: false)
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

    // MARK: - 救援闸门：别让「救不回来」变成常驻发热

    /// 当前输入的指纹：在线显示器集合 + 屏幕睡眠态 + 合盖态。
    ///
    /// 这三个恰好就是 `decide` 判定「要不要救内屏」的全部依据，而且都很便宜
    /// （几次 CG 查询 + 一次 IORegistry 读），远低于一次 `scanDisplays()` ——
    /// 后者要枚举每台屏的**全部模式列表**。
    ///
    /// 用它当指纹还顺手解决一个自激问题：我们自己那次失败的「打开」也会触发一次
    /// 显示配置变化回调，但它改不动这三样，所以不会把自己重新点着。
    func rescueInputFingerprint() -> String {
        let ids = Self.onlineDisplayList().sorted().map(String.init).joined(separator: ",")
        return "\(ids)|\(displaysAsleep() ? "sleep" : "awake")|\(isLidClosed() ? "closed" : "open")"
    }

    /// 现在允许动手救内屏吗？
    ///
    /// 「开内屏」这条路是**无条件重试**的 —— 判定要开就真去开，失败就重试，巡检每
    /// 10 秒再来一轮。这对能救回来的状态是对的（拔线必亮屏），对**救不回来**的状态
    /// 却是灾难：
    ///
    /// 实测 2026-09-18：内屏连续 92 分钟一次都没开成，GUI 巡检和守护巡检每 20 秒
    /// 各试一轮，日志里 965 行有 944 行是同一条「1 个候选都没开成」。每次失败的代价
    /// 也不是一个 if：`setEnabled` 失败前要按 2.5 秒轮询在线列表，期间 RunLoop 每
    /// 80ms 醒一次，进程根本进不了空闲；再加上每轮都全量枚举一遍显示器模式列表。
    /// 结果是活动监视器里 743 的 12 小时电源（正常菜单栏应用是个位数）。
    ///
    /// 闸门的两条规则：
    ///   ① **指纹变了就立刻放行**并清零退避 —— 真拔线、真插上、开合盖、睡眠唤醒
    ///      都属于这一类，「拔线必亮」的硬承诺不受任何影响；
    ///   ② 指纹没变而上次又失败了，按连续失败次数退避（30/60/120/300 秒封顶）。
    ///      指纹没变意味着「同一份输入又算了一遍」，而前面那 900 多次已经给出过
    ///      同一个答案：开不成。
    func rescueGateAllowsAttempt(now: Date = Date()) -> Bool {
        let fp = rescueInputFingerprint()
        if fp != rescueFingerprint {
            rescueFingerprint = fp
            rescueFailStreak = 0
            rescueGateUntil = nil
            return true
        }
        if let until = rescueGateUntil, now < until { return false }
        return true
    }

    /// 试了一次、没成：记一级退避。
    func noteRescueAttemptFailed(now: Date = Date()) {
        rescueFailStreak += 1
        let i = min(rescueFailStreak - 1, BuiltinRestoreTiming.failBackoff.count - 1)
        rescueGateUntil = now.addingTimeInterval(BuiltinRestoreTiming.failBackoff[max(0, i)])
    }

    /// 成了：退避和失败日志的限频一起清零。
    func noteRescueAttemptSucceeded() {
        rescueFailStreak = 0
        rescueGateUntil = nil
        lastRescueFailLogAt = nil
    }

    /// 救援失败的日志限频。
    ///
    /// 头两次照打（现场最重要：失败到底发生在哪一步、候选是谁），之后最多每分钟
    /// 一条 —— 后面那些内容一模一样，写它们只是把日志刷干净、顺便耗点电。
    func logRescueFailure(_ text: String, now: Date = Date()) {
        if rescueFailStreak <= 2 {
            lastRescueFailLogAt = now
            ruleLog(text)
            return
        }
        if let last = lastRescueFailLogAt, now.timeIntervalSince(last) < 60 { return }
        lastRescueFailLogAt = now
        ruleLog(text)
    }

    /// 周期巡检这一轮能不能直接跳过。
    ///
    /// 巡检的职责只有一个：**兜底「配置变化通知丢了」**。通知丢了意味着确实发生过一次
    /// 显示配置变化却没喊我们 —— 而那种情况下指纹必然已经变了。所以指纹和上次得出
    /// 「不用动手」时一样时，再算一遍不会有新结论（`decide` 是纯函数）。
    ///
    /// 但不能无限跳（见 `maxPeriodicSkips`：同一份在线集合内部也可能翻转），
    /// 所以跳满 5 次就放行一次完整复算，一分钟内至少算一次。
    ///
    /// 附带效果：干掉了常态下每 10 秒一行的「巡检：检查完毕，无需动作」——
    /// 用户正常用着（外接屏 + 内屏关掉）时它一直在刷，一天上千行。
    func periodicCheckShouldSkip() -> Bool {
        guard lastIdleFingerprint == rescueInputFingerprint() else { return false }
        guard skippedPeriodicChecks < BuiltinRestoreTiming.maxPeriodicSkips else {
            skippedPeriodicChecks = 0
            return false
        }
        skippedPeriodicChecks += 1
        return true
    }

    /// 周期巡检的入口。
    func periodicRescueCheck() {
        // ① 最便宜的一档：内屏在线 / 合盖，一定不需要救援（只花几次 CG 查询）
        guard maybeNeedsRescue() else { return }
        // ② 这份输入刚算过、结论是「不用动手」→ 跳过（有上限，见 periodicCheckShouldSkip）
        if periodicCheckShouldSkip() { return }
        applyAutoBuiltinRule(force: true, source: "巡检", quiet: true)
    }

    /// 这一轮失败之后该用哪条重试链。
    ///
    /// 首次失败用完整链（拔线那一刻显示配置还在重建，值得一秒一秒试到 15 秒）；
    /// 已经在同一份输入上失败过了，就只留两次短试 —— 输入没变，上一次的答案
    /// 就是这一次的答案，没必要再烧 15 秒的空转轮询。
    private func rescueRetryChain() -> [TimeInterval] {
        if rescueFailStreak <= 1 && !lastEnableWasRejected {
            return BuiltinRestoreTiming.backoff
        }
        return BuiltinRestoreTiming.repeatBackoff
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
    ///   - quiet: 无事可做时不写日志。只给周期巡检用 —— 它每 10 秒一次，
    ///     常态下「检查完毕，无需动作」会一直刷屏（一次评估一行，一天上千行）。
    /// - Returns: 真的改动了显示配置才返回 true。
    @discardableResult
    func applyAutoBuiltinRule(force: Bool = false, source: String = "未标注",
                              quiet: Bool = false) -> Bool {
        // 「救内屏」这一支先过闸门，而且必须在 `autoBuiltinPlan()` **之前** ——
        // 那一步要枚举每台屏的全部模式列表，比闸门本身贵两个数量级。
        // 内屏在线时 `maybeNeedsRescue()` 直接否掉，连闸门都不用问（那是关内屏那一支）。
        let rescuePossible = maybeNeedsRescue()
        if rescuePossible, !rescueGateAllowsAttempt() { return false }

        let plan = autoBuiltinPlan()

        // ---- 该把内屏开回来：不设任何前置条件，**也不看开关** ----
        // 这不是「用户的一个动作」，而是一个必须修好的故障状态：用户面前没有屏幕，
        // 也没法打开菜单去点「重新扫描显示器」，只能等人来救。所以只要判定要开，
        // 每一次评估都真去开一次，失败就重试。
        //
        // 不看开关是 1.4.1 改的，见 `decide` 里那段：开关关着的人手动关掉内屏再拔线，
        // 同样会黑屏。开关管的是偏好，不是要不要救人。
        if plan.kind == .enableBuiltin {
            // 走到这里 externalCount 必然是 0（见 decide），别再枚举一次了 ——
            // 这行原来是 displays()，每次失败都白搭一次全量枚举。
            lastExternalPresent = false
            if openBuiltin(plan: plan, source: source) {
                noteRescueAttemptSucceeded()
                lastIdleFingerprint = nil
                return true
            }
            noteRescueAttemptFailed()
            // 试过又失败 → 不记「已算过」：同一份输入的节奏交给闸门按退避决定，
            // 记成 idle 就等于连退避重试的机会都没了
            lastIdleFingerprint = nil
            // 系统干脆拒绝了那个 id（它现在不是一台显示器）时，长重试链纯属空转：
            // 这条 id 要重新有效只能靠显示配置变化，而那时指纹会变、闸门会放行。
            scheduleBuiltinRestore(step: 0, chain: rescueRetryChain())
            return false
        }

        // 这一轮没打算动手（内屏在位 / 合盖 / 开关关着 / 还没到边缘）→ 记下这算过，
        // 周期巡检在指纹不变时就不重复算了
        lastIdleFingerprint = rescueInputFingerprint()

        guard autoDisableBuiltinWhenExternal else {
            lastExternalPresent = nil       // 开关关了就别留着旧记忆，免得下次打开时误判
            return false
        }

        // ---- 其余情况：屏幕睡眠时一律按兵不动，而且**不更新记忆** ----
        // 不更新记忆这点很关键：假设接上外接屏的那一刻屏幕正好睡着，若把这轮记成
        // 「已处理」，醒来后 prev == hasExternal，就再也没人去关内屏了。
        if displaysAsleep() {
            if force, !quiet { ruleLog("[\(source)] 屏幕睡眠中，本轮跳过") }
            return false
        }

        let hasExternal = displays(includeModes: false).contains { !$0.isBuiltin }
        let prev = lastExternalPresent
        lastExternalPresent = hasExternal

        // 关内屏只在外接屏「刚接上」的那一下动手，平时保持安静 ——
        // 这样用户临时把内屏开回来干活，不会被规则立刻打回去。
        let edge = force || prev == nil || prev != hasExternal
        guard edge else { return false }
        if force, plan.kind == .idle {
            if !quiet { ruleLog("[\(source)] 检查完毕，无需动作（\(plan.reason)）") }
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
    ///
    /// - Parameter periodic: 是不是 10 秒巡检来的（而不是配置变化回调来的）。
    ///   巡检要过「这份输入已经评估过」的去重，否则守护进程会每 10 秒无条件
    ///   枚举一遍所有显示器的模式列表 —— 常态下（外接屏 + 内屏关掉）也是一样，
    ///   白天到晚就这么白烧着。
    @discardableResult
    func rescueBuiltinIfNeeded(source: String, periodic: Bool = false) -> Bool {
        // 廉价初筛：内屏在线 / 合盖 → 一定不需要救（几次 CG 查询）
        guard maybeNeedsRescue() else { return false }
        // 巡检去重：同一份输入刚算过、结论「不用动手」→ 跳过（有上限）
        if periodic, periodicCheckShouldSkip() { return false }
        // 闸门：同一份输入刚失败过，就别再动手了（见 rescueGateAllowsAttempt）
        guard rescueGateAllowsAttempt() else { return false }

        let plan = autoBuiltinPlan()
        guard plan.kind == .enableBuiltin else {
            lastIdleFingerprint = rescueInputFingerprint()
            return false
        }
        if openBuiltin(plan: plan, source: source) {
            noteRescueAttemptSucceeded()
            lastIdleFingerprint = nil
            return true
        }
        noteRescueAttemptFailed()
        lastIdleFingerprint = nil
        scheduleBuiltinRestore(step: 0, chain: rescueRetryChain())
        return false
    }

    private func scheduleBuiltinRestore(step: Int, chain: [TimeInterval]) {
        if step == 0 { restoreChain += 1 }
        let myChain = restoreChain

        guard step < chain.count else {
            ruleLog("重试 \(chain.count) 次仍未成功，交给巡检继续兜底")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + chain[step]) { [weak self] in
            // 不检查开关：重试只可能是在救内屏（见 applyAutoBuiltinRule 开头）
            guard let self, myChain == self.restoreChain else { return }
            // 重新判定：也许这期间内屏已经被系统或用户打开了
            let plan = self.autoBuiltinPlan()
            guard plan.kind == .enableBuiltin else {
                self.ruleLog("重试前复查：内屏已不需要打开，停止重试")
                return
            }
            // 换下一轮时照样把所有候选过一遍 —— id 变了也能认出来
            if self.openBuiltin(plan: plan, source: "重试第 \(step + 1) 次") {
                self.noteRescueAttemptSucceeded()
                return
            }
            self.scheduleBuiltinRestore(step: step + 1, chain: chain)
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
    ///
    /// 定时器只做最便宜的两道判断（内屏在线？这份输入评估过吗？），
    /// 真需要全量枚举的情况交给 `periodicRescueCheck`。理由见它上面那段。
    func startSafetyMonitor() {
        guard safetyTimer == nil, !knownBuiltinIDs.isEmpty else { return }
        let t = Timer(timeInterval: BuiltinRestoreTiming.monitorInterval, repeats: true) { [weak self] _ in
            self?.periodicRescueCheck()
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
