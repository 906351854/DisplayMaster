import Foundation
import IOKit
import Darwin

/// 外接显示器的 DDC/CI 控制（亮度等），走 IOAVService 的私有 I2C 通道。
///
/// 时序与重试策略照搬 MonitorControl 的 Arm64DDC —— 那是目前验证最充分的
/// Apple Silicon DDC 实现，参数都是实机调出来的：
///
///   · 每个 I²C 报文必须**连发 2 遍**，每遍之前 sleep 10ms
///     （M 系 Mac 上单发报文会被吞掉，这是关键差异）
///   · 读报文：连发 2 遍 → sleep 50ms → 读 11 字节
///   · 失败要按 VESA DDC/CI 4.4.1 的错误恢复流程重试（间隔 20ms）
///
/// 另外两条设计原则是踩坑换来的：
///
///   1. **写不能被读卡住**：亮度最大值缓存起来，拖滑块时直接写，不先读一遍。
///      否则读一旦失败，写就永远发不出去 —— 表现就是「拖了没反应」。
///   2. **失败要冷却、但能自愈**：连续失败后进入冷却期，期内不再发起任何
///      I²C 事务（既不猛敲显示器，也不让菜单反复触发探测），冷却结束自动恢复。
final class DDC {
    static let shared = DDC()

