import AppKit

// 自检模式：不开 GUI，直接验证枚举 / 分辨率 / HiDPI / 亮度四条路径
// 用法: Display Master.app/Contents/MacOS/DisplayMaster --selftest
func runSelfTest() {
    _ = NSApplication.shared          // 建立与 window server 的连接，保证 NSScreen 可用
    let dm = DisplayManager.shared
    print("=== \(AppInfo.name) \(AppInfo.bundleVersion) 自检 ===")
    print("私有 API 可用:")
    print("  CGSConfigureDisplayEnabled : \(PrivateAPI.shared.configureDisplayEnabled != nil ? "✓" : "✗")")
    print("  DisplayServicesGetBrightness : \(PrivateAPI.shared.getBrightness != nil ? "✓" : "✗")")
    print("  DisplayServicesSetBrightness : \(PrivateAPI.shared.setBrightness != nil ? "✓" : "✗")")
    print("  DDC(IOAVService)              : \(DDC.shared.isAvailable ? "✓" : "✗")")
    print("  DDC 状态                      : \(ddcStateLine())")
    print("  DDC 原始诊断 (VCP 0x10): \(DDC.shared.diagnoseRaw(0, 0x10))")
    print("  DDC 扫描日志:")
    for line in DDC.shared.scanLog { print("    · \(line)") }
    print("  后台项（崩溃保活）            : \(KeepAliveAgent.diagnosticLine)")
    // 这两行值得单独打：救援路径的成败全看它们，而且两个都有坑 ——
    // `displaysAsleep()` 只查**在线**的屏，在线列表为空时它会答「没睡」，
    // 而那恰恰是最需要判断、最容易误判的场合。真正可信的是下面「屏幕亮着」那一行
    // （powerd 的 "…display is on" 断言，不依赖显示器在不在线）。
    print("  屏幕睡眠（只查在线屏）        : \(dm.debugDisplaysAsleep() ? "是" : "否")"
          + "（在线 [\(DisplayManager.idList(dm.onlineIDs()))]）")
    switch dm.debugScreenIsLit() {
    case .lit:
        print("  屏幕亮着（powerd 断言）       : 是")
    case .dark:
        print("  屏幕亮着（powerd 断言）       : 否")
    case .unreadable(let why):
        print("  屏幕亮着（powerd 断言）       : 读不到 —— \(why)")
    }
    // 亮度键这一行合并写法：开关、权限、监听三件事都会让它「装了却没反应」，
    // 分开报反而容易只看一半（见 brightnessKeysStateLine 的几种输出）。
    // 这里**真的试着装一次监听**再报：只说「没装上」的话，分不清是开关关着、
    // 还是权限没给、还是系统压根不让建 tap —— 而这三者的解决办法完全不同。
    // 子开关先推给监听再 start()，否则 F 行通道压根不会被尝试（见 runHotKeyStatus）。
    BrightnessKeyMonitor.shared.capturesFunctionRow = dm.brightnessKeysFunctionRow
    let keyErr = BrightnessKeyMonitor.shared.start()
    print("  亮度键（F1 / F2）接管         : " + dm.brightnessKeysStateLine()
          + (keyErr.map { "　〔装监听失败：\($0)〕" } ?? ""))
    // 吞键范围单独一行：这是「这功能会不会弄坏键盘」的**唯一**线索 ——
    // 而「已接管」三个字在这件事上什么也没说（2026-09-27 的「键盘打不了字」）。
    print("  亮度键 · 吞键范围             : " + BrightnessKeyMonitor.shared.swallowScope)
    BrightnessKeyMonitor.shared.stop()
    print("")
    let list = dm.displays()
    print("检测到 \(list.count) 台显示器")
    for d in list {
        print("── \(d.name)")
        print("   id=\(d.id)  内置=\(d.isBuiltin)  主屏=\(d.isMain)")
        print("   逻辑分辨率 \(d.logicalWidth)×\(d.logicalHeight)   物理像素 \(d.pixelWidth)×\(d.pixelHeight)")
        print("   分辨率菜单 常显 \(dm.uniqueModes(d).count) 项 / 完整 \(dm.uniqueModes(d, includeAll: true).count) 项")
        if let toggle = dm.hidpiToggle(d) {
            let t = toggle.target
            print("   HiDPI：当前\(dm.isHiDPI(d) ? "已开启" : "已关闭")"
                  + " → 目标 \(t.width)×\(t.height) 物理 \(t.pixelWidth)×\(t.pixelHeight)"
                  + (toggle.sameResolution ? "（同分辨率换倍率）" : "（无同分辨率变体，取最接近档位）"))
        } else {
            print("   HiDPI：当前\(dm.isHiDPI(d) ? "已开启" : "已关闭")，该屏没有相反的渲染倍率，不可切换")
        }
        if let b = dm.brightness(of: d) {
            print("   当前亮度 \(Int((b * 100).rounded()))%  (可读写)")
            if let warn = dm.brightnessWarning(for: d) { print("   ⚠️ \(warn)") }
        } else {
            let note = dm.ddcNote(for: d)
            print("   亮度：不可控" + (note.map { "  —— \($0)" } ?? ""))
        }
    }
    print("")
    print("被本应用关闭、等待重新打开的显示器: \(disabledLine())")
    exit(0)
}

