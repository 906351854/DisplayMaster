import AppKit
import CoreGraphics
import IOKit
import IOKit.pwr_mgt

/// 常见的逻辑分辨率白名单。
///
/// 单独提成顶层类型是有原因的：Swift 的 extension **不能新增存储属性**，
/// 而这张表属于「枚举分辨率」这件事，放在它唯一的使用者旁边最合适。
private enum CommonResolutions {
    static let all: Set<String> = [
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
}

extension DisplayManager {
    /// 在线显示器 id 的原始列表：顺序同 CoreGraphics 返回，不去重、不排序。
    ///
    /// 单独留这一份是给诊断命令用的 —— 它要打印的是「系统此刻怎么说的」，
    /// 而不是我们整理过的视图。`onlineIDs()` 只是它的集合形式。
    static func onlineDisplayList() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(max(count, 1)))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// 在线显示器集合
    func onlineIDs() -> Set<CGDirectDisplayID> { Set(Self.onlineDisplayList()) }

    // MARK: - 枚举

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
    func virtualDisplayIDs() -> Set<CGDirectDisplayID> {
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

    /// 这块屏是不是「用户根本看不见」的**占位屏**。
    ///
    /// 系统造出来的条目有两类会混进在线列表，它们 `CGDisplayIsBuiltin` 都返回 0，
    /// 于是会被自动规则当成「外接屏还接着」，让「拔掉外接屏就把内屏开回来」
    /// 这条规则永远不触发 —— 用户面前一块能看的屏都没有：
    ///
    /// ① 虚拟屏：所有真实屏都不可用时系统拿来顶班的（见 `isVirtualDisplay`）。
    /// ② 随航 / 隔空播放的**残影**：名字形如「 (AirPlay)」（设备名是空的），
    ///    或者干脆读不出 EDID。1.4.1 修的正是这一条 —— 实测 zed 这台机器上
    ///    iPad 随航断掉之后，`displayNames` 缓存里留下了三条「 (AirPlay)」，
    ///    拔线后它就是在线列表里唯一那块「屏」，规则全程按 idle 处理，
    ///    从 04:43 一直黑到 07:15。
    ///
    /// 判宽不判紧，和 `isVirtualDisplay` 同一个取舍：把真实屏误判成占位屏，
    /// 代价只是「多开一次内屏」；漏判的代价是用户对着黑屏。
    static func isPhantomDisplay(name: String, vendor: UInt32, model: UInt32,
                                 logicalWidth: Int, logicalHeight: Int) -> Bool {
        // 名字就是随航 / 隔空播放这一家子的。设成「一律不算」是有意的：
        // 真在随航的时候内屏多亮一次只是多余，而分不清残影的代价是黑屏。
        if isEphemeral(name) { return true }

        // 读不到任何 EDID：真实外接屏的厂商码一定非 0。系统造的条目这里是 0。
        if vendor == 0 && model == 0 { return true }

        // 有 EDID 却报不出可用模式 —— 这块屏此刻渲染不出任何东西。
        if logicalWidth <= 0 || logicalHeight <= 0 { return true }

        return false
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

    /// 一次扫描的结果。
    struct ScanResult {
        var items: [DisplayItem] = []
        /// 每台**在线且不是虚拟屏**的显示器各判了一次「是不是占位屏」。
        /// 留着它是因为这个功能出问题的样子是黑屏，而黑屏时用户没法自己排查 ——
        /// 日志和 `--auto-test` 里得能看出「当时到底是谁被当成了外接屏」。
        var verdicts: [(id: CGDirectDisplayID, name: String, phantom: Bool, forced: Bool)] = []

        /// 被判为占位屏而剔掉的条目
        var phantoms: [(id: CGDirectDisplayID, name: String)] {
            verdicts.filter { $0.phantom }.map { ($0.id, $0.forced ? "\($0.name)［强制］" : $0.name) }
        }
    }

    func displays() -> [DisplayItem] { scanDisplays().items }

    /// 当前被判为占位屏的 displayID（记录对账用）。
    func phantomDisplayIDs() -> Set<CGDirectDisplayID> {
        Set(scanDisplays().phantoms.map { $0.id })
    }

    /// 当前被判为占位屏的条目（诊断打印用）。
    func detectedPhantomDisplays() -> [(id: CGDirectDisplayID, name: String)] {
        scanDisplays().phantoms
    }

    /// 枚举在线显示器。
    ///
    /// 菜单、自动规则、分辨率列表吃的都是这一份结果，所以「哪些条目不算一块屏」
    /// 只在**这一处**判定（虚拟屏 + 占位屏），别处不再重复判断 ——
    /// 曾经虚拟屏的判定漏了一种，规则就整晚不触发，而菜单看上去一切正常。
    func scanDisplays() -> ScanResult {
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
        var nameCache = Self.prefs.dictionary(forKey: Self.nameCacheKey) as? [String: String] ?? [:]
        var cacheChanged = false

        var result = ScanResult()
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
            // 顺手把内屏的 id 记下来（见 knownBuiltinIDs）：它一旦被关掉，
            // 这些信息就全查不到了，必须在还能看到它的时候留一份。
            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            if isBuiltin, knownBuiltinID != id { rememberBuiltin(id) }

            // 内屏永远不判占位屏：把它剔掉会让规则以为「内屏不在线」，
            // 反过来对着一块本来就亮着的屏反复执行「打开」。
            let forced = Self.debugHideExternals && !isBuiltin
            let phantom = !isBuiltin
                && (forced || Self.isPhantomDisplay(name: name,
                                                    vendor: CGDisplayVendorNumber(id),
                                                    model: CGDisplayModelNumber(id),
                                                    logicalWidth: lw, logicalHeight: lh))
            result.verdicts.append((id, name, phantom, forced))
            if phantom { continue }

            result.items.append(DisplayItem(
                id: id,
                name: name,
                isBuiltin: isBuiltin,
                isMain: CGDisplayIsMain(id) != 0,
                pixelWidth: cur?.pixelWidth ?? lw, pixelHeight: cur?.pixelHeight ?? lh,
                logicalWidth: lw, logicalHeight: lh,
                modes: modes
            ))
        }
        if cacheChanged { Self.prefs.set(nameCache, forKey: Self.nameCacheKey) }
        return result
    }

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
        return CommonResolutions.all.contains("\(m.width)x\(m.height)")
    }

    /// 折叠掉了多少档（用于菜单里提示「还有 N 项」）
    func hiddenModeCount(_ d: DisplayItem) -> Int {
        max(0, uniqueModes(d, includeAll: true).count - uniqueModes(d, includeAll: false).count)
    }

    /// 分辨率菜单是否展示全部档位（持久化）
    var showAllResolutions: Bool {
        get { Self.prefs.bool(forKey: DefaultsKey.showAllResolutions) }
        set { Self.prefs.set(newValue, forKey: DefaultsKey.showAllResolutions) }
    }
}
