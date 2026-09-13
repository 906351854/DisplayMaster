import Foundation
import IOKit
import CoreGraphics

// MARK: - IOAVService 私有符号（IOKit.framework 内已确认存在）
@_silgen_name("IOAVServiceCreateWithService")
func _avCreate(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceWriteI2C")
func _avWrite(_ service: CFTypeRef, _ chip: UInt32, _ dataAddr: UInt32,
              _ data: UnsafeMutablePointer<UInt8>, _ length: UInt32) -> IOReturn

@_silgen_name("IOAVServiceReadI2C")
func _avRead(_ service: CFTypeRef, _ chip: UInt32, _ dataAddr: UInt32,
             _ data: UnsafeMutablePointer<UInt8>, _ length: UInt32) -> IOReturn

let kDDCChip: UInt32 = 0x37
let kDDCData: UInt32 = 0x51
let kHostAddr: UInt8 = 0x6E          // 0x37 << 1
let kSourceAddr: UInt8 = 0x51

func xorChecksum(_ bytes: [UInt8]) -> UInt8 {
    bytes.reduce(UInt8(0)) { $0 ^ $1 }
}

/// 扫描所有 DCPAVServiceProxy，返回 (Location, IOAVService)
func scanAVServices() -> [(String, CFTypeRef)] {
    var out: [(String, CFTypeRef)] = []
    var iter: io_iterator_t = 0
    let match = IOServiceMatching("DCPAVServiceProxy")
    guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else {
        print("  ✗ 无法匹配 DCPAVServiceProxy")
        return out
    }
    defer { IOObjectRelease(iter) }
    var svc = IOIteratorNext(iter)
    while svc != 0 {
        var loc = "?"
        if let p = IORegistryEntryCreateCFProperty(svc, "Location" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String { loc = p }
        var name = "?"
        if let p = IORegistryEntryCreateCFProperty(svc, "IODisplayPrefsKey" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String { name = p.components(separatedBy: "/").last ?? p }
        print("  发现 DCPAVServiceProxy  Location=\(loc)  prefs=\(name)")
        if let av = _avCreate(kCFAllocatorDefault, svc)?.takeRetainedValue() {
            out.append((loc, av))
        } else {
            print("    ✗ IOAVServiceCreateWithService 返回 nil")
        }
        IOObjectRelease(svc)
        svc = IOIteratorNext(iter)
    }
    return out
}

/// 读取 VCP 功能：返回 (当前值, 最大值)
func readVCP(_ av: CFTypeRef, _ vcp: UInt8) -> (cur: UInt16, max: UInt16)? {
    var body: [UInt8] = [0x82, 0x01, vcp]                 // length=2, GetVCP, code
    body.append(xorChecksum([kHostAddr, kSourceAddr] + body))

    var req = body
    let wret = _avWrite(av, kDDCChip, kDDCData, &req, UInt32(req.count))

    var reply = [UInt8](repeating: 0, count: 11)
    let rret = _avRead(av, kDDCChip, kDDCData, &reply, UInt32(reply.count))

    print("    write(0x\(String(vcp, radix: 16)))=\(wret)  read=\(rret)  reply=[\(reply.map { String(format: "%02X", $0) }.joined(separator: " "))]")

    // 期望: 6E 88 02 result vcp typeHi typeLo maxHi maxLo curHi curLo
    guard rret == KERN_SUCCESS, reply[0] == kHostAddr, reply[2] == 0x02, reply[3] == 0x00 else {
        return nil
    }
    let maxV = (UInt16(reply[7]) << 8) | UInt16(reply[8])
    let curV = (UInt16(reply[9]) << 8) | UInt16(reply[10])
    return (curV, maxV)
}

/// 设置 VCP
@discardableResult
func writeVCP(_ av: CFTypeRef, _ vcp: UInt8, _ value: UInt16) -> IOReturn {
    var body: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)]
    body.append(xorChecksum([kHostAddr, kSourceAddr] + body))
    var req = body
    return _avWrite(av, kDDCChip, kDDCData, &req, UInt32(req.count))
}

// MARK: - 主流程
print("=== DDC 通路探测 ===")
let services = scanAVServices()
print("可用 IOAVService: \(services.count) 个\n")

let external = services.filter { $0.0.lowercased().contains("external") }
print("外部显示器服务: \(external.count) 个")
for (loc, av) in external {
    print("\n--- 探测 \(loc) ---")
    // 0x10 = 亮度, 0x12 = 对比度, 0xDF = 电源
    for (vcp, label) in [(UInt8(0x10), "亮度 Brightness"), (UInt8(0x12), "对比度 Contrast"), (UInt8(0xDF), "电源 Power")] {
        if let r = readVCP(av, vcp) {
            let pct = r.max > 0 ? Int(Double(r.cur) / Double(r.max) * 100) : 0
            print("    ✓ \(label) (VCP 0x\(String(vcp, radix: 16))): 当前=\(r.cur) 最大=\(r.max) → \(pct)%")
        } else {
            print("    ✗ \(label) 无响应")
        }
    }
}
print("\n=== 完成 ===")
