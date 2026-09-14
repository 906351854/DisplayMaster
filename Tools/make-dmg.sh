#!/bin/bash
# 把已构建好的 Display Master.app 打成 DMG 安装包。
#
# 用法：
#   Tools/make-dmg.sh                 打当前版本 → build/DisplayMaster-<版本>.dmg
#   Tools/make-dmg.sh --no-layout     跳过窗口布局（无图形会话的 CI 上可以用）
#
# 为什么不用 create-dmg：
#   它要额外装（brew / git clone，国内还得挂代理），而 hdiutil + 一个 .DS_Store
#   就能把该做的都做完。零硬依赖，随手能跑。
#
# 窗口布局（尺寸 / 图标位置 / 背景图）有两套做法，按可用性自动选：
#   1) Tools/make-dsstore.py —— 直接拼 .DS_Store，不需要任何系统授权（首选）
#      需要 pip install ds_store mac_alias
#   2) AppleScript 驱动 Finder —— 不需要额外依赖，但要「自动化」权限
# 两套都不行时，仍然产出一个可用的 DMG：拖拽安装、卷图标都在，只是窗口是默认样式。
#
# 产出的 DMG 里有什么：
#   Display Master.app                 应用本体
#   Applications  →  /Applications     软链，用户拖过去就装完了
#   .background/                       窗口背景图
#   .VolumeIcon.icns                   卷图标
set -e
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
BUNDLE_NAME="Display Master"
EXE_NAME="DisplayMaster"
VOL_NAME="Display Master"

VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/DisplayMaster/AppInfo.swift | head -1)
VERSION=${VERSION:-1.0.0}

APP="$ROOT/build/${BUNDLE_NAME}.app"
WORK="$ROOT/build/dmg"
STAGE="$WORK/stage"
RW_DMG="$WORK/rw.dmg"
OUT="$ROOT/build/DisplayMaster-${VERSION}.dmg"

# 窗口内容区尺寸。背景图也是按这个尺寸生成的，两者必须一致。
BG_WIDTH=660
BG_HEIGHT=420
TITLEBAR=22          # WindowBounds 的高度要算上标题栏

# 图标纵向位置（距内容区顶部）。**必须和背景图里落点框的中心用同一个值**，
# 否则两者会错开 —— 这个坑踩过一次：常量定义在下面，生成背景图时还没赋值，
# 结果背景用了默认的 0.44H、图标用了 175，差了 9pt。所以常量统一放这里。
# 取值依据：Finder 内容区底下压着一条状态栏，可用高度比窗口小，175 是实测
# 下来让「图标 + 两个落点框」在可见区域里看着舒服的位置。
ICON_Y=175

DO_LAYOUT=1
[ "$1" = "--no-layout" ] && DO_LAYOUT=0

if [ ! -d "$APP" ]; then
  echo "✗ 没找到 $APP —— 先跑 ./build.sh --no-install"
  exit 1
fi

# 找一个装了 ds_store + mac_alias 的 python
find_python() {
  for cand in "${PYTHON:-}" "$(command -v python3 || true)" /usr/bin/python3 \
              "$HOME/.workbuddy/binaries/python/versions/3.13.12/bin/python3"; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    if "$cand" -c 'import ds_store, mac_alias' >/dev/null 2>&1; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}

echo "==> 准备暂存目录"
mkdir -p "$WORK"
# 只删自己建的东西，不对整个目录 rm -rf（会触发宿主环境的批量删除保护）
if [ -d "$STAGE" ]; then
  rm -rf "$STAGE/${BUNDLE_NAME}.app" "$STAGE/Applications" \
         "$STAGE/.background" "$STAGE/.VolumeIcon.icns" "$STAGE/.DS_Store"
fi
mkdir -p "$STAGE/.background"

# 用 ditto 拷贝，保留扩展属性与代码签名封印（cp -R 会破坏签名）
ditto "$APP" "$STAGE/${BUNDLE_NAME}.app"

# 拖拽安装的关键：这个软链让用户不用自己去开「应用程序」文件夹
ln -sfn /Applications "$STAGE/Applications"

