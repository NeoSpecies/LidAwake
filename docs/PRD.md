# LidAwake — 产品规划（PRD）

## 0. 先纠正一个前提

你看到的两种网上做法，都不能真正解决"合盖继续跑"：

| 网传做法 | 实际效果 | 为什么 |
|---|---|---|
| `caffeinate -disu -t 3600` | **无效** | `-d/-i/-u` 建立的是 `PreventUserIdleDisplaySleep` / `PreventUserIdleSystemSleep` / `UserIsActive` 这类 **idle** 断言。合盖属于 **forced sleep（clamshell sleep）**，会绕过所有 idle 断言。只有 `caffeinate -s`（`PreventSystemSleep`）在**接通电源**时有机会拦住合盖睡眠，而这恰恰是教程里最少提到的那个参数。 |
| Amphetamine | 有效但有限制 | 它是 App Store 沙盒应用，拿不到 root，因此只能走断言路线 → 官方文档明确要求"接了电源 / 外接显示器 / 外接键鼠"之一。**纯电池 + 无外设合盖，它也保不住。** |

真正 100% 可靠（含纯电池）的只有一条路：把系统级 `SleepDisabled` 置 1（`pmset -a disablesleep 1` 走的就是这个），**需要 root**。

本机已实测确认（见 `docs/SPEC.md` §2）：
- 非 root 调 `IOPMSetSystemPowerSetting("SleepDisabled")` → `kIOReturnNotPrivileged (0xe00002c1)`
- 读取 `IOPMCopySystemPowerSettings()` 非 root 可用，当前 `SleepDisabled = 0`

所以产品设计必须是 **双层机制 + 一次授权的特权守护进程**，而不是简单包一层 `caffeinate`。

## 1. 目标用户与场景

主用户：**在 Mac 上跑长时间 AI Agent / 编译 / 训练 / 下载的开发者（就是你）**。

核心场景：
1. **S1 合盖带走**：Agent 正在跑一个 20 分钟的任务，我要合盖去开会，回来时它应该已经跑完，SSH / API 连接不断。
2. **S2 定时保护**：只想保护接下来 2 小时，之后自动恢复正常省电，避免忘关把电池跑干。
3. **S3 脚本联动**：Agent / Makefile 在任务开始前自己 `lidawake on --for 2h`，结束后 `lidawake off`——不需要人操作。
4. **S4 出门在外**：纯电池、没有外接显示器，也要能合盖续跑（这是 Amphetamine 做不到的那一格）。
5. **S5 别把机器搞坏**：电量过低、机身过热、超过最长时限时必须**自动放开**，不能让机器一直不睡把电池干到 0% 或者高温烤着。

非目标（明确不做）：
- 不做防止**屏幕**变暗/锁屏的功能（那是安全风险，且系统设置里已有）。默认让屏幕正常休眠，只保系统不睡。
- 不做窗口界面、不做偏好设置窗口。菜单栏一个图标搞定。
- 不做外接显示器管理、不做屏幕分辨率切换。
- 不做云同步、不做账号、不联网（除自检里的可选连通性探测）。

## 2. 产品形态

macOS 原生**菜单栏状态项**（`LSUIElement`，无 Dock 图标、无窗口）+ 一个 root 守护进程 + 一个 CLI。

```
LidAwake.app        菜单栏 UI（普通用户权限）
lidawake            CLI，给脚本 / Agent 用
lidawaked           特权守护进程（root，launchd 托管，按需启动、空闲自退）
lidawake-probe      合盖连续性自检工具（验证"真的没睡、真的没断网"）
```

## 3. 功能清单（P0 = 首版必须）

