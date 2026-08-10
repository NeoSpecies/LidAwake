# LidAwake — 多轮评审记录

每一轮都实际改了代码，下面记录的是**发现的问题**和**改法**，不是清单式自我表扬。

---

## R1 — 正确性 / API 用法

| # | 问题 | 严重度 | 改法 |
|---|---|---|---|
| R1-1 | `SystemInfo.powerState()` 只认内置电池，但如果机器**没有**内置电池却接了 UPS，列表非空、循环走完也找不到内置电池 → `onExternalPower` 停在 `false`。后果：台式机 + UPS 上 `requireExternalPower` 守卫**永远误触发**，一开就被立刻关掉。 | 高 | 增加 `foundInternalBattery` 标记，找不到内置电池就返回 `onExternalPower: true, batteryPercent: nil` |
| R1-2 | 探针的 SIGTERM handler 在 `for` 循环里创建 `DispatchSourceSignal`，局部变量出作用域即释放 → 信号源被取消，`stop` 实际上依赖默认行为，而 `signal(sig, SIG_IGN)` 又把默认行为屏蔽了 → **`lidawake-probe stop` 杀不掉采样进程**。 | 高 | 干脆去掉信号处理：默认 SIGTERM 直接终止即可。每个采样点是一次完整 `write`，不会写出半行；`report` 也会跳过无法解析的行 |
| R1-3 | 探针子进程没有脱离控制终端，调用方 shell 一关就被 SIGHUP 带走 —— 而采样**必须**跨越整个"合盖—开盖"过程。 | 高 | `runLoop` 开头调用 `setsid()` |
| R1-4 | 菜单栏图标：先在"取不到 SF Symbol"时设了文字兜底，紧接着又被倒计时分支无条件覆盖成 `""` → 图标和文字**同时为空**，菜单栏出现一个看不见的空位。 | 中 | 合并成一次 title 计算 |
| R1-5 | `menuNeedsUpdate` 里 `refresh()` 是异步的，菜单用的是**上一次**的状态；启动后第一次打开菜单会显示错的值。 | 中 | 加 `menuIsOpen` 标记；状态到达后若菜单仍开着就就地 `rebuild(menu)` |
| R1-6 | `terminate()` 无条件把 `mode` 清成 `off`，这让「重启后恢复上次会话」这个选项**根本不可能生效**（关机时正好走 SIGTERM）。 | 中 | 只有 `persistAcrossReboot == false` 时才清 mode；SleepDisabled 无论如何都放开 |
| R1-7 | `setMode` 的守卫条件 `status != nil \|\| lastError == nil` 语义含糊，会在守护进程装了但暂时连不上时静默转入受限模式，且不释放，可能出现"守护进程和 App 同时在挂断言"。 | 中 | 改成：装了就一定走守护进程；失败才退回受限模式**并弹窗说明局限**；每次守护进程接管时主动 `limited.apply(.off)` |
| R1-8 | `main.swift` 单实例判断用 pid 大小比较"谁先启动"，pid 会回绕，逻辑不可靠。 | 低 | 改为"已有其它未终止实例 → 本次直接退出" |

## R2 — 安全 / 权限

| # | 检查项 | 结论 |
|---|---|---|
| R2-1 | XPC 攻击面 | `ApplyRequest` 只能表达 `off` / `indefinite` / `until(seconds)`，**没有任何字段能表达路径、命令、shell 参数**。即使鉴权被绕过，能力上限也只是"让这台机器不睡觉"。这是本设计最重要的一条安全属性 |
| R2-2 | 客户端鉴权 | `uid == 0 或 admin 组成员`。**已知局限**：本机 0 个代码签名身份，无法用 `SecCodeCheckValidity` + code requirement 校验调用方。但 admin 用户本来就能 `sudo pmset -a disablesleep 1`，所以不构成提权。`AuthPolicy` 留了扩展点，拿到 Developer ID 后补 audit_token 校验即可 |
| R2-3 | 服务端输入校验 | 时长 ∈ [5s, 30d] 且必须有限；`Guards` 全部 clamp。校验在**服务端**做，不信客户端（L1 #30–32 覆盖） |
| R2-4 | 子进程执行 | 只 exec `/usr/bin/pmset`、`/bin/launchctl`、`/usr/bin/osascript`，全部绝对路径、参数数组传递（无 shell 拼接），不依赖 PATH |
| R2-5 | 文件权限 | 守护进程二进制 `root:wheel 0755`、plist `root:wheel 0644`（launchd 硬要求）、`state.json 0600`、状态目录 `0700`。守护进程**不放在 `/usr/local`**（Homebrew 会把它设成用户可写），而是 `/Library/PrivilegedHelperTools` |
| R2-6 | 密码处理 | 本程序全程接触不到密码：授权由 `osascript ... with administrator privileges` 弹**系统原生对话框**收集（支持触控 ID） |
| R2-7 | 日志内容 | 只记状态转换与错误。第三方断言信息来自 `pmset -g assertions`，且只在用户主动点「诊断」时读取 |
| R2-8 | 私有符号 | `IOPMSetSystemPowerSetting` 通过 `dlsym` 动态解析，符号消失只会降级到 `pmset`，不会启动失败 |

