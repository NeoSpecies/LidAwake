#!/bin/bash
# 完整安装：构建 → 装 App 到 /Applications → 用 sudo 装特权服务 → 启动 App。
# 你会被要求输入一次管理员密码（或触控 ID，取决于系统配置）；之后开关不再需要密码。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_SRC="$ROOT/build/LidAwake.app"
APP_DST="/Applications/LidAwake.app"

if [ ! -d "$APP_SRC" ] || [ "${1:-}" = "--rebuild" ]; then
    "$ROOT/scripts/build.sh"
fi

echo "==> 运行单元测试"
"$ROOT/.build/release/lidawake-tests" | tail -3

echo "==> 安装 App 到 $APP_DST"
if pgrep -f "LidAwake.app/Contents/MacOS/LidAwake" >/dev/null 2>&1; then
    echo "    先退出正在运行的 LidAwake"
    pkill -f "LidAwake.app/Contents/MacOS/LidAwake" || true
    sleep 1
fi
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "==> 安装特权服务（需要管理员密码）"
sudo "$APP_DST/Contents/Resources/install-helper.sh"

echo "==> 启动菜单栏 App"
open "$APP_DST"

echo ""
echo "完成。菜单栏右上角应该出现 LidAwake 图标。"
echo "命令行:  lidawake status | lidawake on --for 2h | lidawake off | lidawake doctor"
