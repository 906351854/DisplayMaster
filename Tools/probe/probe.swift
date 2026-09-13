import Foundation
import CoreGraphics
import AppKit
import Darwin

print("=== 系统: \(ProcessInfo.processInfo.operatingSystemVersionString) ===")

// ---------- 1. 显示器枚举 ----------
var cnt: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &cnt)
var ds = [CGDirectDisplayID](repeating: 0, count: Int(max(cnt, 1)))
CGGetOnlineDisplayList(cnt, &ds, &cnt)
print("\n=== 在线显示器 \(cnt) 台 ===")
for d in ds.prefix(Int(cnt)) {
    let builtin = CGDisplayIsBuiltin(d) != 0
    let vendor = CGDisplayVendorNumber(d), model = CGDisplayModelNumber(d)
    print("displayID=\(d)  内置=\(builtin)  主屏=\(CGDisplayIsMain(d) != 0)  像素=\(CGDisplayPixelsWide(d))x\(CGDisplayPixelsHigh(d))  vendor=\(vendor) model=\(model)")
    if let arr = CGDisplayCopyAllDisplayModes(d, nil) as? [CGDisplayMode] {
        if let cur = CGDisplayCopyDisplayMode(d) {
            print("  当前: \(cur.width)x\(cur.height) 像素=\(cur.pixelWidth)x\(cur.pixelHeight) @\(cur.refreshRate)Hz")
        }
        let uniq = Set(arr.map { "\($0.width)x\($0.height)" })
        let hi = arr.filter { $0.pixelWidth > $0.width }.count
        print("  模式总数=\(arr.count)  逻辑分辨率种类=\(uniq.count)  HiDPI模式=\(hi)")
        print("  分辨率: \(uniq.sorted().prefix(10).joined(separator: ", "))")
    }
}

// ---------- 2. 私有符号探测 ----------
print("\n=== 私有 API 符号探测 ===")
let frameworks = [
  "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
  "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
  "/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay",
  "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
  "/System/Library/Frameworks/IOKit.framework/IOKit",
]
let wanted = [
  "CGSConfigureDisplayEnabled", "SLSConfigureDisplayEnabled", "CGSSetDisplayPowerState",
  "CGSGetDisplayPowerState", "CGSGetDisplayEnabled", "CGSRemoveDisplay",
  "CGSMainConnectionID", "CGSDefaultConnection", "CGSGetConnectionIDForPSN",
  "DisplayServicesGetBrightness", "DisplayServicesSetBrightness", "DisplayServicesCanChangeBrightness",
  "DisplayServicesIsSmartDisplay", "DisplayServicesBrightnessChanged",
  "IOAVServiceCreate", "IOAVServiceCreateWithService", "IOAVServiceWriteI2C", "IOAVServiceReadI2C",
]
for p in frameworks {
    guard let h = dlopen(p, RTLD_LAZY) else { print("✗ dlopen 失败: \(p)"); continue }
    let found = wanted.filter { dlsym(h, $0) != nil }
    let nm = p.split(separator: "/").last.map(String.init) ?? p
    print("✓ \(nm) → \(found.count) 个: \(found.joined(separator: ", "))")
}
if let gh = dlopen(nil, RTLD_LAZY) {
    let g = wanted.filter { dlsym(gh, $0) != nil }
    print("全局: \(g.joined(separator: ", "))")
}

// ---------- 3. 亮度只读测试（安全） ----------
print("\n=== 内置屏亮度读取测试 ===")
if let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
   let s = dlsym(h, "DisplayServicesCanChangeBrightness") {
    typealias CanF = @convention(c) (CGDirectDisplayID) -> Int32
    let can = unsafeBitCast(s, to: CanF.self)
    for d in ds.prefix(Int(cnt)) {
        print("  displayID=\(d) CanChangeBrightness=\(can(d))")
    }
}
if let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
   let s = dlsym(h, "DisplayServicesGetBrightness") {
    typealias GetF = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    let get = unsafeBitCast(s, to: GetF.self)
    for d in ds.prefix(Int(cnt)) {
        var b: Float = -1
        let r = get(d, &b)
        print("  displayID=\(d) GetBrightness ret=\(r) value=\(b)")
    }
}
