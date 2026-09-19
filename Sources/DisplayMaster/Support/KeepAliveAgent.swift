import AppKit
import ServiceManagement

/// 后台项（LaunchAgent）——**只有一条规则**：
/// 菜单栏应用本体异常退出（崩溃、被杀、非零退出码）时由 launchd 几秒内拉起来；
/// 用户正常退出（exit 0）不被强行拉活，退出就是退出。
///
/// ## 为什么内屏救援不再需要一个常驻进程
///
/// 1.4.4 起，内屏恢复挪进了应用自己的退出流程（`DisplayManager.restoreBuiltinBeforeQuit`）：
/// 退出那一刻把被本应用关掉的内屏还回来。「App 不在 + 内屏关着」这个状态从此
/// 不存在 —— 拔线时内屏本来就是亮的，于是不再需要有人在旁边守着。
///
/// 唯一漏网的是**崩溃**：崩溃不走正常退出路径，退出钩子没有执行机会，内屏可能
/// 留在关着的状态。这一层负责把崩溃的实例重新拉起来，新实例一启动就会按规则
/// 把内屏补回来（`applyAutoBuiltinRule(force: true, source: "启动检查")`）。
///
/// ## 1.5.0：改用 SMAppService 登记，plist 挪进 bundle
///
/// 1.4.4 及更早是自己往 `~/Library/LaunchAgents/` 写 plist 再 `launchctl bootstrap`。
/// 那种「裸 LaunchAgent」在系统里是**没有归属**的后台项，系统设置里会把它显示成
/// 「项目来自身份不明的开发者。」，图标还是一张空白的可执行文件占位图 ——
/// 恰好是最容易被当成恶意软件的样子。
///
/// 现在把 plist 作为 bundle 的一部分（`Contents/Library/LaunchAgents/<id>.agent.plist`）
/// 交给 `SMAppService.agent(plistName:)` 登记：后台项挂在这个 app 名下，
/// 面板里显示 app 自己的图标和「1 个项目」，卸载 app 时系统也会一并收拾干净。
/// 代价是需要 macOS 13（所以部署目标从 12 提到了 13）。
///
/// ## 这一层是「一条规则」，不是「一个进程」
///
/// plist 只有几百字节，干活的是系统自带的 launchd —— 应用没在跑的时候，不会
/// 因此多出任何进程、任何内存、任何唤醒。1.4.3 的救援守护恰好相反：一个常驻
/// 无界面进程，还在 `~/Library/Application Support/` 下放了一份 .app 外的可执行
/// 副本。那副样子在安全直觉上非常接近恶意软件，用户会去「隐私与安全性」里怀疑它、
/// 在活动监视器里盯着它 —— 得不偿失，1.4.4 已经把它整个撤掉了。
///
/// ## 指挥权交接
///
/// 登记那一刻 launchd 会按 `RunAtLoad` 立刻另起一份实例，而用户手上可能正开着
/// 一份手动启动的 —— 同一时刻只能有一个菜单栏实例，于是等那一份起来后主动退位。
/// 「谁是自己人」靠 plist 里注入的环境变量认（`DISPLAYMASTER_SUPERVISED`），
/// 不靠猜。
enum KeepAliveAgent {
    /// 交接进行中。这一刻的 terminate 不是「用户要退出」，退出流程里的内屏恢复
    /// 必须跳过 —— 否则内屏会闪一下，再被接棒的新实例按规则关回去。
    static var isHandingOver = false

    /// launchd 拉起的实例会带上这个环境变量。它写在我们自己签名过的 bundle 内
    /// plist 里，进程外无法伪造，比「查 pid 猜身份」可靠。
    private static let supervisedEnvKey = "DISPLAYMASTER_SUPERVISED"

    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.zed.displaymaster" }

    /// 1.5.0 起：bundle 内的后台项，文件由 build.sh 按这个标签生成。
    private static var agentLabel: String { bundleID + ".agent" }
    private static var agentPlistName: String { agentLabel + ".plist" }

    /// 1.4.4 及更早：写在用户目录里那份保活 plist 用的标签，1.5.0 要清掉。
    private static var legacyLabel: String { bundleID }

    private static var domain: String { "gui/\(getuid())" }
    private static var myPID: Int32 { ProcessInfo.processInfo.processIdentifier }

    /// 诊断命令（--auto-test / --selftest 这些）都带参数，真正的菜单栏会话没有。
    /// 诊断跑一次就 exit，装保活毫无意义还会留下登记。
    static var isDiagnosticRun: Bool {
        CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
    }

