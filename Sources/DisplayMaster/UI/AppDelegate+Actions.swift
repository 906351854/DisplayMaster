import AppKit
import CoreGraphics

extension AppDelegate {
    // MARK: - 动作

    /// 卡片行被点击。
    ///
    /// 菜单项的动作拿不到点击坐标，所以用鼠标当前位置反查：点到哪张卡的哪个部位，
    /// 就办哪件事。滑块自己会吃掉鼠标事件，正常拖亮度不会走到这里 ——
    /// 万一走上来了（判定落在滑块上），也不能顺手换页，那是很吓人的行为。
    @objc func cardsRowClicked(_ sender: NSMenuItem) {
        guard let row = sender.view as? CardsRowView else { return }
        handleCardsHit(row)
    }

    @discardableResult
    func handleCardsHit(_ row: CardsRowView) -> String {
        switch row.hitAtMouse() {
        case .detail(let id):
            settingsDisplayID = id
            reopenMenu()
            return "卡片 \(id) → 详情页"
        case .toggleOn(let id):
            return toggleDisplayOn(id)
        case .toggleHiDPI(let id):
            return toggleHiDPIBecauseCardClicked(id)
        case .pagePrev:
            cardPage = max(0, cardPage - 1)
            reopenMenu()
            return "上一页"
        case .pageNext:
            cardPage += 1
            reopenMenu()
            return "下一页"
        case .slider:
            return "落在滑块上（不换页）"
        case .none:
            return "没命中任何卡片"
        }
    }

    /// 卡片上那个「开启」开关：开着就关掉，关着就打开。
    ///
    /// 关掉一台屏要等系统改完显示配置（最长两秒），期间菜单必须**先收起来**，
    /// 否则菜单就那么挂在那儿不动，看起来像卡死。办完再把菜单弹回来，
    /// 用户看到的就已经是新的状态了。
    @discardableResult
    private func toggleDisplayOn(_ id: CGDirectDisplayID) -> String {
        let mgr = DisplayManager.shared
        isRepaging = true                 // 这次关闭不是「用户关掉菜单」，页面状态要留着
        statusItem.menu?.cancelTracking()

        let wasOn = mgr.displays().contains { $0.id == id }
        let ok: Bool
        if let d = mgr.displays().first(where: { $0.id == id }) {
            ok = mgr.setEnabled(d.id, false, name: d.name)
        } else {
            ok = mgr.setEnabled(id, true)
        }
        reopenMenu()
        let what = wasOn ? "关闭" : "打开"
        return ok ? "\(what)成功" : "\(what)失败（系统拒绝，或这是最后一台屏）"
    }

