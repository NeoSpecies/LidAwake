# LidAwake — 技术选型与设计规格（SPEC）

## 1. 目标机器实测环境

| 项 | 值 | 影响 |
|---|---|---|
| macOS | 26.5 (25F71) | 支持全部所用 API |
| 硬件 | MacBook Pro `Mac17,6`，Apple M5 Max，18 核，128GB | arm64 单架构即可 |
| 工具链 | `/Library/Developer/CommandLineTools`，Swift 6.3.3 | **只有 CLT，没有完整 Xcode** |
| XCTest / swift-testing | **不可用**（CLT 未附带 `Testing` / `XCTest` swift module，已实测 `swift test` 失败） | → 自建轻量测试 harness（可执行 target） |
| 代码签名身份 | `security find-identity -v -p codesigning` → **0 valid identities** | → 只能 ad-hoc（`codesign -s -`）→ 排除 `SMAppService.daemon` |
| sudo | 需要密码，`/etc/pam.d/sudo_local` 不存在（无 sudo 触控 ID） | → 特权操作必须走 GUI 授权框（`osascript ... with administrator privileges`，支持触控 ID） |
| 当前电源 | 电池 67% | E2E 建议接电源做 |
| 已有干扰 | `pid 3481 (Kaka)` 持有 `NoDisplaySleepAssertion "ShadowstarKit No Sleep"` 已 253 小时 | 诊断面板需要暴露这类第三方断言 |

## 2. 关键 API 实测结论（全部在本机跑过）

```
dlopen(/System/Library/Frameworks/IOKit.framework)            → ok
dlsym("IOPMCopySystemPowerSettings")                          → ok，非 root 可读
  返回: {"SleepDisabled": 0, "Update DarkWakeBG Setting": 1}
dlsym("IOPMSetSystemPowerSetting")                            → ok
  非 root 调用 → 0xe00002c1 == kIOReturnNotPrivileged   ← 证实必须 root
IOPMAssertionCreateWithName("PreventUserIdleSystemSleep")     → rc=0，普通用户可用
IOPSCopyPowerSourcesInfo / IOPSGetPowerSourceDescription      → ok（state=Battery Power, 67/100）
IORegistryEntryCreateCFProperty(IOPMrootDomain,"AppleClamshellState")     → 0（盖子打开）
IORegistryEntryCreateCFProperty(IOPMrootDomain,"AppleClamshellCausesSleep") → 0
ProcessInfo.thermalState                                      → 0 (.nominal)
mach_continuous_time() - mach_absolute_time()                 → 3423 秒
```

最后一条是本设计里最有价值的发现：

> `mach_absolute_time()` **在系统睡眠期间停止推进**，`mach_continuous_time()` **继续推进**。
> 两者之差 = 开机以来累计睡眠时长。

因此 **"刚才那次合盖到底睡没睡、睡了多久"可以被精确、确定性地测量**，不需要靠猜日志。这是 `lidawake-probe` 的核心原理，也让 E2E 从"感觉可以"变成一个可量化的断言。

`AppleClamshellCausesSleep` 在盖子打开、纯电池、无外设的状态下就已经是 0，说明它**不能**用来预测合盖是否会睡 → 只作为原始诊断信息展示，不参与任何决策逻辑。

## 3. 机制设计：双层

| 层 | 手段 | 需要 root | 能拦住合盖睡眠吗 | 备注 |
|---|---|---|---|---|
| L1 断言层 | `IOPMAssertionCreateWithName`：`PreventUserIdleSystemSleep` + `PreventSystemSleep` | 否 | **仅接通电源时可能有效**（等价 `caffeinate -s`；Amphetamine 走的就是这层，所以它要求接电源/外接显示器/外接键鼠） | 立即生效，`pmset -g assertions` 可见 |
| L2 系统设置层 | `IOPMSetSystemPowerSetting("SleepDisabled", true)`（= `pmset -a disablesleep 1`） | **是** | **是，含纯电池** | 系统级持久设置，进程退出后仍生效 → 必须有失效安全 |

默认 = **两层同时施加**。理由：
- L2 是可靠性来源；
- L1 成本≈0，且提供三个额外价值：(a) 守护进程未安装时的降级路径（"受限模式"），(b) `pmset -g assertions` 里能看到是谁干的，(c) 万一 L2 施加失败（私有符号消失 + pmset 也失败）仍能拦住 idle 睡眠。

