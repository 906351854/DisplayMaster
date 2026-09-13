// make-icons.swift — 从 Resources/Logo.jpg 生成应用图标与菜单栏图标
//
//   swift Tools/make-icons.swift [仓库根目录]
//
// 产出：
//   Resources/AppIcon.icns         macOS 应用图标（squircle 遮罩 + 全套尺寸）
//   Resources/MenuBarIcon.png      菜单栏图标 @1x / @2x / @3x（template 单色）
//   Resources/MenuBarIcon@2x.png
//   Resources/MenuBarIcon@3x.png
//   docs/icon.png                  README 用展示图
//   /tmp/menubar-preview.png       视觉自检图（放大 8 倍，白/深底各一份）
//
// 为什么菜单栏图标要重绘而不是缩放原图：
// 原图的霓虹描边在 1639px 下只有几个像素宽，缩到 18pt 后线宽不足 0.1px，
// 必然糊成一团灰。菜单栏需要的是高对比的单色字形，所以这里按原图的
// 「笔记本」形态重绘一个矢量字形。

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 基础工具

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func log(_ msg: String) { print(msg) }

let repoRoot: URL = {
    let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: arg)
}()

let resourcesDir = repoRoot.appendingPathComponent("Resources")
let docsDir = repoRoot.appendingPathComponent("docs")
try? FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)

/// 把 CGImage 写成 PNG
func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        die("无法创建 \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { die("写入 \(url.path) 失败") }
}

func makeContext(pixels: Int) -> CGContext {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        die("创建 \(pixels)px 上下文失败")
    }
    ctx.interpolationQuality = .high
    return ctx
}

// MARK: - 载入并居中裁成方形

let logoURL = resourcesDir.appendingPathComponent("Logo.jpg")
guard let srcImage = NSImage(contentsOf: logoURL),
      let tiff = srcImage.tiffRepresentation,
      let srcRep = NSBitmapImageRep(data: tiff),
      let cgSource = srcRep.cgImage else {
    die("读不到素材：\(logoURL.path)")
}

let side = min(cgSource.width, cgSource.height)
let cropRect = CGRect(x: (cgSource.width - side) / 2,
                      y: (cgSource.height - side) / 2,
                      width: side, height: side)
guard let artwork = cgSource.cropping(to: cropRect) else { die("居中裁剪失败") }
log("素材 \(cgSource.width)×\(cgSource.height) → 裁剪为 \(side)×\(side)")

// MARK: - 应用图标（macOS 图标网格：1024 画布内 824×824 的圆角方形）

/// Big Sur 之后的 macOS 图标规范：内容区占 824/1024，圆角半径约 185.4/824。
func renderAppIcon(pixels: Int) -> CGImage {
    let ctx = makeContext(pixels: pixels)
    let canvas = CGFloat(pixels)
    let inset = canvas * (100.0 / 1024.0)
    let content = canvas - inset * 2
    let radius = content * (185.4 / 824.0)
    let rect = CGRect(x: inset, y: inset, width: content, height: content)

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.draw(artwork, in: rect)
    ctx.restoreGState()
    guard let out = ctx.makeImage() else { die("生成 \(pixels)px 应用图标失败") }
    return out
}

// 生成 .iconset（iconutil 要求的固定命名）
let iconsetDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DisplayMaster.iconset")
try? FileManager.default.removeItem(at: iconsetDir)
try! FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let iconSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for spec in iconSizes {
    writePNG(renderAppIcon(pixels: spec.pixels), to: iconsetDir.appendingPathComponent("\(spec.name).png"))
}
log("iconset 已生成（\(iconSizes.count) 个尺寸）")

let icnsURL = resourcesDir.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { die("iconutil 转换 icns 失败") }
log("✓ \(icnsURL.lastPathComponent)")

// README 用展示图
writePNG(renderAppIcon(pixels: 512), to: docsDir.appendingPathComponent("icon.png"))
log("✓ docs/icon.png")

