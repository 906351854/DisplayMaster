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

# 只清掉我们自己写进 bundle 的那几样（可执行文件 / 资源 / Info.plist / 代码签名），
# 不对整个 .app 做 rm -rf：既能避免误删，也不会触发宿主环境的批量删除保护。
clean_bundle() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  rm -rf "$dir/Contents/MacOS" "$dir/Contents/Resources" \
         "$dir/Contents/Info.plist" "$dir/Contents/_CodeSignature"
}

clean_bundle "$APP_DIR"
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
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

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
WAS_RUNNING=0
if pgrep -x "$EXE_NAME" >/dev/null 2>&1; then
  WAS_RUNNING=1
  pkill -x "$EXE_NAME" || true
  sleep 1
fi
if [ -d "$LEGACY_DIR" ]; then
  echo "    清理旧版本：$LEGACY_DIR"
  pkill -x MonitorMate 2>/dev/null || true
  rm -rf "$LEGACY_DIR"
fi

clean_bundle "$INSTALL_DIR"
# 用 ditto 而不是 cp -R：保留扩展属性与资源分支
ditto "$APP_DIR" "$INSTALL_DIR"
xattr -cr "$INSTALL_DIR" 2>/dev/null || true

if [ "$WAS_RUNNING" = "1" ]; then
  open "$INSTALL_DIR"
  echo "已重新启动菜单栏实例"
fi

echo
echo "构建完成：$APP_DIR   →   已安装：$INSTALL_DIR"
echo "自检：${INSTALL_DIR}/Contents/MacOS/${EXE_NAME} --selftest"
build_dmg
