# LidAwake — 测试计划

## 0. 测试策略

睡眠行为天生难测（不能在脚本里"合上盖子"）。策略是把不可测的部分压缩到最小：

```
纯函数决策引擎 ──────────► L1 单元测试（26 例，无 IO、无时钟、无 root）
真机施加 / 回读 / 恢复 ──► L2 集成测试（需 sudo，脚本自动化）
"合盖到底睡没睡" ────────► L3 E2E（唯一需要人手合盖，但结论可量化：mach 时钟差）
```

L3 之所以能成为**断言**而不是"感觉"，靠的是 `mach_continuous_time() - mach_absolute_time()`：
该差值只在系统睡眠时增长。合盖前后各采一次，差值增量 > 1s 即判定 `slept=true`。这是确定性的，不依赖日志解析。

## 1. L1 单元测试（`scripts/run-tests.sh`）

无 XCTest（CLT 限制），用自建 harness：`expect(cond, "name")`，失败累计，非 0 退出。

### 决策引擎优先级
| # | 场景 | 期望 |
|---|---|---|
| 1 | `mode=off` | `release(.userOff)` |
| 2 | `mode=off` 且同时电量低 | `release(.userOff)`（用户意图优先） |
| 3 | `indefinite`，无守卫 | `keepAwake` |
| 4 | `until(now+60)` | `keepAwake` |
| 5 | `until(now-1)` | `release(.timerExpired)` |
| 6 | `until(now)`（边界，等号） | `release(.timerExpired)` |
| 7 | `indefinite`，`max=12h`，`startedAt=now-13h` | `release(.maxSessionReached)` |
| 8 | `indefinite`，`max=12h`，`startedAt=now-11h59m` | `keepAwake` |
| 9 | `until(now+60)` 但已超 `max` | `release(.maxSessionReached)`（截止未到但总时长到了） |
| 10 | `max=nil`，`startedAt=now-100h` | `keepAwake` |
| 11 | `requireExternalPower=true`，电池 | `release(.requiresExternalPower)` |
| 12 | `requireExternalPower=true`，接电 | `keepAwake` |
| 13 | 温度 `critical`，守卫开 | `release(.criticalThermal)` |
| 14 | 温度 `critical`，守卫关 | `keepAwake` |
| 15 | 温度 `serious`，守卫开 | `keepAwake`（只在 critical 放开） |
| 16 | `floor=20`，电池 19% | `release(.batteryFloor)` |
| 17 | `floor=20`，电池 20%（边界，`<=`） | `release(.batteryFloor)` |
| 18 | `floor=20`，电池 21% | `keepAwake` |
| 19 | `floor=20`，**接电** 5% | `keepAwake`（电量守卫只在电池供电时生效） |
| 20 | `floor=nil`，电池 1% | `keepAwake` |
| 21 | `floor=20`，`batteryPercent=nil`（无电池机型） | `keepAwake` |
| 22 | 定时到期 + 电量低同时成立 | `release(.timerExpired)`（顺序即优先级） |

### 定时计算
| # | 场景 | 期望 |
|---|---|---|
| 23 | `until(t)`，`max=nil` | `nextEvaluation == t` |
| 24 | `indefinite`，`max=12h` | `nextEvaluation == startedAt+12h` |
| 25 | `until(start+13h)`，`max=12h` | `nextEvaluation == startedAt+12h`（取更早） |
| 26 | `indefinite`，`max=nil` | `nil`（不装定时器） |
| 27 | `off` | `nil` |

### 编解码 / 校验 / 解析
| # | 场景 | 期望 |
|---|---|---|
| 28 | `PersistedState` JSON round-trip（含 `until` 日期） | 相等，日期误差 < 1ms |
| 29 | `Mode` 三态 round-trip | 相等 |
| 30 | `ApplyRequest.until(seconds: 0/-1/NaN/Inf/40天)` | 全部 `throw`/被拒 |
| 31 | `ApplyRequest.until(seconds: 5)` / `until(30天)` | 通过（边界内） |
| 32 | `Guards` 校验：`floor=0 → 5`，`floor=200 → 90`，`max=1 → 60` | clamp 生效 |
| 33 | 解析 `pmset -g` 输出提取 `SleepDisabled`（含 tab/多空格/缺失三种输入） | 正确 / 正确 / nil |
| 34 | `AuthPolicy.isAllowed(uid:0)` | true |
| 35 | `AuthPolicy.isAllowed(uid:501, groups:[80])` | true（80=admin） |
| 36 | `AuthPolicy.isAllowed(uid:501, groups:[20])` | false |
| 37 | 剩余时间格式化：`3661s → "1:01:01"`，`59s → "0:00:59"`，负数 → `"0:00:00"` | 相符 |
| 38 | 重启复位逻辑：`bootTime` 变化 + `persist=false` → `off` | 相符 |
| 39 | `bootTime` 变化 + `persist=true` → 保留会话 | 相符 |
| 40 | `bootTime` 未变 → 保留会话 | 相符 |
| 41 | 损坏 JSON → 返回默认 off 状态而非崩溃 | 相符 |
| 42 | 空闲自退判定：`off` + 0 客户端 → true；`indefinite` + 0 客户端 → **false** | 相符 |

## 2. L2 集成测试（`sudo scripts/integration-test.sh`）

驱动方式：真机安装后的守护进程 + `lidawake` CLI。每步都**回读系统真实状态**（`pmset -g` / `IOPMCopySystemPowerSettings`），不信 CLI 自报。