L1 **不包含** `PreventUserIdleDisplaySleep`。合盖时让屏幕正常关掉，省电、少发热。仅当用户显式勾选"合盖时同时保持屏幕唤醒"才加上。

### L2 的两条实现路径（自动降级）

```
setSleepDisabled(true):
  1. dlsym("IOPMSetSystemPowerSetting")  → 调用      （~微秒级，无 fork）
  2. 回读 IOPMCopySystemPowerSettings() 校验是否真的变了
  3. 若 1 或 2 失败 → /usr/bin/pmset -a disablesleep 1（fork+exec，~20ms）
  4. 再次回读校验；仍失败 → 返回错误，UI 显示"机制降级为仅断言层"
```
**任何"已开启"状态都必须以回读结果为准**，不接受乐观假设。

## 4. 技术选型

| 决策点 | 选择 | 理由 / 被否方案 |
|---|---|---|
| 语言 | Swift 6.3（`swift-tools-version:6.0`，`swiftLanguageMode(.v5)`） | 系统原生、零依赖。用 v5 语言模式避免为一个菜单栏小工具付严格并发的复杂度税 |
| 构建 | **SwiftPM** + 手工组装 `.app` bundle（`scripts/build.sh`） | 本机无完整 Xcode，`xcodebuild` 无法构建 app target。SwiftPM 可产出可执行文件，bundle 手工拼即可 |
| UI 框架 | **AppKit `NSStatusItem` + `NSMenu`** | SwiftUI `MenuBarExtra` 要拉起 SwiftUI 运行时（内存/启动开销更大），且菜单行为可控性差。性能预算优先 → AppKit |
| 依赖 | **0 个第三方包** | 原生要求 |
| 特权模型 | 经典 `/Library/LaunchDaemons` + 一次性 GUI 授权安装 | **否决 `SMAppService.daemon`**：要求 app 有有效签名，本机 0 个签名身份，ad-hoc 下不可靠。**否决每次 `osascript` 提权**：每次开关都弹密码，UX 不可接受 |
| 进程间通信 | **NSXPCConnection**（Mach service，双向） | 否决"共享文件 + kqueue 监听"：没有请求/响应语义，拿不到错误原因。否决 UNIX socket：要自己做成帧和生命周期。XPC 天然有 `effectiveUserIdentifier` 鉴权和连接失效回调 |
| 序列化 | XPC 接口只传 `Data`（内含 JSON `Codable`） | 避免 `NSSecureCoding` 类白名单的坑；`NSData`/`NSString` 本来就在默认允许集合里 |
| 守护进程生命周期 | `RunAtLoad=true` + `KeepAlive={SuccessfulExit:false}` + 空闲 120s 主动 `exit(0)` | 关闭时零常驻进程（按需 MachServices 拉起）；崩溃必被拉起；正常退出不被拉起 |
| 测试框架 | **自建 harness**（`Sources/LidAwakeTests` 可执行 target） | CLT 无 XCTest/Testing（已实测）。核心逻辑设计为纯函数，harness 足够 |
| 登录启动 | `~/Library/LaunchAgents/*.plist`（`RunAtLoad`，不设 KeepAlive） | 不需要授权；`SMAppService.mainApp` 在 ad-hoc 签名下不可靠 |

## 5. 架构

```
                        ┌──────────────────────────────┐
   用户点菜单 ─────────▶ │  LidAwake.app (uid=501)      │
                        │  AppKit NSStatusItem          │
                        │  LSUIElement=1, 无窗口         │
                        └───────────┬──────────────────┘
   脚本 / Agent ───────▶ ┌──────────┴──────────┐
                        │ lidawake (CLI)      │
                        └──────────┬──────────┘
                                   │ NSXPCConnection(machServiceName:
                                   │   "com.cogito.lidawaked", .privileged)
                                   │ 双向：请求/响应 + 状态推送
                        ┌──────────▼───────────────────────────────┐
                        │ lidawaked (uid=0, launchd system domain) │
                        │                                          │
                        │  ┌────────────────────────────────────┐  │
                        │  │ Engine.evaluate(session,guards,env)│  │ ← 纯函数，全部单测在这
                        │  │        → .keepAwake / .release(r)  │  │
                        │  └────────────────────────────────────┘  │
                        │  SleepDisabledController (dlsym→pmset)   │ L2
                        │  AssertionHolder (IOPMAssertion)         │ L1
                        │  PowerSourceMonitor (IOPS 通知，无轮询)    │ 事件源
                        │  ThermalMonitor (NSProcessInfo 通知)      │ 事件源
                        │  DeadlineTimer (DispatchSourceTimer)     │ 事件源
                        │  StateStore (/Library/Application        │
                        │      Support/LidAwake/state.json)        │
                        └──────────────────────────────────────────┘

  lidawake-probe (独立，不依赖守护进程)：mach 时钟差 + 网卡状态 → 合盖连续性报告
```

