// 打印所有在线显示器的属性，用来找出「虚拟显示器」的特征。
//
// 背景：macOS 26 在所有真实显示器都不可用时会创建一个虚拟显示器维持显示输出，
// 它的 CGDisplayIsBuiltin 返回 0 —— 于是会被误当成「还有外接屏在用」，
// 让「拔掉外接屏就把内屏开回来」这条规则完全不触发。
// 这个探针把各种可能的判据一次性列出来，好挑一个可靠的。
//
// 编译：swiftc -O Tools/probe/dumpprops.swift -o /tmp/dumpprops
// 运行：/tmp/dumpprops

import Foundation
import CoreGraphics
import AppKit
import IOKit

typealias U32Fn = @convention(c) (CGDirectDisplayID) -> UInt32

let cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
let global = dlopen(nil, RTLD_LAZY)

func sym(_ name: String) -> U32Fn? {
    for h in [cg, global] {
        guard let h = h, let s = dlsym(h, name) else { continue }
        return unsafeBitCast(s, to: U32Fn.self)
    }
    return nil
}

let queries: [(String, U32Fn?)] = [
    ("IsBuiltin", sym("CGDisplayIsBuiltin")),
    ("IsVirtualDevice", sym("CGDisplayIsVirtualDevice")),
    ("IsMain", sym("CGDisplayIsMain")),
    ("IsActive", sym("CGDisplayIsActive")),
    ("IsOnline", sym("CGDisplayIsOnline")),
    ("IsAsleep", sym("CGDisplayIsAsleep")),
    ("IsInMirrorSet", sym("CGDisplayIsInMirrorSet")),
    ("IsAlwaysInMirrorSet", sym("CGDisplayIsAlwaysInMirrorSet")),
    ("IsInHWMirrorSet", sym("CGDisplayIsInHWMirrorSet")),
    ("IsStereo", sym("CGDisplayIsStereo")),
    ("UsesOpenGLAcceleration", sym("CGDisplayUsesOpenGLAcceleration")),
    ("SupportsAllModes", sym("CGDisplaySupportsAllModes")),
]

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

var count: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(max(count, 1)))
CGGetOnlineDisplayList(count, &ids, &count)
let online = Array(ids.prefix(Int(count)))

print("CoreGraphics 在线显示器: \(online)")

// NSScreen 一侧的信息
var nsInfo: [CGDirectDisplayID: String] = [:]
for s in NSScreen.screens {
    guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
    let d = s.deviceDescription
    nsInfo[CGDirectDisplayID(n.uint32Value)] =
        "\(s.localizedName)  \(Int(s.frame.width))x\(Int(s.frame.height))"
        + "  desc=\(d)"
}

// IOKit 一侧：找出所有带 EDID 信息的显示服务，用来对照
var hwList: [String] = []
var iter: io_iterator_t = 0
if IOServiceGetMatchingServices(kIOMainPortDefault,
                                IOServiceMatching("IODisplayConnect"), &iter) == KERN_SUCCESS {
    while case let svc = IOIteratorNext(iter), svc != 0 {
        defer { IOObjectRelease(svc) }
        let vendor = IORegistryEntryCreateCFProperty(svc, "DisplayVendorID" as CFString, nil, 0)?.takeRetainedValue() as? Int
        let product = IORegistryEntryCreateCFProperty(svc, "DisplayProductID" as CFString, nil, 0)?.takeRetainedValue() as? Int
        let serial = IORegistryEntryCreateCFProperty(svc, "DisplaySerialNumber" as CFString, nil, 0)?.takeRetainedValue() as? Int
        hwList.append("vendor=\(vendor.map(String.init) ?? "-") product=\(product.map(String.init) ?? "-") serial=\(serial.map(String.init) ?? "-")")
    }
    IOObjectRelease(iter)
}
print("IODisplayConnect 服务: \(hwList.isEmpty ? "（无）" : hwList.joined(separator: " | "))")
print()

for id in online {
    print("=== id=\(id) ===")
    print("  \(pad("NSScreen", 24)): \(nsInfo[id] ?? "（NSScreen 里没有）")")
    print("  \(pad("vendor/model/serial", 24)): \(CGDisplayVendorNumber(id))/\(CGDisplayModelNumber(id))/\(CGDisplaySerialNumber(id))")
    if let cur = CGDisplayCopyDisplayMode(id) {
        print("  \(pad("mode", 24)): \(cur.width)x\(cur.height) 像素 \(cur.pixelWidth)x\(cur.pixelHeight) @\(cur.refreshRate)Hz")
    }
    for (name, fn) in queries {
        guard let fn = fn else { print("  \(pad(name, 24)): （符号不存在）"); continue }
        print("  \(pad(name, 24)): \(fn(id))")
    }
    if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
        print("  \(pad("UUID", 24)): \(CFUUIDCreateString(nil, uuid) as String? ?? "?")")
    }
    print()
}
