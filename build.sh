#!/bin/bash
# 构建 Display Master.app（菜单栏工具，无 Dock 图标）
#
# 用法：
#   ./build.sh                  构建通用二进制 + 签名 + 安装到 /Applications
#   ./build.sh --no-install     只构建到 build/，不动 /Applications
#   ./build.sh --native         只编当前架构（日常改代码时快很多）
#   ./build.sh --dmg            构建完成后顺便打出 DMG 安装包（可与其他参数组合）
set -e
cd "$(dirname "$0")"

EXE_NAME="DisplayMaster"                 # 二进制名（不带空格，命令行友好）
BUNDLE_NAME="Display Master"             # .app 与 Finder 显示名
BUNDLE_ID="com.zed.displaymaster"
APP_DIR="build/${BUNDLE_NAME}.app"
INSTALL_DIR="/Applications/${BUNDLE_NAME}.app"
LEGACY_DIR="/Applications/MonitorMate.app"   # 旧名字，顺手清掉

# 版本号只在 AppInfo.swift 里维护，这里读出来避免两处不一致。
#
# 路径**不写死**：源文件按职责分了层，位置随时可能再变，而写死的路径不会报错 ——
# 它只会让下面这行 sed 读不到东西、静默回落到兜底版本号，于是 Info.plist 里
# 装着一个错的版本，从外面完全看不出来。所以按文件名找，找不到就出大声。
APPINFO=$(find Sources -name AppInfo.swift -print -quit)
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$APPINFO" 2>/dev/null | head -1)
if [ -z "$VERSION" ]; then
  echo "    ⚠️  没能从 ${APPINFO:-Sources 下的 AppInfo.swift} 读出 version，本次回落到 1.0.0"
fi
VERSION=${VERSION:-1.0.0}

DO_INSTALL=1
UNIVERSAL=1
DO_DMG=0
for arg in "$@"; do
  case "$arg" in
    --no-install) DO_INSTALL=0 ;;
    --native)     UNIVERSAL=0 ;;   # 只编当前架构，日常开发时快很多
    --dmg)        DO_DMG=1 ;;
  esac
done

# 需要时打出 DMG。单独抽成函数是因为 --no-install 分支会提前 exit。
build_dmg() {
  [ "$DO_DMG" = "1" ] || return 0
  echo
  echo "==> 打包 DMG"
  bash Tools/make-dmg.sh
}

echo "==> swift build -c release"

# Xcode 的许可证没同意时，swift 会直接拒绝干活（退出码 69，只打印一行提示）。
# 系统里那份 CommandLineTools 自带独立工具链，能编就先用它编下去 ——
# 重装或者更新过 Xcode 的人经常会撞上这个，不该因为许可证就走不下去。
if ! swift --version >/dev/null 2>&1; then
  if [ -x /Library/Developer/CommandLineTools/usr/bin/swift ]; then
    DEVELOPER_DIR=/Library/Developer/CommandLineTools
    export DEVELOPER_DIR
    echo "    注意：Xcode 许可证尚未同意，本次改用 CommandLineTools 工具链"
    echo "    想换回 Xcode 工具链，在终端跑一次：sudo xcodebuild -license accept"
    # CLT 里没有 xcbuild，交叉编译（--arch x86_64）走不通，只能编当前架构。
    # 自己机器上用完全够；要发 Release 就得先同意 Xcode 许可证。
    if [ "$UNIVERSAL" = "1" ]; then
      UNIVERSAL=0
      echo "    另外：CommandLineTools 不带 xcbuild，编不了通用二进制，本次只编当前架构"
    fi
  else
    echo "    ✗ swift 用不了，也没找到 CommandLineTools 工具链"
    exit 1
  fi
fi

# 注意：必须带 --disable-sandbox，否则在受限环境下 SwiftPM 的
# manifest 沙箱会报 "sandbox-exec: sandbox_apply: Operation not permitted"
if [ "$UNIVERSAL" = "1" ]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
else
  ARCH_FLAGS=()
fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --disable-sandbox

# 产物路径问 SwiftPM 要，不要写死。
# 曾经这里写的是 .build/apple/Products/Release/ —— Xcode 27 起 SwiftPM 改把
# 多架构产物放进 .build/out/Products/Release/，旧目录不再更新。里面留着上次
# 构建的二进制，于是 cp 静默复制了一个不含新代码的包：版本号还是新的，
# 功能却是旧的，从外面完全看不出来。这种坑只能靠「不写死路径」根治。
BIN_DIR=$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --disable-sandbox --show-bin-path)
BIN_PATH="$BIN_DIR/${EXE_NAME}"