安装布局：
```
/Applications/LidAwake.app/Contents/
    Info.plist                      LSUIElement=1
    MacOS/LidAwake                  菜单栏 App
    Resources/lidawaked             守护进程副本（供安装脚本拷贝）
    Resources/lidawake              CLI 副本
    Resources/lidawake-probe        探针副本
    Resources/install-helper.sh     特权安装脚本
    Resources/uninstall-helper.sh   特权卸载脚本
/usr/local/libexec/lidawaked                        root:wheel 0755
/usr/local/bin/lidawake                             root:wheel 0755（软链或副本）
/usr/local/bin/lidawake-probe                       root:wheel 0755
/Library/LaunchDaemons/com.cogito.lidawaked.plist   root:wheel 0644
/Library/Application Support/LidAwake/state.json    root:wheel 0600
/var/log/lidawaked.log                              root:wheel 0644
~/Library/LaunchAgents/com.cogito.LidAwake.plist    登录启动（可选）
```

launchd 要求 plist 与被执行程序不可被非 root 写入，故 `/usr/local/libexec` 下的文件必须 `root:wheel`（Homebrew 会把 `/usr/local` 设为用户可写 → 安装脚本显式 `chown root:wheel` 并校验目录属主，若 `/usr/local/libexec` 属主不是 root 则改用 `/Library/PrivilegedHelperTools/`）。

## 6. 状态机与决策引擎

```swift
enum Mode { case off, indefinite, until(Date) }

struct Guards {
    var batteryFloorPercent: Int?     // nil=不启用；默认 20；仅电池供电时判定
    var requireExternalPower: Bool    // 默认 false
    var releaseOnCriticalThermal: Bool// 默认 true
    var maxSessionSeconds: Double?    // 默认 43200 (12h)；nil=无限制
    var keepDisplayAwake: Bool        // 默认 false
    var persistAcrossReboot: Bool     // 默认 false
}

struct Session { var mode: Mode; var startedAt: Date; var origin: String }

struct Env { var now: Date; var onExternalPower: Bool; var batteryPercent: Int?; var thermal: ThermalLevel }

enum ReleaseReason { userOff, timerExpired, maxSessionReached, batteryFloor,
                     requiresExternalPower, criticalThermal }

enum Decision { case keepAwake, release(ReleaseReason) }
```

`Engine.evaluate` 判定顺序（**顺序即优先级，写死并单测**）：

1. `mode == .off` → `release(.userOff)`
2. `case .until(d)`，`now >= d` → `release(.timerExpired)`
3. `maxSessionSeconds != nil` 且 `now >= startedAt + max` → `release(.maxSessionReached)`
4. `requireExternalPower` 且 `!onExternalPower` → `release(.requiresExternalPower)`
5. `releaseOnCriticalThermal` 且 `thermal == .critical` → `release(.criticalThermal)`
6. `batteryFloor != nil` 且 `!onExternalPower` 且 `battery <= floor` → `release(.batteryFloor)`
7. 否则 → `keepAwake`

`Engine.nextEvaluation(session:guards:) -> Date?` = `min(deadline, startedAt+max)`，都没有则 `nil`（不装定时器）。电量/温度变化由通知驱动；额外挂一个 **5 分钟心跳**仅在会话激活期间兜底（唤醒开销可忽略，leeway 30s）。

引擎是纯函数：**不读时钟、不读 IOKit**，`Env` 全部由外部注入 → 100% 可单测，这是把睡眠这种"没法在 CI 里复现"的逻辑变得可测的关键。

## 7. XPC 接口与鉴权

```swift
@objc protocol DaemonAPI {                       // daemon 导出
    func ping(reply: @escaping (String) -> Void)                       // 版本握手
    func status(reply: @escaping (Data?, String?) -> Void)             // StatusDTO JSON
    func apply(_ request: Data, reply: @escaping (Data?, String?) -> Void) // ApplyRequest → StatusDTO
    func setGuards(_ guards: Data, reply: @escaping (Data?, String?) -> Void)
}

@objc protocol ClientAPI {                       // app/CLI 导出，daemon 反向推送
    func stateDidChange(_ status: Data)
}
```

