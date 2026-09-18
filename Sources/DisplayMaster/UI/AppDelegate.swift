import AppKit
import CoreGraphics

/// 菜单里的亮度滑块。
/// 拖动过程中 NSSlider 只保证「连续动作」，拿不到可靠的「松手」时机，
/// 而最后一档亮度必须确保落到显示器上 —— 这个子类在 BrightnessSlider 里，
/// 挪到 MenuPanel.swift 了（那边同时接管了它的绘制）。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

// 这个类被拆在 AppDelegate+*.swift 几个文件里。Swift 的 private 只到文件级，
// 所以下面那些被 extension 用到的成员没有写 private —— 它们是模块内部状态，
// 不是对外 API。

    var statusItem: NSStatusItem!
    /// 最近一次滑块拖动事件的时间。
    ///
    /// 这里刻意记时间而不是用布尔量：拖动期间禁止重建菜单是必要的（否则正在拖的
    /// 滑块会被整个换掉），但布尔量一旦因为某次收不到 mouseUp 而卡住 true，
    /// 菜单就**再也不会重建** —— 表现为显示器开回来了、菜单里却还显示旧状态。
    /// 记时间可以让这个状态自己过期。
    var lastDragAt: Date?
    private var isDraggingSlider: Bool {
        guard let t = lastDragAt else { return false }
        return Date().timeIntervalSince(t) < 1.5
    }
    /// 当前菜单里的亮度数值标签，用于就地显示「写入无应答」
    var sliderLabels: [CGDirectDisplayID: NSTextField] = [:]

    /// 第二页：正在看哪台显示器的详情。nil = 主面板
    var settingsDisplayID: CGDirectDisplayID?
    /// 卡片分页页码
    var cardPage = 0
    /// 正在「换页重开菜单」。
    ///
    /// 菜单的换页是「关掉再打开」（菜单项动作一触发，菜单必然关闭），
    /// 而 menuDidClose 里要把页面状态复位。没有这个标记的话，
    /// 换页时状态会被自己清掉，重开之后又回到主面板。
    var isRepaging = false

    /// 开发用：让 `--shot-menu` / `--dump-menu` 直接把菜单开在某台屏的详情页
    var debugPresetSettingsID: CGDirectDisplayID?

    /// 当前菜单里的卡片行。重建菜单时更新，换页与命中判定都靠它
    weak var cardsRow: CardsRowView?

    /// 分辨率滑块每一档对应的模式，建菜单时顺手算好。
    ///
    /// 滑块身上只有「下标」——`NSSlider` 没法背一个 `CGDisplayMode` 数组；
    /// 松手那一刻要拿下标换回真正的模式，就得有这张表。它必须和滑块上摆的
    /// 是同一份列表，否则拖到第 7 档会切到别的分辨率上去。
    var resolutionModes: [CGDirectDisplayID: [CGDisplayMode]] = [:]

    /// 开发用：把卡片数量凑到 n 张，用来看翻页（真机上凑不出那么多显示器）
    var debugFakeCardCount: Int?
    /// 开发用：把这几张卡画成「已关闭」状态，用来核对关闭态的样式
    var debugForceOffIndices: [Int] = []
    /// 开发用：强制把亮度画成这个值（0…1），用来核对滑块两端到底到没到底
    var debugFakeBrightness: Double?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()

        registerSystemObservers()

        // 分辨率记忆播种：记下启动时每块屏的档位。之后的插拔才有「恢复」可谈，
        // 而启动那一刻谁都不该被改档位（见 DisplayManager+ModeMemory）。
        DisplayManager.shared.seedModeMemory()

        // 亮度写入失败时，就在滑块那一行后面显示「无应答」，而不是让用户对着没反应的滑块干瞪眼
        DisplayManager.shared.onBrightnessWriteResult = { [weak self] id, ok in
            self?.showWriteResult(id, ok)
        }

        // 开关是持久化的：应用重启后，如果外接屏早就接着，规则也该照常生效。
        // 延后两秒，等显示器和 DDC 都就绪了再判断。
        let mgr = DisplayManager.shared
        mgr.ruleLog("应用启动（版本 \(AppInfo.version)，自动关内屏开关"
                    + "\(mgr.autoDisableBuiltinWhenExternal ? "已打开" : "未打开")）")
        // 巡检跟开关无关：它只管「一块能看的屏都没有」这种故障态，
        // 和「有外接屏时要顺手关内屏」这个偏好是两回事（见 applyAutoBuiltinRule）。
        mgr.startSafetyMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            mgr.applyAutoBuiltinRule(force: true, source: "启动检查")
        }
        // 自动亮度同理：开关持久化，启动后照常接管（幂等，开关没开就不起表）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            mgr.startAutoBrightnessMonitor()
        }
        // 菜单开着时滑块跟手：自动亮度每改一台屏就广播一次，这里就地刷 UI
        NotificationCenter.default.addObserver(
            self, selector: #selector(autoBrightnessApplied(_:)),
            name: .autoBrightnessDidApply, object: nil)

        // 保活代理：注册进 launchd（异常退出自动拉起 + 登录自启）。救援内屏的前提
        // 是应用活着，这一层保证「应用死了也有人在几秒内把它扶起来」。
        // 后台跑：launchctl 往返要几百毫秒，不能挡启动。
        DispatchQueue.global(qos: .utility).async {
            KeepAliveAgent.installAndHandOverIfOutsider()
        }
    }

    /// 建状态栏图标与菜单。
    /// 独立成方法是为了让 `--shot-menu` 能只拿外观、不背副作用（不启动巡检、不跑自动规则）——
    /// 截图工具要是顺手把用户的显示器关了，那就很难解释了。
    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = Self.menuBarIcon()
            b.toolTip = "\(AppInfo.displayName) — 显示器开关 / 亮度 / HiDPI / 分辨率"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// 开发用：装上状态栏图标（供截图/结构打印），不启动任何后台行为
    func debugInstallStatusItem() {
        installStatusItem()
    }

    /// 开发用：拿到状态栏按钮，好把菜单弹在该弹的地方
    var debugStatusButton: NSStatusBarButton? { statusItem?.button }

    /// 开发用：把菜单弹出来。给 `--shot-menu` 用，返回后调用方负责截屏与退出。
    func debugPopUpMenu() {
        guard let button = statusItem.button else { return }
        statusItem.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 6), in: button)
    }

    /// 监听屏幕配置变化。
    ///
    /// 关键场景：**显示器睡眠唤醒后，DDC 的 I²C 通道会哑掉** —— 句柄还在、
    /// 也不报错，但读不出也写不进，表现就是「亮度滑块还在，拖了却没反应」。
    /// 收到这些通知就标记通道待重建，用户根本不需要知道「重新检测 DDC」这个按钮。
    private func registerSystemObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            ws.addObserver(self, selector: #selector(screenConfigChanged(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenConfigChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screenConfigChanged(_ note: Notification) {
        DisplayManager.shared.screenConfigurationChanged()
    }

    /// 就地反馈亮度写入结果（不重建菜单也能看到）
    private func showWriteResult(_ id: CGDirectDisplayID, _ ok: Bool) {
        guard let label = sliderLabels[id] else { return }
        if ok {
            label.textColor = .secondaryLabelColor
            return
        }
        label.stringValue = "无应答"
        label.textColor = .systemRed
        label.isHidden = false
    }

    // 每次打开菜单都重建，保证状态实时
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !isDraggingSlider else { return }
        DisplayManager.shared.refresh()
        build(menu)
    }

    /// 菜单开着时每秒把亮度滑块对齐到硬件真值。
    ///
    /// 亮度可能被任何人改：系统环境光自动调节（内屏）、显示器自己的物理按键、
    /// 我们的自动亮度、别的进程。菜单是打开那一刻画的静态快照，谁改了都不会
    /// 反映进来 —— 这里补一条「开着时定期对齐」的通道，与自动亮度的即时通知
    /// 互补（通知快，但只覆盖我们自己的写入）。
    ///
    /// Timer 必须挂 .common 模式：菜单跟踪期间主线程跑的是 tracking 模式，
    /// 默认模式下的定时器整个菜单打开期间一次都不会响。
    private var brightnessSyncTimer: Timer?

    func menuWillOpen(_ menu: NSMenu) {
        if brightnessSyncTimer == nil {
            let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.syncSlidersWithHardware()
            }
            brightnessSyncTimer = t
            RunLoop.main.add(t, forMode: .common)
        }
        syncSlidersWithHardware()   // 打开的瞬间先对齐一次，别等一秒
    }

    /// 读每台屏的实时亮度并就地刷新滑块。拖动期间完全让路。
    @objc func syncSlidersWithHardware() {
        guard !isDraggingSlider else { return }
        let mgr = DisplayManager.shared
        for d in mgr.displays(includeModes: false) {
            guard let v = mgr.brightness(of: d) else { continue }
            cardsRow?.updateBrightness(displayID: d.id, percent: Int((v * 100).rounded()))
        }
    }

    /// 菜单一关，任何拖动都已经结束了 —— 顺手把状态复位（配合时间戳双重保险）
    func menuDidClose(_ menu: NSMenu) {
        brightnessSyncTimer?.invalidate()
        brightnessSyncTimer = nil
        lastDragAt = nil
        sliderLabels.removeAll()
        // 换页时菜单也会先关一次，这次不算「用户关掉了菜单」，页面状态得留着
        if isRepaging {
            isRepaging = false
        } else {
            settingsDisplayID = nil
            cardPage = 0
        }
    }

    /// 换个页面重新打开菜单。
    ///
    /// 菜单项的动作一触发，菜单必然关闭，所以「页内跳转」只能做成关掉再打开。
    /// 延迟一点点是为了等上一条菜单彻底收干净 —— 紧接着 popUp 会被系统直接忽略。
    func reopenMenu() {
        isRepaging = true
        // 换页的这一刻菜单必须先是关着的：真实路径上菜单项动作本身就会关掉菜单，
        // 但从自测里直接调动作时它不会，这里显式收一下，两种情况才等价
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.statusItem.menu?.popUp(positioning: nil,
                                        at: NSPoint(x: 0, y: button.bounds.minY - 6), in: button)
        }
    }

    /// 菜单栏图标：优先用打包进 Resources 的单色 template 图，
    /// 取不到就退回 SF Symbol（例如直接跑 .build 里的裸二进制时）。
    private static func menuBarIcon() -> NSImage? {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        var foundAny = false
        for name in ["MenuBarIcon", "MenuBarIcon@2x", "MenuBarIcon@3x"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = NSSize(width: 18, height: 18)
            image.addRepresentation(rep)
            foundAny = true
        }
        if foundAny {
            image.isTemplate = true      // 让系统按菜单栏明暗自动反色
            return image
        }
        let fallback = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: AppInfo.name)
        fallback?.isTemplate = true
        return fallback
    }
}