echo "==> 生成窗口背景图"
swift "$ROOT/Tools/make-dmg-background.swift" "$STAGE/.background/dmg-background.tiff" \
      "$BG_WIDTH" "$BG_HEIGHT" 1 "$ICON_Y"

# 卷图标
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
fi

echo "==> 建立可写磁盘映像"
[ -f "$RW_DMG" ] && rm -f "$RW_DMG"
hdiutil create -srcfolder "$STAGE" -volname "$VOL_NAME" -fs HFS+ \
        -format UDRW -ov "$RW_DMG" >/dev/null

# 同名卷可能还挂着，先踢掉
if [ -d "/Volumes/$VOL_NAME" ]; then
  hdiutil detach "/Volumes/$VOL_NAME" -force >/dev/null 2>&1 || true
fi

echo "==> 挂载并设置窗口布局"
# -noautoopen：不让 Finder 抢先把窗口开出来，否则它会拿默认设置覆盖掉我们的 .DS_Store
hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" >/dev/null
MOUNT="/Volumes/$VOL_NAME"
for _ in $(seq 1 20); do
  [ -d "$MOUNT" ] && break
  sleep 0.5
done
if [ ! -d "$MOUNT" ]; then
  echo "✗ 挂载失败"
  exit 1
fi

# 卷的「自定义图标」标志位（kHasCustomIcon = 0x0400）
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a C "$MOUNT" 2>/dev/null || true
fi

LAYOUT_DONE=""

if [ "$DO_LAYOUT" = "1" ]; then
  if PY=$(find_python); then
    if "$PY" "$ROOT/Tools/make-dsstore.py" \
        --volume "$MOUNT" \
        --app "${BUNDLE_NAME}.app" \
        --background ".background/dmg-background.tiff" \
        --window-bounds "240,160,${BG_WIDTH},$((BG_HEIGHT + TITLEBAR))" \
        --app-pos "165,${ICON_Y}" \
        --apps-pos "495,${ICON_Y}"; then
      LAYOUT_DONE="make-dsstore.py（无需授权）"
    fi
  else
    echo "    （没找到带 ds_store/mac_alias 的 python3，退回 Finder 脚本方式）"
  fi

  # 兜底：让 Finder 自己写（脚本先落盘再执行，避免 heredoc 嵌在 if 条件里）
  if [ -z "$LAYOUT_DONE" ]; then
    AS_FILE="$WORK/layout.applescript"
    cat > "$AS_FILE" <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {240, 160, $((240 + BG_WIDTH)), $((160 + BG_HEIGHT + TITLEBAR))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 12
    set background picture of opts to file ".background:dmg-background.tiff"
    set position of item "${BUNDLE_NAME}.app" of container window to {165, $ICON_Y}
    set position of item "Applications" of container window to {495, $ICON_Y}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
    if osascript "$AS_FILE" >"$WORK/layout.log" 2>&1; then
      LAYOUT_DONE="AppleScript"
    else
      echo "    ⚠️  Finder 脚本失败，两种布局方式都没成功 —— DMG 仍然可用，只是窗口是默认样式"
      head -2 "$WORK/layout.log" | sed 's/^/       /'
    fi
    rm -f "$AS_FILE"
  fi
else
  echo "    已按参数跳过布局"
fi

[ -n "$LAYOUT_DONE" ] && echo "    布局方式：$LAYOUT_DONE"

# 让文件系统把元数据刷下去，别急着卸载
sync
sleep 1

if [ -n "$LAYOUT_DONE" ] && [ ! -f "$MOUNT/.DS_Store" ]; then
  echo "    ⚠️  卷里没有 .DS_Store —— 布局可能没落盘"
fi

echo "==> 卸载并压缩"
hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || {
  sleep 2
  hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
}

[ -f "$OUT" ] && rm -f "$OUT"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -f "$RW_DMG"

SIZE=$(ls -lh "$OUT" | awk '{print $5}')
echo
echo "打包完成：$OUT  ($SIZE)"
echo "想要自己看一眼：open \"$OUT\""