| # | 步骤 | 断言 |
|---|---|---|
| I1 | 初始 `lidawake status --json` | `mode=off`，`sleepDisabled=false` |
| I2 | 首次 `status` 时守护进程按需被 launchd 拉起 | `pgrep lidawaked` 非空 |
| I3 | `lidawake on` | `pmset -g \| grep SleepDisabled` → **1**；`pmset -g assertions` 含 `LidAwake` |
| I4 | 再次 `lidawake on`（幂等） | 仍为 1，无报错 |
| I5 | `lidawake off` | `SleepDisabled` → **0**；断言消失 |
| I6 | `lidawake off`（幂等） | 无报错 |
| I7 | `lidawake on --for 6s`，等 10s | 自动变 `off`，`SleepDisabled` → 0，`lastReleaseReason=timerExpired` |
| I8 | `lidawake on` 后 `kill -9 <lidawaked>` | 3s 内 launchd 拉起新 pid；`SleepDisabled` 仍为 1；`status` 仍 `indefinite` |
| I9 | `lidawake on` 后 `launchctl bootout system/com.cogito.lidawaked` | `SleepDisabled` → **0**（SIGTERM 失效安全）；进程不再存在 |
| I10 | 重新 `bootstrap` | 服务恢复，状态为 `off` |
| I11 | `lidawake on --require-ac` 在**电池**供电下 | 立即 `release(.requiresExternalPower)`，`SleepDisabled` 保持 0，CLI 返回原因 |
| I12 | `lidawake on --for 90000`（>30天上限外的值 3000000） | 被服务端拒绝，退出码非 0 |
| I13 | `lidawake off` 后等 130s | `pgrep lidawaked` 为空（空闲自退，零常驻） |
| I14 | 空闲自退后 `lidawake status` | 成功（按需重新拉起） |
| I15 | 全程 `lidawaked` CPU 时间 | 会话激活 60s 内累计 CPU < 0.5s |
| I16 | `scripts/uninstall.sh` 后 | `SleepDisabled`=0；无 plist；`pgrep lidawaked` 空 |

未覆盖并已记录原因：**非 admin 用户被拒**的用例需要新建一个标准用户账号，属于改动系统账号，不在本次自动化范围；`AuthPolicy` 已由 L1 #34–36 纯函数覆盖。

## 3. L3 E2E 合盖实测（`lidawake-probe`）

探针每 1s 采样：`mach_absolute_time`、`mach_continuous_time`、wall clock、Wi-Fi 接口 IPv4 是否存在（`getifaddrs`），可选 `--tcp host:port` 做真实连通性。写入 `~/.lidawake-probe/<run>.jsonl`。

`lidawake-probe report` 输出：
```
睡眠检测      : slept=false   (continuous-absolute 增量 0.00s)
最大采样间隔  : 1.03s         (>5s 视为进程被冻结)
网卡连续性    : en0 IPv4 全程存在 (0 次丢失 / 120 采样)
TCP 连通性    : 24/24 成功    (仅 --tcp 时)
判定          : PASS
```

### E2E-A 对照组（证明问题存在，也证明探针有效）
1. `lidawake off`（确认 `SleepDisabled=0`）
2. `lidawake-probe start`
3. **人工：合盖 40 秒，然后打开**
4. `lidawake-probe report` → 期望 **`slept=true`**，睡眠时长 ≈ 合盖时长

若这一步 `slept=false`，说明本机在当前条件下合盖本来就不睡（例如接了外接显示器），必须先排除干扰再继续，否则实验组结论无意义。

### E2E-B 实验组（证明工具有效）
1. `lidawake on`（确认 `SleepDisabled=1`）
2. `lidawake-probe start`
3. **人工：合盖 60 秒，然后打开**
4. `lidawake-probe report` → 期望 **`slept=false`**、最大采样间隔 < 5s、网卡全程在线
5. `lidawake off`

### E2E-C 长任务真实场景（可选，验证"Agent 不断"）
合盖期间跑 `while true; do date >> /tmp/lidawake-e2e.log; sleep 2; done`，开盖后检查日志时间戳无 > 6s 的空洞。

### E2E-D 断言层是否足够（回答 SPEC §3 的开放问题）
1. `lidawake off`，`caffeinate -s` 前台运行（只有 L1 的 `PreventSystemSleep`，**无 root**）
2. **接通电源**，合盖 60s
3. 探针报告 → 得出"L1 单独在 AC 下是否足够"的实测结论，写回 SPEC。

这一项决定了未来能否给没有管理员权限的机器提供"零授权模式"。

## 4. 性能验证

| # | 项 | 方法 | 阈值 |
|---|---|---|---|
| P1 | 关闭状态常驻进程数 | `pgrep -c lidawaked` | 0 |
| P2 | 守护进程激活态 RSS | `ps -o rss= -p <pid>` | < 8192 KB |
| P3 | App RSS | `ps -o rss=` | < 30720 KB |
| P4 | App 空闲 CPU（菜单关闭 60s） | `ps -o time=` 前后差 | < 0.2s |
| P5 | 开关往返延迟 | CLI 内置计时 `--timing` | < 50ms（含 XPC 往返） |
| P6 | 守护进程激活 60s CPU | 同 I15 | < 0.5s |

## 5. 回归清单（每次改动后跑）

```bash
scripts/build.sh && scripts/run-tests.sh          # 必跑
sudo scripts/integration-test.sh                  # 改守护进程/XPC/引擎时必跑
# 改机制层（L1/L2）时必跑 E2E-B
```
