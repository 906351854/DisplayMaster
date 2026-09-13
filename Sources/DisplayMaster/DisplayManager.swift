import AppKit
import CoreGraphics

struct DisplayItem {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    let isMain: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let logicalWidth: Int
    let logicalHeight: Int
    let modes: [CGDisplayMode]
}

/// 显示器统一管理：枚举 / 开关 / 分辨率 / 亮度
final class DisplayManager {
    static let shared = DisplayManager()

    /// 被本 app 关闭的显示器（id -> 名字）。CGGetOnlineDisplayList 里查不到它们，
    /// 所以必须自己记住才能重新打开 —— 而且必须落盘，否则 app 一重启这块屏就失联了。
    private(set) var disabled: [CGDirectDisplayID: String] = [:]

    private static let disabledKey = "disabledDisplays"

    // MARK: 读写节流
    /// 外接屏读 DDC 的间隔下限：打开菜单就会触发读，不加节流会被菜单反复猛敲。
    private let minReadInterval: TimeInterval = 2.0
    /// 写间隔下限：外接屏走 I²C，拖滑块时的高频写是「把显示器写死」的主因。
    private let minWriteIntervalExternal: TimeInterval = 0.10
    private let minWriteIntervalBuiltin: TimeInterval = 0.03

    private var lastRead: [CGDirectDisplayID: Date] = [:]
    private var lastWrite: [CGDirectDisplayID: Date] = [:]
    private var pendingBrightness: [CGDirectDisplayID: Double] = [:]
    private var flushScheduled: Set<CGDirectDisplayID> = []

    private init() {
        DDC.shared.refresh()
        loadDisabled()
    }

    func refresh() {
        DDC.shared.refresh()
        pruneDisabled()
    }

    // MARK: - 「已关闭显示器」的持久化

