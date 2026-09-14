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
| **单独开关显示器** | 真的把显示器从桌面布局里移除（窗口会重排），不是盖一层黑。被关掉的显示器会留在菜单底部，点一下就能开回来。 |
| **亮度** | 滑块**直接放在一级菜单**里每台显示器标题的下方，不用展开二级菜单。内置屏走 `DisplayServices`，外接屏走 I²C 上的 DDC/CI。 |
| **HiDPI 开关** | 在**同一逻辑分辨率**上切换渲染倍率（`2560×1440 HiDPI ⇄ 2560×1440`）。若面板没有同尺寸的变体（内置 Retina 屏就是如此），会退一步切到最接近的分辨率，并在菜单标题里写清楚要切到哪一档。 |
| **分辨率切换** | 默认只列常见档位（HiDPI 会标注），另有「显示所有分辨率」开关可以展开 EDID 里的完整列表。 |
| **DDC 诊断** | `--ddc-test` / `--ddc-storm` 会端到端验证 DDC 通道；亮度不可控时菜单里会用人话写明原因。 |

纯 Swift + AppKit。没有第三方依赖，不装内核扩展，不需要任何 entitlement，不联网。

## 环境要求

- macOS 14 或更高
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
  main.swift           入口 + 命令行诊断模式（--selftest / --ddc-test / --hidpi-test / --dump-menu）
  AppDelegate.swift    菜单栏图标与菜单构建
  DisplayManager.swift 显示器枚举、开关、分辨率、HiDPI 判定、亮度节流
  DDC.swift            外接屏 DDC/CI 通道（IOAVService），含时序、重试与冷却
  PrivateAPI.swift     私有符号的运行时加载
  AppInfo.swift        名称 / 版本 / 仓库地址（版本号同时被 build.sh 读取）
Tools/
  make-icons.swift     从 Resources/Logo.jpg 生成应用图标与菜单栏图标
  make-dmg.sh          把 .app 打成 DMG 安装包（拖拽安装布局 + 背景图 + 卷图标）
  make-dmg-background.swift  生成 DMG 窗口的背景图
  make-dsstore.py      直接写出 .DS_Store，设定 DMG 窗口尺寸/图标位置/背景（不需要 Finder 授权）
  probe/               独立的私有 API 探测脚本，用来确认某台机器上这些符号还在不在
Resources/             logo、生成好的 .icns 与菜单栏图标
docs/                  官网站点与文档（GitHub Pages 直接托管这个目录）
DEPLOY.md              官网部署指南：换平台、换域名、排查都看这份
```

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
- **关闭显示器是会话级的。** 显示睡眠或重启之后一切都会回来。这是安全网不是 bug。app 会在 `UserDefaults` 里记住你关过哪些屏，以便菜单里提供重新打开的入口。
- **DDC 通道可能被写死。** 密集的 DDC 事务会让部分显示器停止应答，直到断电重启。app 因此对写入做了 100ms、读取做了 2s 的节流；如果亮度突然不响应，把显示器**电源**断一下（不是视频线），或者对这块屏做一次「关闭 → 打开」，等效于一次链路重训练。
- **外接屏的映射目前是按位置的。** 只有一台外接屏时 DDC 服务序号与显示器 ID 一一对应；接两台同型号外接屏时应该按 EDID 配对，这部分还没做。
- **Intel 机器上外接屏亮度不可用。** 该功能依赖只存在于 Apple Silicon 的 `IOAVService` 私有框架，Intel 需要另一套 `IOI2CInterface`，本项目没有实现，所以那台屏的亮度位置会显示「亮度不可控」。其余功能（开关显示器、分辨率、HiDPI、内置屏亮度）不受影响。Intel 路径未经实机测试。

## 相关项目

- [BetterDisplay](https://github.com/waydabber/BetterDisplay) —— 功能强大得多，也正是它把「显示器连接」划到了付费 Pro 里
- [MonitorControl](https://github.com/MonitorControl/MonitorControl) —— `DDC.swift` 里的时序参数参考了它的 `Arm64DDC` 实现
- [ddcctl](https://github.com/kfix/ddcctl) —— DDC/CI 报文格式的好参考

## 许可证

MIT，见 [LICENSE](LICENSE)。
