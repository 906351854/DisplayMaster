import AppKit

// 后台项（崩溃保活）的运维命令。
//
// 用法: DisplayMaster --agent-reset
//
// 适合「保活明明登记着、崩溃却不恢复」的场景：注销系统里那条登记再重新登记。
// app 被替换过之后（升级、重装、开发时反复覆盖），登记可能还指着旧的 bundle，
// 于是 launchd 每次尝试启动都失败而外表完全看不出来。
func runAgentReset() {
    _ = NSApplication.shared
    print("=== 重建后台项登记 ===")
    for line in KeepAliveAgent.resetRegistration() { print(line) }
    print("")
    print("说明：登记重建后 launchd 会按 RunAtLoad 立刻拉起一个受它管辖的实例，")
    print("      当前这个手动启动的实例会在几秒内主动退位。")
    print("      核对：launchctl print gui/$(id -u)/com.zed.displaymaster.agent")
    exit(0)
}
