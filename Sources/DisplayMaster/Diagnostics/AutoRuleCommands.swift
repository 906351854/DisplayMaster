import AppKit

// 自动关闭内置屏的规则诊断：默认只报告会做什么，加 --apply 才真的执行一次
// 用法: DisplayMaster --auto-test [--apply] [--on|--off]
func runAutoTest() {
    _ = NSApplication.shared
    let dm = DisplayManager.shared
    let apply = CommandLine.arguments.contains("--apply")

    print("=== \(AppInfo.name) 自动关闭内置屏 · 规则诊断 ===")

    if CommandLine.arguments.contains("--on") { dm.autoDisableBuiltinWhenExternal = true }
    if CommandLine.arguments.contains("--off") { dm.autoDisableBuiltinWhenExternal = false }
    DisplayManager.debugHideExternals = CommandLine.arguments.contains("--fake-no-external")

    print("开关         : \(dm.autoDisableBuiltinWhenExternal ? "已打开" : "未打开")")
    if DisplayManager.debugHideExternals {
        print("              ⚠︎ --fake-no-external 生效：外接屏一律当成占位屏，"
              + "模拟「拔线后只剩随航残影」")
    }
    let list = dm.displays()
    print("在线显示器   : \(list.count) 台")
    for d in list {
        print("   · \(d.isBuiltin ? "内置" : "外接")  \(d.name)  id=\(d.id)")
    }
    print("已关闭记录   : \(disabledLine())")
    print("记住的内屏   : " + (dm.knownBuiltinID.map { "id=\($0)" } ?? "（还没见过）"))
    let virtuals = dm.detectedVirtualDisplayIDs()
    print("虚拟屏排除   : " + (virtuals.isEmpty ? "无"
                                        : virtuals.map { "id=\($0)" }.joined(separator: ", ")))
    let phantoms = dm.detectedPhantomDisplays()
    print("占位屏排除   : " + (phantoms.isEmpty ? "无"
                                        : phantoms.map { "id=\($0.id)「\($0.name)」" }
                                            .joined(separator: ", ")))
    print("屏幕睡眠     : " + (dm.debugDisplaysAsleep() ? "是" : "否")
          + "    合盖: " + (dm.isLidClosed() ? "是" : "否"))
    print("--- 在线显示器原始属性 ---")
    for id in dm.debugOnlineIDs() {
        let v = CGDisplayVendorNumber(id)
        let m = CGDisplayModelNumber(id)
        print("   id=\(id) vendor=\(v) \(DisplayManager.fourCCString(v))"
              + "  model=\(m) \(DisplayManager.fourCCString(m))"
              + "  判为虚拟屏=\(DisplayManager.isVirtualDisplay(id, nsName: nil, hasNSScreen: true))")
    }

    let memos = dm.debugModeMemos()
    print("记住的分辨率 : " + (memos.isEmpty ? "（还没有）"
          : memos.sorted { $0.key < $1.key }
              .map { "\($0.key) → \($0.value.text)" }.joined(separator: " · ")))
    let plan = dm.autoBuiltinPlan()
    let idText = plan.displayID.map { "\($0)" } ?? "-"
    switch plan.kind {
    case .idle:           print("规则判定     : 不动")
    case .disableBuiltin: print("规则判定     : 关闭 \(plan.displayName) (id=\(idText))")
    case .enableBuiltin:  print("规则判定     : 打开 \(plan.displayName) (id=\(idText))")
    }
    print("理由         : \(plan.reason)")
    if plan.kind == .enableBuiltin {
        print("救援候选     : " + (plan.candidateIDs.isEmpty ? "（空，救不回来）"
              : plan.candidateIDs.map { "id=\($0)" }.joined(separator: " → ")))
    }
    print("日志文件     : \(dm.ruleLogPath)")

    guard apply else {
        printRecentRuleLog(15)
        print("")
        print("（仅报告。要真的执行一次，加 --apply）")
        exit(0)
    }

    print("")
    print("执行 ...")
    let changed = dm.applyAutoBuiltinRule(force: true, source: "命令行 --apply")
    print("执行结果     : " + (changed ? "✓ 改动了显示配置" : "没有需要改动的地方"))
    for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
    print("执行后在线   : " + dm.displays().map { "\($0.name)(\($0.isBuiltin ? "内置" : "外接"))" }
                              .joined(separator: ", "))
    print("执行后记录   : \(disabledLine())")
    printRecentRuleLog(10)

    // 测试用：把刚关掉的内屏开回来，免得留下一块关着的屏幕没人管。
    // 用裸二进制跑的时候 defaults 与 .app 不共享，菜单里不会出现恢复入口，
    // 所以这一步是必需的。
    if CommandLine.arguments.contains("--restore"), let (id, rec) = dm.disabled.first(where: { $0.value.isBuiltin }) {
        print("")
        print("恢复：打开 \(rec.name) ...")
        print("           : " + (dm.setEnabled(id, true) ? "✓ 已恢复" : "✗ 恢复失败"))
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
        print("恢复后在线   : " + dm.displays().map { "\($0.name)" }.joined(separator: ", "))
        print("恢复后记录   : \(disabledLine())")
    }
    exit(0)
}

