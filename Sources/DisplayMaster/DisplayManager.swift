import AppKit
import CoreGraphics
import IOKit.pwr_mgt

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

/// 被本 app 关闭的显示器记录。
///
/// 除了名字，还存下 EDID 三要素（厂商/型号/序列号）。
/// 原因：显示器重新上线时系统**可能给它分配一个全新的 displayID**，
/// 只按 id 记账的话，旧的记录会永远清不掉 —— 菜单里就会一直多出一张
/// 灰着的卡片，而那块屏其实早就亮着了。
struct DisabledDisplay {
    let name: String
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    /// 是不是笔记本内屏。
    ///
    /// 拔掉外接屏之后要靠这个字段认出「哪条记录是内屏」，好把它开回来。
    /// 认不出来的话，用户可能面对一块怎么点都没反应的黑屏。
    let isBuiltin: Bool

    // 下面这几个是「关闭那一刻的快照」。
    //
    // 关掉之后 CoreGraphics 对这些一律返回垃圾值（分辨率读成 0、CGDisplayIsBuiltin
    // 把外接屏报成内屏），但菜单里那张卡还得把「这是台什么屏、刚才多亮」画出来 ——
    // 卡片上留一片空白比数字不准更让人困惑。所以关闭前先抄一份。
    let logicalWidth: Int
    let logicalHeight: Int
    let refreshRate: Double
    /// 关闭前的亮度 0...1。nil = 当时就不可控（或旧格式记录里没有）
    let brightness: Double?
    /// 关闭前是不是 HiDPI
    let hidpi: Bool

    init(name: String, vendor: UInt32, model: UInt32, serial: UInt32, isBuiltin: Bool,
         logicalWidth: Int = 0, logicalHeight: Int = 0, refreshRate: Double = 0,
         brightness: Double? = nil, hidpi: Bool = false) {
        self.name = name
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.isBuiltin = isBuiltin
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.refreshRate = refreshRate
        self.brightness = brightness
        self.hidpi = hidpi
    }

    /// 有没有可用于比对的硬件信息
    var hasHardwareID: Bool { vendor != 0 || model != 0 || serial != 0 }

    /// 卡片上那行「2560 × 1440 · 60 Hz」
    var specLine: String {
        guard logicalWidth > 0, logicalHeight > 0 else { return "关闭时的分辨率未记录" }
        var s = "\(logicalWidth) × \(logicalHeight)"
        if refreshRate >= 1 { s += " · \(Int(refreshRate.rounded())) Hz" }
        return s
    }
}

/// 显示器统一管理：枚举 / 开关 / 分辨率 / 亮度
final class DisplayManager {
    static let shared = DisplayManager()

    /// 被本 app 关闭的显示器（id -> 记录）。CGGetOnlineDisplayList 里查不到它们，
    /// 所以必须自己记住才能重新打开 —— 而且必须落盘，否则 app 一重启这块屏就失联了。
    private(set) var disabled: [CGDirectDisplayID: DisabledDisplay] = [:]

    private static let disabledKey = "disabledDisplays"

    /// 曾经见过的内屏 displayID（落盘）。
    ///
    /// 判断「该不该把内屏开回来」最可信的依据是 disabled 里那条 isBuiltin 记录，
    /// 但那条记录是有可能不在了的：用户手动开过一次内屏、系统重建过显示配置、
    /// 或者 reconcileDisabled 把它清了。记录一没，同时又没有外接屏，规则就会
    /// 认为「不是我关的，不关我事」—— 而用户面对的是**一块黑屏**。
    /// 所以这里额外记住内屏长什么样，作为最后一道保险。
    var knownBuiltinID: CGDirectDisplayID? {
        get {
            let v = UserDefaults.standard.integer(forKey: "knownBuiltinDisplayID")
            return v == 0 ? nil : CGDirectDisplayID(v)
        }
        set {
            UserDefaults.standard.set(newValue.map { Int($0) } ?? 0, forKey: "knownBuiltinDisplayID")
            // 同上：这条是「内屏被关掉之后还能认回它」的最后一道保险，不能丢
            UserDefaults.standard.synchronize()
        }
    }

