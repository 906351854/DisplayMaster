// make-dmg-background.swift
//
// 生成 DMG 安装窗口的背景图。
//
// 设计基调与官网 / 应用图标一致：极深底色 + 青→紫霓虹光晕，
// 中间一个指向右侧的箭头，暗示「把左边的图标拖到右边」。
// 刻意不放文字 —— DMG 背景是烤进图里的，写字就没法跟着系统语言变了。
//
// 用法：
//   swift Tools/make-dmg-background.swift <输出路径> <宽pt> <高pt> [倍率]
//
// 倍率说明：Finder 是按 1:1 像素绘制 .DS_Store 背景图的（在真实 DMG 上量过，
// 大厂发的成品也是 1x / 72dpi），所以倍率给 1 最保险；给 2 只是留个对照。

import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("用法: make-dmg-background.swift <输出路径> <宽pt> <高pt> [倍率]\n".data(using: .utf8)!)
    exit(1)
}
let outPath = args[1]
guard let wPt = Double(args[2]), let hPt = Double(args[3]) else {
    FileHandle.standardError.write("宽高必须是数字\n".data(using: .utf8)!)
    exit(1)
}
let scale = args.count >= 5 ? (Double(args[4]) ?? 1) : 1
// 视觉中心距离顶部多少点。要和 .DS_Store 里图标的位置用同一个值，
// 否则背景里的落点框会和真实图标错开。不传就取 0.44H。
let centerYArg = args.count >= 6 ? Double(args[5]) : nil

let px = Int((wPt * scale).rounded())
let py = Int((hPt * scale).rounded())

guard let ctx = CGContext(data: nil,
                          width: px, height: py,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write("创建绘图上下文失败\n".data(using: .utf8)!)
    exit(1)
}

ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high
// 之后一律用「点」作坐标，倍率交给这一句
ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

let W = CGFloat(wPt), H = CGFloat(hPt)

// MARK: - 小工具

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// Finder 的图标位置是从左上角算的，CoreGraphics 是从左下角算 —— 这里统一成「距顶部」来写代码。
func fromTop(_ y: CGFloat) -> CGFloat { H - y }

func fill(_ rect: CGRect, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fill(rect)
}

/// 一团柔和的光晕
func glow(at center: CGPoint, radius: CGFloat, color: CGColor, alpha: CGFloat) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let comps: [CGFloat] = [0, 0, 0, alpha, 0, 0, 0, 0]
    guard let grad = CGGradient(colorSpace: space, colorComponents: comps, locations: [0, 1], count: 2) else { return }
    ctx.saveGState()
    ctx.drawRadialGradient(grad,
                           startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius,
                           options: [])
    ctx.restoreGState()
}

