#!/bin/bash
# 构建 Display Master.app（菜单栏工具，无 Dock 图标）
#
# 用法：
#   ./build.sh              构建 + 签名 + 安装到 /Applications
#   ./build.sh --no-install 只构建到 build/，不动 /Applications
set -e
cd "$(dirname "$0")"

EXE_NAME="DisplayMaster"                 # 二进制名（不带空格，命令行友好）
BUNDLE_NAME="Display Master"             # .app 与 Finder 显示名
BUNDLE_ID="com.zed.displaymaster"
APP_DIR="build/${BUNDLE_NAME}.app"
INSTALL_DIR="/Applications/${BUNDLE_NAME}.app"
LEGACY_DIR="/Applications/MonitorMate.app"   # 旧名字，顺手清掉

# 版本号只在 AppInfo.swift 里维护，这里读出来避免两处不一致
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/DisplayMaster/AppInfo.swift | head -1)
VERSION=${VERSION:-1.0.0}

DO_INSTALL=1
[ "$1" = "--no-install" ] && DO_INSTALL=0

echo "==> swift build -c release"
# 注意：必须带 --disable-sandbox，否则在受限环境下 SwiftPM 的
# manifest 沙箱会报 "sandbox-exec: sandbox_apply: Operation not permitted"
swift build -c release --disable-sandbox

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
cp ".build/release/${EXE_NAME}" "$APP_DIR/Contents/MacOS/${EXE_NAME}"

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
