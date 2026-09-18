# Display Master

一个极小的 macOS 菜单栏工具，用来管理显示器：**单独开关某台显示器、调节亮度、切换 HiDPI、切换分辨率** —— 全在一个菜单里，没有 Dock 图标。

<p align="center">
  <img src="docs/icon.png" width="160" alt="Display Master 图标">
</p>

<p align="center">
  <a href="https://github.com/906351854/DisplayMaster/releases/latest"><b>下载</b></a>
  &nbsp;·&nbsp;
  <a href="https://906351854.github.io/DisplayMaster/"><b>官网与文档</b></a>
  &nbsp;·&nbsp;
  <a href="README.md">English</a>
</p>

---

## 为什么做这个

macOS 的「显示器」设置面板管不了一些很实际的事：不能单独关掉某一台显示器、够不到外接屏的 DDC 亮度、HiDPI 模式藏在一长串分辨率列表里。Display Master 把这些都挪到菜单栏，两下点完。

它最初是为了替代 BetterDisplay 需要付费 Pro 才能用的「断开显示器」功能，后来长成了一个通用的显示器控制器。

## 功能

| 功能 | 说明 |
|---|---|
| **单独开关显示器** | 把显示器真正从桌面布局里摘掉，窗口会重排到剩下的屏上。**被关掉的显示器不离开那一排卡片** —— 它照旧占一张卡，只是整张变灰、「开启」落在关的位置上，拨回去就亮。 |
| **有外接屏时自动关内屏** | 卡片下方那一排里的开关。接上外接显示器就关掉笔记本内屏，拔掉再自动开回来。只在这两个瞬间动手，不会抢你手动开回来的操作。**拔线必亮是硬承诺**：就算把开关关掉、就算关闭记录丢了，只要外接屏一个不剩而内屏不在线，每 10 秒的巡检也会把它救回来（合盖状态除外，不会打扰睡眠）。 |
| **亮度** | 一台屏一条滑块，**就在它自己的卡片上**，打开菜单直接拖，不用展开。内置屏走 `DisplayServices`，外接屏走 I²C 上的 DDC/CI。 |
| **HiDPI 开关** | 在卡片**右上角**，正对着「开启」下面那一枚。当前跑在哪种倍率看分辨率那一行右端 —— 是 HiDPI 档位时，数字后面会跟一枚 `HiDPI` 小标签。优先在**同一逻辑分辨率**上换渲染倍率（`2560×1440 HiDPI ⇄ 2560×1440`）；面板没有同尺寸变体时开关会灰掉，去详情页的「全部分辨率」里精确挑一档更稳。 |
| **分辨率滑块** | 卡片上的第二条滑块，**和亮度滑块左端严格对齐**。轨道上的格子点就是筛选后的档位（只留和面板原生比例一致的，同一逻辑宽度优先 HiDPI 那版），右端跟着当前分辨率。拖动时只改数字，**松手才真的切**。偏门档位（会改变长宽比的那些）走详情页的「全部分辨率」。 |
| **DDC 诊断** | `--ddc-test` / `--ddc-storm` 会端到端验证 DDC 通道；亮度不可控时卡片上会就地写明原因，全文在详情页。 |

纯 Swift + AppKit。没有第三方依赖，不装内核扩展，不需要任何 entitlement，不联网。

## 环境要求

- macOS 13 或更高
- Apple Silicon / Intel 均可运行（发布的是通用二进制）
- 开发与验证环境：macOS 26.6 (Tahoe) + Apple Silicon

> **Intel Mac 上外接屏亮度不可用。** 外接屏亮度走 `IOAVService` 私有框架，它只存在于 Apple Silicon；
> Intel 需要另一套 `IOI2CInterface`，本项目没有实现。其余功能（开关显示器、分辨率、HiDPI、内置屏亮度）都正常。
> Intel 路径没有实机测试过，遇到问题欢迎开 issue。

## 下载

