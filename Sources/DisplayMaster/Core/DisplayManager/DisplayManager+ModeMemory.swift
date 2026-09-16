import AppKit
import CoreGraphics

// MARK: - 分辨率记忆：重连时把上一回的档位恢复回去

/// zed 的真实现场：把外接屏从默认档切到别的档，拔线再插回来，
/// macOS 按它自己的默认档（2560×1440）把屏点起来 —— 用户上一回的选择丢了。
/// 系统对「睡眠唤醒」的恢复是可靠的，但对「重新枚举」（插拔后换 displayID、
/// 配置被重建）经常直接回面板默认档。
///
/// 记账身份用 **EDID 三要素**（vendor/model/serial），和「已关闭显示器」的记录
/// 同一套思路：displayID 插拔之后会变，EDID 不会。序列号拿不到就记 0，
/// 同型号多台的极端情况会串 —— 但总好过完全不记。
///
/// **什么时候记**：一台一直在在线的屏，档位变了，就是「有人改了它」——
/// 用户在系统设置里改、拖我们的滑块改、还是本应用自己刚恢复完，都照单全收。
/// （本应用恢复完的那次配置变化里，当前档位 == 记忆，等于空转，天然收敛。）
///
/// **什么时候恢复**：一台屏**重新上线**（上次评估不在、这次在了），且落点
/// 不是记住的那档 —— 也就是插拔、重连这类瞬间。app 启动那一刻不恢复：
/// 开机换了套显示器环境是常态，谁都不想被 app 在启动时改一次分辨率。
extension DisplayManager {

    struct ModeMemo: Equatable, Codable {
        let width: Int
        let height: Int
        /// 记的时候是不是 HiDPI 渲染（同一逻辑尺寸有两版，必须分开记）
        let hidpi: Bool
        /// 记的时候的刷新率。恢复时只作优先级参考（挑最接近的），不作硬条件 ——
        /// 同一逻辑档在模式表里可能有 60/120Hz 两版，用户当时用哪档就贴哪档。
        let refresh: Double

        var text: String { "\(width)×\(height)" + (hidpi ? " HiDPI" : "") }
    }

    /// 一台屏在一次评估里要做的事（纯函数的输出，场景自测直接钉它）
    enum ModeMemoryAction: Equatable {
        case idle
        /// 更新记忆
        case save(ModeMemo)
        /// 把这一档恢复回去
        case restore(ModeMemo)
    }

    // MARK: 记账

