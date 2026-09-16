import AppKit

/// launchd 保活代理（LaunchAgent）。
///
/// 为什么存在：救援内屏的前提是「应用活着」。应用崩溃、被系统杀掉之后用户又拔了线，
/// 就没有任何人去把内屏开回来 —— zed 真实撞上的现场。把注册成 launchd 的
/// LaunchAgent 之后，进程异常退出（崩溃、信号、非零退出码）会被 launchd 在几秒内
/// 拉起来；新进程启动时的「启动检查」看到「没有外接屏 + 内屏不在线」就会照常救援。
/// 关闭记录、历史内屏 id 早已落盘（见 DisplayManager+Disabled），进程死了记忆不丢。
///
/// 行为约定（都写进 plist）：
/// - `KeepAlive.SuccessfulExit = false`：**异常**退出才重启。用户从菜单里正常退出
///   （exit 0）不会被强行拉活 —— 退出就是退出；崩溃才有人管。
/// - `RunAtLoad`：登录时自启。顺带把「装成登录项」这件一直欠着的事一起办了。
///
/// 「指挥权交接」：用户手动 `open`（或 build.sh 装）起来的实例不在 launchd 管辖下，
/// 而同一时刻只能有一个菜单栏实例。所以手动启动的实例在把 plist 注册进 launchd 后，
/// 等到 launchd 拉起自己的实例就主动退位 —— 最终常驻的永远是 launchd 管着的那份。
/// 这样判断「我是谁」只依赖 launchctl print 里的 pid，不猜环境变量。
enum KeepAliveAgent {
    private static var label: String {
        Bundle.main.bundleIdentifier ?? "com.zed.displaymaster"
    }

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var myPID: Int32 { ProcessInfo.processInfo.processIdentifier }

    /// 诊断命令（--auto-test / --selftest / --drag-res 这些）都带参数，
    /// 真正的菜单栏会话没有。诊断跑一次就 exit，装保活毫无意义还会留下 plist。
    static var isDiagnosticRun: Bool {
        CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
    }

    /// 入口：确保 LaunchAgent 就位；如果当前实例不在 launchd 管辖下，
    /// 就把位置让给 launchd 拉起的实例。后台线程调用。
    static func installAndHandOverIfOutsider() {
        guard !isDiagnosticRun else { return }
        guard let exe = Bundle.main.executableURL?.path else { return }
        // 从 DMG / 下载目录里直接跑的（还没真正安装）不装：plist 指到一个会被弹出的
        // 卷上，重启之后就是一条死链，还白白注册了一个永远起不来的服务。
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let installed = exe.hasPrefix("/Applications/") || exe.hasPrefix(home + "/Applications/")
        guard installed else { return }

        let domain = "gui/\(getuid())"

        // ① plist 落盘。内容没变就不写，免得每次启动都碰一次盘。
        let desired = desiredPlist(executable: exe)
        let current = (try? String(contentsOf: plistURL, encoding: .utf8))
        if current != desired {
            do {
                try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try desired.write(to: plistURL, atomically: true, encoding: .utf8)
                DisplayManager.shared.ruleLog("保活代理：已写入 \(plistURL.path)")
            } catch {
                DisplayManager.shared.ruleLog("保活代理：plist 写入失败 \(error.localizedDescription)")
                return
            }
        }

        // ② 我自己就是 launchd 拉起来的 → 什么都不用做，安心干活。
        if supervisedPID(domain: domain) == myPID {
            DisplayManager.shared.ruleLog("保活代理：本实例由 launchd 启动（pid=\(myPID)）")
            return
        }

        // ③ 手动启动的实例：把服务注册进 launchd（RunAtLoad 会立刻拉起一个新实例）。
        run("/bin/launchctl", ["bootstrap", domain, plistURL.path])

        // ④ 等 launchd 的实例出现。bootstrap 到子进程真正跑起来有零点几秒的窗。
        var pid = waitForSupervisedPID(domain: domain, timeout: 6)
        if pid == nil {
            // 已注册但没在跑（比如用户上次正常退出后今晚手动再开）：
            // SuccessfulExit=false 不会自动拉，主动踢一脚。
            run("/bin/launchctl", ["kickstart", "\(domain)/\(label)"])
            pid = waitForSupervisedPID(domain: domain, timeout: 6)
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

        // ⑤ launchd 有自己的实例了 → 我这个手动启动的让位。
        DispatchQueue.main.async {
            DisplayManager.shared.ruleLog("保活代理：指挥权已交给 launchd（pid=\(pid!)），本实例退出")
            NSApp.terminate(nil)
        }
    }

    /// plist 内容。ProgramArguments 每次启动都按**当前**可执行文件路径重算：
    /// 应用以后换了安装位置，plist 也会跟着刷新，不会留一条死链。
    private static func desiredPlist(executable: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executable)</string>
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
    }

    /// launchctl print 里那个 pid：launchd 管辖下正在跑的实例，没有就是 nil。
    private static func supervisedPID(domain: String) -> Int32? {
        let (_, out) = run("/bin/launchctl", ["print", "\(domain)/\(label)"])
        // 形如 "\tpid =\t1234"。只认这一行，输出里别的 "pid" 一概不看。
        guard let range = out.range(of: "pid =\\s+(\\d+)", options: .regularExpression) else {
            return nil
        }
        let digits = out[range].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int32(digits)
    }

    private static func waitForSupervisedPID(domain: String, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = supervisedPID(domain: domain), pid != myPID { return pid }
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
