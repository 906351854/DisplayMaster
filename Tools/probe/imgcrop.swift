// imgcrop.swift — 从截图里裁一块并放大，用于核对细节（连字、小图标、开关状态）
//
// 用法: swift imgcrop.swift <源图> <输出图> <x> <y> <宽> <高> [放大倍数=4]
//
// 坐标原点在左上角，和你在预览里看到的方位一致。

import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count >= 7 else {
    print("用法: swift imgcrop.swift <源图> <输出图> <x> <y> <宽> <高> [放大倍数=4]")
    exit(1)
}

let srcURL = URL(fileURLWithPath: a[1]) as CFURL
let dstURL = URL(fileURLWithPath: a[2]) as CFURL
guard let src = CGImageSourceCreateWithURL(srcURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("读不到源图: \(a[1])"); exit(1)
}

let x = Int(a[3]) ?? 0
let y = Int(a[4]) ?? 0
let w = Int(a[5]) ?? 100
let h = Int(a[6]) ?? 100
let scale = a.count > 7 ? (Int(a[7]) ?? 4) : 4

print("源图尺寸: \(img.width)×\(img.height)")
let rect = CGRect(x: x, y: y, width: w, height: h).intersection(
    CGRect(x: 0, y: 0, width: img.width, height: img.height))
guard let cropped = img.cropping(to: rect) else { print("裁剪失败"); exit(1) }

let dw = Int(rect.width) * scale
let dh = Int(rect.height) * scale
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: dw, height: dh, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("建上下文失败"); exit(1)
}
ctx.interpolationQuality = .high
ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: dw, height: dh))

guard let out = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(dstURL, UTType.png.identifier as CFString, 1, nil) else {
    print("写图失败"); exit(1)
}
CGImageDestinationAddImage(dest, out, nil)
CGImageDestinationFinalize(dest)
print("已保存 \(a[2]) (\(dw)×\(dh))")