// 只打印自动规则的运行记录，不查询、不改动任何状态。
// 排查「拔了外接屏内屏没亮」时，这个的输出基本就能定论。
// 用法: DisplayMaster --auto-log [条数，默认 80]
func runAutoLog() {
    _ = NSApplication.shared
    let args = CommandLine.arguments
    var n = 80
    if let i = args.firstIndex(of: "--auto-log"), i + 1 < args.count, let v = Int(args[i + 1]) { n = v }
    printRecentRuleLog(n)
    exit(0)
}

// 自动规则的判定自测：用构造出来的场景把所有分支走一遍，完全不接触真实显示器
// 用法: DisplayMaster --auto-scenarios
func runAutoScenarios() {
    typealias Input = DisplayManager.AutoBuiltinInput
    typealias Kind = DisplayManager.AutoBuiltinPlan.Kind

    // 「拔掉外接屏要把内屏开回来」这条最要紧：写错的代价是用户面对一块黑屏。
    // 真机上没法随便插拔线，所以用构造场景把它钉住。
    let cases: [(name: String, input: Input, expect: Kind, expectID: CGDirectDisplayID?)] = [
        ("开关关闭 · 有外接屏 · 内屏在线",
         Input(switchOn: false, asleep: false, externalCount: 1,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         .idle, nil),

        ("屏幕睡眠 · 有外接屏 · 内屏在线",
         Input(switchOn: true, asleep: true, externalCount: 1,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         .idle, nil),

        ("接上 1 台外接屏 · 内屏在线",
         Input(switchOn: true, asleep: false, externalCount: 1,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         .disableBuiltin, 1),

        ("接上 2 台外接屏 · 内屏在线",
         Input(switchOn: true, asleep: false, externalCount: 2,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         .disableBuiltin, 1),

        ("有外接屏 · 内屏已经关了（不该重复操作）",
         Input(switchOn: true, asleep: false, externalCount: 1,
               builtinDisabledID: 1, builtinDisabledName: "内置屏"),
         .idle, nil),

        ("拔掉外接屏 · 内屏被本应用关着（必须开回来）",
         Input(switchOn: true, asleep: false, externalCount: 0,
               builtinDisabledID: 1, builtinDisabledName: "内置屏"),
         .enableBuiltin, 1),

        ("拔掉外接屏 · 内屏一直开着",
         Input(switchOn: true, asleep: false, externalCount: 0,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         .idle, nil),

        // 这条是 1.1.1 补的：关闭记录本身有可能丢了（用户手动开过一次内屏、
        // 系统重建过配置）。记录一没，旧逻辑就以为自己没关过、什么都不做，
        // 而用户面对的是一块黑屏 —— 所以必须能靠记住的内屏 id 兜住。
        ("拔掉外接屏 · 内屏不在线 · 关闭记录丢了（靠记住的内屏 id 兜底）",
         Input(switchOn: true, asleep: false, externalCount: 0, knownBuiltinIDs: [7]),
         .enableBuiltin, 7),

        // 屏幕睡眠时不开内屏，用户就真的什么都看不到。黑屏优先于「不打扰」。
        ("拔掉外接屏 · 内屏不在线 · 屏幕正在睡眠（照样救）",
         Input(switchOn: true, asleep: true, externalCount: 0,
               builtinDisabledID: 1, builtinDisabledName: "内置屏"),
         .enableBuiltin, 1),

        ("拔掉外接屏 · 内屏不在线 · 连内屏 id 都拿不到（只能交给系统）",
         Input(switchOn: true, asleep: false, externalCount: 0),
         .idle, nil),

        // 1.4.1：上面那条「拔掉外接屏就把内屏开回来」之所以整晚没生效，
        // 是因为外接屏数量算成了 1 —— 那块「屏」是随航断掉之后的残影。
        // 判定本身没问题，问题在喂给它的输入；这里把「喂对了」这个前提钉住。
        ("拔掉外接屏 · 只有随航残影在线（残影不计入外接屏 → 照样救）",
         Input(switchOn: true, asleep: false, externalCount: 0,
               builtinDisabledID: 1, builtinDisabledName: "内置屏"),
         .enableBuiltin, 1),

        // ---- 1.4.1：救援不再受开关限制，以及一条必须守住的边界 ----
        // 开关关着的人同样会黑屏：外接屏插着的时候手动关掉内屏是允许的
        // （那会儿还有外接屏可看），拔了线就一块屏不剩。旧代码在这一格只
        // 回一句「开关没打开」，然后就什么都不做。
        ("开关关着 · 拔掉外接屏 · 内屏被关着（照样必须救）",
         Input(switchOn: false, asleep: false, externalCount: 0,
               builtinDisabledID: 1, builtinDisabledName: "内置屏"),
         .enableBuiltin, 1),

        ("开关关着 · 有外接屏 · 内屏在线（尊重开关，不动）",
         Input(switchOn: false, asleep: false, externalCount: 1,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         .idle, nil),

        // 这条是防「亲手造黑屏」的回归：没有外接屏时**绝不能**走到关内屏那一支。
        // 救援分支必须在「内屏在线」时就返回，而不是往下掉。
        ("没有外接屏 · 内屏在线（绝不能反过来把内屏关掉）",
         Input(switchOn: true, asleep: false, externalCount: 0,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         .idle, nil),

        // ---- 1.4.1：合盖不是故障 ----
        // 合盖之后 macOS 会把内屏从显示配置里摘掉（clamshell），得到的正是
        // 「内屏不在线」这个状态 —— 和「内屏被关掉了」长得一模一样。
        // 但合盖时内屏本来就不会亮（面板不亮），去开它没有任何收益，
        // 而 setEnabled 会先声明一次用户活动把屏幕叫醒：电脑装包里的时候
        // 每 10 秒来一次，就是白白发热。开盖会触发配置变化，那时再救不迟。
        ("合盖 · 没有外接屏 · 内屏不在线（clamshell 正常状态，别去惊动它）",
         Input(switchOn: true, asleep: false, lidClosed: true, externalCount: 0,
               builtinDisabledID: 1, builtinDisabledName: "内置屏"),
         .idle, nil),

        ("合盖 · 没有外接屏 · 内屏不在线 · 开关也没开（同样不动）",
         Input(switchOn: false, asleep: false, lidClosed: true, externalCount: 0,
               builtinDisabledID: 1, builtinDisabledName: "内置屏"),
         .idle, nil),

        // 合盖时不做救援，但**开盖之后必须立刻救**（这是上面那条的配套保证）
        ("合盖 + 没有外接屏 · 开盖之后（同样的状态，救）",
         Input(switchOn: true, asleep: false, lidClosed: false, externalCount: 0,
               builtinDisabledID: 1, builtinDisabledName: "内置屏"),
         .enableBuiltin, 1),

        // 合盖时若内屏仍在位，一样什么都不用做
        ("合盖 · 没有外接屏 · 内屏在线（不动）",
         Input(switchOn: true, asleep: false, lidClosed: true, externalCount: 0,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         .idle, nil),
    ]

    print("=== 自动关闭内置屏 · 判定自测（构造场景，不接触真实显示器）===")
    var failed = 0
    for c in cases {
        let plan = DisplayManager.decide(c.input)
        let ok = plan.kind == c.expect && plan.displayID == c.expectID
        if !ok { failed += 1 }
        let kindText: String
        switch plan.kind {
        case .idle:           kindText = "不动"
        case .disableBuiltin: kindText = "关闭 \(plan.displayName)"
        case .enableBuiltin:  kindText = "打开 \(plan.displayName)"
        }
        print("\(ok ? "✓" : "✗") \(c.name)")
        print("      判定 \(kindText)  ——  \(plan.reason)")
    }
    // ---- 虚拟屏识别 ----
    // 系统在「所有真实屏都不可用」时会造一台虚拟屏，它 CGDisplayIsBuiltin 返回 0。
    // 不认出来就会被当成「外接屏还接着」，规则干脆不触发，而用户面对的是黑屏。
    // 取值参照实测（macOS 26.6）：vendor/model = 0x756E6B6E / 0x76657274，即 'unkn'/'vert'。
    let vs: [(name: String, vendor: UInt32, model: UInt32, nsName: String?,
              hasScreen: Bool, expect: Bool)] = [
        // 这里用**实测到的原始整数**，不靠手写四字符码 —— 上一版把 'virt'
        // 误写成 'vert'，判据就静默失效了，而所有用手写常量的用例还是全绿。
        ("虚拟屏：实测原始整数 vendor=1970170734 model=1986622068（'unkn'/'virt'）",
         1970170734, 1986622068, "", true, true),
        ("虚拟屏：同上，但 NSScreen 里没有这条", 1970170734, 1986622068, nil, false, true),
        ("虚拟屏：model 换成 'vert' 也要认（兼容字串变化）", 1970170734, 1986359924, "", true, true),
        ("真实外接屏：Mi Monitor 实测 EDID 25001/10145", 25001, 10145, "Mi Monitor", true, false),
        ("真实内屏：实测 EDID 1552/41032", 1552, 41032, "Built-in Retina Display", true, false),
        ("没名字 + EDID 全 0（兜底判为虚拟屏）", 0, 0, "", true, true),
        ("没名字但有 EDID（真实屏，不算虚拟）", 1234, 5678, "", true, false),
        ("EDID 全 0 但有名字（真实屏，不算虚拟）", 0, 0, "某显示器", true, false),
    ]
    // ---- 救援候选 id ----
    // 救援能不能成，取决于这个列表：记录里那条最可信，排第一；历史 id 跟上补齐、去重。
    // 只要列表里有对的那个，哪怕它的位置靠后也能救回来（打开时按顺序挨个试）。
    let cands: [(name: String, input: Input, expect: [CGDirectDisplayID])] = [
        ("记录 + 历史都有：记录排第一，历史去重后跟上",
         Input(switchOn: true, asleep: false, externalCount: 0,
               builtinDisabledID: 3, knownBuiltinIDs: [1, 3, 7]),
         [3, 1, 7]),
        ("只有历史 id（关闭记录丢了）",
         Input(switchOn: true, asleep: false, externalCount: 0, knownBuiltinIDs: [1, 7]),
         [1, 7]),
        ("什么都没有 → 拿不到候补，只能交给系统",
         Input(switchOn: true, asleep: false, externalCount: 0),
         []),
        ("有外接屏时不需要候选（关内屏的 id 就在眼前）",
         Input(switchOn: true, asleep: false, externalCount: 1,
               builtinOnlineID: 1, builtinOnlineName: "内置屏"),
         []),
    ]
    print("")
    print("--- 救援候选 id ---")
    for c in cands {
        let got = DisplayManager.decide(c.input).candidateIDs
        let ok = got == c.expect
        if !ok { failed += 1 }
        print("\(ok ? "✓" : "✗") \(c.name)  →  [" + got.map { String($0) }.joined(separator: ", ") + "]")
    }

    print("")
    print("--- 虚拟屏识别 ---")
    for c in vs {
        let got = DisplayManager.isVirtualDisplay(vendor: c.vendor, model: c.model,
                                                  nsName: c.nsName, hasNSScreen: c.hasScreen)
        let ok = got == c.expect
        if !ok { failed += 1 }
        print("\(ok ? "✓" : "✗") \(c.name)  →  \(got ? "判为虚拟屏" : "真实屏")")
    }

    // ---- 占位屏识别 ----
    // 1.4.1：随航 / 隔空播放断掉之后，系统会在在线列表里留下一条残影，
    // 它 CGDisplayIsBuiltin 返回 0、虚拟屏判据也认不出来，于是被当成「外接屏还接着」，
    // 规则整晚按 idle 处理，用户面对黑屏。这里把每一条判据都钉住。
    // 名字那一列用**实测到的原文**：zed 这台机器上 displayNames 里留下的就是「 (AirPlay)」
    // —— 注意开头的空格，设备名是空的。
    let ps: [(name: String, dispName: String, vendor: UInt32, model: UInt32,
              lw: Int, lh: Int, expect: Bool)] = [
        ("随航残影：名字实测为「 (AirPlay)」（设备名是空的）",
         " (AirPlay)", 0, 0, 1920, 1080, true),
        ("同上，但 EDID 读到了东西（名字就够判）",
         " (AirPlay)", 1234, 5678, 1920, 1080, true),
        ("随航全名 Sidecar Display (AirPlay)",
         "Sidecar Display (AirPlay)", 0, 0, 2732, 2048, true),
        ("中文名「隔空播放」",
         "隔空播放", 0, 0, 1920, 1080, true),
        ("没有名字的外接屏（连缓存都丢了）+ 读不到 EDID",
         "外接显示器 35", 0, 0, 1920, 1080, true),
        ("有 EDID 但报不出任何模式（渲染不出东西）",
         "某某牌显示器", 1234, 5678, 0, 0, true),
        ("真实外接屏：Mi Monitor 实测 EDID 25001/10145",
         "Mi Monitor", 25001, 10145, 2560, 1440, false),
        ("真实内屏：实测 EDID 1552/41032",
         "Built-in Retina Display", 1552, 41032, 1680, 1050, false),
    ]
    print("")
    print("--- 占位屏识别 ---")
    for c in ps {
        let got = DisplayManager.isPhantomDisplay(name: c.dispName, vendor: c.vendor,
                                                  model: c.model,
                                                  logicalWidth: c.lw, logicalHeight: c.lh)
        let ok = got == c.expect
        if !ok { failed += 1 }
        print("\(ok ? "✓" : "✗") \(c.name)  →  \(got ? "判为占位屏（不计入外接屏）" : "真实屏")")
    }

    // ---- 分辨率记忆（重连恢复）----
    // 插拔没法在命令行里模拟，判定核心照样抽成纯函数把每个分支钉住。
    // zed 的现场：外接屏切到非默认档 → 拔线 → 插回来，系统落在默认档 → 应该恢复。
    func memo(_ w: Int, _ h: Int, hidpi: Bool, hz: Double) -> DisplayManager.ModeMemo {
        DisplayManager.ModeMemo(width: w, height: h, hidpi: hidpi, refresh: hz)
    }
    let mms: [(name: String, seen: DisplayManager.ModeMemo?, saved: DisplayManager.ModeMemo?,
               current: DisplayManager.ModeMemo?, allowRestore: Bool,
               expect: DisplayManager.ModeMemoryAction)] = [
        ("重新上线 · 有记忆且不同（zed 的现场：重插回落到默认档） → 恢复",
         nil, memo(2560, 1440, hidpi: true, hz: 60), memo(2560, 1440, hidpi: false, hz: 60),
         true, .restore(memo(2560, 1440, hidpi: true, hz: 60))),
        ("重新上线 · 还没有记忆（第一次用这块屏） → 记住当前档",
         nil, nil, memo(1920, 1080, hidpi: false, hz: 60),
         true, .save(memo(1920, 1080, hidpi: false, hz: 60))),
        ("重新上线 · 系统自己就恢复对了 → 不用动",
         nil, memo(2560, 1440, hidpi: true, hz: 60), memo(2560, 1440, hidpi: true, hz: 60),
         true, .save(memo(2560, 1440, hidpi: true, hz: 60))),
        ("在线期间档位被改（系统设置里改的也算） → 照单全收更新记忆",
         memo(2560, 1440, hidpi: true, hz: 60), memo(2560, 1440, hidpi: true, hz: 60),
         memo(1920, 1080, hidpi: false, hz: 60), true, .save(memo(1920, 1080, hidpi: false, hz: 60))),
        ("在线期间没变 → 不动",
         memo(2560, 1440, hidpi: true, hz: 60), memo(2560, 1440, hidpi: true, hz: 60),
         memo(2560, 1440, hidpi: true, hz: 60), true, .idle),
        // 启动播种前的第一次评估绝不恢复：app 一启动就改人分辨率是骚扰
        ("启动后第一次评估（还没播种）· 有记忆且不同 → 只记不恢复",
         nil, memo(2560, 1440, hidpi: true, hz: 60), memo(2560, 1440, hidpi: false, hz: 60),
         false, .save(memo(2560, 1440, hidpi: false, hz: 60))),
        ("档位相同、刷新率不同（60Hz 记忆 · 重连落在 120Hz）→ 也要恢复",
         nil, memo(2560, 1440, hidpi: true, hz: 60), memo(2560, 1440, hidpi: true, hz: 120),
         true, .restore(memo(2560, 1440, hidpi: true, hz: 60))),
    ]
    print("")
    print("--- 分辨率记忆 ---")
    for c in mms {
        let got = DisplayManager.modeMemoryDecision(seen: c.seen, saved: c.saved,
                                                    current: c.current, allowRestore: c.allowRestore)
        let ok = got == c.expect
        if !ok { failed += 1 }
        let text: String
        switch got {
        case .idle:             text = "不动"
        case .save(let m):      text = "记住 \(m.text)"
        case .restore(let m):   text = "恢复 \(m.text)"
        }
        print("\(ok ? "✓" : "✗") \(c.name)  →  \(text)")
    }

    print("")
    if failed == 0 {
        print("全部 \(cases.count + cands.count + vs.count + ps.count + mms.count) 条通过")
    } else {
        print("✗ \(failed)/\(cases.count + cands.count + vs.count + ps.count + mms.count) 条不符合预期")
    }
    exit(failed == 0 ? 0 : 1)
}