### P0 核心
| 编号 | 功能 | 验收标准 |
|---|---|---|
| F1 | 一键开启"合盖续跑"（无限期） | 合盖 ≥60s 再打开，`lidawake-probe` 报告 `slept=false`，网络无中断 |
| F2 | 定时开启（15m/30m/1h/2h/4h/8h/自定义） | 到点自动关闭，`SleepDisabled` 回到 0 |
| F3 | 一键关闭，立即恢复系统默认省电行为 | `pmset -g \| grep SleepDisabled` → 0，断言全部释放 |
| F4 | 菜单栏状态可视：关闭 / 已开启 / 剩余时间 / 受限模式 | 图标 + 可选倒计时文字 |
| F5 | 双层机制自动选择：断言层（无需 root）+ SleepDisabled 层（root） | 守护进程未安装时以"受限模式"运行并明确提示局限 |
| F6 | 一次性授权安装特权服务（系统原生授权框，支持触控 ID） | 装完后所有开关操作**不再要密码** |
| F7 | CLI：`lidawake on/off/status/probe` | `status --json` 输出可被脚本解析 |

### P0 安全守卫（缺一个都不能发）
| 编号 | 功能 | 默认值 |
|---|---|---|
| G1 | 电量低于阈值自动关闭（仅电池供电时生效） | 20% |
| G2 | 仅在接通电源时保持 | 关（S4 需要电池也能用） |
| G3 | 机身温度到 `critical` 自动关闭 | 开 |
| G4 | 单次会话最长时限 | 12 小时 |
| G5 | 重启后不自动恢复（失效安全） | 开（即不恢复） |
| G6 | 守护进程收到 SIGTERM（卸载/关机/`bootout`）立即放开 SleepDisabled | 固定行为 |
| G7 | 守护进程崩溃 → launchd 拉起 → 读持久化状态重新施加 | 固定行为 |

### P1（本次一并实现，成本低）
- 诊断子菜单：SleepDisabled 实值、上盖状态、电源/电量、温度、**其他正在阻止休眠的进程**（本机实测发现有个 `Kaka` 进程已经挂了 253 小时的 `NoDisplaySleepAssertion`，这种东西必须能看见）。
- 登录时自动启动（`~/Library/LaunchAgents`，不需要授权）。
- 自检：合盖连续性测试（对照组 + 实验组）。
- 一键复制诊断信息到剪贴板。

### P2（不做，记录在案）
- 全局快捷键（需要辅助功能权限，成本/收益不划算）
- "某进程存活期间保持唤醒"（`lidawake on --while-pid N`）——留接口不做 UI
- 通知中心提醒（守卫触发时）——守护进程发通知需要走 App 中转，首版只写日志

## 4. 交互设计（菜单）

```
┌──────────────────────────────────────┐
│ 已开启 · 剩余 1:59:31                 │  ← 禁用项，等宽字体
│ 机制: SleepDisabled + 断言            │
├──────────────────────────────────────┤
│ 开启（无限期）                        │
│ 定时开启                            ▸ │ → 15 分钟 / 30 分钟 / 1 小时 / 2 小时
│                                      │    4 小时 / 8 小时 / 自定义…
│ 关闭                          ⌘.     │
├──────────────────────────────────────┤
│ 安全策略                            ▸ │ → ✓ 电量低于 20% 自动关闭 ▸
│                                      │    ☐ 仅在接通电源时保持
│                                      │    ✓ 机身过热时自动关闭
│                                      │    ✓ 单次最长 12 小时 ▸
│                                      │    ☐ 合盖时同时保持屏幕唤醒（费电）
│ 诊断                                ▸ │ → SleepDisabled = 1
│                                      │    上盖: 打开 / 电源: 电池 67%
│                                      │    温度: 正常
│                                      │    其他阻止休眠的进程 (1) ▸
│                                      │    复制诊断信息 / 打开日志
├──────────────────────────────────────┤
│ ✓ 登录时启动                          │
│ 安装 / 修复后台服务…                   │
│ 自检（合盖连续性测试）…                 │
├──────────────────────────────────────┤
│ 关于 LidAwake                         │
│ 退出                          ⌘Q     │
└──────────────────────────────────────┘
```

图标语义（SF Symbols，带 fallback 链）：

| 状态 | 图标 | 说明 |
|---|---|---|
| 关闭 | `powersleep` | 普通线条 |
| 已开启（无限期） | `infinity.circle.fill` | 实心，一眼看出在生效 |
| 已开启（定时） | `timer` + 可选剩余分钟文字 | |
| 受限模式（服务未装） | `exclamationmark.triangle` | 点开有安装引导 |
| 守卫已触发刚自动关闭 | `bolt.slash.fill`（5 秒后回落） | |