/// 用渐变描一条路径（先把路径加粗转成填充区域，再裁剪填充渐变）
func strokeWithGradient(path: CGPath, lineWidth: CGFloat, alpha: CGFloat,
                        from: CGPoint, to: CGPoint, colors: [CGColor]) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let grad = CGGradient(colorsSpace: space, colors: colors as CFArray,
                               locations: nil) else { return }
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.addPath(path)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(grad, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// MARK: - 1. 底色

fill(CGRect(x: 0, y: 0, width: W, height: H), rgb(0x0A0A11))

// 上深下浅的极弱渐变，让背景不至于像一块死板的纯色
do {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let grad = CGGradient(colorsSpace: space,
                          colors: [rgb(0x131320), rgb(0x0A0A11), rgb(0x06060A)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.saveGState()
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: H),
                           end: CGPoint(x: 0, y: 0),
                           options: [])
    ctx.restoreGState()
}

// MARK: - 2. 两处柔光（左边青色给应用图标，右边紫色给 Applications）

// 视觉中心：由调用方传入（通常是 .DS_Store 里图标的位置），保证落点框和真实图标对齐。
// 注意 Finder 会把内容区整体往下挪一点（本机实测约 30pt），但图标和背景图是
// 一起挪的，所以只要两边用同一个数值就对得上。
let centerY = fromTop(centerYArg ?? (H * 0.44))

let leftCenter = CGPoint(x: W * 0.25, y: centerY)
let rightCenter = CGPoint(x: W * 0.75, y: centerY)

glow(at: leftCenter, radius: W * 0.34, color: rgb(0x22D3EE), alpha: 0.13)
glow(at: rightCenter, radius: W * 0.34, color: rgb(0xA855F7), alpha: 0.13)

// MARK: - 3. 两个落点提示（很淡的圆角方框，暗示「这里要放东西」）
// 尺寸是一路调出来的：
//   132×132 —— 几乎被 128pt 的图标整个盖住，只在边缘露一圈，看着像图标自带的描边
//   178×178 —— 够大了，但 Finder 还会在图标下面画一行文件名，方框的下边正好压在
//              文字上，很难看
//   190×216 —— 竖长卡片，把「图标 + 文件名」整格（约 154pt）完整框住并留出余量
let boxW: CGFloat = 190
let boxH: CGFloat = 216
for (center, tint, alpha) in [(leftCenter, rgb(0x22D3EE), CGFloat(0.22)),
                              (rightCenter, rgb(0xA855F7), CGFloat(0.22))] {
    let rect = CGRect(x: center.x - boxW / 2, y: center.y - boxH / 2,
                      width: boxW, height: boxH)
    let path = CGPath(roundedRect: rect, cornerWidth: 34, cornerHeight: 34, transform: nil)
    ctx.saveGState()
    ctx.setStrokeColor(tint.copy(alpha: alpha)!)
    ctx.setLineWidth(1.5)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - 4. 中间的箭头（对着右边，表示「往那边拖」）

let midY = centerY
let chevrons: [(CGFloat, CGFloat)] = [(W * 0.50 - 21, 0.34), (W * 0.50, 0.66), (W * 0.50 + 21, 1.0)]
let arrowColors = [rgb(0x22D3EE), rgb(0x8B5CF6), rgb(0xE879F9)]

for (x, alpha) in chevrons {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x - 7, y: midY + 15))
    p.addLine(to: CGPoint(x: x + 7, y: midY))
    p.addLine(to: CGPoint(x: x - 7, y: midY - 15))
    strokeWithGradient(path: p,
                       lineWidth: 4.2,
                       alpha: alpha,
                       from: CGPoint(x: x - 7, y: midY),
                       to: CGPoint(x: x + 7, y: midY),
                       colors: arrowColors)
}

// MARK: - 5. 顶部一条极弱的分隔线，给画面收个上边
// 只在顶部放：底部那条会被 Finder 的状态栏压住，画了也看不见。

do {
    let y = H * 0.09
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let grad = CGGradient(colorsSpace: space,
                          colors: [rgb(0xFFFFFF, 0), rgb(0xFFFFFF, 0.07), rgb(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: y, width: W, height: 1))
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: y), end: CGPoint(x: W, y: y), options: [])
    ctx.restoreGState()
}

// MARK: - 输出

guard let cgImage = ctx.makeImage() else {
    FileHandle.standardError.write("生成图像失败\n".data(using: .utf8)!)
    exit(1)
}

let rep = NSBitmapImageRep(cgImage: cgImage)
// 逻辑尺寸设成「点」，像素尺寸保持 px —— 这样写出的 TIFF 会带上正确的分辨率
rep.size = NSSize(width: wPt, height: hPt)

guard let data = rep.representation(using: .tiff, properties: [:]) else {
    FileHandle.standardError.write("编码 TIFF 失败\n".data(using: .utf8)!)
    exit(1)
}

do {
    try data.write(to: URL(fileURLWithPath: outPath))
} catch {
    FileHandle.standardError.write("写入失败: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}

print("  背景图：\(outPath)  \(px)×\(py)px  逻辑 \(Int(wPt))×\(Int(hPt))pt  \(Int(scale))x  视觉中心 y=\(Int(centerYArg ?? (hPt * 0.44)))")
