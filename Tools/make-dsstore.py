#!/usr/bin/env python3
"""给 DMG 卷写入 .DS_Store，设定安装窗口的样子。

为什么要自己生成：
    Finder 的窗口布局（尺寸、图标位置、背景图）只存在 .DS_Store 里，而这个文件
    正常只能由 Finder 自己写出来 —— 也就是要用 AppleScript 去驱动 Finder，
    那需要「自动化」权限（系统设置 → 隐私与安全性 → 自动化 → 勾选 Finder）。
    对开源项目来说这太脆了：别人 clone 下来跑打包脚本，要么弹权限框，要么直接失败。

    .DS_Store 的格式是公开的（Bud1 容器 + 若干记录），背景图那一项存的是
    「别名」（alias）二进制块 —— 由 mac_alias 生成，和 Finder 自己写的格式一致。
    所以这里直接拼出来，零权限、可重复。

依赖（两个小包，只在打 DMG 时需要）：
    pip install ds_store mac_alias

用法见 --help。
"""

import argparse
import os
import sys

try:
    from ds_store import DSStore
    from mac_alias import Alias
except ImportError:
    sys.stderr.write(
        "缺少依赖。请先安装：\n"
        "    pip install ds_store mac_alias\n"
        "（只在生成 DMG 时需要；不装的话 make-dmg.sh 会退回到 Finder 脚本方式）\n"
    )
    sys.exit(2)


def pair(text):
    """解析 '165,210' 这种坐标"""
    parts = text.split(",")
    if len(parts) != 2:
        raise argparse.ArgumentTypeError("坐标格式应为 x,y")
    return (int(parts[0]), int(parts[1]))


def bounds(text):
    """解析 '240,160,660,442' → (left, top, width, height)"""
    parts = [int(v) for v in text.split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("窗口应为 左,上,宽,高")
    return tuple(parts)


def main():
    ap = argparse.ArgumentParser(description="为 DMG 卷生成 .DS_Store 布局")
    ap.add_argument("--volume", required=True, help="已挂载的卷路径，例如 /Volumes/Display Master")
    ap.add_argument("--app", required=True, help="应用包名，例如 'Display Master.app'")
    ap.add_argument("--background", help="背景图在卷内的相对路径，例如 .background/dmg-background.tiff")
    ap.add_argument("--window-bounds", type=bounds, default=(240, 160, 660, 442),
                    help="窗口位置与尺寸 左,上,宽,高（默认 240,160,660,442）")
    ap.add_argument("--app-pos", type=pair, default=(165, 210), help="应用图标位置 x,y")
    ap.add_argument("--apps-pos", type=pair, default=(495, 210), help="Applications 图标位置 x,y")
    ap.add_argument("--icon-size", type=float, default=128.0)
    ap.add_argument("--text-size", type=float, default=12.0)
    args = ap.parse_args()

    vol = os.path.abspath(args.volume)
    if not os.path.isdir(vol):
        sys.stderr.write("卷不存在：%s\n" % vol)
        return 1

    app_path = os.path.join(vol, args.app)
    if not os.path.exists(app_path):
        sys.stderr.write("应用不存在：%s\n" % app_path)
        return 1

    left, top, width, height = args.window_bounds

    # ---- 背景图的书签 ----
    # 必须指向「当前挂载的这个卷」里的文件，Finder 才能解析出来。
    # 所以要先把 DMG 挂上再跑这个脚本，不能在生成镜像之前做。
    #
    # 用 Alias 而不是 Bookmark：这个坑很隐蔽。两种都是「文件的引用」，但二进制格式不同
    # —— Alias 以 \x00\x00\x00\x00 开头，Bookmark 以 "book" 魔数开头。
    # Finder 只认前者，喂给它 Bookmark 会静默忽略，表现为「窗口尺寸和图标位置都对，
    # 就是背景图不显示」。对照过真实发行版 DMG 里的 .DS_Store 才定位到这点。
    bg_alias = None
    if args.background:
        bg_path = os.path.join(vol, args.background)
        if os.path.exists(bg_path):
            bg_alias = Alias.for_file(bg_path).to_bytes()
        else:
            sys.stderr.write("警告：背景图不存在，跳过（%s）\n" % bg_path)

    # ---- 图标视图设置（icvp）----
    icvp = {
        "viewOptionsVersion": 1,
        "showIconPreview": True,
        "showItemInfo": False,
        "labelOnBottom": True,
        "textSize": args.text_size,
        "iconSize": args.icon_size,
        "arrangeBy": "none",
        "gridSpacing": 100.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        # 底色兜底（背景图解析不出来、或没铺满时露出来的颜色）。
        # 取的是背景图最底部那一档颜色，这样万一露出来也看不出接缝。
        "backgroundColorRed": 0.024,
        "backgroundColorGreen": 0.024,
        "backgroundColorBlue": 0.039,
    }
    if bg_alias:
        icvp["backgroundType"] = 2          # 2 = 用图片作背景
        icvp["backgroundImageAlias"] = bg_alias
    else:
        icvp["backgroundType"] = 1          # 1 = 纯色

    # ---- 窗口设置（bwsp）----
    bwsp = {
        "ShowSidebar": False,
        "ShowStatusBar": False,
        "ShowToolbar": False,
        "ShowPathbar": False,
        "ShowTabView": False,
        "ContainerShowSidebar": False,
        "SidebarWidth": 0,
        "WindowBounds": "{{%d, %d}, {%d, %d}}" % (left, top, width, height),
    }

    ds_path = os.path.join(vol, ".DS_Store")
    if os.path.exists(ds_path):
        os.remove(ds_path)

    with DSStore.open(ds_path, "w+") as d:
        d["."]["bwsp"] = bwsp
        d["."]["icvp"] = icvp
        # 视图设置版本号，Finder 靠它判断结构是否认识
        d["."]["vSrn"] = (b"long", 1)

        d[args.app]["Iloc"] = args.app_pos
        d["Applications"]["Iloc"] = args.apps_pos

        # 把隐藏的辅助文件挪到窗口外面，免得用户开了「显示隐藏文件」看到它们挤在中间
        below = height + 200
        for hidden, x in ((".background", 120), (".VolumeIcon.icns", 300)):
            if os.path.exists(os.path.join(vol, hidden)):
                d[hidden]["Iloc"] = (x, below)

    print("  .DS_Store：窗口 %dx%d @ (%d,%d)，图标 %s / %s，背景 %s"
          % (width, height, left, top, args.app_pos, args.apps_pos,
             "已设置" if bg_alias else "未设置（用纯色）"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
