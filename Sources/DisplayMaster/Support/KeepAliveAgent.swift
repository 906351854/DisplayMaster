import AppKit

/// launchd 保活代理（LaunchAgent）——**只有一条规则**：
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
/// ## 这一层是「一条规则」，不是「一个进程」
///
/// plist 只有几百字节，干活的是系统自带的 launchd —— 应用没在跑的时候，不会
/// 因此多出任何进程、任何内存、任何唤醒。这一点值得写下来，因为上一版的救援
/// 守护恰好相反：一个常驻无界面进程，还在 `~/Library/Application Support/` 下
/// 放了一份 .app 外的可执行副本。那副样子在安全直觉上非常接近恶意软件，
/// 用户会去「隐私与安全性」里怀疑它、在活动监视器里盯着它 —— 得不偿失。
///
/// ## 指挥权交接
///
/// 用户手动 `open` 起来的实例不在 launchd 管辖下，而同一时刻只能有一个菜单栏
/// 实例 —— 注册完 plist、等 launchd 拉起自己的实例后主动退位，常驻的永远是
/// launchd 管着的那份。判断只认 `launchctl print` 里的 pid，不猜环境变量。
enum KeepAliveAgent {
    /// 交接进行中。这一刻的 terminate 不是「用户要退出」，退出流程里的内屏恢复
    /// 必须跳过 —— 否则内屏会闪一下，再被接棒的新实例按规则关回去。
    static var isHandingOver = false

    private static var baseLabel: String {
        Bundle.main.bundleIdentifier ?? "com.zed.displaymaster"
    }

    private static func plistURL(_ label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// 诊断命令（--auto-test / --selftest 这些）都带参数，真正的菜单栏会话没有。
    /// 诊断跑一次就 exit，装保活毫无意义还会留下 plist。
    static var isDiagnosticRun: Bool {
        CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
    }

    /// 入口：确保 LaunchAgent 就位；如果当前 GUI 实例不在 launchd 管辖下，
    /// 就把位置让给 launchd 拉起的实例。后台线程调用。
    static func installAndHandOverIfOutsider() {
        guard !isDiagnosticRun else { return }
        // 从 DMG / 下载目录里直接跑的（还没真正安装）不装：plist 指到一个会被弹出的
        // 卷上，重启之后就是一条死链，还白白注册了一个永远起不来的服务。
        guard let exe = Bundle.main.executableURL?.path else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let installed = exe.hasPrefix("/Applications/") || exe.hasPrefix(home + "/Applications/")
        guard installed else { return }

        let domain = "gui/\(getuid())"

        // ① 撤掉上一版的救援守护（服务 + plist + .app 外的二进制副本）。
        //    老用户机器上都留着，不清掉等于白改，而且那份副本正是最像恶意软件的一处。
        removeLegacyRescueDaemon(domain: domain)

        // ② plist 落盘。内容没变就不写，免得每次启动都碰一次盘。
        writePlistIfNeeded(label: baseLabel, arguments: [exe])

        // ③ 我自己就是 launchd 拉起来的 → 什么都不用做，安心干活。
        if supervisedPID(domain: domain, label: baseLabel) == myPID {
            DisplayManager.shared.ruleLog("保活代理：本实例由 launchd 启动（pid=\(myPID)）")
            return
        }

        // ④ 手动启动的 GUI 实例：注册进 launchd（RunAtLoad 立刻拉起一个新实例）。
        run("/bin/launchctl", ["bootstrap", domain, plistURL(baseLabel).path])

        // ⑤ 等 launchd 的实例出现。bootstrap 到子进程真正跑起来有零点几秒的窗。
        var pid = waitForSupervisedPID(domain: domain, label: baseLabel, timeout: 6)
        if pid == nil {
            // 已注册但没在跑（比如用户上次正常退出后今晚手动再开）：
            // SuccessfulExit=false 不会自动拉，主动踢一脚。
            run("/bin/launchctl", ["kickstart", "\(domain)/\(baseLabel)"])
            pid = waitForSupervisedPID(domain: domain, label: baseLabel, timeout: 6)
        }

        if pid == myPID {
            DisplayManager.shared.ruleLog("保活代理：本实例由 launchd 启动（pid=\(myPID)）")
            return
        }
        guard pid != nil else {
            // bootstrap 失败（极少见）：不退位，手动实例继续干活，总比没有强。
            DisplayManager.shared.ruleLog("保活代理：launchd 迟迟没拉起实例，本实例继续运行")
            return
        }

        // ⑥ launchd 有自己的 GUI 实例了 → 我这个手动启动的让位。
        DispatchQueue.main.async {
            DisplayManager.shared.ruleLog("保活代理：指挥权已交给 launchd（pid=\(pid!)），本实例退出")
            isHandingOver = true
            NSApp.terminate(nil)
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
    private static func removeLegacyRescueDaemon(domain: String) {
        let label = baseLabel + ".rescue"
        let fm = FileManager.default

        let (_, out) = run("/bin/launchctl", ["print", "\(domain)/\(label)"])
        if out.contains("state =") {
            run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
            DisplayManager.shared.ruleLog("保活代理：已移除旧的救援守护服务")
        }

        let plist = plistURL(label)
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

    private static func writePlistIfNeeded(label: String, arguments: [String]) {
        let url = plistURL(label)
        let desired = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
        \(arguments.map { "        <string>\($0)</string>" }.joined(separator: "\n"))
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key><false/>
            </dict>
            <key>ThrottleInterval</key><integer>5</integer>
        </dict>
        </plist>
        """
        let current = (try? String(contentsOf: url, encoding: .utf8))
        if current == desired { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try desired.write(to: url, atomically: true, encoding: .utf8)
            DisplayManager.shared.ruleLog("保活代理：已写入 \(url.path)")
        } catch {
            DisplayManager.shared.ruleLog("保活代理：plist 写入失败 \(error.localizedDescription)")
        }
    }

    private static var myPID: Int32 { ProcessInfo.processInfo.processIdentifier }

    /// launchctl print 里那个 pid：launchd 管辖下正在跑的实例，没有就是 nil。
    private static func supervisedPID(domain: String, label: String) -> Int32? {
        let (_, out) = run("/bin/launchctl", ["print", "\(domain)/\(label)"])
        // 形如 "\tpid =\t1234"。只认这一行，输出里别的 "pid" 一概不看。
        guard let range = out.range(of: "pid =\\s+(\\d+)", options: .regularExpression) else {
            return nil
        }
        let digits = out[range].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int32(digits)
    }

    private static func waitForSupervisedPID(domain: String, label: String,
                                             timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = supervisedPID(domain: domain, label: label), pid != myPID { return pid }
            usleep(300_000)
        }
        return nil
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
