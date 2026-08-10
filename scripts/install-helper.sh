#!/bin/bash
# 特权安装脚本。必须以 root 运行（由 scripts/install.sh 的 sudo 或
# App 菜单里的系统授权框调用）。可以从两个位置运行：
#   • App bundle 的 Contents/Resources（二进制是同级文件）
#   • 源码 scripts/ 目录（二进制在 ../.build/release）
set -euo pipefail

if [ "$(id -u)" != "0" ]; then
    echo "必须以 root 运行" >&2
    exit 1
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$DIR/lidawaked" ]; then
    SRC="$DIR"
elif [ -x "$DIR/../.build/release/lidawaked" ]; then
    SRC="$(cd "$DIR/../.build/release" && pwd)"
else
    echo "找不到 lidawaked。请先运行 scripts/build.sh" >&2
    exit 1
fi

LABEL="com.cogito.lidawaked"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
HELPER_DIR="/Library/PrivilegedHelperTools"
HELPER="$HELPER_DIR/lidawaked"
STATE_DIR="/Library/Application Support/LidAwake"

echo "==> 停止已有服务（如果有）"
launchctl bootout "system/$LABEL" 2>/dev/null || true
sleep 0.5

echo "==> 复位 SleepDisabled（安装期间保持系统默认行为）"
/usr/bin/pmset -a disablesleep 0 2>/dev/null || true

echo "==> 安装守护进程 -> $HELPER"
install -d -o root -g wheel -m 755 "$HELPER_DIR"
install -o root -g wheel -m 755 "$SRC/lidawaked" "$HELPER"

echo "==> 安装命令行工具 -> /usr/local/bin"
install -d -o root -g wheel -m 755 /usr/local/bin
install -o root -g wheel -m 755 "$SRC/lidawake"       /usr/local/bin/lidawake
install -o root -g wheel -m 755 "$SRC/lidawake-probe" /usr/local/bin/lidawake-probe

echo "==> 准备状态目录"
install -d -o root -g wheel -m 700 "$STATE_DIR"

echo "==> 写入 LaunchDaemon -> $PLIST"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$HELPER</string>
    </array>

    <!-- 按需启动：关闭状态下守护进程会自退，客户端一连接 launchd 就拉起 -->
    <key>MachServices</key>
    <dict>
        <key>$LABEL</key>
        <true/>
    </dict>

    <!-- 开机跑一次：无条件把 SleepDisabled 复位为 0（失效安全） -->
    <key>RunAtLoad</key>
    <true/>

    <!-- 只在异常退出时重启；正常 exit(0)（空闲自退）不重启 -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>ThrottleInterval</key>
    <integer>1</integer>

    <key>StandardErrorPath</key>
    <string>/var/log/lidawaked.err.log</string>
</dict>
</plist>
PLIST_EOF

chown root:wheel "$PLIST"
chmod 644 "$PLIST"

echo "==> 加载服务"
launchctl bootstrap system "$PLIST"
sleep 1

echo "==> 校验"
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo "    launchd 已注册 ✅"
else
    echo "    launchd 注册失败 ❌" >&2
    exit 1
fi
"$HELPER" --check || true
echo ""
echo "安装完成。之后所有开关操作都不再需要密码。"
echo "试试:  lidawake status   |   lidawake on --for 2h   |   lidawake doctor"