if [ ! -f "$BIN_PATH" ]; then
  echo "    ✗ 没找到编译产物：$BIN_PATH"
  exit 1
fi

# 第二道闸：产物必须比所有源文件都新。万一哪天增量构建又犯了同样的毛病，
# 这里会停下来，而不是把一个旧包签个名装上去。
STALE_SRC=$(find Sources -name '*.swift' -newer "$BIN_PATH" -print -quit)
if [ -n "$STALE_SRC" ]; then
  echo "    ✗ 编译产物比源码旧，拒绝继续："
  echo "        产物 $BIN_PATH  ($(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$BIN_PATH"))"
  echo "        源码 $STALE_SRC  ($(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$STALE_SRC"))"
  echo "      跑一次 swift package clean 再重试。"
  exit 1
fi

echo "    产物：$BIN_PATH"
echo "    架构：$(lipo -info "$BIN_PATH" 2>/dev/null | sed 's/.*are: //')"

echo "==> 组装 .app bundle (v$VERSION)"

# 组装 .app 时**不删除任何东西**，一律靠 ditto 覆盖 + `codesign --force` 重建签名。
#
# bundle 里的内容全是这个脚本每次重新生成的固定几样（可执行文件、图标、Info.plist、
# 后台项 plist），ditto 到已存在的目录本来就是覆盖语义;签名也由 codesign --force
# 自己替换，不需要先清掉 _CodeSignature。
#
# 为什么不做整目录清理：受限环境对「一个回合内删除大量文件」有保护（阈值 50），
# 而组装 .app 是每次构建都要做的日常动作，不该每次都卡在人工确认上。
# 2026-09-18 因此被打断两次，第二次尤其难看：实例已经 pkill 掉了、安装却被拦下，
# 结果是菜单栏 App 直接停摆（进程一个都没了）。
#
# 代价：万一将来从 bundle 里**删掉**某个资源文件，旧版残留下来的那份不会被清掉。
# 真需要时手工删那一个文件即可 —— 不要把整目录清理放回日常构建路径。
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/${EXE_NAME}"

# 图标资源：AppIcon.icns（Finder/关于面板）+ 菜单栏 template 图
for f in Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png Resources/MenuBarIcon@3x.png; do
  [ -f "$f" ] && cp "$f" "$APP_DIR/Contents/Resources/"
done
if [ ! -f Resources/AppIcon.icns ]; then
  echo "    ⚠️  缺少 Resources/AppIcon.icns —— 请先跑 swift Tools/make-icons.swift ."
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>${EXE_NAME}</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundleName</key><string>${BUNDLE_NAME}</string>
	<key>CFBundleDisplayName</key><string>${BUNDLE_NAME}</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 后台项（LaunchAgent）。1.5.0 起不再往 ~/Library/LaunchAgents/ 写 plist，而是把它
# 作为 bundle 的一部分交给 SMAppService 登记 —— 后台项于是挂在 app 名下，系统设置里
# 显示 app 自己的图标，而不是「项目来自身份不明的开发者。」。
#
# 两个硬要求，写错了 SMAppService 会直接拒绝登记或登记成一个起不来的服务：
#   1. 路径必须是 Contents/Library/LaunchAgents/；
#   2. 可执行文件只能用 BundleProgram 写**相对 bundle 根**的路径，不能用 Program/ProgramArguments。
# 另外 RunAtLoad + KeepAlive(SuccessfulExit=false) 就是原来的语义：
# 登录时自动起来、正常退出不拉活、崩溃才补一份。
#
# DISPLAYMASTER_SUPERVISED 让被 launchd 拉起的那份实例认得出自己（见 KeepAliveAgent）。
mkdir -p "$APP_DIR/Contents/Library/LaunchAgents"
cat > "$APP_DIR/Contents/Library/LaunchAgents/${BUNDLE_ID}.agent.plist" <<AGENTPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>${BUNDLE_ID}.agent</string>
	<key>BundleProgram</key><string>Contents/MacOS/${EXE_NAME}</string>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key><false/>
	</dict>
	<key>ThrottleInterval</key><integer>5</integer>
	<key>EnvironmentVariables</key>
	<dict>
		<key>DISPLAYMASTER_SUPERVISED</key><string>1</string>
	</dict>
</dict>
</plist>
AGENTPLIST

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP_DIR"
codesign -dv "$APP_DIR" 2>&1 | head -3