    private typealias CreateF = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias WriteF = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32) -> IOReturn
    private typealias ReadF = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32) -> IOReturn

    private let createFn: CreateF?
    private let writeFn: WriteF?
    private let readFn: ReadF?

    // MARK: - DDC/CI over I²C 常量
    private let chip: UInt32 = 0x37        // 7bit DDC/CI 从机地址
    private let dataAddr: UInt32 = 0x51    // IOAVService 的数据偏移（惯例值）
    private let hostAddr: UInt8 = 0x6E     // 0x37 << 1，报文里的「目的地址」
    private let sourceAddr: UInt8 = 0x51   // 报文里的「源地址」= 主机
    private let vcpBrightness: UInt8 = 0x10

    // MARK: - 时序（MonitorControl Arm64DDC 实测值，勿随意调小）
    private let preWriteSleep: UInt32 = 10_000     // 每遍报文之前的 10ms
    private let postWriteReadSleep: UInt32 = 50_000 // 发完读请求后等显示器备答
    private let retrySleep: UInt32 = 20_000         // 轮次之间的 20ms
    private let writeCycles = 2                     // 每份报文连发 2 遍
    private let readAttempts = 3                    // 一次读取最多 3 轮

    /// 失败后的冷却时长。冷却期内不发起任何 I²C，冷却结束自动重试（自愈）。
    private let cooldownSeconds: TimeInterval = 20

    /// 仅调试用：写完是否读一次把应答取走（MonitorControl 不读，默认关）
    var drainReplyAfterWrite = false

    // MARK: - 状态
    private let lock = NSRecursiveLock()
    private var externalServices: [CFTypeRef] = []
    private(set) var scanLog: [String] = []

    private(set) var consecutiveFailures = 0
    private(set) var lastFailureAt: Date?
    private(set) var lastDiagnosis = "尚未探测"
    private(set) var lastRawReply = ""

    /// 每个外部显示器最近一次成功读到的亮度 0...1 与最大值。
    /// UI 靠它兜住滑块 —— 读失败时滑块不该消失。
    private(set) var cachedBrightness: [Int: Double] = [:]
    private(set) var cachedMax: [Int: UInt16] = [:]

    var externalCount: Int {
        lock.lock(); defer { lock.unlock() }
        return externalServices.count
    }

    var isAvailable: Bool { createFn != nil && writeFn != nil && readFn != nil }

    private init() {
        let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        let global = dlopen(nil, RTLD_LAZY)
        let handles = [iokit, global]
        func load<T>(_ name: String, _ t: T.Type) -> T? {
            for h in handles {
                guard let h = h, let s = dlsym(h, name) else { continue }
                return unsafeBitCast(s, to: t)
            }
            return nil
        }
        createFn = load("IOAVServiceCreateWithService", CreateF.self)
        writeFn = load("IOAVServiceWriteI2C", WriteF.self)
        readFn = load("IOAVServiceReadI2C", ReadF.self)
    }

    private func checksum(_ bytes: [UInt8]) -> UInt8 { bytes.reduce(UInt8(0)) { $0 ^ $1 } }

    // MARK: - 服务发现

    /// 重新扫描外部显示器的 AVService（只重建句柄，不动冷却状态）
    func refresh() {
        lock.lock(); defer { lock.unlock() }
        externalServices.removeAll()
        scanLog.removeAll()
        guard let createFn = createFn else { scanLog.append("createFn 缺失"); return }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else {
            scanLog.append("IOServiceGetMatchingServices 失败")
            return
        }
        defer { IOObjectRelease(iter) }
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            let loc = (IORegistryEntryCreateCFProperty(svc, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String) ?? "<无 Location>"
            if loc.lowercased().contains("external") {
                if let av = createFn(kCFAllocatorDefault, svc)?.takeRetainedValue() {
                    externalServices.append(av)
                    scanLog.append("External ✓ 已获取 IOAVService")
                } else {
                    scanLog.append("External ✗ IOAVServiceCreateWithService 返回 nil")
                }
            } else {
                scanLog.append("跳过 Location=\(loc)")
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iter)
        }
    }

    /// 用户手动「重新检测 DDC」：清掉失败计数与冷却，重建句柄
    func forceReprobe() {
        lock.lock(); defer { lock.unlock() }
        consecutiveFailures = 0
        lastFailureAt = nil
        lastDiagnosis = "尚未探测"
        lastRawReply = ""
        refresh()
    }

    // MARK: - 冷却

    var isCoolingDown: Bool {
        guard let t = lastFailureAt else { return false }
        return Date().timeIntervalSince(t) < cooldownSeconds
    }

    var cooldownRemaining: Int {
        guard let t = lastFailureAt else { return 0 }
        return max(0, Int((cooldownSeconds - Date().timeIntervalSince(t)).rounded(.up)))
    }

    // MARK: - I²C 原语

    private func service(_ index: Int) -> CFTypeRef? {
        guard index >= 0, index < externalServices.count else { return nil }
        return externalServices[index]
    }

    /// 发一个 I²C 报文。连发 2 遍、每遍前 sleep 10ms —— M 系 Mac 单发会被吞。
    @discardableResult
    private func send(_ av: CFTypeRef, _ bytes: [UInt8]) -> Bool {
        guard let writeFn = writeFn else { return false }
        var buf = bytes
        var ok = false
        for _ in 0..<writeCycles {
            usleep(preWriteSleep)
            ok = writeFn(av, chip, dataAddr, &buf, UInt32(buf.count)) == KERN_SUCCESS
        }
        return ok
    }

    /// 发读请求 + 收 11 字节应答。reply 原样带出，由调用方判定有效性。
    private func readOnce(_ av: CFTypeRef, _ code: UInt8, offset: UInt32, reply: inout [UInt8]) -> Bool {
        var req: [UInt8] = [0x82, 0x01, code]
        req.append(checksum([hostAddr, sourceAddr] + req))
        guard send(av, req) else { return false }
        usleep(postWriteReadSleep)
        var buf = [UInt8](repeating: 0, count: 11)
        guard let readFn = readFn, readFn(av, chip, offset, &buf, UInt32(buf.count)) == KERN_SUCCESS else { return false }
        reply = buf
        return true
    }

    /// 判定一帧是否为有效的「Get VCP Feature Reply」。
    /// 注意：**不能只看字节 0/2/3** —— 显示器不应答时驱动会把上次的残留数据
    /// 一起回填，尾巴看着完全正常（`00 10 00 00 64 00 64 A4`），必须核对
    /// 字节 4 是不是我们请求的那个 VCP 码。
    private func decode(_ reply: [UInt8], _ code: UInt8) -> (cur: UInt16, max: UInt16)? {
        guard reply.count >= 11, reply[0] == hostAddr, reply[2] == 0x02, reply[3] == 0x00, reply[4] == code else {
            return nil
        }
        let maxV = (UInt16(reply[6]) << 8) | UInt16(reply[7])
        let curV = (UInt16(reply[8]) << 8) | UInt16(reply[9])
        guard maxV > 0 else { return nil }
        return (curV, maxV)
    }

    /// 判定 DDC/CI 空报文（Null Message）：长度字节声明 0 个数据字节且校验和自洽。
    /// 本机实测帧：空报文 `6E 80 BE`（校验和 = XOR(0x80) ^ 0x3E）。
    func isNullMessage(_ reply: [UInt8]) -> Bool {
        guard reply.count >= 3, reply[0] == hostAddr else { return false }
        let dataLen = Int(reply[1] & 0x7F)
        guard dataLen == 0 else { return false }
        var x: UInt8 = 0
        for i in 1...(1 + dataLen) { x ^= reply[i] }
        return (x ^ 0x3E) == reply[1 + dataLen + 1]
    }

    // MARK: - 结果记账

    private func markSuccess() {
        consecutiveFailures = 0
        lastFailureAt = nil
        lastDiagnosis = "正常"
        lastRawReply = ""
    }

    private func markFailure(_ raw: [UInt8], context: String) {
        consecutiveFailures += 1
        lastFailureAt = Date()
        if !raw.isEmpty {
            lastRawReply = raw.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        if raw.isEmpty {
            lastDiagnosis = "\(context)：I²C 事务失败"
        } else if isNullMessage(raw) {
            lastDiagnosis = "显示器未应答（空报文）—— 冷却 \(cooldownRemaining)s 后自动重试，或给显示器断电重启"
        } else {
            lastDiagnosis = "\(context)：应答无法识别（\(lastRawReply)）"
        }
    }

    // MARK: - VCP 读写

    /// 读 VCP。返回 nil 时调用方应继续用缓存值，而不是把 UI 藏掉。
    /// - Parameter force: 忽略冷却期（供「重新检测 DDC」与诊断用）
    func readVCP(_ index: Int, _ code: UInt8, attempts: Int? = nil, force: Bool = false) -> (cur: UInt16, max: UInt16)? {
        lock.lock(); defer { lock.unlock() }

        guard isAvailable else { lastDiagnosis = "IOAVService 符号缺失"; return nil }
        if isCoolingDown && !force {
            lastDiagnosis = "DDC 无应答，冷却中（\(cooldownRemaining)s 后自动重试）"
            return nil
        }
        guard let av = service(index) else {
            lastDiagnosis = "未找到该屏的 DDC 通道"
            return nil
        }

        let tries = max(1, attempts ?? readAttempts)
        var lastRaw: [UInt8] = []

        for attempt in 0..<tries {
            // 主用 0x51；最后一轮再附带试一次 offset=0（MonitorControl 用的是 0）
            var offsets: [UInt32] = [dataAddr]
            if attempt == tries - 1 { offsets.append(0) }

            for off in offsets {
                var reply: [UInt8] = []
                guard readOnce(av, code, offset: off, reply: &reply) else { continue }
                lastRaw = reply
                if let v = decode(reply, code) {
                    markSuccess()
                    cachedMax[index] = v.max
                    return v
                }
            }
            if attempt < tries - 1 { usleep(retrySleep) }
        }

        markFailure(lastRaw, context: "读取")
        return nil
    }

    /// 写 VCP。写请求的应答不需要取走（MonitorControl 亦如此）。
    @discardableResult
    func writeVCP(_ index: Int, _ code: UInt8, _ value: UInt16, force: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }

        guard let writeFn = writeFn, let av = service(index) else {
            lastDiagnosis = "未找到该屏的 DDC 通道"
            return false
        }
        if isCoolingDown && !force {
            lastDiagnosis = "DDC 无应答，冷却中（\(cooldownRemaining)s）"
            return false
        }

        var pkt: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        pkt.append(checksum([hostAddr, sourceAddr] + pkt))

        var ok = false
        for _ in 0..<writeCycles {
            usleep(preWriteSleep)
            ok = writeFn(av, chip, dataAddr, &pkt, UInt32(pkt.count)) == KERN_SUCCESS
        }
        guard ok else {
            markFailure([], context: "写入")
            return false
        }

        if drainReplyAfterWrite {
            var drain: [UInt8] = []
            _ = readOnce(av, code, offset: dataAddr, reply: &drain)
            lastRawReply = drain.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        markSuccess()
        return true
    }

    // MARK: - 亮度专用封装

    /// 读亮度 0...1。读不到时回落到缓存值 —— 这是「滑块不消失」的关键。
    func brightness(_ index: Int) -> Double? {
        if let r = readVCP(index, vcpBrightness), r.max > 0 {
            let v = Double(r.cur) / Double(r.max)
            cachedBrightness[index] = v
            return v
        }
        return cachedBrightness[index]
    }

    /// 设置亮度 0...1。**不先读**（读失败不该挡住写），最大值走缓存。
    @discardableResult
    func setBrightness(_ index: Int, _ value: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }

        let v = max(0, min(1, value))
        var maxV = cachedMax[index]
        if maxV == nil, let r = readVCP(index, vcpBrightness, attempts: 2) {
            maxV = r.max
        }
        guard let m = maxV, m > 0 else {
            // 连最大值都拿不到：用 DDC/CI 的通用上限 100 兜一次，仍记录为未验证
            if writeVCP(index, vcpBrightness, UInt16((v * 100).rounded())) {
                cachedBrightness[index] = v
                return true
            }
            return false
        }
        let raw = UInt16((v * Double(m)).rounded())
        guard writeVCP(index, vcpBrightness, raw) else { return false }
        cachedBrightness[index] = v
        return true
    }

    /// 一次性原始诊断（绕过冷却，只发一轮事务）
    func diagnoseRaw(_ index: Int, _ code: UInt8 = 0x10) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let av = service(index) else {
            return "无第 \(index) 个外部服务（共 \(externalServices.count) 个）"
        }
        var reply: [UInt8] = []
        let sent = readOnce(av, code, offset: dataAddr, reply: &reply)
        let hex = reply.map { String(format: "%02X", $0) }.joined(separator: " ")
        let verdict: String
        if !sent {
            verdict = "读事务失败"
        } else if decode(reply, code) != nil {
            verdict = "✓ 有效"
        } else if isNullMessage(reply) {
            verdict = "✗ 空报文（显示器未应答）"
        } else {
            verdict = "✗ 无效应答"
        }
        return "sent=\(sent) \(verdict) reply=[\(hex)]"
    }

    /// 写一次并复读验证（自带恢复），供 --ddc-test 用
    func writeAndVerify(_ index: Int, _ target: Double) -> (wrote: Bool, readback: Double?) {
        let wrote = setBrightness(index, target)
        guard wrote else { return (false, nil) }
        usleep(300_000)   // 给显示器时间落实
        let back = readVCP(index, vcpBrightness, force: true).map { Double($0.cur) / Double($0.max) }
        return (true, back)
    }
}