    private var modeMemos: [String: ModeMemo] {
        get {
            guard let data = Self.prefs.data(forKey: DefaultsKey.rememberedModes) else { return [:] }
            return (try? JSONDecoder().decode([String: ModeMemo].self, from: data)) ?? [:]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                Self.prefs.set(data, forKey: DefaultsKey.rememberedModes)
            }
        }
    }

    /// EDID 三要素 → 记账键
    static func modeMemoKey(vendor: UInt32, model: UInt32, serial: UInt32) -> String {
        "\(vendor)-\(model)-\(serial)"
    }

    static func modeMemoKey(_ id: CGDirectDisplayID) -> String {
        modeMemoKey(vendor: CGDisplayVendorNumber(id),
                    model: CGDisplayModelNumber(id),
                    serial: CGDisplaySerialNumber(id))
    }

    /// 这块屏此刻的档位快照
    static func currentMemo(_ id: CGDirectDisplayID) -> ModeMemo? {
        guard let m = CGDisplayCopyDisplayMode(id) else { return nil }
        return ModeMemo(width: m.width, height: m.height,
                        hidpi: m.pixelWidth > m.width, refresh: m.refreshRate)
    }

    /// 名字缓存里查名字；查不到就用 id 兜底（日志用，不值得为它做一次完整扫描）
    private func name(for id: CGDirectDisplayID) -> String {
        let cache = Self.prefs.dictionary(forKey: Self.nameCacheKey) as? [String: String] ?? [:]
        return cache[String(id)] ?? "显示器 \(id)"
    }

    /// 判定核心：只吃输入、只吐结论，不碰任何系统状态。所有分支都收在这里，
    /// `--auto-scenarios` 把每一种取值组合都跑一遍。
    static func modeMemoryDecision(seen: ModeMemo?, saved: ModeMemo?, current: ModeMemo?,
                                   allowRestore: Bool) -> ModeMemoryAction {
        guard let cur = current else { return .idle }
        if let prev = seen {
            // 一直在在线：档位变了就是「有人改了它」，照单全收
            return prev != cur ? .save(cur) : .idle
        }
        // 第一次见到（刚上线 / 刚启动）。启动后的第一次评估不恢复，
        // 否则 app 一启动就把所有人的分辨率改一遍 —— 那是骚扰。
        if allowRestore, let saved = saved, saved != cur { return .restore(saved) }
        return .save(cur)
    }

    // MARK: 评估入口

    /// 应用启动时播种：把当前在线的屏全部记成「见过」。
    /// 不播种的话，启动后的第一次配置变化会把所有屏当成「刚上线」，
    /// 好端端把记住的档位恢复一遍。
    func seedModeMemory() {
        var seen: [String: ModeMemo] = [:]
        for d in displays() {
            guard let cur = Self.currentMemo(d.id) else { continue }
            seen[Self.modeMemoKey(d.id)] = cur
        }
        modeMemorySeen = seen
        modeMemoryPending.removeAll()
        modeMemorySeeded = true
    }

    /// 每次屏幕配置变化都评估一遍（screenConfigurationChanged 调）。
    /// `items` 用扫描结果 —— 虚拟屏 / 占位屏已经被剔掉了，不该记账。
    ///
    /// 三类屏三种处理：一直在账的照常评估（档位变了就记）；**新上线的先挂起**，
    /// 满 2.5 秒等模式落定再判（风暴里的首见档位是随机的，见 ModeRestoreRecord
    /// 旁边那条实测）；消失的摘出账本。
    func trackModeMemory(items: [DisplayItem]) {
        var memos = modeMemos
        var memosChanged = false

        var online: [String: CGDirectDisplayID] = [:]
        for d in items { online[Self.modeMemoKey(d.id)] = d.id }

        // 消失的屏：从「见过」和「挂起」里都摘掉 —— 下次回来才算「重新上线」
        for key in modeMemorySeen.keys where online[key] == nil {
            modeMemorySeen.removeValue(forKey: key)
        }
        for key in modeMemoryPending.keys where online[key] == nil {
            modeMemoryPending.removeValue(forKey: key)
        }

        // 新面孔：挂起，不判。落定评估在下面 ④
        let now = Date()
        for (key, id) in online where modeMemorySeen[key] == nil && modeMemoryPending[key] == nil {
            modeMemoryPending[key] = (id, now)
            ruleLog("分辨率记忆：新面孔挂起，等模式落定（\(name(for: id))）")
        }

        // 老面孔：照常评估
        for d in items {
            let key = Self.modeMemoKey(d.id)
            guard modeMemoryPending[key] == nil, let cur = Self.currentMemo(d.id) else { continue }
            let action = Self.modeMemoryDecision(seen: modeMemorySeen[key],
                                                 saved: memos[key],
                                                 current: cur,
                                                 allowRestore: modeMemorySeeded)
            switch action {
            case .idle:
                break
            case .save(let m):
                // 「刚恢复就被弹回」：系统在插拔后的几秒里会把它的默认配置再套一遍，
                // 恢复好的档位可能被弹回落点档 —— 那一下长得跟「用户改档位」一模一样。
                // 别把它记下来：补切一次；补过还弹，才是真的该认输照记。
                if let lr = lastModeRestore[key],
                   Date().timeIntervalSince(lr.at) < 6,
                   m == lr.bounce, !lr.reasserted {
                    lastModeRestore[key] = ModeRestoreRecord(memo: lr.memo, bounce: lr.bounce,
                                                             at: lr.at, reasserted: true)
                    ruleLog("分辨率记忆：「\(d.name)」刚恢复就被弹回 \(m.text)（系统没站稳），再补一次")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.applyRememberedMode(displayID: d.id, memo: lr.memo, bounce: lr.bounce,
                                                  reasserted: true)
                    }
                } else if memos[key] != m {
                    memos[key] = m
                    memosChanged = true
                    ruleLog("分辨率记忆：「\(d.name)」记下 \(m.text)")
                }
            case .restore(let m):
                scheduleModeRestore(d, key: key, memo: m)
            }
            modeMemorySeen[key] = cur
        }

        if memosChanged { modeMemos = memos }

        // ④ 落定评估：已经满龄的现在判；再排一个兜底扫描（风暴结束后不一定还有通知来）
        settlePending()
        let work = DispatchWorkItem { [weak self] in self?.settlePending() }
        modeMemorySettleWork?.cancel()
        modeMemorySettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }

    /// 判定挂起中的新屏。满 2.5 秒才算「落定」；没满龄的等下一轮。
    private func settlePending() {
        var memos = modeMemos
        var memosChanged = false
        let now = Date()

        for (key, entry) in modeMemoryPending where now.timeIntervalSince(entry.firstSeen) >= 2.5 {
            modeMemoryPending.removeValue(forKey: key)
            guard Self.onlineDisplayList().contains(entry.id),
                  let cur = Self.currentMemo(entry.id) else { continue }
            let action = Self.modeMemoryDecision(seen: nil,
                                                 saved: memos[key],
                                                 current: cur,
                                                 allowRestore: modeMemorySeeded)
            switch action {
            case .idle:
                break
            case .save(let m):
                if memos[key] != m {
                    memos[key] = m
                    memosChanged = true
                    ruleLog("分辨率记忆：「\(name(for: entry.id))」记下 \(m.text)（落定）")
                }
            case .restore(let m):
                if let d = displays().first(where: { $0.id == entry.id }) {
                    scheduleModeRestore(d, key: key, memo: m)
                }
            }
            modeMemorySeen[key] = cur
        }

        if memosChanged { modeMemos = memos }
    }

    // MARK: 恢复

    private func scheduleModeRestore(_ d: DisplayItem, key: String, memo: ModeMemo) {
        let bounce = Self.currentMemo(d.id)
        ruleLog("分辨率记忆：「\(d.name)」重新上线，落点 \(bounce?.text ?? "?")"
                + " ≠ 记住的 \(memo.text)，稍后恢复")
        // 系统刚把屏点起来，立刻改模式容易失败（自动规则同一条经验），缓一拍再动手
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.applyRememberedMode(displayID: d.id, memo: memo, bounce: bounce, reasserted: false)
        }
    }

    /// 把记住的那档真的切回去。动手前重查一遍：这一拍半里系统可能自己恢复好了，
    /// 屏也可能又拔掉了 —— 两种都不用管。
    func applyRememberedMode(displayID: CGDirectDisplayID, memo: ModeMemo,
                             bounce: ModeMemo?, reasserted: Bool) {
        guard Self.onlineDisplayList().contains(displayID) else { return }
        guard let cur = Self.currentMemo(displayID), cur != memo else { return }

        // CGDisplayMode 不能跨配置复用（重连后是新的模式对象），在**这块屏现在的**
        // 完整模式表里找回同一档：逻辑尺寸 + 渲染倍率必须都一致，刷新率贴最接近的
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
        let matches = modes.filter {
            $0.width == memo.width && $0.height == memo.height
                && ($0.pixelWidth > $0.width) == memo.hidpi
        }
        guard let target = matches.sorted(by: {
            let da = abs($0.refreshRate - memo.refresh)
            let db = abs($1.refreshRate - memo.refresh)
            if da != db { return da < db }
            return $0.refreshRate > $1.refreshRate
        }).first else {
            ruleLog("分辨率记忆：这块屏的模式表里没有 \(memo.text) 了（换屏了？），放弃")
            return
        }

        let key = Self.modeMemoKey(displayID)
        // 记下恢复现场：几秒内若被弹回落点档（系统没站稳），判定环节会再补一次。
        // 补切的这一下也记成 reasserted —— 再弹就是系统铁了心，别无限打下去。
        lastModeRestore[key] = ModeRestoreRecord(memo: memo, bounce: bounce ?? cur,
                                                 at: Date(), reasserted: reasserted)
        ruleLog("分辨率记忆：切回 \(memo.text) ...")
        if setMode(displayID, target) {
            ruleLog("分辨率记忆：✓ 已恢复 \(memo.text)")
        } else {
            ruleLog("分辨率记忆：✗ 系统拒绝，不再重试（菜单里手动切仍然可用）")
            lastModeRestore.removeValue(forKey: key)
        }
    }

    // MARK: 诊断

    /// `--auto-test` 打印用
    func debugModeMemos() -> [String: ModeMemo] { modeMemos }
}