    /// 诊断用：「登记了没有 / 用户批没批 / bundle 里有没有这份 plist」三件事一眼看清。
    /// 改用 SMAppService 之后，这一环最容易出问题、也最难从外部观察（系统只在
    /// 设置面板里给一个笼统的开关），所以自检必须能把它打出来。
    static var diagnosticLine: String {
        let status = SMAppService.agent(plistName: agentPlistName).status
        let state: String
        switch status {
        case .enabled:          state = "✓ 已登记"
        case .notRegistered:    state = "未登记"
        case .requiresApproval: state = "已登记，但被你在系统设置里关掉了"
        case .notFound:         state = "✗ bundle 内没有 \(agentPlistName)"
        @unknown default:       state = "未知(\(status.rawValue))"
        }
        return "\(state)  [\(agentLabel)]"
    }

    /// 诊断用：注销后重新登记（`--agent-reset`）。
    ///
    /// app 被替换过之后，系统里那条登记可能还指着**旧的** bundle（升级、重装、
    /// 开发时反复 ditto 覆盖都会），表现为 `launchctl print` 里
    /// `job state = spawn failed / last exit code = 78: EX_CONFIG` —— 后台项看着
    /// 「已登记」，实际一次都起不来。注销重建是唯一能让它恢复正常的手段。
    static func resetRegistration() -> [String] {
        let service = SMAppService.agent(plistName: agentPlistName)
        var lines: [String] = ["重建前：\(diagnosticLine)"]
        refreshLaunchServices()
        do {
            try service.unregister()
            lines.append("已注销")
        } catch {
            lines.append("注销失败（多数情况下说明本来就没登记）：\(error.localizedDescription)")
        }
        do {
            try service.register()
            lines.append("已重新登记")
        } catch {
            lines.append("登记失败：\(error.localizedDescription)")
        }
        lines.append("重建后：\(diagnosticLine)")
        return lines
    }

    /// 入口：确保后台项已登记；如果当前 GUI 实例不在 launchd 管辖下，
    /// 就把位置让给 launchd 拉起的实例。后台线程调用。
    static func installAndHandOverIfOutsider() {
        guard !isDiagnosticRun else { return }
        // 从 DMG / 下载目录里直接跑的（还没真正安装）不登记：plist 指向一个会被弹出的
        // 卷，重启之后就是一条死链，还会在系统设置里留下一个永远起不来的后台项。
        guard let exe = Bundle.main.executableURL?.path else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let installed = exe.hasPrefix("/Applications/") || exe.hasPrefix(home + "/Applications/")
        guard installed else { return }

        // ① 老版本留在用户目录里的东西：1.4.3 的救援守护，以及 1.4.4 那份保活 plist。
        //    不清理就会出现「两套保活同时生效」，而且旧 plist 会一直挂在系统设置里。
        removeLegacyRescueDaemon()
        removeLegacyLaunchAgent()

        // ② 登记后台项。已登记过的再调 register() 会抛错，所以先看状态。
        let service = SMAppService.agent(plistName: agentPlistName)
        switch service.status {
        case .enabled:
            // 登记还在，但它可能已经不认现在这个 bundle 了（app 被覆盖安装过）。
            // 这时候登记看着一切正常，launchd 却每次 spawn 都失败，只有重建才能修好。
            if !isSupervised && serviceLooksBroken() {
                rebuildRegistration(service)
            }
        case .requiresApproval:
            // 用户在系统设置里关掉了它。尊重这个选择：不强行拉活，也不退位。
            DisplayManager.shared.ruleLog("保活代理：后台项已登记但被用户关掉，跳过")
            return
        default:
            do {
                try service.register()
                DisplayManager.shared.ruleLog("保活代理：已登记后台项 \(agentLabel)")
            } catch {
                DisplayManager.shared.ruleLog("保活代理：后台项登记失败 \(error.localizedDescription)")
                return
            }
        }

        // ③ 我自己就是后台项拉起来的 → 什么都不用做，安心干活。
        if isSupervised {
            DisplayManager.shared.ruleLog("保活代理：本实例由 launchd 启动（pid=\(myPID)）")
            return
        }

        // ④ 手动启动的实例（双击、`open`）。常驻的**必须**是 launchd 名下那份：
        //    只有它崩溃才会被重新拉起，而手动启动的进程不在 launchd 管辖区里，
        //    崩掉就真没了 —— 「崩溃后把内屏补回来」这个保证会静默失效。
        //    所以这里一律把位置让出去，不区分本次有没有刚登记。
        if let pid = launchdPID(), pid != myPID {
            handOver(to: pid)
            return
        }

        // ⑤ 服务已登记但没在跑（用户上次正常退出、今晚又手动打开）：RunAtLoad 只在
        //    登记和登录时触发，这时候得自己叫一声。
        run("/bin/launchctl", ["kickstart", "\(domain)/\(agentLabel)"])
        if let pid = waitForSupervisedPID(timeout: 8) {
            handOver(to: pid)
            return
        }

        // ⑥ 没等来。可能是它正卡在失败重试里（launchd 每 5 秒一次），也可能真的起不来。
        //    不退位 —— 但接着盯一会儿：常驻的必须是 launchd 那份，晚一点交接也比不交好，
        //    否则这个「手动启动的」实例崩掉之后没有任何东西会把它拉回来。
        DisplayManager.shared.ruleLog("保活代理：launchd 尚未拉起实例，本实例先运行并继续等")
        watchForSupervisedInstance(rounds: 6)
    }

