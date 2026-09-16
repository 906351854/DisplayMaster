import Foundation

// 自动亮度端到端诊断（只读，不动任何显示器）：
// 每 500ms 采样一次环境光代理读数，持续 8 秒 —— 用手遮住笔记本顶部传感器
// 或开关灯，能看到读数变化即说明传感器链路通；随后打印映射目标与各外接屏现状。
// 用法: DisplayMaster --als-test
func runALSTest() {
    print("=== Display Manager 环境光自动亮度 · 诊断 ===")
    let sensor = AmbientLight.sensorPathAvailable
    print("传感器通路（内置屏环境光补偿）: \(sensor ? "✓ 可用" : "✗ 当前不可用（内置屏离线或本机不支持）")")

    guard let first = AmbientLight.normalizedLevel() else {
        print("当前读数: 拿不到 —— 内置屏不在线时这是预期行为（自动亮度会降级为保持现状）")
        print("提示: 让内置屏亮起来（或在菜单里暂时关掉「自动关闭内置屏」）再测")
        print("开关状态: \(DisplayManager.shared.autoBrightnessExternals ? "已打开" : "未打开")")
        return
    }

    print("开关状态: \(DisplayManager.shared.autoBrightnessExternals ? "已打开" : "未打开")")
    print("采样 8 秒（每 0.5 秒一次），期间遮挡/照亮笔记本顶部传感器，读数应当变化：")
    var values: [Double] = []
    for i in 0..<16 {
        if i > 0 { Thread.sleep(forTimeInterval: 0.5) }
        if let v = AmbientLight.normalizedLevel() {
            values.append(v)
            print(String(format: "  [%04.1fs] 环境光读数 %.3f", Double(i) * 0.5, v))
        } else {
            print(String(format: "  [%04.1fs] 读数丢失（降级保持现状）", Double(i) * 0.5))
        }
    }
    if let lo = values.min(), let hi = values.max(), values.count > 1 {
        print(String(format: "波动范围: %.3f … %.3f（差 %.3f，>0 说明传感器链路有响应）", lo, hi, hi - lo))
    }

    let diag = DisplayManager.shared.autoBrightnessDiagnostic()
    if let target = diag.target {
        print(String(format: "映射目标亮度: %.0f%%（下限 12%%，线性映射）", target * 100))
    }
    if diag.lines.isEmpty {
        print("外接屏: 无在线外接屏")
    } else {
        print("外接屏现状:")
        for l in diag.lines { print(l) }
    }
}
