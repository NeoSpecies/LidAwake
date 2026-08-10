#!/bin/bash
# 构建 LidAwake：SwiftPM 编译 + 手工组装 .app bundle + ad-hoc 签名。
# 本机只有 Command Line Tools（无完整 Xcode），因此不能用 xcodebuild 构建 app target。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="1.0.1"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/LidAwake.app"

echo "==> swift build -c release"
swift build -c release

BIN="$ROOT/.build/release"
for f in LidAwakeUI lidawaked lidawake lidawake-probe; do
    [ -x "$BIN/$f" ] || { echo "缺少构建产物: $BIN/$f"; exit 1; }
done

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/LidAwakeUI"     "$APP/Contents/MacOS/LidAwake"
cp "$BIN/lidawaked"      "$APP/Contents/Resources/lidawaked"
cp "$BIN/lidawake"       "$APP/Contents/Resources/lidawake"
cp "$BIN/lidawake-probe" "$APP/Contents/Resources/lidawake-probe"
cp "$ROOT/scripts/install-helper.sh"   "$APP/Contents/Resources/install-helper.sh"
cp "$ROOT/scripts/uninstall-helper.sh" "$APP/Contents/Resources/uninstall-helper.sh"

# App 图标：没有就现场生成（只依赖 CLT，见 tools/make-icon.swift）
if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
    echo "==> 生成 App 图标"
    swift "$ROOT/tools/make-icon.swift" "$ROOT/Resources" >/dev/null
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod 755 "$APP/Contents/Resources/"*.sh "$APP/Contents/Resources/lidawake"* "$APP/Contents/Resources/lidawaked"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>LidAwake</string>
    <key>CFBundleDisplayName</key>       <string>LidAwake</string>
    <key>CFBundleIdentifier</key>        <string>com.cogito.LidAwake</string>
    <key>CFBundleExecutable</key>        <string>LidAwake</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>15.0</string>
    <key>LSUIElement</key>               <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>  <string>LidAwake — 合盖续跑 · MIT License</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key>   <false/>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名（本机无 Developer ID，见 docs/SPEC.md §1）"
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/lidawaked" >/dev/null
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/lidawake" >/dev/null
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/lidawake-probe" >/dev/null
codesign --force --sign - --timestamp=none "$APP" >/dev/null
codesign --verify --deep --strict "$APP" && echo "    签名校验通过"

echo ""
echo "构建完成:"
echo "  App        : $APP"
echo "  守护进程    : $BIN/lidawaked"
echo "  CLI        : $BIN/lidawake"
echo "  探针       : $BIN/lidawake-probe"
echo ""
echo "下一步: scripts/run-tests.sh  然后  scripts/install.sh"