// MARK: - 菜单栏字形（按原图的笔记本形态重绘）

/// 在 18×18 的设计坐标里画一台笔记本：屏幕描边 + 底座实心，y 轴向下。
/// 屏幕与底座之间留 1.4 单位的缝，保证 18px 下两者不糊在一起。
func drawMenuBarGlyph(in ctx: CGContext, scale: CGFloat, tint: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: 0, y: 18 * scale)
    ctx.scaleBy(x: scale, y: -scale)          // 换成 y 向下的设计坐标

    ctx.setFillColor(tint)
    ctx.setStrokeColor(tint)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)

    // 屏幕：圆角描边矩形
    let screen = CGRect(x: 3.15, y: 2.15, width: 11.7, height: 9.05)
    ctx.setLineWidth(1.45)
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 1.45, cornerHeight: 1.45, transform: nil))
    ctx.strokePath()

    // 底座：比屏幕略宽的实心圆角条
    let base = CGRect(x: 1.5, y: 12.6, width: 15.0, height: 1.75)
    ctx.addPath(CGPath(roundedRect: base, cornerWidth: 0.87, cornerHeight: 0.87, transform: nil))
    ctx.fillPath()

    ctx.restoreGState()
}

func renderMenuBarIcon(pixels: Int, tint: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)) -> CGImage {
    let ctx = makeContext(pixels: pixels)
    drawMenuBarGlyph(in: ctx, scale: CGFloat(pixels) / 18.0, tint: tint)
    guard let out = ctx.makeImage() else { die("生成菜单栏图标失败") }
    return out
}

for (suffix, pixels) in [("", 18), ("@2x", 36), ("@3x", 54)] {
    let url = resourcesDir.appendingPathComponent("MenuBarIcon\(suffix).png")
    writePNG(renderMenuBarIcon(pixels: pixels), to: url)
    log("✓ \(url.lastPathComponent)  \(pixels)×\(pixels)")
}

// MARK: - 视觉自检图：把三种分辨率都按 18pt 渲染，放大 8 倍摆在浅/深两色菜单栏上

func previewStrip() -> CGImage {
    let zoom: CGFloat = 8
    let glyph = 18 * zoom                       // 三种分辨率都按同一视觉尺寸画
    let cell = glyph + 48
    let height = glyph + 48
    let width = cell * 3
    guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        die("创建自检图失败")
    }
    ctx.interpolationQuality = .high

    // 左边浅色、右边深色，模拟菜单栏的两种外观
    ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1))
    ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))

    // 每个分辨率各自画一遍，浅色区填黑、深色区填白（等价于 template 的自动反色）
    for (i, pixels) in [18, 36, 54].enumerated() {
        let x = CGFloat(i) * cell + (cell - glyph) / 2
        let y = (height - glyph) / 2
        let target = CGRect(x: x, y: y, width: glyph, height: glyph)

        for light in [true, false] {
            let halfWidth = width / 2
            let clipRect = light ? CGRect(x: 0, y: 0, width: halfWidth, height: height)
                                 : CGRect(x: halfWidth, y: 0, width: halfWidth, height: height)
            ctx.saveGState()
            ctx.clip(to: clipRect)
            ctx.draw(renderMenuBarIcon(pixels: pixels, tint: light ? CGColor(red: 0, green: 0, blue: 0, alpha: 1)
                                                                  : CGColor(red: 1, green: 1, blue: 1, alpha: 1)),
                     in: target)
            ctx.restoreGState()
        }
    }
    guard let out = ctx.makeImage() else { die("生成自检图失败") }
    return out
}

let previewURL = URL(fileURLWithPath: "/tmp/menubar-preview.png")
writePNG(previewStrip(), to: previewURL)
log("✓ 自检图 \(previewURL.path)")
log("\n完成。替换素材只需覆盖 Resources/Logo.jpg 后重跑本脚本。")
