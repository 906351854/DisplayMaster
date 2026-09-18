import AppKit

/// 诊断命令入口。
///
/// 顺序与原实现里那串顶层 `if` 严格一致：每条命令自己 `exit`，所以实际语义是
/// 「先匹配到的先执行」。要加新命令，请加在末尾并在对应文件里实现。
func runDiagnosticCommandIfNeeded() {
    let args = CommandLine.arguments

    if args.contains("--selftest") { runSelfTest() }
    if args.contains("--modes") { runModes() }
    if args.contains("--hidpi-test") { runHiDPITest() }
    if args.contains("--ddc-test") { runDDCTest() }
    if args.contains("--ddc-storm") { runDDCStorm() }
    if args.contains("--dump-menu") { runDumpMenu() }
    if args.contains("--hits") { runHits() }
    if args.contains("--shot-menu") { runShotMenu() }
    if args.contains("--hidpi-toggle") { runHiDPIToggle() }
    if args.contains("--drag-res") { runDragResolution() }
    if args.contains("--display-on") || args.contains("--display-off") { runDisplayOnOff() }
    if args.contains("--toggle-test") { runToggleTest() }
    if args.contains("--auto-test") { runAutoTest() }
    if args.contains("--auto-log") { runAutoLog() }
    if args.contains("--als-test") { runALSTest() }
    if args.contains("--agent-reset") { runAgentReset() }
    if args.contains("--set-display") { runSetDisplay() }
    if args.contains("--auto-scenarios") { runAutoScenarios() }
    if args.contains("--wake-test") { runWakeTest() }
    if args.contains("--ddc-recover-test") { runDDCRecoverTest() }
}