到 [Releases](https://github.com/906351854/DisplayMaster/releases/latest) 下载：

- **`DisplayMaster-<版本>.dmg`**（推荐）— 双击挂载，把窗口左边的 `Display Master.app` 拖到右边的「应用程序」上就装好了，再推出磁盘。
- **`DisplayMaster-<版本>.zip`** — 不想挂载磁盘映像时用。请用系统自带的「归档实用工具」解压，别用会丢元数据的第三方工具。

首次打开会被 Gatekeeper 拦一次（本项目没有 Apple 开发者签名）：右键点 App → 选「打开」→ 再点一次「打开」即可。
完整步骤（含命令行做法）见[安装说明](https://906351854.github.io/DisplayMaster/install.html)。

## 构建与安装

```bash
git clone https://github.com/906351854/DisplayMaster.git
cd DisplayMaster
./build.sh
```

`build.sh` 会编译通用二进制（arm64 + x86_64）、组装 `.app`、做 ad-hoc 签名、安装到 `/Applications`，并重启正在运行的实例。

- `--no-install` 只构建到 `build/`，不动 `/Applications`
- `--native` 只编当前架构，日常改代码时快很多
- `--dmg` 构建完顺便打出 `build/DisplayMaster-<版本>.dmg`（可与上面两个组合）
  DMG 的窗口布局由 `Tools/make-dsstore.py` 生成，需要 `pip install ds_store mac_alias`；
  没装会自动退回用 AppleScript 驱动 Finder，再不行就出一个窗口样式朴素但可用的 DMG。

应用只活在菜单栏里 —— 没有 Dock 图标，也没有窗口。

### 图标

`Resources/AppIcon.icns` 和菜单栏图标都已提交进仓库，直接构建即可用。要从 `Resources/Logo.jpg` 重新生成：

```bash
swift Tools/make-icons.swift .
```

会产出带圆角遮罩的完整应用图标（整个 `.iconset`），以及 18/36/54 px 的单色菜单栏字形。把你的方形素材覆盖到 `Resources/Logo.jpg` 再跑一次就行。

## 仓库结构

```
Sources/DisplayMaster/
  main.swift           入口：先看是不是命令行诊断，否则启动菜单栏应用
  Support/
    AppInfo.swift      名称 / 版本 / 仓库地址（版本号同时被 build.sh 读取）
    DynamicSymbol.swift 运行时 dlopen/dlsym 加载，两个私有 API 封装共用
    Defaults.swift     所有 UserDefaults 键集中于此（键值一律不可改）
  Core/
    PrivateAPI.swift   显示开关与内置屏亮度用的私有符号
    DDC.swift          外接屏 DDC/CI 通道（IOAVService），含时序、重试与冷却
    DisplayManager/    显示器状态，按职责拆开
      DisplayManager.swift            存储状态 + 生命周期入口
      DisplayManager+Enumeration.swift 显示器枚举、虚拟屏/占位屏判定、分辨率档位表
      DisplayManager+Disabled.swift    本应用关闭过的记录与对账
      DisplayManager+Power.swift       开关屏、显示器睡眠、合盖、显示配置提交
      DisplayManager+AutoRule.swift    自动关内屏规则，含重试与巡检兜底
      DisplayManager+Brightness.swift  亮度读写与写入节流
      DisplayManager+Modes.swift       分辨率切换与 HiDPI
      DisplayManager+Logging.swift     规则日志落盘
  Diagnostics/         二进制的命令行诊断模式，按命令分组各占一个文件
    Dispatcher.swift   按顺序分发（顺序决定多条 flag 同时出现时谁生效）
    Support.swift      共用的打印/解析工具
    SelfTest.swift     自检：私有 API、显示器、分辨率、亮度
    DisplayCommands.swift  档位 / HiDPI / 开关屏 / 回归测试
    DDCCommands.swift  DDC 端到端、压力、唤醒、自愈测试
    AutoRuleCommands.swift 自动规则诊断、运行日志、构造场景
    UICaptureCommands.swift 菜单结构、命中点、菜单截图
  UI/
    AppDelegate.swift  菜单栏图标、系统通知、菜单生命周期
    AppDelegate+Menu.swift     菜单构建与卡片模型
    AppDelegate+Actions.swift  菜单动作：开关、分辨率、HiDPI、关于
    AppDelegate+Debug.swift    供诊断命令驱动的自测钩子
    CardsRowView.swift 显示器卡片：两条滑块、两枚开关、悬停与命中判定
    MenuRows.swift     其余自绘行：自动关内屏开关行、返回行、详情页横幅
    PanelStyle.swift   面板尺寸与配色常量
    PanelDrawing.swift 绘制原语：图标、文字、胶囊、开关、缩略图
    PanelSlider.swift  亮度与分辨率共用的自绘滑块
    ModeRef.swift      把「显示器 + 目标模式」打包进菜单项
Tools/
  make-icons.swift     从 Resources/Logo.jpg 生成应用图标与菜单栏图标
  make-dmg.sh          把 .app 打成 DMG 安装包（拖拽安装布局 + 背景图 + 卷图标）
  make-dmg-background.swift  生成 DMG 窗口的背景图
  make-dsstore.py      直接写出 .DS_Store，设定 DMG 窗口尺寸/图标位置/背景（不需要 Finder 授权）
  gen-changelog.py     从 CHANGELOG.md 重新生成官网首页的「版本更新」列表
  probe/               独立的私有 API 探测脚本，用来确认某台机器上这些符号还在不在
Resources/             logo、生成好的 .icns 与菜单栏图标
docs/                  官网站点与文档（GitHub Pages 直接托管这个目录）
DEPLOY.md              官网部署指南：换平台、换域名、排查都看这份
```

`DisplayManager` 与 `AppDelegate` 的类体拆在多个 extension 文件里。Swift 的 `private` 只到
文件级，所以跨文件用到的成员是 `internal`；存储属性则必须留在类体里（extension 不能新增
存储属性）。这两点在 core 文件开头都写明了。

## 命令行

这个二进制同时是个诊断工具（GUI 不好脚本化，所以把验证都做成了命令行）：

```bash
APP="/Applications/Display Master.app/Contents/MacOS/DisplayMaster"

"$APP" --selftest                    # 私有 API 可用性、显示器、模式、亮度
"$APP" --dump-menu                   # 不开菜单，直接把整棵菜单树打印出来
"$APP" --hidpi-test                  # 只报告 HiDPI 开关会切到哪（不改动）
"$APP" --hidpi-test --apply --all    # 真的切一遍每台屏，然后恢复
"$APP" --ddc-test                    # 读 → 写 → 复读 → 恢复，证明 DDC 写入真的生效
"$APP" --ddc-storm                   # 模拟拖滑块：100 次高频调用，验证节流有效
"$APP" --toggle-test                 # 关一台屏 → 再打开，验证「已关闭」记录被正确清掉
"$APP" --ddc-recover-test            # 伪造 DDC 通道哑掉，验证自愈逻辑能救回来
"$APP" --wake-test                   # 让屏幕睡一下再唤醒，验证唤醒后通道仍可用
"$APP" --auto-test                   # 报告自动关内屏这一轮会做什么判断（加 --apply 才执行）
"$APP" --auto-scenarios              # 跑判定逻辑的场景自测，不接触真实显示器
"$APP" --shot-menu /tmp/m.png         # 弹出真实菜单并截图
"$APP" --shot-menu /tmp/m.png --fake-cards 3 --fake-off 2   # 伪造 3 张卡，把第 2 张画成已关闭
"$APP" --shot-menu /tmp/m.png --click-card 0 --click-part hidpi  # 模拟点卡片上的某个部位（on / hidpi / body）
"$APP" --shot-menu /tmp/m.png --fake-bright 58                   # 把亮度冻结成 58% 再画，核对滑块右端
"$APP" --hits                        # 打印每张卡里「开启 / HiDPI / 卡片主体」的屏幕坐标
"$APP" --modes                       # 打印每块屏在分辨率滑块里会出现的档位（筛选后）
"$APP" --drag-res 0 3                # 模拟把第 0 张卡的分辨率滑块拖到第 3 档并松手
"$APP" --display-off 2               # 直接关一台屏（记录丢了时用这条把它开回来）
"$APP" --display-on 2
"$APP" --hidpi-toggle 2              # 报告并真的切一次 HiDPI
```

## 实现要点

三条私有 API 路径，全部用 `dlopen`/`dlsym` 在运行时加载，构建时**不链接任何私有框架**：

| 能力 | API | 框架 |
|---|---|---|
| 开关显示器 | `CGSConfigureDisplayEnabled`，必须包在 `CGBeginDisplayConfiguration` → `CGCompleteDisplayConfiguration` 事务里 | `SkyLight` |
| 内置屏亮度 | `DisplayServicesGetBrightness` / `SetBrightness` / `CanChangeBrightness` | `DisplayServices` |
| 外接屏亮度 | `IOAVServiceCreateWithService` + `WriteI2C` / `ReadI2C`，DDC/CI VCP `0x10` | `IOKit` |
| 完整模式列表 | `CGDisplayCopyAllDisplayModes` + `kCGDisplayShowDuplicateLowResolutionModes` | `CoreGraphics` |

改这份代码前值得知道的两件事：

1. **`CGSConfigureDisplayEnabled` 的第一个参数是 `CGDisplayConfigRef`，不是连接 ID。** 传 `CGSMainConnectionID()` 会直接崩在 `SLSConfigureDisplayEnabled` 里。必须用公开的配置事务把它包起来。
2. **`CGDisplayCopyAllDisplayModes` 不给 `kCGDisplayShowDuplicateLowResolutionModes` 就看不到 HiDPI 模式。** 在内置 Retina 屏上只会返回 3 个老式缩放模式，连当前正在用的那个模式都不在里面。

## 已知限制

- **用了私有 API，不能上架 App Store。** Apple 可能在任何版本改掉或删掉这些符号，`--selftest` 能告诉你它们还在不在。
- **ad-hoc 签名。** `spctl -a -vv` 会报 `rejected` —— 这是自建应用的正常现象（没有 Developer ID）。本地构建没有 quarantine 属性，能直接跑。把 `.app` 拷到别的 Mac 时 Gatekeeper 会拦，右键 → 打开，或 `xattr -cr`。
- **关闭显示器是会话级的。** 显示睡眠或重启之后一切都会回来。这是安全网不是 bug。app 会在 `UserDefaults` 里记住你关过哪些屏 —— 关掉那一刻的分辨率、刷新率、亮度、HiDPI 也一起抄下来 —— 所以那张灰掉的卡片不会留一片空白，拨回「开启」就能开回来。
- **DDC 通道可能被写死。** 密集的 DDC 事务会让部分显示器停止应答，直到断电重启。app 因此对写入做了 100ms、读取做了 2s 的节流；如果亮度突然不响应，把显示器**电源**断一下（不是视频线），或者对这块屏做一次「关闭 → 打开」，等效于一次链路重训练。
- **外接屏的映射目前是按位置的。** 只有一台外接屏时 DDC 服务序号与显示器 ID 一一对应；接两台同型号外接屏时应该按 EDID 配对，这部分还没做。
- **Intel 机器上外接屏亮度不可用。** 该功能依赖只存在于 Apple Silicon 的 `IOAVService` 私有框架，Intel 需要另一套 `IOI2CInterface`，本项目没有实现，所以那台屏的亮度位置会显示「亮度不可控」。其余功能（开关显示器、分辨率、HiDPI、内置屏亮度）不受影响。Intel 路径未经实机测试。

## 相关项目

- [BetterDisplay](https://github.com/waydabber/BetterDisplay) —— 功能强大得多，也正是它把「显示器连接」划到了付费 Pro 里
- [MonitorControl](https://github.com/MonitorControl/MonitorControl) —— `Core/DDC.swift` 里的时序参数参考了它的 `Arm64DDC` 实现
- [ddcctl](https://github.com/kfix/ddcctl) —— DDC/CI 报文格式的好参考

## 许可证

MIT，见 [LICENSE](LICENSE)。