关键交互原则：
- **开启必须在 200ms 内在图标上体现**，并且状态来自守护进程回读的**真实** `SleepDisabled` 值，不是 UI 自己的乐观状态。
- 关闭是幂等的，随便点多少次都安全。
- 任何守卫触发导致的自动关闭，菜单顶部会显示原因（"因电量低于 20% 已自动关闭"），直到用户下次操作。

## 5. 性能与能耗预算（"性能最好"的量化定义）

| 指标 | 预算 | 手段 |
|---|---|---|
| 空闲 CPU（App） | 0.0%（无菜单打开时无定时器） | 状态由 XPC **推送**，不轮询 |
| 空闲 CPU（守护进程） | 0.0% | IOKit 通知 + dispatch timer，无轮询循环 |
| 关闭状态 + 无客户端连接时的守护进程 | **0 个进程** | 空闲 120s 自动 `exit(0)`，launchd 按需（MachServices）拉起 |
| 关闭状态 + 菜单栏 App 在运行 | < 8 MB / 0% CPU 常驻 | App 保持一条 XPC 连接以接收推送，此时守护进程不自退（见 docs/REVIEW.md R3-3 的取舍说明） |
| 开启状态下守护进程 RSS | < 20 MB（实测 15.7 MB） | 纯 Foundation，不链 AppKit |
| App RSS | < 48 MB（实测 43 MB，AppKit 基线） | AppKit `NSStatusItem`，**不用 SwiftUI 运行时**，无窗口、无 Dock |
| 开关延迟 | < 5 ms | 直接 IOKit 调用（`dlsym`），不 fork `pmset` |
| 唤醒次数 | 定时会话每分钟 ≤1 次（tolerance 10s） | `DispatchSourceTimer` + leeway |

对比基线：`caffeinate` 常驻一个进程 + `Amphetamine` 常驻 App（约 60–90MB）。LidAwake 在**关闭状态下开销为零个进程**（除菜单栏 App 自身）。

## 6. 风险与对策

| 风险 | 等级 | 对策 |
|---|---|---|
| 忘记关闭 → 电池耗尽 | 高 | G1 电量守卫（默认 20%）+ G4 最长 12h + 菜单栏图标实心高亮 |
| 合盖长时间高负载 → 过热 | 中 | G3 温度守卫；合盖时**不**保持屏幕唤醒（默认），减少发热 |
| 守护进程挂了但 SleepDisabled 还是 1 | 中 | `SleepDisabled` 是系统持久设置，进程死了机器仍不睡 → 用 `KeepAlive{SuccessfulExit=false}` 让 launchd 立刻拉起并重新接管；开机时无条件复位为 0 |
| 卸载后残留不睡状态 | 中 | G6 SIGTERM 放开 + `uninstall.sh` 显式复位 |
| 无开发者证书，只能 ad-hoc 签名 | 中 | 放弃 `SMAppService.daemon`（要求有效签名），改用经典 `/Library/LaunchDaemons` + 一次性授权安装。XPC 鉴权改为 **uid + admin 组**校验（局限已在 SPEC §7 记录） |
| 私有符号 `IOPMSetSystemPowerSetting` 未来消失 | 低 | `dlsym` 动态解析，找不到就回退 `/usr/bin/pmset -a disablesleep 1`，不会启动失败 |
| macOS 26 上 clamshell 行为变化 | 低 | E2E 实测验证（对照组 + 实验组），并在 SPEC 里区分"断言层是否足够"的实测结论 |

## 7. 发布验收（Definition of Done）

1. `scripts/run-tests.sh` 全绿（单元测试）。
2. `sudo scripts/integration-test.sh` 全绿（含崩溃恢复、bootout 失效安全、定时到点自动关闭）。
3. 本机 E2E：对照组合盖 30s → 探针报告 `slept=true`；实验组合盖 60s → 探针报告 `slept=false` 且网络无中断。
4. 关闭状态且无客户端连接时 `pgrep lidawaked` 为空（零常驻开销）。
5. 卸载后 `pmset -g | grep SleepDisabled` → 0，且 `/Library/LaunchDaemons` 无残留。
