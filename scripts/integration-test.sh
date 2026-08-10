#!/bin/bash
# L2 集成测试 —— 需要 root，跑在真实系统上。
#   sudo scripts/integration-test.sh            # 全部
#   SKIP_SLOW=1 sudo scripts/integration-test.sh # 跳过 130s 的空闲自退测试
#
# 每一步都回读系统真实状态（pmset / launchctl），不相信 CLI 的自述。
set -uo pipefail

if [ "$(id -u)" != "0" ]; then
    echo "需要 root：sudo $0" >&2
    exit 1
fi

LIDAWAKE="${LIDAWAKE:-/usr/local/bin/lidawake}"
LABEL="com.cogito.lidawaked"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SKIP_SLOW="${SKIP_SLOW:-0}"

[ -x "$LIDAWAKE" ] || { echo "找不到 $LIDAWAKE，请先安装：scripts/install.sh" >&2; exit 1; }
[ -f "$PLIST" ] || { echo "找不到 $PLIST，请先安装：scripts/install.sh" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
skip(){ echo "  ⏭  $1"; }
step(){ echo ""; echo "── $1"; }

sd() { /usr/bin/pmset -g | awk '/SleepDisabled/{print $2; exit}'; }
assert_sd() {
    local want="$1" got; got="$(sd)"
    [ "$got" = "$want" ] && ok "SleepDisabled = $want" || bad "SleepDisabled 期望 $want，实际 $got"
}
# 用 plutil 读 JSON：不依赖 python3（osascript 起的 root shell 里 python3 会被 TCC 拦住）
jget() {
    plutil -extract "$1" raw -o - -- - 2>/dev/null || true
}
sfield() { "$LIDAWAKE" status --json 2>/dev/null | jget "$1"; }
daemon_pid() { pgrep -x lidawaked | head -1; }

echo "LidAwake 集成测试"
echo "=================="

# 保存原有安全策略，结束时恢复
SNAP="$("$LIDAWAKE" status --json 2>/dev/null)"
G_FLOOR="$(printf '%s' "$SNAP" | plutil -extract guards.batteryFloorPercent raw -o - -- - 2>/dev/null)"
G_MAX="$(printf '%s' "$SNAP" | plutil -extract guards.maxSessionSeconds raw -o - -- - 2>/dev/null)"
G_AC="$(printf '%s' "$SNAP" | plutil -extract guards.requireExternalPower raw -o - -- - 2>/dev/null)"
restore() {
    [ -n "${G_FLOOR:-}" ] && "$LIDAWAKE" guards --battery-floor "$G_FLOOR" >/dev/null 2>&1
    [ -n "${G_MAX:-}" ] && "$LIDAWAKE" guards --max "${G_MAX%%.*}" >/dev/null 2>&1
    [ "${G_AC:-false}" = "true" ] && "$LIDAWAKE" guards --require-ac on >/dev/null 2>&1
    [ "${G_AC:-false}" = "false" ] && "$LIDAWAKE" guards --require-ac off >/dev/null 2>&1
    "$LIDAWAKE" off >/dev/null 2>&1
}
trap restore EXIT

step "I1/I2 初始状态与按需拉起"
"$LIDAWAKE" off >/dev/null 2>&1
MODE="$(sfield mode.kind)"
[ "$MODE" = "off" ] && ok "I1 初始 mode=off" || bad "I1 mode=$MODE"
assert_sd 0
PID="$(daemon_pid)"
[ -n "$PID" ] && ok "I2 守护进程已被按需拉起 (pid $PID)" || bad "I2 守护进程未运行"

step "I3/I4 开启（含幂等）"
"$LIDAWAKE" on >/dev/null 2>&1
assert_sd 1
if /usr/bin/pmset -g assertions | grep -q "LidAwake"; then
    ok "I3 断言已挂上（pmset -g assertions 可见）"
else
    bad "I3 未在 pmset -g assertions 中看到 LidAwake"
fi
[ "$(sfield mechanism)" = "full" ] && ok "I3 机制 = full" || bad "I3 机制 = $(sfield mechanism)"
"$LIDAWAKE" on >/dev/null 2>&1 && ok "I4 重复开启幂等" || bad "I4 重复开启报错"
assert_sd 1

step "I5/I6 关闭（含幂等）"
"$LIDAWAKE" off >/dev/null 2>&1
assert_sd 0
if /usr/bin/pmset -g assertions | grep -q "LidAwake"; then
    bad "I5 断言未释放"
else
    ok "I5 断言已释放"
fi
"$LIDAWAKE" off >/dev/null 2>&1 && ok "I6 重复关闭幂等" || bad "I6 重复关闭报错"

step "I7 定时到点自动关闭"
"$LIDAWAKE" on --for 6s >/dev/null 2>&1
assert_sd 1
echo "     等待 10s…"
sleep 10
[ "$(sfield mode.kind)" = "off" ] && ok "I7 到点已自动关闭" || bad "I7 仍是 $(sfield mode.kind)"
assert_sd 0
REASON="$(sfield lastReleaseReason)"
[ "$REASON" = "timerExpired" ] && ok "I7 结束原因 = timerExpired" || bad "I7 结束原因 = $REASON"

step "I8 崩溃恢复（kill -9 后 launchd 拉起并重新接管）"
"$LIDAWAKE" on >/dev/null 2>&1
OLD_PID="$(daemon_pid)"
kill -9 "$OLD_PID" 2>/dev/null
NEW_PID=""
for _ in $(seq 1 30); do
    sleep 0.5
    P="$(daemon_pid)"
    if [ -n "$P" ] && [ "$P" != "$OLD_PID" ]; then NEW_PID="$P"; break; fi
done
[ -n "$NEW_PID" ] && ok "I8 launchd 已拉起新进程 (pid $OLD_PID → $NEW_PID)" || bad "I8 未被拉起"
assert_sd 1
[ "$(sfield mode.kind)" = "indefinite" ] && ok "I8 会话状态已从磁盘恢复" || bad "I8 状态丢失: $(sfield mode.kind)"

step "I9 失效安全：bootout 时必须放开 SleepDisabled"
launchctl bootout "system/$LABEL" 2>/dev/null
sleep 1.5
assert_sd 0
pgrep -x lidawaked >/dev/null && bad "I9 进程仍在" || ok "I9 进程已退出"

step "I10 重新加载"
launchctl bootstrap system "$PLIST" 2>/dev/null
sleep 1
[ "$(sfield mode.kind)" = "off" ] && ok "I10 重载后为关闭状态" || bad "I10 状态 = $(sfield mode.kind)"

step "I11 安全策略立即拦下"
ON_AC="$(sfield onExternalPower)"
if [ "$ON_AC" = "false" ]; then
    OUT="$("$LIDAWAKE" on --require-ac 2>&1)"; RC=$?
    [ "$RC" = "3" ] && ok "I11 退出码 3（被安全策略拦下）" || bad "I11 退出码 $RC"
    assert_sd 0
    R="$(sfield lastReleaseReason)"
    [ "$R" = "requiresExternalPower" ] && ok "I11 原因 = requiresExternalPower" || bad "I11 原因 = $R"
    "$LIDAWAKE" guards --require-ac off >/dev/null 2>&1
else
    "$LIDAWAKE" guards --require-ac on >/dev/null 2>&1
    "$LIDAWAKE" on >/dev/null 2>&1
    [ "$(sfield active)" = "true" ] && ok "I11 接电 + 需接电源 → 正常开启（正向路径）" \
        || bad "I11 接电时被误拦: $(sfield lastReleaseReason)"
    skip "I11 反向路径需要拔掉电源，本次跳过（当前接通电源）"
    "$LIDAWAKE" off >/dev/null 2>&1
    "$LIDAWAKE" guards --require-ac off >/dev/null 2>&1
fi

step "I12 服务端拒绝越界时长"
"$LIDAWAKE" on --for 3000000 >/dev/null 2>&1
RC=$?
[ "$RC" != "0" ] && ok "I12 越界时长被拒（退出码 $RC）" || bad "I12 越界时长被接受了"
assert_sd 0

step "I13/I14 空闲自退（零常驻开销）与按需重启"
"$LIDAWAKE" off >/dev/null 2>&1
if [ "$SKIP_SLOW" = "1" ]; then
    skip "I13 跳过（SKIP_SLOW=1）"
else
    echo "     等待 135s 观察空闲自退…"
    sleep 135
    if pgrep -x lidawaked >/dev/null; then
        bad "I13 关闭状态下守护进程仍在常驻"
    else
        ok "I13 关闭状态下守护进程已自退（0 个常驻进程）"
    fi
    [ "$(sfield mode.kind)" = "off" ] && ok "I14 按需重新拉起并可正常查询" || bad "I14 查询失败"
fi

step "I15 能耗：会话激活期间 CPU 占用"
"$LIDAWAKE" on >/dev/null 2>&1
P="$(daemon_pid)"
sleep 20
CPU_TIME="$(ps -o time= -p "$P" 2>/dev/null | tr -d ' ')"
RSS="$(ps -o rss= -p "$P" 2>/dev/null | tr -d ' ')"
echo "     lidawaked pid=$P CPU 累计=$CPU_TIME RSS=${RSS}KB"
case "$CPU_TIME" in
    0:00.*|00:00*|0:00) ok "I15 CPU 累计 < 1s（事件驱动，无轮询）" ;;
    *) bad "I15 CPU 累计偏高: $CPU_TIME" ;;
esac
if [ -n "$RSS" ] && [ "$RSS" -lt 32768 ]; then
    ok "I15 RSS ${RSS}KB < 32MB"
else
    bad "I15 RSS 偏高: ${RSS}KB"
fi
"$LIDAWAKE" off >/dev/null 2>&1
assert_sd 0

echo ""
echo "=================="
echo "通过 $PASS / 失败 $FAIL"
[ "$FAIL" = "0" ] && echo "✅ 集成测试全部通过" || echo "❌ 有失败项"
echo ""
echo "最近日志:"
tail -12 /var/log/lidawaked.log 2>/dev/null || echo "(无日志)"
exit "$FAIL"