if [ "$DO_INSTALL" = "0" ]; then
  echo
  echo "构建完成（未安装）：$APP_DIR"
  echo "自检：${APP_DIR}/Contents/MacOS/${EXE_NAME} --selftest"
  build_dmg
  exit 0
fi

# ---- 安装到 /Applications 并重启（如果原本在运行）----
echo
echo "==> 安装到 ${INSTALL_DIR}"

# ⚠️ 顺序很重要：**先复制，再停旧实例**。
#
# ditto 是覆盖语义，运行中的进程持有的是旧 inode，覆盖文件不会打断它；
# 反过来先 pkill 的话，一旦复制失败（受限环境的删除保护就会让脚本中途停下），
# 结果就是 App 已经被杀掉、新版却没装上 —— 菜单栏凭空少一个图标，
# 而脚本只留下一行错误。2026-09-18 正是这么撞了一次。
ditto "$APP_DIR" "$INSTALL_DIR"
xattr -cr "$INSTALL_DIR" 2>/dev/null || true

# 刷新 LaunchServices 缓存。**这一步不能省**：
# 用 ditto 覆盖一个已经装过的 App 之后，LaunchServices 数据库里那条记录可能还指着
# 旧的 bundle，而 1.5.0 的后台项是按 `BundleProgram`（相对 bundle 的路径）记录可执行
# 文件的 —— 解析不到就每次 spawn 都失败。症状极具迷惑性：`launchctl print` 里显示
# 「已登记」，但 `runs` 一直涨、`last exit code = 78: EX_CONFIG`、`job state = spawn
# failed`，而同一个二进制从终端直接跑完全正常。2026-09-18 为这个排查了一小时。
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$INSTALL_DIR" >/dev/null 2>&1 || true
  # 再把构建目录里那份注销掉。它和 /Applications 里的那份**是同一个 bundle id**，
  # 两条记录并存时，launchd 解析后台项那条 `BundleProgram`（相对 bundle 的路径）
  # 有可能命中构建目录那份 —— 而那份随时会被下次构建覆盖掉，于是每次 spawn 都失败
  # （`EX_CONFIG`），症状是「后台项明明登记着，却一次都没起来」。
  # 2026-09-18 为此排查掉一个多小时，最后就是靠注销这条记录才通的。
  APP_DIR_ABS="$(cd "$(dirname "$APP_DIR")" && pwd)/$(basename "$APP_DIR")"
  "$LSREGISTER" -u "$APP_DIR_ABS" >/dev/null 2>&1 || true
fi

WAS_RUNNING=0
if pgrep -x "$EXE_NAME" >/dev/null 2>&1; then
  WAS_RUNNING=1
  # 保活代理管着老进程：先摘掉 launchd 的注册，不然 SIGTERM 算异常退出，
  # launchd 会在覆盖文件的当口把旧二进制又拉起来，和新装好的打架。
  # 两个标签都摘：1.4.4 及更早写在用户目录那份，和 1.5.0 的 bundle 内后台项。
  launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/$BUNDLE_ID.agent" 2>/dev/null || true
  pkill -x "$EXE_NAME" || true
  sleep 1
fi
if [ -d "$LEGACY_DIR" ]; then
  echo "    清理旧版本：$LEGACY_DIR"
  pkill -x MonitorMate 2>/dev/null || true
  rm -rf "$LEGACY_DIR"
fi

if [ "$WAS_RUNNING" = "1" ]; then
  # bootout + pkill 之后 LaunchServices 还没更新完状态，紧接着 open 会静默失败 ——
  # 表现是「服务没重新注册、也没有新实例」，而这里照样打印「已重新启动」。
  # 2026-09-18 因为这个假成功连踩两次（每次都以为是代码没生效）。所以重试到
  # 进程真的起来为止，起不来就明确报出来，别让这句话变成谎话。
  restarted=0
  for _ in 1 2 3 4 5; do
    open "$INSTALL_DIR" 2>/dev/null || true
    sleep 1
    if pgrep -x "$EXE_NAME" >/dev/null 2>&1; then restarted=1; break; fi
  done
  if [ "$restarted" = "1" ]; then
    echo "已重新启动菜单栏实例"
  else
    echo "⚠️  菜单栏实例没能自动起来，请手动打开：$INSTALL_DIR" >&2
  fi
fi

echo
echo "构建完成：$APP_DIR   →   已安装：$INSTALL_DIR"
echo "自检：${INSTALL_DIR}/Contents/MacOS/${EXE_NAME} --selftest"
build_dmg