    /// 后台复检：每 20 秒看一眼 launchd 名下有没有实例，有就让位。
    ///
    /// 只在「已确认本实例不是 launchd 名下那份」时才调用，所以这里的每一次让位都是
    /// 正确的 —— 常驻的必须是受管辖的那份，否则崩溃时没人把它拉回来。
    private static func watchForSupervisedInstance(rounds: Int) {
        guard rounds > 0 else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            if let pid = launchdPID(), pid != myPID {
                handOver(to: pid)
                return
            }
            watchForSupervisedInstance(rounds: rounds - 1)
        }
    }

    private static var isSupervised: Bool {
        ProcessInfo.processInfo.environment[supervisedEnvKey] == "1"
    }

    /// 清理 1.4.4 及更早写在 `~/Library/LaunchAgents/` 下的保活 plist。
    ///
    /// 服务不停掉的话，launchd 仍然按注册时的规则管着它（删文件不管用），
    /// 于是旧的「裸后台项」和新登记的那份会同时生效。
    private static func removeLegacyLaunchAgent() {
        let fm = FileManager.default
        let (_, out) = run("/bin/launchctl", ["print", "\(domain)/\(legacyLabel)"])
        if out.contains("state =") {
            run("/bin/launchctl", ["bootout", "\(domain)/\(legacyLabel)"])
            DisplayManager.shared.ruleLog("保活代理：已停用 1.4.4 的保活服务")
        }
        let plist = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
        if fm.fileExists(atPath: plist.path) {
            try? fm.removeItem(at: plist)
            DisplayManager.shared.ruleLog("保活代理：已删除用户目录里的旧保活 plist")
        }
    }

    /// 清理 1.4.3 及更早版本的救援守护残留：常驻服务、它的 plist、
    /// 以及 `~/Library/Application Support/DisplayMaster/` 下那份 .app 外的副本。
    ///
    /// 三样都要显式清掉：
    /// - 服务不停，进程会一直跑到注销（launchd 只认注册时的 plist，删文件不管用）；
    /// - plist 不删，重启后服务又回来；
    /// - 副本不删，用户目录里就还留着一个「来路不明的常驻可执行文件」。
    ///
    /// ⚠️ 注意区分：日志写在 `Application Support/Display Master/`（**带空格**），
    /// 副本在 `Application Support/DisplayMaster/`（**不带空格**）。只动后者。
    private static func removeLegacyRescueDaemon() {
        let label = bundleID + ".rescue"
        let fm = FileManager.default

        let (_, out) = run("/bin/launchctl", ["print", "\(domain)/\(label)"])
        if out.contains("state =") {
            run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
            DisplayManager.shared.ruleLog("保活代理：已移除旧的救援守护服务")
        }

        let plist = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        if fm.fileExists(atPath: plist.path) {
            try? fm.removeItem(at: plist)
            DisplayManager.shared.ruleLog("保活代理：已删除救援守护的 plist")
        }

        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DisplayMaster")
        if let items = try? fm.contentsOfDirectory(atPath: dir.path) {
            for item in items
            where item.hasPrefix("DisplayMasterRescue") || item.hasPrefix(".Rescue.tmp") {
                try? fm.removeItem(at: dir.appendingPathComponent(item))
            }
            // 目录里没别的东西了就一并撤掉，别在用户目录留空壳。
            if ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty {
                try? fm.removeItem(at: dir)
            }
            DisplayManager.shared.ruleLog("保活代理：已清理 Application Support 下的守护副本")
        }
    }

    /// 登记是否已经「失效」：登记（`SMAppService` 那边）说一切正常，launchd 这边却不是
    /// 起不来、就是根本没有这个服务。
    ///
    /// 判据取自 `launchctl print` 的输出，两种情况都算失效：
    /// - 查不到这个服务 —— 登记还在、服务却不在 launchd 里，多半是被 bootout 过或被
    ///   覆盖安装弄丢了引用；
    /// - 留下 `job state = spawn failed` / `last exit code = 78: EX_CONFIG` ——
    ///   launchd 每次尝试都失败（`EX_CONFIG` 是它「配置错了、根本没法 spawn」的记法）。
    ///
    /// 拿不准时不动：重建登记会把正在跑的那份实例踢掉，宁可少做也不要做错。
    private static func serviceLooksBroken() -> Bool {
        let (_, out) = run("/bin/launchctl", ["print", "\(domain)/\(agentLabel)"])
        guard out.contains("state =") else { return true }
        if out.contains("job state = spawn failed") { return true }
        guard let range = out.range(of: "last exit code = (\\d+)", options: .regularExpression) else {
            return false
        }
        let digits = out[range].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int32(digits).map { $0 != 0 } ?? false
    }

    /// 注销后重新登记，并顺手让 LaunchServices 重新认识这个 bundle。
    ///
    /// 「覆盖安装过 app」之后必须走这一趟：`SMAppService` 的后台项是按**相对 bundle
    /// 的路径**记录可执行文件的，系统里那条记录会一直指着旧的 bundle，于是 launchd
    /// spawn 时解析不到文件、每次都失败（`EX_CONFIG`）—— 而面板里它看着还是「已启用」。
    ///
    /// 两件事都要做：先让 LaunchServices 认下新 bundle，再重建登记。
    /// 只做后者，新建的记录照样解析不到（实测）。
    private static func rebuildRegistration(_ service: SMAppService) {
        DisplayManager.shared.ruleLog("保活代理：后台项已失效（多半是 app 被覆盖安装过），重建登记")
        refreshLaunchServices()
        try? service.unregister()
        do {
            try service.register()
            DisplayManager.shared.ruleLog("保活代理：后台项登记已重建")
        } catch {
            DisplayManager.shared.ruleLog("保活代理：重建登记失败 \(error.localizedDescription)")
        }
    }

    /// 让 LaunchServices 重新扫描现在这个 bundle（系统自带的 lsregister）。
    private static func refreshLaunchServices() {
        let lsr = "/System/Library/Frameworks/CoreServices.framework/Frameworks"
            + "/LaunchServices.framework/Support/lsregister"
        run(lsr, ["-f", Bundle.main.bundleURL.path])
    }

    /// launchd 名下那份实例的 pid。
    ///
    /// `SMAppService` 登记的服务能在 `gui/<uid>/<label>` 里查到（`managed_by =
    /// com.apple.xpc.ServiceManagement`、`type = Submitted`），所以这里只认这一个来源：
    /// 「同 bundle 的另一个进程」不能当判据 —— 用户可能在别处又双击了一次，
    /// 拿它当接管者会退错位（把唯一受管辖的实例赶走）。
    private static func launchdPID() -> Int32? {
        let (_, out) = run("/bin/launchctl", ["print", "\(domain)/\(agentLabel)"])
        // ⚠️ 必须**先确认这个作业真的在跑**再读 pid。
        //
        // spawn 失败时 `launchctl print` 里**照样**有一行 `pid = N` —— 那是 launchd
        // 用来尝试启动的 xpcproxy，不是我们的 app（2026-09-19 实测：
        // `state = spawn scheduled` / `job state = spawn failed` / `pid = 58906`，
        // 而那个 pid 没有任何启动日志）。把它当成「launchd 那份已经起来了」，
        // 就会交接到一个不存在的进程然后自杀 —— 结果一个实例都不剩、菜单栏图标消失。
        guard out.contains("job state = running") else { return nil }
        // 形如 "\tpid =\t1234"。只认这一行，输出里别的 "pid" 一概不看。
        guard let range = out.range(of: "pid =\\s+(\\d+)", options: .regularExpression) else {
            return nil
        }
        let digits = out[range].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int32(digits)
    }

    private static func waitForSupervisedPID(timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = launchdPID(), pid != myPID { return pid }
            usleep(300_000)
        }
        return nil
    }

    /// 把指挥权交给 launchd 名下那份实例，然后自己退出。
    ///
    /// 走主线程 terminate：这一刻不是「用户要退出」，退出流程里的内屏恢复必须跳过
    /// （否则内屏会闪一下，再被接棒的新实例按规则关回去）。
    ///
    /// 让位前先**停掉周期巡检**：从这一刻起本实例已经救不了任何人，但巡检表还在跑，
    /// 于是同一份故障会被两个实例各算一遍 —— 而同一时刻只有一个进程能提交显示配置，
    /// 两边都会失败，白烧两份唤醒。1.4.3 那会儿日志里 `[巡检]` 与 `[守护·巡检]`
    /// 交替出现、每 20 秒两轮空转，就是同一幅景象。
    private static func handOver(to pid: Int32) {
        DispatchQueue.main.async {
            DisplayManager.shared.stopSafetyMonitor()
            DisplayManager.shared.ruleLog("保活代理：指挥权已交给 launchd（pid=\(pid)），本实例退出")
            isHandingOver = true
            NSApp.terminate(nil)
        }
    }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> (exit: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
