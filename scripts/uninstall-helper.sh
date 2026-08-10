#!/bin/bash
# 特权卸载脚本。必须以 root 运行。
# 关键点：无论如何都要把 SleepDisabled 复位为 0，绝不能留下"永不休眠"的系统。
set -uo pipefail

if [ "$(id -u)" != "0" ]; then
    echo "必须以 root 运行" >&2
    exit 1
fi

LABEL="com.cogito.lidawaked"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

echo "==> 停止并注销服务"
launchctl bootout "system/$LABEL" 2>/dev/null || true
sleep 0.5

echo "==> 复位 SleepDisabled"
/usr/bin/pmset -a disablesleep 0 2>/dev/null || true

echo "==> 删除文件"
rm -f "$PLIST"
rm -f /Library/PrivilegedHelperTools/lidawaked
rm -f /usr/local/bin/lidawake /usr/local/bin/lidawake-probe
rm -rf "/Library/Application Support/LidAwake"

echo "==> 校验"
SD="$(/usr/bin/pmset -g | awk '/SleepDisabled/ {print $2}')"
echo "    SleepDisabled = ${SD:-未知}"
if [ "${SD:-1}" != "0" ]; then
    echo "    ❌ SleepDisabled 未复位，请手动执行: sudo pmset -a disablesleep 0" >&2
    exit 1
fi
if pgrep -x lidawaked >/dev/null 2>&1; then
    echo "    ⚠️ lidawaked 仍在运行，尝试结束"
    pkill -TERM -x lidawaked || true
fi
echo ""
echo "卸载完成（日志 /var/log/lidawaked.log 保留，可自行删除）。"