    /// DDC 通道需要重建（屏幕配置刚变过：睡眠唤醒、插拔、分辨率变更）
    private var ddcDirty = false

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
        // 屏幕配置刚变过（尤其显示器睡眠唤醒）时，I²C 通道很可能已经哑了，
        // 趁打开菜单这一次机会先把句柄重建好，后面读亮度就不会又慢又失败。
        if ddcDirty {
            ddcDirty = false
            DDC.shared.forceReprobe()
        }
        reconcileDisabled()
    }

    // MARK: - 「已关闭显示器」的持久化

    private func loadDisabled() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.disabledKey) else { return }
        var loaded: [CGDirectDisplayID: DisabledDisplay] = [:]
        for (key, value) in raw {
            guard let id = UInt32(key) else { continue }
            if let name = value as? String {
                // 1.0.x 的旧格式：只存了名字。没有硬件信息，只能按 id 比对
                loaded[CGDirectDisplayID(id)] = DisabledDisplay(name: name, vendor: 0, model: 0, serial: 0,
                                                                isBuiltin: Self.looksBuiltin(name))
            } else if let dict = value as? [String: Any] {
                let name = (dict["name"] as? String) ?? "显示器"
                // 1.1.0 之前的记录没有 isBuiltin 字段，按名字补一次推断。
                // 这一步不能省：内屏要是被旧版本关掉、用户再拔了外接屏，
                // 认不出它是内屏就没人去开它 —— 用户面对的会是一块黑屏。
                let isBuiltin = (dict["isBuiltin"] as? String).map { $0 == "1" }
                    ?? Self.looksBuiltin(name)
                let hz = Double(dict["hz"] as? String ?? "") ?? 0
                let bright = (dict["brightness"] as? String).flatMap { $0.isEmpty ? nil : Double($0) }
                loaded[CGDirectDisplayID(id)] = DisabledDisplay(
                    name: name,
                    vendor: UInt32(dict["vendor"] as? String ?? "") ?? 0,
                    model: UInt32(dict["model"] as? String ?? "") ?? 0,
                    serial: UInt32(dict["serial"] as? String ?? "") ?? 0,
                    isBuiltin: isBuiltin,
                    logicalWidth: Int(dict["w"] as? String ?? "") ?? 0,
                    logicalHeight: Int(dict["h"] as? String ?? "") ?? 0,
                    refreshRate: hz,
                    brightness: bright,
                    hidpi: (dict["hidpi"] as? String) == "1"
                )
            }
        }
        // 一台笔记本只有一块内屏。万一记录里躺着好几条被标成内屏的
        // （1.0.x/1.1.0 在显示器离线后查 CGDisplayIsBuiltin 拿到过错误结果），
        // 只认「记住的那块内屏」，其余降级成外接屏 —— 挑错会把外接屏当内屏去开。
        // 只在确实知道内屏是谁的时候才动手：不知道就别改，免得把唯一的内屏记录也弄丢。
        if let keep = knownBuiltinID {
            let strays = loaded.filter { $0.value.isBuiltin && $0.key != keep }.map { $0.key }
            for id in strays {
                guard let rec = loaded[id] else { continue }
                loaded[id] = DisabledDisplay(name: rec.name, vendor: rec.vendor, model: rec.model,
                                             serial: rec.serial, isBuiltin: false)
            }
        }
        disabled = loaded
    }

    /// 从显示器名字猜它是不是笔记本内屏。
    ///
    /// 只用在**旧记录**（没有 isBuiltin 字段）上兜底：Apple 给内屏起的名
    /// 都带 "Built-in"，这是当时唯一还能拿到的线索。
    private static func looksBuiltin(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("built-in") || n.contains("内建") || n.contains("内置")
    }

    private func saveDisabled() {
        let raw: [String: [String: String]] = Dictionary(uniqueKeysWithValues: disabled.map { (id, rec) in
            (String(id), [
                "name": rec.name,
                "vendor": String(rec.vendor),
                "model": String(rec.model),
                "serial": String(rec.serial),
                "isBuiltin": rec.isBuiltin ? "1" : "0",
                "w": String(rec.logicalWidth),
                "h": String(rec.logicalHeight),
                "hz": String(rec.refreshRate),
                "brightness": rec.brightness.map { String($0) } ?? "",
                "hidpi": rec.hidpi ? "1" : "0"
            ])
        })
        UserDefaults.standard.set(raw, forKey: Self.disabledKey)
        // 显式同步一次。UserDefaults 的 set 是把值交给 cfprefsd 异步落盘的，
        // 这条记录却关系到一个**已经被关掉的屏幕还能不能找回来** ——
        // 写入那一刻进程要是刚好没了（崩溃、强退、命令行跑一次就 exit），
        // 代价是用户对着一块黑屏、菜单里还没有它的卡片。不值得赌这个窗口。
        UserDefaults.standard.synchronize()
    }

    /// 让用户手动丢掉一条「已关闭」记录。
    ///
    /// 什么时候需要：显示器被关掉之后又**拔了线**（或者 iPad 的随航断开），
    /// 那台屏永远不会回来，记录却会一直留着 —— 菜单里就挂着一张永远开不起来的卡片。
    /// 自动清理只能覆盖「按 EDID 认出来它回来了」，剩下的得给用户一条手动收尾的路。
    @discardableResult
    func forgetDisabled(_ id: CGDirectDisplayID) -> Bool {
        guard disabled.removeValue(forKey: id) != nil else { return false }
        saveDisabled()
        return true
    }

    /// 在线显示器集合
    private func onlineIDs() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(max(count, 1)))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Set(ids.prefix(Int(count)))
    }

    /// EDID 三要素。显示器关掉之后这些查询就取不到了，所以必须在关闭**之前**记下来。
    private func hardwareID(_ id: CGDirectDisplayID) -> (vendor: UInt32, model: UInt32, serial: UInt32) {
        (CGDisplayVendorNumber(id), CGDisplayModelNumber(id), CGDisplaySerialNumber(id))
    }

    /// 显示器可能自己回来了（显示睡眠唤醒 / 系统重启 / 重新插拔 / 系统设置里手动打开），
    /// 这时就不该再把它算作「已关闭」，否则菜单里会挂一条点不动的僵尸项。
    ///
    /// 判定顺序：① id 直接在线；② id 不在线但 EDID 三要素能对上某台在线显示器
    /// （说明系统换了个 id 把它认回来了）。第 ② 条只在**候选唯一**时生效，
    /// 避免接了两台同型号显示器时误判 —— 宁可留一条多余的入口，也不能把入口删错。
    func reconcileDisabled() {
        guard !disabled.isEmpty else { return }
        let list = displays()
        // id 判定用 CoreGraphics 的在线列表（比 NSScreen 更早、更可靠），
        // EDID 比对才需要 NSScreen 那套信息。
        // 虚拟屏要剔掉：它的 displayID 每次生成都不一样，万一撞上某条记录的 id，
        // 就会被误判成「这块屏自己回来了」，把记录删掉。
        let online = onlineIDs().subtracting(virtualDisplayIDs()).union(list.map { $0.id })
        var changed = false

        // 随航 / 隔空播放投出来的屏是临时的：iPad 一断开，它就永远不可能自己回来，
        // 记录却会一直赖着 —— 菜单里于是挂着一张永远开不起来的卡片
        // （实测「Sidecar Display (AirPlay)」被关掉之后就是这样）。
        // 这类记录直接丢掉，不给用户留一堆清理不掉的条目。
        for id in disabled.filter({ Self.isEphemeral($0.value.name) }).map({ $0.key }) {
            disabled.removeValue(forKey: id)
            changed = true
        }

        for (id, rec) in disabled {
            if online.contains(id) {
                disabled.removeValue(forKey: id)
                changed = true
                continue
            }
            guard rec.hasHardwareID else { continue }   // 旧格式记录没有可比对的信息
            let candidates = list.filter { d in
                let h = hardwareID(d.id)
                return h.vendor == rec.vendor && h.model == rec.model
            }
            let matched: [DisplayItem]
            if rec.serial != 0 {
                matched = candidates.filter { hardwareID($0.id).serial == rec.serial }
            } else {
                matched = candidates
            }
            if matched.count == 1 {
                disabled.removeValue(forKey: id)
                changed = true
            }
        }
        if changed { saveDisabled() }
    }

    // MARK: - 枚举

    /// 显示器名称缓存（id -> 名字）
    private static let nameCacheKey = "displayNames"

    /// 在线显示器的 id，顺序：先按 NSScreen 的顺序（主屏在前），再补上 NSScreen 漏掉的。
    ///
    /// **为什么要以 CoreGraphics 为准**：`NSScreen.screens` 在一台被关掉的显示器
    /// 重新打开之后**不会更新** —— 实测（macOS 26.6）等了 3 秒仍是旧列表，而
    /// CoreGraphics 的在线列表 0.2 秒内就恢复了。只信 NSScreen 的话，用户把显示器
    /// 打开之后菜单里根本看不到它。
    private func orderedOnlineIDs() -> [CGDirectDisplayID] {
        let online = onlineIDs()
        var out: [CGDirectDisplayID] = []
        for s in NSScreen.screens {
            guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(num.uint32Value)
            if online.contains(id), !out.contains(id) { out.append(id) }
        }
        for id in online.sorted(by: { $0 < $1 }) where !out.contains(id) { out.append(id) }
        return out
    }

    /// 系统自己造出来的虚拟显示器（不对应任何真实硬件）。
    ///
    /// 触发条件很明确：**所有真实显示器都不可用时**，macOS 会造一台出来维持显示输出。
    /// 实测（macOS 26.6）它的 EDID 是两个四字符码 `'unkn'` / `'vert'`，
    /// 在 NSScreen 里有条目但 localizedName 是空串，分辨率固定 1920×1080。
    ///
    /// 为什么必须认出来：它 `CGDisplayIsBuiltin` 返回 0，会被当成「外接屏还接着」——
    /// 于是「拔掉外接屏就把内屏开回来」这条规则永远不触发，
    /// 而用户面前只有一块他根本看不见的虚拟屏，等于黑屏。
    private func virtualDisplayIDs() -> Set<CGDirectDisplayID> {
        var names: [CGDirectDisplayID: String] = [:]
        var isScreen: Set<CGDirectDisplayID> = []
        for s in NSScreen.screens {
            guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(num.uint32Value)
            isScreen.insert(id)
            names[id] = s.localizedName
        }

        var out: Set<CGDirectDisplayID> = []
        for id in onlineIDs() where Self.isVirtualDisplay(id,
                                                         nsName: names[id],
                                                         hasNSScreen: isScreen.contains(id)) {
            out.insert(id)
        }
        return out
    }

    /// 判定单台显示器是不是虚拟屏。抽成静态纯函数，好脱离硬件跑场景测试。
    static func isVirtualDisplay(_ id: CGDirectDisplayID,
                                 nsName: String?,
                                 hasNSScreen: Bool) -> Bool {
        isVirtualDisplay(vendor: CGDisplayVendorNumber(id),
                         model: CGDisplayModelNumber(id),
                         nsName: nsName,
                         hasNSScreen: hasNSScreen)
    }

    /// 判定的本体：只吃 EDID 三要素和 NSScreen 信息，不碰任何系统查询。
    /// 拆出来是为了能让 `--auto-scenarios` 把每一种取值组合都跑一遍。
    static func isVirtualDisplay(vendor: UInt32,
                                 model: UInt32,
                                 nsName: String?,
                                 hasNSScreen: Bool) -> Bool {
        // 判据 1：vendor 是四字符码 'unkn'（未知厂商）。
        // 实测 macOS 26.6 的虚拟屏 vendor/model = 1970170734/1986622068，
        // 即 'unkn' / 'virt' —— 注意是 virt 不是 vert，这里写错过一次，
        // 结果整套识别静默失效（test 里补了真实整数用例把它钉住）。
        // 只看 vendor 就够：'unkn' 已经说明它不是任何真实硬件。
        if vendor == fourCC("unkn") { return true }

        // 判据 2：是 NSScreen 但没有名字，而且 EDID 完全读不到。
        // 这里宁可判宽：把一台真实屏误当虚拟屏，代价只是「多开一次内屏」；
        // 漏判的代价是用户对着一块看不见的虚拟屏黑屏。
        return hasNSScreen && (nsName ?? "").isEmpty && vendor == 0 && model == 0
    }

    /// 名字一看就是「临时投屏」的记录。
    ///
    /// 随航（Sidecar）和隔空播放投出来的屏，是靠另一台设备**现造**出来的：
    /// 设备一断，那块屏就不存在了，记录永远不会被 EDID 比对清掉。
    static func isEphemeral(_ name: String) -> Bool {
        let hints = ["Sidecar", "AirPlay", "随航", "隔空播放"]
        return hints.contains { name.localizedCaseInsensitiveContains($0) }
    }

    /// "unkn" 这种四字符码 → CGDisplayVendorNumber 返回的那种整数
    static func fourCC(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for c in s.utf8 { v = (v << 8) | UInt32(c) }
        return v
    }

    /// 反过来：把那个整数还原成可读的四字符码，诊断打印用。
    /// 有这个才好核对 —— `1970170734` 和 `1986622068` 摆在眼前根本看不出是 'unkn' / 'virt'。
    static func fourCCString(_ v: UInt32) -> String {
        let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                     UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
              let s = String(bytes: bytes, encoding: .ascii) else {
            return "0x" + String(v, radix: 16)
        }
        return "'\(s)'"
    }

    /// 当前被识别为虚拟屏的 displayID（诊断打印用）
    func detectedVirtualDisplayIDs() -> [CGDirectDisplayID] { virtualDisplayIDs().sorted() }

    /// 当前在线显示器 id（诊断打印用，含被过滤掉的虚拟屏）
    func debugOnlineIDs() -> [CGDirectDisplayID] { onlineIDs().sorted() }

    func displays() -> [DisplayItem] {
        // kCGDisplayShowDuplicateLowResolutionModes 必须给，否则拿不到完整的缩放模式列表：
        // 内置 Retina 屏默认只会返回 3 个「非 HiDPI」模式，连当前正在用的 HiDPI 模式都不在里面。
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary

        // 系统造的虚拟屏要排除掉，别让它进菜单、也别让它冒充「外接屏」
        let virtuals = virtualDisplayIDs()

        var nsNames: [CGDirectDisplayID: String] = [:]
        for s in NSScreen.screens {
            guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  !s.localizedName.isEmpty else { continue }
            nsNames[CGDirectDisplayID(num.uint32Value)] = s.localizedName
        }
        var nameCache = UserDefaults.standard.dictionary(forKey: Self.nameCacheKey) as? [String: String] ?? [:]
        var cacheChanged = false

        var out: [DisplayItem] = []
        for id in orderedOnlineIDs() {
            // 虚拟屏不进菜单，也不参与任何判断（理由见 virtualDisplayIDs）
            if virtuals.contains(id) { continue }

            let name: String
            if let n = nsNames[id] {
                name = n
                if nameCache[String(id)] != n { nameCache[String(id)] = n; cacheChanged = true }
            } else if let n = nameCache[String(id)], !n.isEmpty {
                name = n          // NSScreen 还没更新，用上次见到的名字
            } else {
                name = CGDisplayIsBuiltin(id) != 0 ? "内置显示器" : "外接显示器 \(id)"
            }

            let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
            let cur = CGDisplayCopyDisplayMode(id)
            let lw = cur?.width ?? 0
            let lh = cur?.height ?? 0
            // 顺手把内屏的 id 记下来（见 knownBuiltinID）：它一旦被关掉，
            // 这些信息就全查不到了，必须在还能看到它的时候留一份。
            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            if isBuiltin, knownBuiltinID != id { knownBuiltinID = id }

            out.append(DisplayItem(
                id: id,
                name: name,
                isBuiltin: isBuiltin,
                isMain: CGDisplayIsMain(id) != 0,
                pixelWidth: cur?.pixelWidth ?? lw, pixelHeight: cur?.pixelHeight ?? lh,
                logicalWidth: lw, logicalHeight: lh,
                modes: modes
            ))
        }
        if cacheChanged { UserDefaults.standard.set(nameCache, forKey: Self.nameCacheKey) }
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

    /// 打开 / 关闭一台显示器。
    ///
    /// 这里刻意**不相信 API 的返回值，只相信观测结果**。踩过的两个坑：
    ///
    ///   1. `CGCompleteDisplayConfiguration` 可能返回失败，但显示配置其实已经生效
    ///      —— 屏幕亮了，代码却以为没成功，于是「已关闭」记录留着不删，
    ///      菜单里就一直多一张灰卡片。
    ///   2. 显示器重新上线时系统会分配**新的 displayID**，按旧 id 记账永远对不上。
    ///
    /// 所以：动作发出去之后轮询在线列表，按「原 id 上线」或「出现了新的显示器」来判定，
    /// 判定成功就把记录删掉；失败则保留入口让用户还能再点一次。
    @discardableResult
    func setEnabled(_ id: CGDirectDisplayID, _ on: Bool, name: String = "", force: Bool = false) -> Bool {
        guard PrivateAPI.shared.configureDisplayEnabled != nil else { return false }

        // 安全保护：绝不允许关掉最后一台，否则用户会面对全黑。
        // force 只给命令行诊断用（要复现「外接屏消失」就得能关掉当前唯一在线的屏）。
        if !on, !force, onlineIDs().count <= 1 { return false }

        // 屏幕睡着的时候系统会拒绝改显示配置（实测 CGCompleteDisplayConfiguration
        // 直接返回 1014，而不是 0）。用户既然能点到菜单，人就在机器前 ——
        // 先把屏幕唤醒，这既是符合预期的行为，也是让这次操作能生效的前提。
        let wasAsleep = displaysAsleep()
        if wasAsleep { wakeDisplays() }

        let before = onlineIDs()
        // 关闭之前先把这些记下来 —— 一旦关掉，这几个查询就全部取不到了。
        // 「是不是内屏」也必须在这时候问：显示器离线后 CGDisplayIsBuiltin 会返回垃圾值，
        // 实测外接屏会被判成内置屏，而内屏的标记正是「拔线后把谁开回来」的唯一依据。
        let hw = hardwareID(id)
        let wasBuiltin = CGDisplayIsBuiltin(id) != 0

        // 关闭前的快照（见 DisabledDisplay 里那一段）：屏幕一下线，分辨率、亮度、
        // HiDPI 状态就全都查不到了，而菜单里那张卡还得把它们显示出来。
        var snapshot: DisabledDisplay?
        if !on {
            let item = displays().first { $0.id == id }
            let mode = CGDisplayCopyDisplayMode(id)
            snapshot = DisabledDisplay(
                name: name.isEmpty ? "显示器" : name,
                vendor: hw.vendor, model: hw.model, serial: hw.serial,
                isBuiltin: wasBuiltin,
                logicalWidth: item?.logicalWidth ?? mode?.width ?? 0,
                logicalHeight: item?.logicalHeight ?? mode?.height ?? 0,
                refreshRate: mode?.refreshRate ?? 0,
                brightness: item.flatMap { brightness(of: $0) },
                hidpi: item.map { isHiDPI($0) } ?? false
            )
        }

        var applied = commitDisplayConfiguration(id, on)
        if !applied && wasAsleep {
            // 唤醒本身要花点时间，等它真醒过来再补一次
            _ = waitUntil({ !self.displaysAsleep() }, timeout: 2.5)
            applied = commitDisplayConfiguration(id, on)
        }

        if on {
            if waitForDisplayOnline(id, hardware: hw, before: before) {
                disabled.removeValue(forKey: id)
                reconcileDisabled()
                saveDisabled()
                return true
            }
            // 没观测到上线：记录保留，用户还能再点一次
            return applied
        }

        // 关闭：同样以观测为准 —— 没真的关掉就不该记成「已关闭」
        if waitUntil({ !self.onlineIDs().contains(id) }, timeout: 2.0) {
            disabled[id] = snapshot ?? DisabledDisplay(name: name.isEmpty ? "显示器" : name,
                                                       vendor: hw.vendor, model: hw.model,
                                                       serial: hw.serial, isBuiltin: wasBuiltin)
            saveDisabled()
            return true
        }
        return false
    }

    /// 提交一次「启用/禁用」显示配置。
    /// 返回值**不可信**：屏幕睡眠时会报 1014、配置却可能已经生效；反过来也可能报成功而没生效。
    /// 所以调用方一律用在线列表复核。
    private func commitDisplayConfiguration(_ id: CGDirectDisplayID, _ on: Bool) -> Bool {
        guard let fn = PrivateAPI.shared.configureDisplayEnabled else { return false }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg else { return false }
        if fn(c, id, on) != 0 {
            CGCancelDisplayConfiguration(c)
            return false
        }
        return CGCompleteDisplayConfiguration(c, .forSession) == .success
    }

    /// 是否有显示器正睡着
    private func displaysAsleep() -> Bool {
        onlineIDs().contains { CGDisplayIsAsleep($0) != 0 }
    }

    /// 唤醒睡眠中的显示器（声明一次用户活动，等价于用户动了下鼠标）
    @discardableResult
    private func wakeDisplays(holdFor seconds: TimeInterval = 3) -> Bool {
        var assertionID: IOPMAssertionID = 0
        let r = IOPMAssertionDeclareUserActivity("\(AppInfo.name) 唤醒屏幕" as CFString,
                                                 kIOPMUserActiveLocal, &assertionID)
        guard r == kIOReturnSuccess else { return false }
        defer { if assertionID != 0 { IOPMAssertionRelease(assertionID) } }
        return waitUntil({ !self.displaysAsleep() }, timeout: seconds)
    }

    /// 等「打开」真正生效。三种判定都算成功：
    /// 原 id 上线 / 出现了新的 displayID / 新 id 的 EDID 与记录的相符。
    private func waitForDisplayOnline(_ id: CGDirectDisplayID,
                                      hardware: (vendor: UInt32, model: UInt32, serial: UInt32),
                                      before: Set<CGDirectDisplayID>) -> Bool {
        waitUntil({
            let now = self.onlineIDs()
            if now.contains(id) { return true }
            let fresh = now.subtracting(before)
            guard !fresh.isEmpty else { return false }
            // 记录了硬件信息的（新格式）：必须 EDID 对得上才算
            if hardware.vendor != 0 || hardware.model != 0 {
                for f in fresh {
                    let h = self.hardwareID(f)
                    if h.vendor == hardware.vendor && h.model == hardware.model
                        && (hardware.serial == 0 || h.serial == hardware.serial) {
                        return true
                    }
                }
                return false
            }
            // 没有硬件信息（1.0.x 的旧记录）：只多出一台就认为就是它
            return fresh.count == 1
        }, timeout: 2.5)
    }

    /// 轮询等待条件成立。用 RunLoop 让步而不是 sleep：
    /// 切换显示器期间系统要处理一堆 window server 事件，纯 sleep 会把菜单卡住。
    private func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        }
        return predicate()
    }

    // MARK: - 有外接屏时自动关闭内置屏

    /// 开关本身（持久化）。打开之后，接上外接屏就关掉笔记本内屏，拔掉再开回来。
    var autoDisableBuiltinWhenExternal: Bool {
        get { UserDefaults.standard.bool(forKey: "autoDisableBuiltinWhenExternal") }
        set { UserDefaults.standard.set(newValue, forKey: "autoDisableBuiltinWhenExternal") }
    }

    /// 上一次评估时「外接屏在不在」。
    ///
    /// 之所以记这个，而不是每次配置变化都无脑执行：用户有时就是想在内屏上干点活
    /// （比如把窗口拖回来），这时候手动把内屏开回来，如果规则当场又把它关掉，
    /// 那这个功能就变成骚扰了。只在「接上」和「拔掉」这两个瞬间动手，
    /// 中间的手动操作都归用户自己。
    private var lastExternalPresent: Bool?

    /// 判定规则的输入。
    ///
    /// 特意抽成独立结构体：显示器插拔没法在命令行里模拟，而"拔掉外接屏要把内屏开回来"
    /// 这条分支一旦写错就是一块黑屏。把输入抽出来之后，全部情形都能脱离真实硬件走一遍
    /// （见 `--auto-scenarios`）。
    struct AutoBuiltinInput {
        var switchOn: Bool
        var asleep: Bool
        /// 当前在线的外接屏数量
        var externalCount: Int
        /// 内屏此刻在不在线
        var builtinOnlineID: CGDirectDisplayID?
        var builtinOnlineName: String = ""
        /// 内屏是不是正被本应用关着
        var builtinDisabledID: CGDirectDisplayID?
        var builtinDisabledName: String = ""
        /// 历史记录里内屏的 id（`knownBuiltinID`）。只在上一条也没了的时候用
        var knownBuiltinID: CGDirectDisplayID?
    }

    /// 自动规则「打算做什么」。只算不做，菜单提示和命令行诊断共用这一套判定，
    /// 避免出现「诊断说会关、实际却不动」这种两套逻辑打架的情况。
    struct AutoBuiltinPlan {
        enum Kind: Equatable {
            case idle                 // 什么都不用做
            case disableBuiltin       // 该关掉内屏
            case enableBuiltin        // 该把内屏开回来
        }
        let kind: Kind
        let displayID: CGDirectDisplayID?
        let displayName: String
        /// 这么决定的理由，直接是人话，可以原样打印给用户
        let reason: String

        static func idle(_ reason: String) -> AutoBuiltinPlan {
            AutoBuiltinPlan(kind: .idle, displayID: nil, displayName: "", reason: reason)
        }
    }

    /// 判定核心：只吃输入、只吐结论，不碰任何系统状态。所有分支都收在这里。
    static func decide(_ i: AutoBuiltinInput) -> AutoBuiltinPlan {
        guard i.switchOn else { return .idle("开关没打开") }

        if i.externalCount == 0 {
            // ---- 没有外接屏了：内屏必须在 ----
            // 这是整个功能唯一「必须做到」的事，做不到的后果是用户面前
            // 一块亮着的屏幕都没有。
            if i.builtinOnlineID != nil { return .idle("没有外接屏，内屏保持打开") }

            // 内屏的 id 优先取「已关闭」记录（那是本应用关的，最可信）；
            // 记录没了就退回曾经见过的内屏 id。少了这层兜底，
            // 记录一旦被清掉，规则就会以为自己没关过、什么都不做。
            guard let id = i.builtinDisabledID ?? i.knownBuiltinID else {
                return .idle("没有外接屏，内屏也不在线，且拿不到内屏的 displayID")
            }
            let fromRecord = i.builtinDisabledID != nil
            // 这里刻意**不看 asleep**：屏幕睡眠时不开内屏，用户就真的什么都看不到。
            // 「多亮一块屏」和「面对黑屏」之间只能选前者。
            return AutoBuiltinPlan(
                kind: .enableBuiltin, displayID: id,
                displayName: fromRecord ? i.builtinDisabledName : "内置屏",
                reason: fromRecord
                    ? "外接屏已拔掉，把内屏开回来"
                    : "外接屏已拔掉，内屏不在线（关闭记录已丢，用记住的内屏 id 兜底）"
            )
        }

        // ---- 有外接屏：该关内屏了 ----
        // 睡眠时改显示配置系统会拒绝，硬来还会把屏幕平白唤醒，所以等醒过来再说。
        guard !i.asleep else { return .idle("屏幕正在睡眠，不打扰它") }
        guard let id = i.builtinOnlineID else {
            return .idle("外接屏已接入，内屏本来就没开")
        }
        return AutoBuiltinPlan(kind: .disableBuiltin, displayID: id,
                               displayName: i.builtinOnlineName,
                               reason: "已接上 \(i.externalCount) 台外接屏")
    }

    /// 用真实状态拼出输入，交给 `decide`。加 --auto-test 时打印的就是它。
    func autoBuiltinPlan() -> AutoBuiltinPlan {
        let list = displays()
        let builtin = list.first { $0.isBuiltin }
        // 挑「内屏」那条记录：先认 id 与记住的内屏一致的那条，认不到才退回任意一条内置记录。
        // 多这一层是因为记录里可能同时存在被误标的内屏条目（老版本在显示器离线后
        // 查 CGDisplayIsBuiltin 拿到过错误结果），挑错会把外接屏当成内屏去开。
        let record = disabled.first { $0.value.isBuiltin && $0.key == knownBuiltinID }
            ?? disabled.first { $0.value.isBuiltin }
        return Self.decide(AutoBuiltinInput(
            switchOn: autoDisableBuiltinWhenExternal,
            asleep: displaysAsleep(),
            externalCount: list.filter { !$0.isBuiltin }.count,
            builtinOnlineID: builtin?.id,
            builtinOnlineName: builtin?.name ?? "",
            builtinDisabledID: record?.key,
            builtinDisabledName: record?.value.name ?? "",
            knownBuiltinID: knownBuiltinID
        ))
    }

    /// 按规则办事。
    ///
    /// - Parameters:
    ///   - force: true 时忽略「外接屏有没有刚变化过」这一层，直接把当前该做的做掉
    ///     （用户刚打开开关、应用刚启动、或巡检时用）。
    ///   - source: 谁触发的。只进日志，事后对时间线用。
    /// - Returns: 真的改动了显示配置才返回 true。
    @discardableResult
    func applyAutoBuiltinRule(force: Bool = false, source: String = "未标注") -> Bool {
        guard autoDisableBuiltinWhenExternal else {
            lastExternalPresent = nil       // 开关关了就别留着旧记忆，免得下次打开时误判
            return false
        }

        let hasExternal = displays().contains { !$0.isBuiltin }
        let prev = lastExternalPresent
        let plan = autoBuiltinPlan()

        // ---- 该把内屏开回来：不设任何前置条件 ----
        // 这不是「用户的一个动作」，而是一个必须修好的故障状态：用户面前没有屏幕，
        // 也没法打开菜单去点「重新扫描显示器」，只能等人来救。所以只要判定要开，
        // 每一次评估都真去开一次，失败就重试。
        if plan.kind == .enableBuiltin {
            lastExternalPresent = hasExternal
            guard let id = plan.displayID else { return false }
            if setEnabled(id, true) {
                ruleLog("[\(source)] 已打开 \(plan.displayName)(id=\(id)) —— \(plan.reason)")
                return true
            }
            ruleLog("[\(source)] 打开 \(plan.displayName)(id=\(id)) 失败（\(plan.reason)），开始重试")
            scheduleBuiltinRestore(step: 0)
            return false
        }

        // ---- 其余情况：屏幕睡眠时一律按兵不动，而且**不更新记忆** ----
        // 不更新记忆这点很关键：假设接上外接屏的那一刻屏幕正好睡着，若把这轮记成
        // 「已处理」，醒来后 prev == hasExternal，就再也没人去关内屏了。
        if displaysAsleep() {
            if force { ruleLog("[\(source)] 屏幕睡眠中，本轮跳过") }
            return false
        }
        lastExternalPresent = hasExternal

        // 关内屏只在外接屏「刚接上」的那一下动手，平时保持安静 ——
        // 这样用户临时把内屏开回来干活，不会被规则立刻打回去。
        let edge = force || prev == nil || prev != hasExternal
        guard edge else { return false }
        if force, plan.kind == .idle {
            ruleLog("[\(source)] 检查完毕，无需动作（\(plan.reason)）")
            return false
        }
        guard plan.kind == .disableBuiltin, let id = plan.displayID else { return false }

        let ok = setEnabled(id, false, name: plan.displayName)
        ruleLog("[\(source)] "
                + (ok ? "已关闭 \(plan.displayName)(id=\(id))" : "关闭 \(plan.displayName)(id=\(id)) 失败")
                + " —— \(plan.reason)")
        return ok
    }

    // MARK: - 打开内屏失败后的重试

    /// 重试间隔（秒）。拔线那一刻系统的显示配置还在重建，这时候改配置失败率不低 ——
    /// 而失败的代价是一块黑屏，所以不能试一次就放弃。
    private static let builtinRestoreBackoff: [TimeInterval] = [0.5, 1.0, 2.0, 4.0, 8.0, 15.0]

    /// 重试链的编号。每开一条新链就自增，旧链的回调一比较编号就知道自己过期了，
    /// 免得几轮插拔叠在一起时同时跑好几条重试链。
    private var restoreChain = 0

    private func scheduleBuiltinRestore(step: Int) {
        if step == 0 { restoreChain += 1 }
        let myChain = restoreChain

        guard step < Self.builtinRestoreBackoff.count else {
            ruleLog("重试 \(Self.builtinRestoreBackoff.count) 次仍未成功，交给巡检继续兜底")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.builtinRestoreBackoff[step]) { [weak self] in
            guard let self, self.autoDisableBuiltinWhenExternal, myChain == self.restoreChain else { return }
            // 重新判定：也许这期间内屏已经被系统或用户打开了
            let plan = self.autoBuiltinPlan()
            guard plan.kind == .enableBuiltin, let id = plan.displayID else {
                self.ruleLog("重试前复查：内屏已不需要打开，停止重试")
                return
            }
            if self.setEnabled(id, true) {
                self.ruleLog("重试第 \(step + 1) 次成功，内屏已打开")
            } else {
                self.ruleLog("重试第 \(step + 1) 次失败")
                self.scheduleBuiltinRestore(step: step + 1)
            }
        }
    }

    // MARK: - 低频兜底巡检

    private var safetyTimer: Timer?
    private static let safetyInterval: TimeInterval = 60

    /// 低频兜底巡检。
    ///
    /// 正常的触发点是「配置变化」通知，但通知有丢的可能（系统正在切换配置、
    /// 应用刚启动还没注册、或者干脆没发）。而这个功能失效的代价是黑屏，
    /// 所以再加一层兜底：每分钟看一眼，**只有真的处于「没有外接屏、内屏却不在线」
    /// 这个故障态时才动手**，其余时候这次检查什么也不做。
    func startSafetyMonitor() {
        guard autoDisableBuiltinWhenExternal, safetyTimer == nil else { return }
        let t = Timer(timeInterval: Self.safetyInterval, repeats: true) { [weak self] _ in
            guard let self, self.autoBuiltinPlan().kind == .enableBuiltin else { return }
            self.applyAutoBuiltinRule(force: true, source: "巡检")
        }
        // .common 模式：菜单跟踪、拖动期间也照常触发（默认模式会被菜单卡住）
        RunLoop.main.add(t, forMode: .common)
        safetyTimer = t
    }

    func stopSafetyMonitor() {
        safetyTimer?.invalidate()
        safetyTimer = nil
    }

    // MARK: - 规则日志

    /// 自动规则的运行记录。
    ///
    /// 这个功能失效的样子是「用户面前一块黑屏」，而那个状态下用户没法打开菜单、
    /// 也没法自己排查。所以每次评估都记一笔：通知有没有来、当时在线的是什么、
    /// 判定成什么、执行成没成。出问题时把日志翻出来就能定论，不用猜。
    private static let ruleLogMaxBytes = 192 * 1024

    private var ruleLogURL: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent(AppInfo.name, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("auto-rule.log")
    }

    /// 日志文件的绝对路径（`--auto-log` 里打印给用户看）
    var ruleLogPath: String { ruleLogURL?.path ?? "(取不到 Application Support 目录)" }

    func ruleLog(_ message: String) {
        guard let url = ruleLogURL else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        let line = "[\(fmt.string(from: Date()))] \(message)\n"
        let fm = FileManager.default

        // 超上限就把前一半砍掉，保留最近的记录
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > Self.ruleLogMaxBytes,
           let data = try? Data(contentsOf: url) {
            try? data.suffix(Self.ruleLogMaxBytes / 2).write(to: url)
        }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// 读回最近若干条（`--auto-log`，也方便用户直接复制出来）
    func recentRuleLog(lines: Int = 60) -> [String] {
        guard let url = ruleLogURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).map(String.init)
    }

    // MARK: - 屏幕配置变化 / 唤醒

    /// 屏幕配置刚变过（显示器睡眠唤醒、插拔、分辨率变更）。
    ///
    /// 唤醒之后 I²C 通道会哑掉：句柄还在、也不报错，但读不出也写不进，
    /// 表现就是「亮度滑块还在，拖了却没反应」。这里标记通道待重建。
    func screenConfigurationChanged() {
        ddcDirty = true
        // 节流表一并清掉：唤醒后第一次打开菜单必须真的去读一次，
        // 否则会拿到唤醒前的旧缓存值
        lastRead.removeAll()
        lastWrite.removeAll()
        pendingBrightness.removeAll()

        // 先把这次通知看到的东西记下来 —— 这是「通知到底有没有到」唯一的证据。
        // 排查「拔了线内屏没亮」时，第一步就是看这里有没有对应时间的记录。
        let snapshot = displays()
            .map { "\($0.name)\($0.isBuiltin ? "(内置)" : "")" }
            .joined(separator: ", ")
        let virtuals = virtualDisplayIDs().sorted()
        ruleLog("配置变化：在线 [\(snapshot.isEmpty ? "无" : snapshot)] · 已关闭 \(disabled.count) 台"
                + " · 睡眠 \(displaysAsleep() ? "是" : "否")"
                + (virtuals.isEmpty ? "" : " · 另排除虚拟屏 \(virtuals.map { String($0) }.joined(separator: ","))"))

        // 显示器从睡眠里回来需要一点时间才恢复应答，延后重建一次；
        // 若那时还没好，下次打开菜单时 refresh() 会再试（ddcDirty 还在）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, self.ddcDirty else { return }
            self.ddcDirty = false
            DDC.shared.forceReprobe()
            self.lastRead.removeAll()
            self.lastWrite.removeAll()
        }

        // 插拔外接屏、系统改显示配置，都会走到这里 —— 也就是自动关内屏规则的触发点。
        // 延后一点：系统刚改完配置，这时候立刻再改一次容易失败。
        // 真失败了也不怕：打开内屏那条路自带重试和巡检兜底。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.applyAutoBuiltinRule(source: "配置变化")
        }
    }

    // MARK: - 分辨率

    /// 切换显示模式（分辨率 / HiDPI）。
    ///
    /// 这里刻意**不相信 API 的返回值，只看观测结果** —— 和 `setEnabled` 同一个理由，
    /// 而且这个坑更隐蔽：菜单项的动作一触发，菜单必然要收起来，而**在菜单还没收干净的
    /// 那一帧里发显示配置更改会被系统吞掉**。实测的现象是
    /// `CGDisplaySetDisplayMode` 返回 success、`CGDisplayCopyDisplayMode` 却原封不动，
    /// 用户看到的就是「点了 HiDPI 没反应」，连个报错都没有。
    /// 所以：发一次 → 等观测，没变就隔一拍再补一次。
    @discardableResult
    func setMode(_ id: CGDirectDisplayID, _ mode: CGDisplayMode) -> Bool {
        // 目标就是当前模式：直接算成功，别在这儿空等两秒
        func key(_ m: CGDisplayMode?) -> String? {
            guard let m = m else { return nil }
            return "\(m.width)x\(m.height)/\(m.pixelWidth)x\(m.pixelHeight)"
        }
        let target = key(mode)
        if key(CGDisplayCopyDisplayMode(id)) == target { return true }

        for attempt in 0..<2 {
            _ = CGDisplaySetDisplayMode(id, mode, nil)
            if waitUntil({ key(CGDisplayCopyDisplayMode(id)) == target }, timeout: 1.0) { return true }
            if attempt == 0 {
                // 补发之前先把这一轮 runloop 走完：要让菜单的跟踪循环彻底退出，
                // 否则第二次照样被吞
                RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            }
        }
        return false
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
        // 节流：短时间内重复调用（例如反复打开菜单）直接用缓存，不再敲 I²C。
        // 但缓存是空的时候节流必须让路 —— 否则刚唤醒那会儿第一读失败，
        // 两秒内再开菜单就直接返回 nil，滑块会「消失」。
        if let t = lastRead[d.id], Date().timeIntervalSince(t) < minReadInterval,
           let cached = DDC.shared.cachedBrightness[i] {
            return cached
        }
        lastRead[d.id] = Date()
        return DDC.shared.brightness(i)
    }

    @discardableResult
    func setBrightness(_ d: DisplayItem, _ value: Double) -> Bool {
        let v = max(0, min(1, value))
        if d.isBuiltin {
            return PrivateAPI.shared.setBrightness?(d.id, Float(v)) == 0
        }
        guard let i = ddcIndex(of: d) else { return false }
        // DDC 那边写失败会自己重建一次句柄再重试，所以这里拿到 false
        // 就意味着「重建之后仍然写不进去」—— 是真实的通道故障
        return DDC.shared.setBrightness(i, v)
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

    /// 亮度写入结果回调（用于在菜单里就地提示「通道没应答」）
    var onBrightnessWriteResult: ((CGDirectDisplayID, Bool) -> Void)?

    private func flush(_ d: DisplayItem) {
        guard let v = pendingBrightness.removeValue(forKey: d.id) else { return }
        lastWrite[d.id] = Date()
        let ok = setBrightness(d, v)
        onBrightnessWriteResult?(d.id, ok)
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
    func forceReprobeDDC() {
        ddcDirty = false
        DDC.shared.forceReprobe()
        lastRead.removeAll()
        lastWrite.removeAll()
    }
}
