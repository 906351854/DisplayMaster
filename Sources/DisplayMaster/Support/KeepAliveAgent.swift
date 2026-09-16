import AppKit

/// launchd 保活代理（LaunchAgent）——两个：
///
/// 1. **GUI 保活**（`<bundle-id>`）：菜单栏应用本体。异常退出（崩溃、被杀、
///    非零退出码）由 launchd 几秒内拉起；用户正常退出（exit 0）不被强行拉活。
/// 2. **救援守护**（`<bundle-id>.rescue`）：无界面常驻进程（`--rescue-daemon`），
///    KeepAlive 无条件 —— 它的职责清单只有一条「用户面前一块屏都没有时把内屏
///    开回来」，GUI 退没退出、活着没活着都轮不到影响它。这是 zed 的硬要求：
///    拔掉显示线内屏必须亮，不管有没有手动退出。
///
/// 两个 plist 都是应用启动时自检自装（路径变了自动刷新），登录自启一并覆盖。
///
/// 「指挥权交接」只针对 GUI：用户手动 `open` 起来的实例不在 launchd 管辖下，
/// 而同一时刻只能有一个菜单栏实例 —— 注册完 plist、等 launchd 拉起自己的实例后
/// 主动退位，常驻的永远是 launchd 管着的那份。判断只认 launchctl print 里的
/// pid，不猜环境变量。守护进程无界面、多一个也无害（救援幂等），不做交接。
enum KeepAliveAgent {
    private struct AgentSpec {
        let label: String
        let arguments: [String]
        /// nil = KeepAlive 无条件（守护进程）；非 nil = SuccessfulExit 语义（GUI）
        let successfulExit: Bool?

        var keepAliveXML: String {
            guard let ok = successfulExit else { return "<true/>" }
            return """
            <dict>
                <key>SuccessfulExit</key><\(ok ? "true" : "false")/>
            </dict>
            """
        }
    }

    private static var baseLabel: String {
        Bundle.main.bundleIdentifier ?? "com.zed.displaymaster"
    }

    private static var specs: [AgentSpec] {
        guard let exe = Bundle.main.executableURL?.path else { return [] }
        return [
            AgentSpec(label: baseLabel, arguments: [exe], successfulExit: false),
            AgentSpec(label: baseLabel + ".rescue", arguments: [exe, "--rescue-daemon"],
                      successfulExit: nil),
        ]
    }

    private static func plistURL(_ label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// 诊断命令（--auto-test / --selftest 这些）都带参数，真正的菜单栏会话没有。
    /// 诊断跑一次就 exit，装保活毫无意义还会留下 plist。守护进程同理跳过。
    static var isDiagnosticRun: Bool {
        CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
    }

    /// 入口：确保两个 LaunchAgent 都就位；如果当前 GUI 实例不在 launchd 管辖下，
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

        // ① 两个 plist 落盘。内容没变就不写，免得每次启动都碰一次盘。
        for spec in specs {
            writePlistIfNeeded(spec)
        }

        // ② 救援守护先保证就位 —— 无论 GUI 自己接下来走哪条分支都要做：
        //    GUI 已被 launchd 管辖时走下面的早退分支，守护的注册不能跟着跳
        //    （否则升级换代后守护永远没机会注册上）。
        ensureRescueDaemonBooted(domain: domain)

        // ③ 我自己就是 launchd 拉起来的 → 什么都不用做，安心干活。
        if supervisedPID(domain: domain, label: baseLabel) == myPID {
            DisplayManager.shared.ruleLog("保活代理：本实例由 launchd 启动（pid=\(myPID)）")
            return
        }

        // ④ 手动启动的 GUI 实例：注册 GUI 服务进 launchd（RunAtLoad 立刻拉起一个
        //    新实例）。守护进程已在 ② 里就位。
        run("/bin/launchctl", ["bootstrap", domain, plistURL(baseLabel).path])

        // ⑤ 等 launchd 的 GUI 实例出现。bootstrap 到子进程真正跑起来有零点几秒的窗。
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
            NSApp.terminate(nil)
        }
    }

    /// 救援守护的自愈入口：GUI 服务「完全没注册」时把它注册回来（RunAtLoad
    /// 会拉起 GUI）。已注册但空闲（用户正常退出过）则**不动** —— 退出就是退出。
    ///
    /// 为什么守护进程来做：launchctl bootstrap 只能由用户会话里 launchd 亲生的
    /// 进程成功调用（实测外部 shell 怎么调都是 EIO）。守护进程正是这样的进程，
    /// 而且它无条件保活 —— GUI 的注册无论怎么丢（升级时序、bootout 残留），
    /// 10 秒内都会被它捡回来。
    static func healGUIAgentIfUnregistered() {
        let domain = "gui/\(getuid())"
        let url = plistURL(baseLabel)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let (_, out) = run("/bin/launchctl", ["print", "\(domain)/\(baseLabel)"])
        guard !out.contains("state =") else { return }   // 已注册（在跑或空闲）都不动
        run("/bin/launchctl", ["bootstrap", domain, url.path])
    }

    /// 救援守护：注册了但没在跑就踢一脚。KeepAlive 无条件的服务正常情况下
    /// 一注册就自己跑起来；这条只是兜底（比如上次被手动 bootout 过）。
    private static func ensureRescueDaemonBooted(domain: String) {
        let label = baseLabel + ".rescue"
        run("/bin/launchctl", ["bootstrap", domain, plistURL(label).path])
        if supervisedPID(domain: domain, label: label) == nil {
            run("/bin/launchctl", ["kickstart", "\(domain)/\(label)"])
        }
    }

    private static func writePlistIfNeeded(_ spec: AgentSpec) {
        let url = plistURL(spec.label)
        let desired = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(spec.label)</string>
            <key>ProgramArguments</key>
            <array>
        \(spec.arguments.map { "            <string>\($0)</string>" }.joined(separator: "\n"))
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key>
            \(spec.keepAliveXML)
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
