import AppKit

// 命令行诊断入口：命中任何一条诊断命令都会在那里 exit，不会走回这里。
runDiagnosticCommandIfNeeded()

// 菜单栏常驻工具：无 Dock 图标
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
