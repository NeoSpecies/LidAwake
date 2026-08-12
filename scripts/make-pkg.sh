#!/bin/bash
# 打成标准 macOS 安装包（.pkg）。
#
# 为什么必须是 .pkg 而不是 .dmg：LidAwake 需要装一个 root 守护进程到
# /Library/PrivilegedHelperTools 并注册 LaunchDaemon。.pkg 的安装器本身就以 root 运行，
# 用户只需要在系统安装界面授权一次；拖拽式 .dmg 做不到这件事。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-1.2.0}"
IDENTIFIER="com.cogito.LidAwake"
LABEL="com.cogito.lidawaked"
OUT="$ROOT/build/LidAwake-$VERSION.pkg"

PKGROOT="$ROOT/build/pkgroot"
SCRIPTS="$ROOT/build/pkgscripts"

echo "==> 构建二进制与 App"
"$ROOT/scripts/build.sh" >/dev/null
echo "    ok"

echo "==> 布置 payload"
rm -rf "$PKGROOT" "$SCRIPTS"
mkdir -p "$PKGROOT/Applications" \
         "$PKGROOT/Library/PrivilegedHelperTools" \
         "$PKGROOT/Library/LaunchDaemons" \
         "$PKGROOT/usr/local/bin" \
         "$SCRIPTS"

cp -R "$ROOT/build/LidAwake.app"           "$PKGROOT/Applications/"
cp "$ROOT/.build/release/lidawaked"        "$PKGROOT/Library/PrivilegedHelperTools/lidawaked"
cp "$ROOT/.build/release/lidawake"         "$PKGROOT/usr/local/bin/lidawake"
cp "$ROOT/.build/release/lidawake-probe"   "$PKGROOT/usr/local/bin/lidawake-probe"
chmod 755 "$PKGROOT/Library/PrivilegedHelperTools/lidawaked" \
          "$PKGROOT/usr/local/bin/lidawake" \
          "$PKGROOT/usr/local/bin/lidawake-probe"

cat > "$PKGROOT/Library/LaunchDaemons/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>/Library/PrivilegedHelperTools/lidawaked</string></array>
    <key>MachServices</key>
    <dict><key>$LABEL</key><true/></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>1</integer>
    <key>StandardErrorPath</key><string>/var/log/lidawaked.err.log</string>
</dict>
</plist>
PLIST
chmod 644 "$PKGROOT/Library/LaunchDaemons/$LABEL.plist"

echo "==> 生成安装脚本"
cat > "$SCRIPTS/preinstall" <<'SH'
#!/bin/bash
# 升级安装：先停旧服务，并把 SleepDisabled 复位，避免升级过程中系统处于"永不休眠"
launchctl bootout system/com.cogito.lidawaked 2>/dev/null || true
/usr/bin/pmset -a disablesleep 0 2>/dev/null || true
pkill -f "LidAwake.app/Contents/MacOS/LidAwake" 2>/dev/null || true
exit 0
SH

cat > "$SCRIPTS/postinstall" <<'SH'
#!/bin/bash
set -uo pipefail
LABEL="com.cogito.lidawaked"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

# launchd 硬要求：plist 和被执行的程序都不能被非 root 写入
chown root:wheel "$PLIST" /Library/PrivilegedHelperTools/lidawaked
chmod 644 "$PLIST"
chmod 755 /Library/PrivilegedHelperTools/lidawaked
chown root:wheel /usr/local/bin/lidawake /usr/local/bin/lidawake-probe 2>/dev/null || true
install -d -o root -g wheel -m 700 "/Library/Application Support/LidAwake"

# 失效安全：装完先保证系统休眠行为是正常的
/usr/bin/pmset -a disablesleep 0 2>/dev/null || true

launchctl bootstrap system "$PLIST" 2>/dev/null || true

# 以当前登录用户（不是 root）打开菜单栏 App
CONSOLE_USER="$(stat -f%Su /dev/console 2>/dev/null || echo "")"
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    CONSOLE_UID="$(id -u "$CONSOLE_USER")"
    launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" \
        open -a /Applications/LidAwake.app 2>/dev/null || true
fi
exit 0
SH
chmod 755 "$SCRIPTS/preinstall" "$SCRIPTS/postinstall"

echo "==> 生成 component plist（关闭 bundle 重定位）"
# 为什么必须关掉 BundleIsRelocatable：
# pkgbuild 默认把 app bundle 标记为"可重定位"，安装时 PackageKit 会通过
# Launch Services 找到系统里**同 bundle id 的其它副本**，然后去动那一份而不是
# /Applications。只要用户在 ~/Downloads、~/Documents 等位置留过一份 LidAwake.app，
# 安装就会失败：
#     PackageKit: Failed to unlinkat file reference /Users/.../build/LidAwake.app/...
#     error: Operation not permitted        ← TCC 保护目录，installd 无权限
#     installer: The upgrade failed. (将文件移到最终目的位置时发生意外错误。)
# 实测踩到过，且回滚后 /Applications 下的 app 会被删掉而新的装不上。
COMPONENT="$ROOT/build/component.plist"
pkgbuild --analyze --root "$PKGROOT" "$COMPONENT" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT" 2>/dev/null \
    || plutil -replace 0.BundleIsRelocatable -bool false "$COMPONENT"
echo "    BundleIsRelocatable = $(/usr/libexec/PlistBuddy -c 'Print :0:BundleIsRelocatable' "$COMPONENT" 2>/dev/null)"

echo "==> pkgbuild"
# 清掉扩展属性（quarantine / provenance），否则会以 AppleDouble(._*) 形式混进 payload
xattr -cr "$PKGROOT"
rm -f "$OUT"
pkgbuild --root "$PKGROOT" \
         --component-plist "$COMPONENT" \
         --scripts "$SCRIPTS" \
         --identifier "$IDENTIFIER" \
         --version "$VERSION" \
         --ownership recommended \
         --install-location / \
         "$OUT" >/dev/null

# 有 Developer ID 时自动签名（本机没有，会跳过）
if security find-identity -v -p basic 2>/dev/null | grep -q "Developer ID Installer"; then
    ID="$(security find-identity -v -p basic | grep "Developer ID Installer" | head -1 | sed 's/.*"\(.*\)".*/\1/')"
    echo "==> 用 $ID 签名安装包"
    productsign --sign "$ID" "$OUT" "$OUT.signed" && mv "$OUT.signed" "$OUT"
else
    echo "==> 未找到 Developer ID Installer 证书，产出**未签名**安装包"
    echo "    首次打开需要右键 →「打开」，或用命令行安装（见 README「安装」一节）"
fi

# 打包暂存目录里有一份同 bundle id 的 app，留着会被 Launch Services 索引到，
# 反过来干扰下一次安装。打完包就清掉。
rm -rf "$PKGROOT" "$SCRIPTS"

echo ""
echo "安装包: $OUT  ($(du -h "$OUT" | cut -f1))"
echo "安装:   sudo installer -pkg \"$OUT\" -target /"
echo "内容:"
pkgutil --payload-files "$OUT" | grep -vE "^\./Applications/LidAwake.app/(Contents/(_CodeSignature|MacOS|Resources)/)?." | sed 's/^/  /'
pkgutil --payload-files "$OUT" | grep -c . | xargs echo "  （共" | tr -d '\n'; echo " 个文件）"