## R3 — 失效模式与能耗

| # | 问题 | 改法 |
|---|---|---|
| R3-1 | 关闭状态下每 1% 电量变化都会触发一次完整 `reconcile`（IOKit 读 + 状态广播），而此时**没有任何可判定的东西**。 | `reconcile` 开头：`mode == off` 且 trigger 是 `notify:*` → 直接返回 |
| R3-2 | `Log` 同时写文件和 stderr，而 launchd 把 stderr 收进 `lidawaked.err.log` → 每条日志**存了两遍**。 | 有文件时不再写 stderr；只在写文件失败时兜底到 stderr |
| R3-3 | PRD 里"关闭状态下守护进程内存 = 0"这个说法**不准确**：菜单栏 App 会保持一条 XPC 连接，而 `shouldIdleExit` 要求 `connectedClients == 0`。 | **不改代码，改说法**。让守护进程在有客户端时也自退会导致连接反复失效、UI 要区分"故意退出"和"坏了"，为省 4MB 不值得。PRD 已更正为"无客户端连接时 0 常驻进程；菜单栏 App 运行时常驻 < 8MB / 0% CPU" |
| R3-4 | `osascript` 授权框可能长时间停在屏幕上，而 `Shell.run` 会阻塞在 `readDataToEndOfFile` → 安装期间**主线程被卡住**，菜单栏无响应。 | 安装挪到后台队列，结果回主线程弹窗；加 `installing` 去重 |
| R3-5 | 受限模式下 App 自己挂的断言名以 "LidAwake" 开头，会被诊断面板当成"其他阻止休眠的进程"列出来。 | 排除条件加 `name.hasPrefix("LidAwake")` |

### 已接受的残余风险（明确记录，不假装解决）

1. **守护进程被 `kill -9` 且 launchd 无法拉起时**（例如 plist 被删），`SleepDisabled` 会停在 1，机器一直不睡。缓解：开机时无条件复位、`uninstall-helper.sh` 显式复位、`lidawake doctor` 会直接显示这个值。没有进程内看门狗能覆盖"进程不存在"的情况，这是这条机制的固有代价。
2. **开启「重启后恢复」时，`startedAt` 沿用重启前的时间**，因此关机很久再开机可能立刻触发"达到最长时限"。这是偏保守的一侧，保留。
3. **非 admin 用户被拒**的用例没有自动化（需要新建标准用户账号，属于改动系统账号）。纯函数部分由 L1 #34–36 覆盖。

## R4 — 代码复查（实现完成后）

- 决策逻辑全部收在 `Engine`（纯函数，不读时钟/不读 IOKit/不写文件），守护进程只负责"把决策变成系统调用"。这是 85 条单测能覆盖住睡眠语义的原因。
- 所有"已开启"的判断都以 `IOPMCopySystemPowerSettings()` **回读结果**为准（`SleepDisabledController.set` 内部写完必校验），不存在乐观状态。
- `AssertionHolder.reconcile(to:)` 是幂等的差集操作，不会重复创建或漏释放。
- 无轮询：电源/电量/温度走 `notify_register_dispatch`，截止时间走 `DispatchSourceTimer`，UI 走 XPC 反向推送。唯一的周期性任务是会话激活期间 300s 的兜底心跳（leeway 30s）和 UI 倒计时 30s 刷新（tolerance 10s）。
- 命名与注释密度与文件内其余部分一致；注释只写"为什么"，不复述代码。

## 验证结果

| 层 | 结果 |
|---|---|
| L1 单元测试 | ✅ 85 项全通过（`scripts/run-tests.sh`） |
| 构建 + ad-hoc 签名 | ✅ `codesign --verify --deep --strict` 通过 |
| L2 集成测试 | 见 `docs/RESULTS.md` |
| L3 合盖 E2E | 见 `docs/RESULTS.md` |
