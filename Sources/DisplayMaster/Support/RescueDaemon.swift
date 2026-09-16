import AppKit
import CoreGraphics
import IOKit
import IOKit.pwr_mgt

/// 无界面救援守护进程（`--rescue-daemon`）。
///
/// 为什么存在：内屏救援的判定和落盘状态在 1.4.1/1.4.2 里已经很硬，但它们全都在
/// GUI 进程里 —— 进程死了（崩溃、被杀、用户手动退出）就没人救了。launchd 保活
/// 能把 GUI 重新拉起来，可那是「几秒后恢复救援能力」，不是「拔线瞬间必有人管」。
/// zed 的要求是一句硬话：**不管应用退没退出，拔掉显示线内屏必须亮。**
///
/// 于是把「救援」这一个动作（且只有这一个动作）独立成一个常驻进程，由 launchd
/// 以 KeepAlive（无条件）养着：GUI 退出、崩溃、还没启动，都不影响它。
/// 它不做任何「关屏」的事 —— 关内屏是 GUI 里的偏好，守护进程的职责清单里
/// 只有一条：用户面前一块能看的屏都没有时，把内屏开回来（见
/// `rescueBuiltinIfNeeded`，幂等，与 GUI 的完整规则天然不打架）。
///
/// 触发两条腿：
/// - CG 显示配置回调：插拔线、睡眠唤醒时立刻评估；
/// - 10 秒巡检定时器：回调漏发、系统没通知时的兜底（GUI 侧同一条经验）。
///
/// 它和 GUI 共用同一份落盘状态与日志（DisplayManager 单例按进程各有一份，
/// 但UserDefaults / auto-rule.log 都是落盘共享的），`--auto-log` 能看到它说的话。
enum RescueDaemon {
    private static var installed = false

    /// CG 显示配置回调。C 函数指针不能捕获上下文，所以提为无捕获的静态常量
    /// （poke 是本枚举的静态方法，引用它不算捕获）。
    private static let reconfigCallback: CGDisplayReconfigurationCallBack = { _, _, _ in
        DispatchQueue.main.async { poke("守护·配置变化") }
    }

    static func run() -> Never {
        let mgr = DisplayManager.shared
        mgr.ruleLog("救援守护：启动（pid=\(ProcessInfo.processInfo.processIdentifier)，"
                    + "只管救援，不做任何关屏动作）")

        // 显示配置一变就评估。回调落在 runloop 线程，转主队列统一动作。
        CGDisplayRegisterReconfigurationCallback(reconfigCallback, nil)

        // 巡检兜底：GUI 侧安全巡检的同一条经验 —— 不能把「系统一定发通知」当假设。
        let timer = Timer(timeInterval: 10, repeats: true) { _ in poke("守护·巡检") }
        RunLoop.main.add(timer, forMode: .common)

        // 启动后先缓一拍再评估第一次：开机/登录的当口显示配置还在变，
        // 太早动手容易和系统抢跑（分辨率记忆那条同款教训）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { poke("守护·启动检查") }

        // 常驻：这个进程的生命周期就是「本用户会话」，退出交给 launchd 重启或登出。
        withKeepRunning {
            RunLoop.main.run()
        }
    }

    private static func poke(_ source: String) {
        guard !installed else { return }
        installed = true
        defer { installed = false }
        // 顺手自愈 GUI 的注册（见 KeepAliveAgent.healGUIAgentIfUnregistered）：
        // GUI 服务没注册上就拉回来，已注册但空闲（用户退出过）不碰。
        KeepAliveAgent.healGUIAgentIfUnregistered()
        DisplayManager.shared.rescueBuiltinIfNeeded(source: source)
    }

    /// 让「永不返回」的意图显式化（RunLoop.main.run() 正常情况下不返回）。
    private static func withKeepRunning(_ body: () -> Void) -> Never {
        body()
        // RunLoop 返回了（理论上只在失效时）：别让进程变成死循环空转，
        // 交给 launchd 决定 —— KeepAlive 会把它拉回来。
        Thread.sleep(forTimeInterval: 5)
        exit(0)
    }
}
