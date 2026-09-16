import AppKit
import CoreGraphics
import IOKit
import IOKit.pwr_mgt

extension DisplayManager {
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
