import AppKit
import CoreGraphics
import IOKit
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
    /// 面板的物理分辨率。卡片规格那一行写的是它，逻辑分辨率由分辨率滑块去说。
    /// 旧记录里没有这一项，读到 0 就退回逻辑分辨率。
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    /// 关闭前的亮度 0...1。nil = 当时就不可控（或旧格式记录里没有）
    let brightness: Double?
    /// 关闭前是不是 HiDPI
    let hidpi: Bool

    init(name: String, vendor: UInt32, model: UInt32, serial: UInt32, isBuiltin: Bool,
         logicalWidth: Int = 0, logicalHeight: Int = 0,
         pixelWidth: Int = 0, pixelHeight: Int = 0, refreshRate: Double = 0,
         brightness: Double? = nil, hidpi: Bool = false) {
        self.name = name
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.isBuiltin = isBuiltin
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.brightness = brightness
        self.hidpi = hidpi
    }

    /// 有没有可用于比对的硬件信息
    var hasHardwareID: Bool { vendor != 0 || model != 0 || serial != 0 }

    /// 卡片上那行面板规格「5120 × 2880 · 60 Hz」。
    /// 物理分辨率优先；旧记录里没存过就退回逻辑分辨率，别让那一行空着。
    var specLine: String {
        let w = pixelWidth > 0 ? pixelWidth : logicalWidth
        let h = pixelHeight > 0 ? pixelHeight : logicalHeight
        guard w > 0, h > 0 else { return "关闭时的分辨率未记录" }
        var s = "\(w) × \(h)"
        if refreshRate >= 1 { s += " · \(Int(refreshRate.rounded())) Hz" }
        return s
    }
}

/// 显示器统一管理：枚举 / 开关 / 分辨率 / 亮度
final class DisplayManager {
    static let shared = DisplayManager()

    // 这一层只放「存储状态 + 生命周期入口」，方法实现按职责分在
    // DisplayManager+*.swift 里。
    //
// 注意：下面若干成员没有写 private，是因为类的实现被拆在多个文件里，
// 而 Swift 的 private 只到文件级。它们是模块内部状态，不是对外 API。

    // MARK: - 状态

    /// 被本 app 关闭的显示器（id -> 记录）。CGGetOnlineDisplayList 里查不到它们，
    /// 所以必须自己记住才能重新打开 —— 而且必须落盘，否则 app 一重启这块屏就失联了。
    var disabled: [CGDirectDisplayID: DisabledDisplay] = [:]

    static let disabledKey = DefaultsKey.disabledDisplays

    /// 显示器名称缓存（id -> 名字）
    static let nameCacheKey = DefaultsKey.displayNames

    /// DDC 通道需要重建（屏幕配置刚变过：睡眠唤醒、插拔、分辨率变更）
    var ddcDirty = false

    // MARK: 读写节流
    /// 外接屏读 DDC 的间隔下限：打开菜单就会触发读，不加节流会被菜单反复猛敲。
    let minReadInterval: TimeInterval = 2.0
    /// 写间隔下限：外接屏走 I²C，拖滑块时的高频写是「把显示器写死」的主因。
    let minWriteIntervalExternal: TimeInterval = 0.10
    let minWriteIntervalBuiltin: TimeInterval = 0.03

    var lastRead: [CGDirectDisplayID: Date] = [:]
    var lastWrite: [CGDirectDisplayID: Date] = [:]
    var pendingBrightness: [CGDirectDisplayID: Double] = [:]
    var flushScheduled: Set<CGDirectDisplayID> = []

    /// 调试用：把外接屏一律当成占位屏（`--auto-test --fake-no-external`）。
    ///
    /// 1.4.1 那次黑屏的现场条件（外接屏接着、内屏被关着、拔线后只剩一条随航残影）
    /// 没法按需复现 —— 总不能为了测一次去插拔 iPad。开着它，规则看到的世界
    /// 就是「外接屏都不在」，于是在真机上也能把「黑屏救援」这条路走一遍。
    static var debugHideExternals = false

    /// 上一次评估时「外接屏在不在」。
    ///
    /// 之所以记这个，而不是每次配置变化都无脑执行：用户有时就是想在内屏上干点活
    /// （比如把窗口拖回来），这时候手动把内屏开回来，如果规则当场又把它关掉，
    /// 那这个功能就变成骚扰了。只在「接上」和「拔掉」这两个瞬间动手，
    /// 中间的手动操作都归用户自己。
    var lastExternalPresent: Bool?

