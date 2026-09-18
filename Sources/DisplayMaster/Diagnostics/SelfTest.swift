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