`ApplyRequest` 只有三种形态：`off` / `indefinite` / `until(seconds:)`。**没有任何字段能表达路径、命令、shell 参数** —— 这是最重要的安全设计：即使鉴权被绕过，攻击面也只有"让这台机器不睡觉"。

鉴权（`listener(_:shouldAcceptNewConnection:)`）：
```
uid = connection.effectiveUserIdentifier
allow if uid == 0
allow if uid 对应用户属于 admin 组（getpwuid + getgrouplist）
otherwise reject（记日志：pid/uid/进程名）
```
输入校验（服务端做，不信客户端）：
- `until` 秒数 ∈ [5, 30*86400]，非 NaN/Inf
- `batteryFloorPercent` clamp 到 [5, 90]
- `maxSessionSeconds` ∈ [60, 30*86400] 或 nil

**已知局限（明确记录，不假装解决）**：本机无开发者证书，无法用 `SecCodeCheckValidity` + `requirement`（team id / bundle id）做客户端签名校验。因此任何本机 admin 用户的进程都能调用本服务。考虑到接口能力上限只是"阻止休眠"，且 admin 用户本来就能 `sudo pmset -a disablesleep 1`，**没有实质提权**。若将来拿到 Developer ID，在 `shouldAcceptNewConnection` 里补 `audit_token` + code requirement 校验即可（代码里已留 `AuthPolicy` 扩展点）。

## 8. 失效安全（Fail-safe）矩阵

| 事件 | 行为 | 实现位置 |
|---|---|---|
| 守护进程崩溃（信号/非 0 退出） | launchd 立即拉起 → 读 `state.json` → 重新施加并**回读校验** | `KeepAlive{SuccessfulExit:false}` + `Daemon.start()` |
| 守护进程收到 SIGTERM（关机 / `launchctl bootout` / 卸载） | 立即 `SleepDisabled=0` + 释放断言 + `mode=off` 落盘，再退出 | `SignalHandler` |
| 系统重启 | 启动时对比 `state.json` 里记录的 `kern.boottime`，不同且 `persistAcrossReboot=false` → 强制 `off` 并复位 `SleepDisabled=0` | `StateStore.reconcileBoot()` |
| App 崩溃 / 退出 | 会话**不受影响**（这是特性：Agent 长任务不能因为 UI 挂了就断）。守护进程只在 `mode==off` 且无客户端时才空闲自退 | `Daemon.idleTimer` |
| `state.json` 损坏 | 视为 `off`，改名为 `state.json.corrupt-<n>`，写新文件，记日志 | `StateStore.load()` |
| L2 施加失败 | 状态标 `degraded=true`，菜单显示"受限模式（仅断言层，需接通电源）" | `StatusDTO.mechanism` |
| 守护进程未安装 | App 以受限模式运行：只挂 L1 断言（App 自己挂，普通权限），菜单显式警告 | `LocalFallbackController` |
| 空闲自退时仍是激活状态 | **不退出**（`shouldIdleExit` 要求 `mode==off`） | `Daemon.idleTimer` |

## 9. 日志

- 守护进程：`/var/log/lidawaked.log`，追加，单行前缀 ISO8601 + level；**只记状态转换和错误，不记周期性心跳**（避免磨 SSD）。超过 2MB 自动截断为后 512KB。
- App / CLI：`OSLog` subsystem `com.cogito.LidAwake`。
- 不记录任何用户数据、进程命令行以外的信息；诊断里展示的第三方断言信息来自 `pmset -g assertions`，仅在用户主动点击时读取。

## 10. 构建产物与命令

```bash
scripts/build.sh          # swift build -c release + 组装 LidAwake.app + ad-hoc 签名
scripts/run-tests.sh      # 单元测试 harness
scripts/integration-test.sh  # 需 sudo：真机施加/回读/崩溃恢复/失效安全
scripts/install.sh        # 装 App + 弹一次系统授权框装守护进程
scripts/uninstall.sh      # 全量卸载并复位 SleepDisabled
```

Release 编译参数：`-O -wmo`（SwiftPM release 默认 whole-module），`MACOSX_DEPLOYMENT_TARGET=15.0`（`Package.swift` 里 `.macOS(.v15)`；本机 26.5，留一档向下兼容）。
