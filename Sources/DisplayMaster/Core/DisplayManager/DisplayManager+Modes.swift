import AppKit
import CoreGraphics
import IOKit
import IOKit.pwr_mgt

extension DisplayManager {
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
}
