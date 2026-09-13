# Display Master

A tiny macOS menu bar app that controls your displays: **turn individual displays on/off, set brightness, toggle HiDPI, and switch resolutions** — all from one menu, no Dock icon.

<p align="center">
  <img src="docs/icon.png" width="160" alt="Display Master icon">
</p>

[中文说明 →](README.zh-CN.md)

---

## Why

macOS gives you one "Displays" pane for everything. It can't power down a single monitor, can't reach a monitor's brightness over DDC, and buries HiDPI modes inside a long resolution list. Display Master puts all of that two clicks away in the menu bar.

It was written as a free replacement for BetterDisplay's Pro-only *display connection* feature, then grew into a general-purpose display controller.

## Features

| Feature | Notes |
|---|---|
| **Per-display on/off** | Really removes the display from the layout (windows reflow), not just a black overlay. Closed displays stay listed at the bottom of the menu so you can bring them back. |
| **Brightness** | The slider sits **directly in the top-level menu** under each display — no submenu to open. Built-in panels go through `DisplayServices`; external monitors go through DDC/CI over I²C. |
| **HiDPI toggle** | Flips the render scale at the same logical resolution (`2560×1440 HiDPI ⇄ 2560×1440`). If the panel has no same-size counterpart (typical for built-in Retina displays), it falls back to the nearest resolution and says so in the menu title. |
| **Resolution switching** | A curated list of common modes (HiDPI variants marked), plus a *Show all resolutions* toggle for the full list an EDID may expose. |
| **DDC diagnostics** | `--ddc-test` / `--ddc-storm` exercise the DDC channel end-to-end; the menu shows a plain-language reason when brightness can't be controlled. |

Everything is plain Swift + AppKit. No third-party dependencies, no kernel extension, no entitlements, no network access.

## Requirements

- macOS 14 or later
- Apple Silicon or Intel
- Built and verified on macOS 26.6 (Tahoe), Apple Silicon

## Build & install

```bash
git clone https://github.com/906351854/DisplayMaster.git
cd DisplayMaster
./build.sh
```

`build.sh` compiles a release binary, assembles the `.app` bundle, ad-hoc signs it, installs it to `/Applications`, and restarts the running instance. Add `--no-install` to only build into `build/`.

The app lives in the menu bar only — there is no Dock icon and no window.

### Icons

`Resources/AppIcon.icns` and the menu bar glyphs are committed, so a build works out of the box. To regenerate them from `Resources/Logo.jpg`:

```bash
swift Tools/make-icons.swift .
```

That produces a squircle-masked app icon (full `.iconset`) plus 18/36/54 px single-colour menu bar glyphs. Replace `Resources/Logo.jpg` with your own square artwork and re-run.

## Repository layout

```
Sources/DisplayMaster/
  main.swift          入口 + 命令行诊断模式（--selftest / --ddc-test / --hidpi-test / --dump-menu）
  AppDelegate.swift   菜单栏图标与菜单构建
  DisplayManager.swift显示器枚举、开关、分辨率、HiDPI 判定、亮度节流
  DDC.swift           外接屏 DDC/CI 通道（IOAVService），含时序、重试与冷却
  PrivateAPI.swift    私有符号的运行时加载
  AppInfo.swift       名称 / 版本 / 仓库地址（版本号同时被 build.sh 读取）
Tools/
  make-icons.swift    从 Resources/Logo.jpg 生成应用图标与菜单栏图标
  probe/              独立的私有 API 探测脚本，用来确认某台机器上这些符号还在
Resources/            logo、生成好的 .icns 与菜单栏图标
```

## Command line

The binary doubles as a diagnostic tool. Handy because the GUI can't be scripted:

```bash
APP="/Applications/Display Master.app/Contents/MacOS/DisplayMaster"

"$APP" --selftest                    # private API availability, displays, modes, brightness
"$APP" --dump-menu                   # print the whole menu tree without opening it
"$APP" --hidpi-test                  # report what a HiDPI toggle would do (read-only)
"$APP" --hidpi-test --apply --all    # actually toggle every display, then restore
"$APP" --ddc-test                    # read → write → re-read → restore, proves DDC writes work
"$APP" --ddc-storm                   # simulate slider dragging: 100 rapid calls, checks throttling
```

## How it works

Three private-API paths, all loaded at runtime with `dlopen`/`dlsym` so nothing private is linked at build time:

| Capability | API | Framework |
|---|---|---|
| Enable/disable a display | `CGSConfigureDisplayEnabled` wrapped in a `CGBeginDisplayConfiguration` → `CGCompleteDisplayConfiguration` transaction | `SkyLight` |
| Built-in brightness | `DisplayServicesGetBrightness` / `SetBrightness` / `CanChangeBrightness` | `DisplayServices` |
| External brightness | `IOAVServiceCreateWithService` + `WriteI2C` / `ReadI2C`, DDC/CI VCP `0x10` | `IOKit` |
| Full mode list | `CGDisplayCopyAllDisplayModes` with `kCGDisplayShowDuplicateLowResolutionModes` | `CoreGraphics` |

Two things worth knowing if you touch this code:

1. **`CGSConfigureDisplayEnabled` takes a `CGDisplayConfigRef`, not a connection ID.** Passing `CGSMainConnectionID()` there segfaults inside `SLSConfigureDisplayEnabled`. It must be used inside the public configuration transaction.
2. **`CGDisplayCopyAllDisplayModes` without `kCGDisplayShowDuplicateLowResolutionModes` hides HiDPI modes.** On a built-in Retina display you get three legacy scaled modes and not even the mode that is currently active.

## Caveats

- **Private API, not App Store distributable.** Apple can change or remove these symbols in any release. `--selftest` tells you whether they still resolve.
- **Ad-hoc signed.** `spctl -a -vv` reports `rejected` — that's expected for a self-built app without a Developer ID. It runs fine because a locally built copy has no quarantine attribute. Gatekeeper will complain if you move the `.app` to another Mac; right-click → Open, or `xattr -cr`.
- **Disabling a display is session-scoped.** It does not survive a display sleep or a reboot — everything comes back. That's a safety net, not a bug. The app remembers which displays you closed (in `UserDefaults`) so the menu can offer to reopen them.
- **DDC can get stuck.** A chattering DDC channel makes some monitors stop answering until they are power-cycled. The app throttles writes (100 ms) and reads (2 s) for exactly this reason; if brightness stops responding, power-cycle the monitor from the wall, or toggle the display off/on once (`CGSConfigureDisplayEnabled`) which re-trains the link.
- **One external display mapping is positional.** With a single external monitor the DDC service index maps 1:1 by display ID. With two or more external monitors of the same model, pairing should be done by EDID; that's not implemented yet.

## Related

- [BetterDisplay](https://github.com/waydabber/BetterDisplay) — far more capable, and where the Pro/paid line is drawn at display connections
- [MonitorControl](https://github.com/MonitorControl/MonitorControl) — the DDC timing in `DDC.swift` follows its `Arm64DDC` implementation
- [ddcctl](https://github.com/kfix/ddcctl) — useful reference for DDC/CI packet formats

## License

MIT — see [LICENSE](LICENSE).
