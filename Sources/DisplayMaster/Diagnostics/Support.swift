import AppKit

func ddcStateLine() -> String {
    var parts: [String] = []
    parts.append("服务数 \(DDC.shared.externalCount)")
    parts.append("连续失败 \(DDC.shared.consecutiveFailures)")
    if DDC.shared.isCoolingDown { parts.append("冷却中(剩 \(DDC.shared.cooldownRemaining)s)") }
    parts.append("诊断「\(DDC.shared.lastDiagnosis)」")
    if DDC.shared.recoveryCount > 0 {
        parts.append("自愈 \(DDC.shared.recoveryCount) 次（最近：\(DDC.shared.lastRecoveryReason)）")
    }
    if !DDC.shared.lastRawReply.isEmpty { parts.append("末次应答 [\(DDC.shared.lastRawReply)]") }
    return parts.joined(separator: "  ")
}

/// 已关闭显示器记录的摘要，用于自检/回归测试打印
func disabledLine() -> String {
    let dm = DisplayManager.shared
    guard !dm.disabled.isEmpty else { return "（空）" }
    return dm.disabled.sorted { $0.key < $1.key }
        .map { "\($0.value.name)(id=\($0.key) \($0.value.isBuiltin ? "内置" : "外接")"
             + " edid=\($0.value.vendor)/\($0.value.model)/\($0.value.serial))" }
        .joined(separator: ", ")
}

/// 打印自动规则最近的运行记录。
///
/// 这个功能出问题时用户看到的是一块黑屏，而黑屏状态下没法打开菜单排查 ——
/// 所以诊断入口（以及给用户贴出来用的 `--auto-log`）必须能把记录翻出来。
func printRecentRuleLog(_ lines: Int = 30) {
    let dm = DisplayManager.shared
    let tail = dm.recentRuleLog(lines: lines)
    print("")
    print("--- 自动规则日志（最近 \(lines) 条）---")
    print("文件: \(dm.ruleLogPath)")
    if tail.isEmpty {
        print("（还没有记录）")
    } else {
        tail.forEach { print($0) }
    }
    print("---")
}

/// 跑一个外部命令（同步等待），供唤醒测试用
@discardableResult
func runTool(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// 命令行入口对应的可执行文件路径，用于打印用法提示
let exeHint = "\(AppInfo.name).app/Contents/MacOS/DisplayMaster"

/// 卡片里那个部位：body（卡片主体，进详情页）/ on（开启开关）/ hidpi（HiDPI 开关）
func parseCardPart(_ s: String) -> CardsRowView.Part {
    switch s {
    case "on": return .toggleOn
    case "hidpi": return .toggleHiDPI
    default: return .detail
    }
}

/// 解析 `--page2 <displayID>`（菜单截图/结构打印用）
func debugPage2Arg() -> CGDirectDisplayID? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--page2"), i + 1 < args.count, let v = UInt32(args[i + 1]) else {
        return nil
    }
    return CGDirectDisplayID(v)
}
