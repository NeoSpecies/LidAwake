#!/bin/bash
# 完整卸载：退出 App → 删登录项 → 卸载特权服务并复位 SleepDisabled → 删 App。
set -uo pipefail

LABEL_AGENT="com.cogito.LidAwake"
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL_AGENT.plist"
APP="/Applications/LidAwake.app"

echo "==> 退出 App"
pkill -f "LidAwake.app/Contents/MacOS/LidAwake" 2>/dev/null || true

echo "==> 移除登录项"
launchctl bootout "gui/$(id -u)/$LABEL_AGENT" 2>/dev/null || true
rm -f "$AGENT_PLIST"

echo "==> 卸载特权服务（需要管理员密码）"
HELPER="$APP/Contents/Resources/uninstall-helper.sh"
if [ ! -x "$HELPER" ]; then
    HELPER="$(cd "$(dirname "$0")" && pwd)/uninstall-helper.sh"
fi
sudo "$HELPER"

echo "==> 删除 App"
rm -rf "$APP"

echo "==> 清理探针数据（可选，保留在 ~/.lidawake-probe）"
echo ""
echo "卸载完成。当前 SleepDisabled:"
pmset -g | grep SleepDisabled || true
