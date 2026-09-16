import AppKit
import CoreGraphics
import IOKit
import IOKit.pwr_mgt

extension DisplayManager {
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

    /// 曾经见过的内屏 displayID（历史，最近的在前，落盘）。
    ///
    /// 1.4.1 加的。原来只记一个 id，而「救援」这条路完全依赖它 ——
    /// 记的那个一旦过期（系统重建过显示配置、用户重装过、清过偏好），
    /// 而我们又刚好面对着「没有外接屏、内屏也不在线」，那就真的一块屏都开不回来了。
    /// 多留几个的成本只是「试不中的 id 会失败一次」，而失败的代价远小于黑屏。
    var knownBuiltinIDs: [CGDirectDisplayID] {
        get {
            let raw = UserDefaults.standard.array(forKey: "knownBuiltinDisplayIDs") as? [Int] ?? []
            var out = raw.map { CGDirectDisplayID($0) }
            // 兼容 1.4.0 及更早留下的单值记录
            if let one = knownBuiltinID, !out.contains(one) { out.insert(one, at: 0) }
            return out
        }
        set {
            var seen: [CGDirectDisplayID] = []
            for id in newValue where !seen.contains(id) { seen.append(id) }
            UserDefaults.standard.set(seen.prefix(4).map { Int($0) }, forKey: "knownBuiltinDisplayIDs")
            UserDefaults.standard.synchronize()
        }
    }

    /// 记下一块内屏的 id（最近的在前，最多留 4 个）
    func rememberBuiltin(_ id: CGDirectDisplayID) {
        var list = knownBuiltinIDs.filter { $0 != id }
        list.insert(id, at: 0)
        knownBuiltinIDs = list
        if knownBuiltinID != id { knownBuiltinID = id }
    }

    /// 名字缓存里那些「一看就是内屏」的 id。
    ///
    /// 救援的候选用完之后的最后一条线索：关闭记录和历史 id 都可能丢，
    /// 而名字缓存往往还在（它是纯展示数据，没人会去清）。同样只用于「打开」，
    /// 所以猜错的代价只是白试一次。
    static func builtinIDsFromNameCache() -> [CGDirectDisplayID] {
        let cache = UserDefaults.standard.dictionary(forKey: nameCacheKey) as? [String: String] ?? [:]
        return cache.compactMap { key, name -> CGDirectDisplayID? in
            guard let id = UInt32(key), looksBuiltin(name) else { return nil }
            return CGDirectDisplayID(id)
        }.sorted()
    }

    // MARK: - 「已关闭显示器」的持久化

    func loadDisabled() {
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
                    pixelWidth: Int(dict["pw"] as? String ?? "") ?? 0,
                    pixelHeight: Int(dict["ph"] as? String ?? "") ?? 0,
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

    func saveDisabled() {
        let raw: [String: [String: String]] = Dictionary(uniqueKeysWithValues: disabled.map { (id, rec) in
            (String(id), [
                "name": rec.name,
                "vendor": String(rec.vendor),
                "model": String(rec.model),
                "serial": String(rec.serial),
                "isBuiltin": rec.isBuiltin ? "1" : "0",
                "w": String(rec.logicalWidth),
                "h": String(rec.logicalHeight),
                "pw": String(rec.pixelWidth),
                "ph": String(rec.pixelHeight),
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

    /// EDID 三要素。显示器关掉之后这些查询就取不到了，所以必须在关闭**之前**记下来。
    func hardwareID(_ id: CGDirectDisplayID) -> (vendor: UInt32, model: UInt32, serial: UInt32) {
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
        // 虚拟屏和占位屏都要剔掉：虚拟屏的 displayID 每次生成都不一样，万一撞上
        // 某条记录的 id，就会被误判成「这块屏自己回来了」，把记录删掉；
        // 占位屏（随航残影之类）则是「在线」但根本不存在，删记录同样没道理。
        let online = onlineIDs()
            .subtracting(virtualDisplayIDs())
            .subtracting(phantomDisplayIDs())
            .union(list.map { $0.id })
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
}