    private func loadDisabled() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.disabledKey) as? [String: String] else { return }
        var loaded: [CGDirectDisplayID: String] = [:]
        for (key, name) in raw {
            if let id = UInt32(key) { loaded[CGDirectDisplayID(id)] = name }
        }
        disabled = loaded
    }

    private func saveDisabled() {
        let raw = Dictionary(uniqueKeysWithValues: disabled.map { (String($0.key), $0.value) })
        UserDefaults.standard.set(raw, forKey: Self.disabledKey)
    }

    /// 在线显示器集合
    private func onlineIDs() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(max(count, 1)))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Set(ids.prefix(Int(count)))
    }

    /// 显示器可能自己回来了（显示睡眠唤醒 / 系统重启 / 重新插拔），
    /// 这时就不该再把它算作「已关闭」，否则菜单里会挂一条点不动的僵尸项。
    func pruneDisabled() {
        let online = onlineIDs()
        let stale = disabled.keys.filter { online.contains($0) }
        guard !stale.isEmpty else { return }
        for id in stale { disabled.removeValue(forKey: id) }
        saveDisabled()
    }

    // MARK: - 枚举

    func displays() -> [DisplayItem] {
        // kCGDisplayShowDuplicateLowResolutionModes 必须给，否则拿不到完整的缩放模式列表：
        // 内置 Retina 屏默认只会返回 3 个「非 HiDPI」模式，连当前正在用的 HiDPI 模式都不在里面。
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        var out: [DisplayItem] = []
        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(num.uint32Value)
            let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
            let cur = CGDisplayCopyDisplayMode(id)
            let lw = cur?.width ?? Int(screen.frame.width)
            let lh = cur?.height ?? Int(screen.frame.height)
            let pw = cur?.pixelWidth ?? lw
            let ph = cur?.pixelHeight ?? lh
            out.append(DisplayItem(
                id: id,
                name: screen.localizedName,
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                isMain: CGDisplayIsMain(id) != 0,
                pixelWidth: pw, pixelHeight: ph,
                logicalWidth: lw, logicalHeight: lh,
                modes: modes
            ))
        }
        return out
    }

    /// 常见的逻辑分辨率。显示器 EDID 里往往按 32 像素步长枚举出一两百个缩放档位
    /// （5120×2880 的面板实测 220 项），全塞进菜单根本没法用，所以默认只列这些常规档位。
    /// 用户可以在菜单里切到「显示所有分辨率」看完整列表。
    private static let commonResolutions: Set<String> = [
        // 16:10（Mac 系）
        "1024x640", "1152x720", "1280x800", "1440x900", "1512x945", "1512x982",
        "1680x1050", "1728x1117", "1792x1120", "1920x1200", "2048x1280",
        "2304x1440", "2560x1600", "2880x1800", "3200x2000", "3360x2100", "3840x2400",
        // MacBook 面板原生档位
        "960x600", "1024x665", "1147x745", "1280x832", "1440x936", "1800x1169",
        "2056x1329", "2294x1477", "3008x1692", "3024x1964", "3360x1890", "3456x2234",
        // 16:9 / 电视
        "1280x720", "1366x768", "1536x864", "1600x900", "1920x1080", "2048x1152",
        "2304x1296", "2560x1440", "2880x1620", "3200x1800", "3840x2160",
        "4096x2304", "5120x2880", "6016x3384", "6144x3456",
        // 21:9 / 带鱼屏
        "2560x1080", "3440x1440", "3840x1600", "5120x2160",
        // 4:3 / 5:4
        "640x480", "800x600", "1024x768", "1152x864", "1280x960", "1280x1024",
        "1400x1050", "1600x1200", "1920x1440", "2048x1536", "2560x1920",
        // 标清
        "720x480", "720x576", "1024x576"
    ]

    /// 去重后的可切换分辨率：同一「逻辑尺寸 + 是否 HiDPI」只保留刷新率最高的那个。
    /// - Parameter includeAll: false 时只保留常见档位；见 `commonResolutions`。
    func uniqueModes(_ d: DisplayItem, includeAll: Bool = false) -> [CGDisplayMode] {
        var best: [String: CGDisplayMode] = [:]
        for m in d.modes {
            let hidpi = m.pixelWidth > m.width
            let key = "\(m.width)x\(m.height)|\(hidpi ? 2 : 1)"
            if let exist = best[key] {
                if m.refreshRate > exist.refreshRate { best[key] = m }
            } else {
                best[key] = m
            }
        }
        var modes = Array(best.values)
        if !includeAll {
            let filtered = modes.filter { isCommonMode($0, of: d) }
            // 万一白名单一个都没命中（很冷门的显示器），退回完整列表，别让菜单空掉
            if !filtered.isEmpty { modes = filtered }
        }
        return modes.sorted {
            if $0.width != $1.width { return $0.width < $1.width }
            if $0.height != $1.height { return $0.height < $1.height }
            return $0.refreshRate < $1.refreshRate
        }
    }

    /// 是否算「常见档位」：白名单里的，或当前正在用的，或面板原生分辨率
    private func isCommonMode(_ m: CGDisplayMode, of d: DisplayItem) -> Bool {
        if m.width == d.logicalWidth && m.height == d.logicalHeight { return true }
        if m.width == d.pixelWidth && m.height == d.pixelHeight { return true }
        return Self.commonResolutions.contains("\(m.width)x\(m.height)")
    }

    /// 折叠掉了多少档（用于菜单里提示「还有 N 项」）
    func hiddenModeCount(_ d: DisplayItem) -> Int {
        max(0, uniqueModes(d, includeAll: true).count - uniqueModes(d, includeAll: false).count)
    }

    /// 分辨率菜单是否展示全部档位（持久化）
    var showAllResolutions: Bool {
        get { UserDefaults.standard.bool(forKey: "showAllResolutions") }
        set { UserDefaults.standard.set(newValue, forKey: "showAllResolutions") }
    }

    // MARK: - 开关显示器

    @discardableResult
    func setEnabled(_ id: CGDirectDisplayID, _ on: Bool, name: String = "") -> Bool {
        guard let fn = PrivateAPI.shared.configureDisplayEnabled else { return false }

        // 安全保护：绝不允许关掉最后一台，否则用户会面对全黑
        if !on, onlineIDs().count <= 1 { return false }

        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg else { return false }
        if fn(c, id, on) != 0 {
            CGCancelDisplayConfiguration(c)
            return false
        }
        guard CGCompleteDisplayConfiguration(c, .forSession) == .success else { return false }

        if on { disabled.removeValue(forKey: id) } else { disabled[id] = name }
        saveDisabled()
        return true
    }

    // MARK: - 分辨率

    @discardableResult
    func setMode(_ id: CGDirectDisplayID, _ mode: CGDisplayMode) -> Bool {
        CGDisplaySetDisplayMode(id, mode, nil) == .success
    }

    // MARK: - HiDPI

    /// 当前是否以 HiDPI 渲染（物理像素多于逻辑尺寸，即 2x 倍率）
    func isHiDPI(_ d: DisplayItem) -> Bool { d.pixelWidth > d.logicalWidth }

    /// HiDPI 开关的目标
    struct HiDPIToggle {
        let target: CGDisplayMode
        /// true = 同一逻辑分辨率上换渲染倍率；false = 该分辨率没有对应变体，改切到最接近的档位
        let sameResolution: Bool
    }

    /// 推导 HiDPI 开关应该切到哪个模式。
    ///
    /// 优先在**同一逻辑分辨率**上换倍率（例如 2560×1440 HiDPI ⇄ 2560×1440 原生），
    /// 这是最容易预期、也不会让你丢失窗口布局的做法。
    /// 但内置 Retina 屏这类面板并不提供同尺寸的变体（1680×1050 只有 HiDPI 版本），
    /// 这时退一步取**逻辑尺寸最接近**的反向模式（1680×1050 HiDPI → 1920×1200 非 HiDPI），
    /// 也就是 macOS「关闭 HiDPI」的实际效果：空间变大、但像素被拉伸。
    func hidpiToggle(_ d: DisplayItem) -> HiDPIToggle? {
        let wantHiDPI = !isHiDPI(d)
        let candidates = uniqueModes(d, includeAll: true).filter {
            ($0.pixelWidth > $0.width) == wantHiDPI
        }
        guard !candidates.isEmpty else { return nil }        // 该屏根本没有相反的渲染倍率

        if let exact = candidates.first(where: { $0.width == d.logicalWidth && $0.height == d.logicalHeight }) {
            return HiDPIToggle(target: exact, sameResolution: true)
        }
        // 距离度量：宽度差优先、高度差次之
        let nearest = candidates.min {
            abs($0.width - d.logicalWidth) * 10_000 + abs($0.height - d.logicalHeight)
                < abs($1.width - d.logicalWidth) * 10_000 + abs($1.height - d.logicalHeight)
        }
        return nearest.map { HiDPIToggle(target: $0, sameResolution: false) }
    }

    /// 执行 HiDPI 切换（切到 `hidpiToggle` 推导出的目标模式）
    @discardableResult
    func toggleHiDPI(_ d: DisplayItem) -> Bool {
        guard let toggle = hidpiToggle(d) else { return false }
        return setMode(d.id, toggle.target)
    }

    // MARK: - 亮度

    /// 外接显示器在 DDC 服务列表里的序号。
    /// 注意：这是按 displayID 升序与 DDC 服务发现顺序一一对应，
    /// 单台外接屏没问题；接两台外接屏时需要改成按 EDID/位置精确配对。
    private func ddcIndex(of d: DisplayItem) -> Int? {
        let externals = displays().filter { !$0.isBuiltin }.sorted { $0.id < $1.id }
        guard let i = externals.firstIndex(where: { $0.id == d.id }) else { return nil }
        return i
    }

    /// 读亮度 0...1；外接屏读不到时返回缓存值（滑块因此不会消失）
    func brightness(of d: DisplayItem) -> Double? {
        if d.isBuiltin {
            guard let can = PrivateAPI.shared.canChangeBrightness, can(d.id) != 0,
                  let get = PrivateAPI.shared.getBrightness else { return nil }
            var v: Float = 0
            guard get(d.id, &v) == 0 else { return nil }
            return Double(v)
        }

        guard let i = ddcIndex(of: d) else { return nil }
        // 节流：短时间内重复调用（例如反复打开菜单）直接用缓存，不再敲 I²C
        if let t = lastRead[d.id], Date().timeIntervalSince(t) < minReadInterval {
            return DDC.shared.cachedBrightness[i]
        }
        lastRead[d.id] = Date()
        return DDC.shared.brightness(i)
    }

    func setBrightness(_ d: DisplayItem, _ value: Double) {
        let v = max(0, min(1, value))
        if d.isBuiltin {
            _ = PrivateAPI.shared.setBrightness?(d.id, Float(v))
        } else if let i = ddcIndex(of: d) {
            DDC.shared.setBrightness(i, v)
        }
    }

    /// 节流后的亮度写入：拖动过程中最多每 100ms 写一次 I²C，且末尾值一定会落到显示器。
    func setBrightnessThrottled(_ d: DisplayItem, _ value: Double) {
        let v = max(0, min(1, value))
        pendingBrightness[d.id] = v
        let interval = d.isBuiltin ? minWriteIntervalBuiltin : minWriteIntervalExternal
        if let t = lastWrite[d.id], Date().timeIntervalSince(t) < interval {
            scheduleFlush(d)
            return
        }
        flush(d)
    }

    /// 立即把待写值落到显示器（鼠标松开时调用，保证不丢最后一次）
    func flushBrightness(_ d: DisplayItem) {
        flush(d)
    }

    private func flush(_ d: DisplayItem) {
        guard let v = pendingBrightness.removeValue(forKey: d.id) else { return }
        lastWrite[d.id] = Date()
        setBrightness(d, v)
    }

    private func scheduleFlush(_ d: DisplayItem) {
        guard !flushScheduled.contains(d.id) else { return }
        flushScheduled.insert(d.id)
        let interval = d.isBuiltin ? minWriteIntervalBuiltin : minWriteIntervalExternal
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self = self else { return }
            self.flushScheduled.remove(d.id)
            guard let fresh = self.displays().first(where: { $0.id == d.id }) else { return }
            self.flush(fresh)
            if self.pendingBrightness[d.id] != nil { self.scheduleFlush(fresh) }
        }
    }

    /// 亮度是否可控。外接屏即使当前读失败，只要有过成功的缓存就仍算可控 —— 这样滑块不会闪没。
    func canControlBrightness(_ d: DisplayItem) -> Bool { brightness(of: d) != nil }

    /// 外接屏亮度不可控时的原因（人话）。内置屏返回 nil。
    func ddcNote(for d: DisplayItem) -> String? {
        guard !d.isBuiltin else { return nil }
        if DDC.shared.externalCount == 0 {
            return "未找到该屏的 DDC 通道 —— 点「重新检测 DDC」或重新插拔视频线"
        }
        return DDC.shared.lastDiagnosis
    }

    /// 有滑块但需要提醒用户时的告警文案（外接屏、且最近一次探测不正常）
    func brightnessWarning(for d: DisplayItem) -> String? {
        guard !d.isBuiltin else { return nil }
        let diag = DDC.shared.lastDiagnosis
        guard diag != "正常", diag != "尚未探测" else { return nil }
        return diag
    }

    /// 用户手动触发：解除 DDC 冷却与失败计数、重建句柄（显示器重新上电后用它）
    func forceReprobeDDC() { DDC.shared.forceReprobe() }
}