    /// 重试链的编号。每开一条新链就自增，旧链的回调一比较编号就知道自己过期了，
    /// 免得几轮插拔叠在一起时同时跑好几条重试链。
    var restoreChain = 0

    var safetyTimer: Timer?

    // MARK: 分辨率记忆（重连恢复）
    // 实现和判定都在 DisplayManager+ModeMemory.swift；extension 不能加存储属性，
    // 所以这两个状态放这儿。

    /// 上一次评估时每台在线屏的档位快照（EDID 键 -> 档位）。
    /// 靠它区分「一直在线、档位被人改了」（照单全收记下来）和「重新上线」
    /// （该把记住的档位恢复回去）这两种情况。
    var modeMemorySeen: [String: DisplayManager.ModeMemo] = [:]
    /// 启动后是否已经播种过。播种前的第一次评估只记不恢复 ——
    /// 启动那一刻谁的档位都不该被改。
    var modeMemorySeeded = false

    /// 刚做完一次「恢复」的现场（EDID 键 -> 记录），见 DisplayManager+ModeMemory。
    struct ModeRestoreRecord {
        let memo: ModeMemo          // 恢复的目标档
        let bounce: ModeMemo        // 恢复前的落点（系统默认档）
        let at: Date
        var reasserted: Bool        // 已经补切过一次了吗
    }
    var lastModeRestore: [String: ModeRestoreRecord] = [:]

    /// 等待「落定」的新上线屏（EDID 键 -> displayID + 首见时刻）。
    /// 实测重连风暴里，刚上线的屏模式读数会跳变（先读到 A，零点几秒后落定到 B），
    /// 立刻判定的话「首见档位」是随机的 —— 所以新屏先挂起，满 2.5 秒再判。
    var modeMemoryPending: [String: (id: CGDirectDisplayID, firstSeen: Date)] = [:]
    /// 落定评估的兜底定时器（最后一次配置变化后 2.6 秒扫一遍挂起表）
    var modeMemorySettleWork: DispatchWorkItem?

    /// 亮度写入结果回调（用于在菜单里就地提示「通道没应答」）
    var onBrightnessWriteResult: ((CGDirectDisplayID, Bool) -> Void)?

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
        // 被剔掉的虚拟屏 / 占位屏也一并记：1.4.1 那次黑屏，真凶就是一行
        // 「在线 [ (AirPlay)]」—— 一块用户看不见的随航残影被当成了外接屏。
        let scan = scanDisplays()
        let snapshot = scan.items
            .map { "\($0.name)\($0.isBuiltin ? "(内置)" : "")" }
            .joined(separator: ", ")
        let virtuals = virtualDisplayIDs().sorted()
        ruleLog("配置变化：在线 [\(snapshot.isEmpty ? "无" : snapshot)] · 已关闭 \(disabled.count) 台"
                + " · 睡眠 \(displaysAsleep() ? "是" : "否")"
                + (isLidClosed() ? " · 合盖" : "")
                + (virtuals.isEmpty ? "" : " · 另排除虚拟屏 \(virtuals.map { String($0) }.joined(separator: ","))")
                + (scan.phantoms.isEmpty ? ""
                   : " · 另排除占位屏 " + scan.phantoms.map { "\($0.id)「\($0.name)」" }.joined(separator: ",")))

        // 显示器从睡眠里回来需要一点时间才恢复应答，延后重建一次；
        // 若那时还没好，下次打开菜单时 refresh() 会再试（ddcDirty 还在）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, self.ddcDirty else { return }
            self.ddcDirty = false
            DDC.shared.forceReprobe()
            self.lastRead.removeAll()
            self.lastWrite.removeAll()
        }

        // 分辨率记忆：区分「一直在线改了档位」和「重新上线」，后者把记住的档位恢复回去
        trackModeMemory(items: scan.items)

        // 插拔外接屏、系统改显示配置，都会走到这里 —— 也就是自动关内屏规则的触发点。
        // 延后一点：系统刚改完配置，这时候立刻再改一次容易失败。
        // 真失败了也不怕：打开内屏那条路自带重试和巡检兜底。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.applyAutoBuiltinRule(source: "配置变化")
        }
    }

}