    /// 卡片上的 HiDPI 开关
    ///
    /// 必须**等菜单彻底收干净**再改显示配置。踩到的坑：菜单项动作一触发菜单就要收，
    /// 如果在收的这一帧里（或者像之前那样，重开菜单的定时器已经排上队、菜单又弹起来了）
    /// 去调 CGDisplaySetDisplayMode，系统会返回 success、配置也确实短暂变过，
    /// 然后**又被还原回去** —— 用户看到的就是「点了 HiDPI 没反应」。
    /// 所以这里挪到 0.25 秒之后再动手，办完才重开菜单。
    @discardableResult
    private func toggleHiDPIBecauseCardClicked(_ id: CGDirectDisplayID) -> String {
        guard let d = DisplayManager.shared.displays().first(where: { $0.id == id }) else {
            return "这台屏是关着的，HiDPI 切不了"
        }
        isRepaging = true
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let ok = DisplayManager.shared.toggleHiDPI(d)
            if !ok { NSSound.beep() }
            self.reopenMenu()
        }
        return "HiDPI 已切换"
    }

    /// 从详情页回到主面板
    @objc func backToMainPage(_ sender: NSMenuItem) {
        settingsDisplayID = nil
        reopenMenu()
    }

    @objc func brightnessChanged(_ sender: PanelSlider) {
        let id = CGDirectDisplayID(sender.tag)
        guard let d = DisplayManager.shared.displays().first(where: { $0.id == id }) else { return }

        lastDragAt = Date()          // 拖动期间不重建菜单（时间戳会自己过期）
        let percent = sender.doubleValue
        if let label = sliderLabels[id] {
            label.stringValue = "\(Int(percent.rounded()))%"
            label.textColor = .secondaryLabelColor
            label.isHidden = false
        }

        // 节流写入：拖动中最多每 100ms 一次 I²C，避免把显示器写死
        DisplayManager.shared.setBrightnessThrottled(d, percent / 100)
        // 自动亮度让位：手动调过之后一小段时间内别再自动覆盖
        DisplayManager.shared.noteManualBrightnessAdjust()

        // 松手那一下把最后一档落实（节流会吞掉末尾几次）。
        // 松手判定走动作事件的事件类型 —— cell 跟踪期间视图的 mouseUp 收不到，
        // onRelease 那条备用通道在真实拖动里从来不会响。
        if sender.isReleaseEvent {
            flushBrightness(displayID: id)
        }
    }

    /// 松手后把最后一档数值真正落到显示器（节流会吞掉末尾几次）
    func flushBrightness(displayID: CGDirectDisplayID) {
        guard let d = DisplayManager.shared.displays().first(where: { $0.id == displayID }) else { return }
        DisplayManager.shared.flushBrightness(d)
    }

    /// 自动亮度改写了某台外接屏：菜单开着就让滑块就地跟过去
    @objc func autoBrightnessApplied(_ note: Notification) {
        guard let id = note.userInfo?["displayID"] as? CGDirectDisplayID,
              let pct = note.userInfo?["percent"] as? Int else { return }
        cardsRow?.updateBrightness(displayID: id, percent: pct)
    }

    // MARK: - 分辨率滑块

    /// 拖动中：只把数字改掉，**不切模式**。
    /// 切一次模式屏幕要黑一下、窗口还要重排，边拖边切屏幕上就是一片频闪。
    ///
    /// 松手才真的切。判定靠动作事件的事件类型（.leftMouseUp）——
    /// 之前靠视图的 mouseUp 回调，但 cell 拖动时会自建事件循环把 mouseUp
    /// 消费掉，那条回调在真实拖动里一次都不会来，于是滑块能拖、模式永远不切。
    @objc func resolutionChanged(_ sender: PanelSlider) {
        lastDragAt = Date()          // 拖动期间不重建菜单（时间戳会自己过期）
        let id = CGDirectDisplayID(sender.tag)
        let index = Int(sender.doubleValue.rounded())
        cardsRow?.previewResolution(id: id, index: index)
        if sender.isReleaseEvent {
            applyResolution(displayID: id, index: index)
        }
    }

    /// 松手：真正切过去。
    ///
    /// 和 HiDPI 那条路一样，必须**等菜单收干净再动手**：在菜单收尾那一帧里改显示配置，
    /// 系统会返回成功、配置也确实短暂变过，然后又被还原回去 —— 用户看到的就是
    /// 「拖了没反应」。切模式本来就要黑屏一下，菜单挂在那儿只会让人以为卡住了，
    /// 索性先收起来、切完再弹回来。
    func applyResolution(displayID id: CGDirectDisplayID, index: Int) {
        let modes = resolutionModes[id] ?? []
        guard index >= 0, index < modes.count else { return }
        let mode = modes[index]

        // 拖回原来那一档（或者只是点了一下滑块头）就当作没动过 ——
        // 没必要为一次「原地踏步」把菜单收起来再弹回去
        if let d = DisplayManager.shared.displays().first(where: { $0.id == id }),
           isCurrent(d, mode) {
            return
        }

        isRepaging = true
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if !DisplayManager.shared.setMode(id, mode) { NSSound.beep() }
            self.reopenMenu()
        }
    }

    /// 这一档是不是这块屏现在正在用的那一档。
    /// 必须同时比对「逻辑尺寸 + 渲染倍率」，否则 HiDPI 和非 HiDPI 会认成同一档。
    private func isCurrent(_ d: DisplayItem, _ m: CGDisplayMode) -> Bool {
        m.width == d.logicalWidth && m.height == d.logicalHeight
            && (m.pixelWidth > m.width) == DisplayManager.shared.isHiDPI(d)
    }

    /// 把一条「已关闭」记录丢掉（显示器早就拔线了，不可能再回来）
    @objc func forgetDisplay(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        DisplayManager.shared.forgetDisabled(CGDirectDisplayID(n.uint32Value))
        settingsDisplayID = nil
    }

    @objc func selectMode(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ModeRef else { return }
        if !DisplayManager.shared.setMode(ref.display, ref.mode) { NSSound.beep() }
    }

    @objc func reprobeDDC(_ sender: NSMenuItem) {
        DisplayManager.shared.forceReprobeDDC()
    }

    @objc func toggleAllResolutions(_ sender: NSMenuItem) {
        DisplayManager.shared.showAllResolutions.toggle()
        // 列表本身已经建好，就地改不划算 —— 收起菜单，下次打开就是新的列表
        sender.menu?.cancelTracking()
    }

    @objc func doRefresh() {
        // 用户主动要求重扫 —— 顺带解除 DDC 冷却并重建句柄
        DisplayManager.shared.forceReprobeDDC()
    }

    /// 切换「外接屏亮度跟随环境光」。
    @objc func toggleAutoBrightness(_ sender: NSMenuItem) {
        let mgr = DisplayManager.shared
        mgr.setAutoBrightnessExternals(!mgr.autoBrightnessExternals)
        sender.menu?.cancelTracking()
    }

    /// 切换「有外接屏时自动关闭内置屏」。
    /// 打开时立刻按当前情况办一次：拨开开关的这一刻，外接屏可能早就接着了。
    @objc func toggleAutoBuiltin(_ sender: NSMenuItem) {
        let mgr = DisplayManager.shared
        mgr.autoDisableBuiltinWhenExternal.toggle()

        // 先收菜单：紧接着要等系统改显示配置，菜单挂在那儿会显得卡住
        sender.menu?.cancelTracking()

        if mgr.autoDisableBuiltinWhenExternal {
            // 与「环境光自动亮度」互斥：关内屏会让环境光读数消失，两个不能同时开
            if mgr.autoBrightnessExternals {
                mgr.setAutoBrightnessExternals(false)
                mgr.ruleLog("自动关内屏：与「环境光自动亮度」互斥，后者已自动关闭")
            }
            // 保险起见再调一次：万一启动时还认不出内屏（没有任何 id 记录），
            // 那会儿巡检没跑起来；现在可能已经认出来了。
            mgr.startSafetyMonitor()
            mgr.applyAutoBuiltinRule(force: true, source: "开关打开")
        } else {
            // 关掉开关**不停巡检**：巡检只管「一块能看的屏都没有」这个故障态，
            // 和这个偏好无关。关掉开关的人照样可能黑屏（内屏是外接屏插着的时候
            // 手动关的），停了巡检就等于把那类人交给黑屏。
            mgr.ruleLog("开关关闭（不再主动关内屏；黑屏救援照旧生效）")
        }
    }

    /// 切换「用键盘 F1 / F2 调亮度」。
    ///
    /// 打开时如果还没有辅助功能权限，**就地去要**：弹系统授权对话框 +
    /// 打开系统设置的辅助功能页。两件都做是有意的 —— 对话框可能已经被
    /// 用户点掉过一次（系统不一定再弹），而设置页永远能打开。
    /// 反过来，启动时一声不吭地弹权限窗才是讨厌的做法。
    @objc func toggleBrightnessKeys(_ sender: NSMenuItem) {
        let mgr = DisplayManager.shared

        // ⚠️ 「开着但这功能还没真正生效」时，这一下点击的语义是**让它生效**，
        // 而不是把开关关掉。这个开关默认就是开的，按普通「翻转」逻辑，
        // 用户第一次点击会把它关掉 —— 而那一行的文案恰好写着「点这里授权」/
        // 「点这里重试」。点了没反应、功能还关了，是最容易让人以为
        // 「这功能是坏的」的一种组合。
        //
        // 两种「没生效」分开处理：
        //   · 没授权     → 弹系统授权框 + 打开设置页；60 秒内再点就放行（见下）
        //   · 授权了但监听没装上 → 就地重试，不翻转（用户该做的都做了）
        if mgr.brightnessKeysEnabled, !BrightnessKeyMonitor.shared.isRunning {
            if BrightnessKeyMonitor.isTrusted {
                sender.menu?.cancelTracking()
                // 看门狗主动退出过接管（判据是会危害键盘）。这一下点击的语义是
                // 「再来一次」，所以要先把它的判决清掉 —— 否则刚起就被判回去。
                BrightnessKeyMonitor.shared.resetAutoStop()
                if let err = mgr.applyBrightnessKeysSetting() {
                    mgr.ruleLog("亮度键：已授权但仍未接管 —— \(err)")
                }
                return
            }
            // 只劫持第一下：不然想关掉这个功能的人会永远卡在「去授权」上。
            // 60 秒内再点一次，就意味着用户已经去过设置页回来了，
            // 这时允许按普通翻转走 —— 把「关掉」这条路留出来。
            if !didJustPromptForKeyTrust() {
                sender.menu?.cancelTracking()
                BrightnessKeyMonitor.promptForTrust()
                BrightnessKeyMonitor.openAccessibilitySettings()
                mgr.ruleLog("亮度键：已请求辅助功能权限（授权后自动接管，不用重开应用）")
                return
            }
        }

        let turningOn = !mgr.brightnessKeysEnabled
        mgr.brightnessKeysEnabled = turningOn
        sender.menu?.cancelTracking()      // 接着可能弹系统窗口，菜单先收起来
        if turningOn { BrightnessKeyMonitor.shared.resetAutoStop() }
        mgr.applyBrightnessKeysSetting()
        if turningOn { mgr.startBrightnessKeyWatcher() }   // 幂等，确保轮询在跑
    }

    /// 切换「接管标准功能键 F1 / F2」。
    ///
    /// 和主开关不同，这一项**不做任何权限引导、不劫持第一次点击** ——
    /// 它纯粹是「要不要响应普通按键里的 F1/F2」的取舍，点了就翻，所见即所得。
    /// （主开关那套两步语义是为了解决「授权动作在别的进程里、我们不知道」，
    /// 这里不存在那个问题。）
    ///
    /// ⚠️ 这一项**不会吞掉任何按键**。早期版本用活动型 tap 接管 keyDown，
    /// 代价是一个卡住的事件回调能把整个键盘扣住（2026-09-27「外接键盘打不了字」）。
    /// 现在走只读通道（`.listenOnly`），按 API 契约就改不了事件 ——
    /// 普通 F1/F2 照旧会被别的应用收到。
    @objc func toggleBrightnessKeysFunctionRow(_ sender: NSMenuItem) {
        let mgr = DisplayManager.shared
        let turningOn = !mgr.brightnessKeysFunctionRow
        mgr.brightnessKeysFunctionRow = turningOn
        // 立刻推给监听：正跑着的话它就是下一毫秒起生效，不用重开应用
        mgr.applyBrightnessKeysSetting(log: false)
        mgr.ruleLog("亮度键：标准功能键 F1 / F2 \(turningOn ? "已纳入响应" : "已不再响应")"
                    + (turningOn ? "（只读监听：不影响打字，也不阻止别的应用收到）"
                                 : "（媒体键通道照旧工作）"))
        sender.menu?.cancelTracking()      // 让开关状态立刻重画
    }

    /// 刚刚请求过授权吗（60 秒内算）—— 见上面那段两步语义
    private func didJustPromptForKeyTrust() -> Bool {
        if let t = lastKeyTrustPromptAt, Date().timeIntervalSince(t) < 60 { return true }
        lastKeyTrustPromptAt = Date()
        return false
    }

    @objc func showAbout() {
        // NSApp.activate() 是 macOS 14 才有的；老系统走带参数的老接口（ Intel 老机型兼容）
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        let credits = NSMutableAttributedString(
            string: AppInfo.isBeta ? "开源显示器控制工具 · Beta 测试阶段\n" : "开源显示器控制工具\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )
        credits.append(NSAttributedString(
            string: AppInfo.repoURL,
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .link: URL(string: AppInfo.repoURL)!]
        ))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.displayName,
            .applicationVersion: AppInfo.displayVersion,
            .version: "",
            .credits: credits
        ])
    }

    @objc func openRepo() {
        guard let url = URL(string: AppInfo.repoURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
