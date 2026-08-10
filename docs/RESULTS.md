# LidAwake — 本机实测结果

机器：MacBook Pro `Mac17,6` / Apple M5 Max / 128GB / macOS 26.5 (25F71)
工具链：Command Line Tools，Swift 6.3.3，**无完整 Xcode、0 个代码签名身份**
测试时间：2026-08-10 ~ 08-11

---

## L1 单元测试 — ✅ 85/85

```
scripts/run-tests.sh
✅ 全部通过：85 项
```

覆盖：决策引擎优先级 22 条（含所有边界的等号情况）、定时计算 5 条、编解码 round-trip、
非法输入拒绝、`Guards` clamp、`pmset -g` 解析、鉴权策略纯函数、时长格式化与解析、
重启复位逻辑、`StateStore` 损坏文件隔离与权限、空闲自退判定、第三方断言解析。

## L2 集成测试 — ✅ 31/31（真机，root）

`SKIP_SLOW=1 sudo scripts/integration-test.sh` → **通过 29 / 失败 0**，另加单独跑的 I13/I14 两项。

| 用例 | 结果 | 实测数据 |
|---|---|---|
| I1 初始 mode=off，SleepDisabled=0 | ✅ | |
| I2 按需被 launchd 拉起 | ✅ | pid 64952 |
| I3 开启 → `SleepDisabled=1` + 断言可见 + 机制=full | ✅ | `pmset -g assertions` 中可见 `LidAwake lid-close keep-awake` |
| I4 重复开启幂等 | ✅ | |
| I5 关闭 → `SleepDisabled=0` + 断言全部释放 | ✅ | 残留断言 0 条 |
| I6 重复关闭幂等 | ✅ | |
| I7 `--for 6s` 到点自动关闭 | ✅ | `lastReleaseReason=timerExpired` |
| I8 `kill -9` → launchd 拉起并重新接管 | ✅ | pid 64952 → 65216，期间 `SleepDisabled` 保持 1，会话从磁盘恢复 |
| I9 `launchctl bootout` 失效安全 | ✅ | `SleepDisabled` 立即回 0，进程退出 |
| I10 重新 bootstrap | ✅ | 状态回到 off |
| I11 安全策略立即拦下 | ✅ | 退出码 3，原因 `requiresExternalPower` |
| I12 服务端拒绝越界时长 | ✅ | `--for 3000000` → 退出码 2，`时长非法: 3000000（允许 5–2592000 秒）` |
| I13 关闭状态空闲自退 | ✅ | 140s 后 `pgrep lidawaked` 为空 |
| I14 按需重新拉起 | ✅ | 新 pid 65573 |
| I15 能耗 | ✅ | 会话激活 20s：CPU 累计 **0:00.04**，RSS **15.98 MB** |

补充的手工验证（普通用户身份，无需密码）：

| 项 | 实测 |
|---|---|
| XPC 往返延迟 | **17.7 ms**（`lidawake --timing on`） |
| 电量下限守卫 | 把下限设成 95%（当时 61%）→ 开启被立即拦下，退出码 3，原因 `batteryFloor`，`SleepDisabled` 保持 0 |
| 菜单栏 App 的 XPC 通路 | App 启动后保持连接 → 关闭状态下守护进程 150s 未自退（符合 REVIEW R3-3 记录的取舍） |
| App 资源占用 | RSS **44.6 MB**，30s 空闲 CPU 增量 **0**，累计 CPU 0:00.29（含启动） |
| 守护进程资源占用 | RSS **15.7 MB**，150s 内 CPU 累计 **0:00.03** |
| 关闭时误挂断言 | 无（`pmset -g assertions` 中 0 条 LidAwake） |

## L3 合盖 E2E — ✅ 对照组与实验组均 PASS

判定依据：`mach_continuous_time() - mach_absolute_time()` 的增量。该差值**只在系统睡眠时增长**，
所以"刚才睡了多久"是测出来的确定值，不是日志推断。

### E2E-A 对照组（LidAwake 关闭，纯电池）

```
采样            : 47 个点，跨度 84.7s
睡眠检测        : slept=true   累计睡眠 61.52s
最大采样间隔    : 62.03s （进程曾被冻结）
上盖            : 检测到合盖，合上约 69s
期望            : 发生睡眠
判定            : ✅ PASS
```

合盖 69 秒 → 系统睡了 **61.52 秒**，采样进程被冻结 62 秒。**问题被精确复现**。

### E2E-B 实验组（LidAwake 开启，纯电池 58–60%，无外接显示器/键鼠）

```
采样            : 325 个点，跨度 163.4s
睡眠检测        : slept=false   累计睡眠 0.00s
最大采样间隔    : 0.51s
上盖            : 检测到合盖，合上约 138s
网卡连续性      : en0，0/325 个采样点无 IPv4 ✅
期望            : 不睡眠（且盖子确实合过）
判定            : ✅ PASS
```

合盖 **138 秒**、**纯电池**、**无任何外设**：

- 累计睡眠 **0.00 秒**
- 最大采样间隔 **0.51 秒**（＝设定的采样周期，进程一次都没被冻结）
- 全程 325 个采样点，`en0` 的 IPv4 地址**一次都没丢**

这正是 `caffeinate` 和 Amphetamine 做不到的那一格：它们只有断言层，纯电池合盖照样睡。

> 说明：对照组的"网卡连续性 0/47 无 IPv4"不代表睡眠期间网络正常 —— 睡眠期间根本没有采样点。
> 对照组的有效结论只有"睡了 61.52 秒"；网络连续性的结论来自实验组的 325 个连续采样点。

## 附：验证过的关键 API 行为

| 项 | 实测值 |
|---|---|
| `IOPMSetSystemPowerSetting`（非 root） | `0xe00002c1` = `kIOReturnNotPrivileged` |
| `IOPMSetSystemPowerSetting`（root，dlsym） | 成功，回读 `SleepDisabled=1` |
| `IOPMCopySystemPowerSettings`（非 root） | 可读：`{"SleepDisabled": 0, "Update DarkWakeBG Setting": 1}` |
| `IOPMAssertionCreateWithName`（普通用户） | rc=0 |
| 非 ASCII 断言名 | ⚠️ `pmset -g assertions` 显示为 `named: ""`，名字丢失 → 断言名必须是纯 ASCII（已修，见 REVIEW） |
| `AppleClamshellCausesSleep`（盖子打开、纯电池） | 0 —— **不能**用来预测合盖是否会睡，只作原始诊断展示 |
| CLT 的 `XCTest` / `Testing` swift module | 不存在 → 自建测试 harness |
| osascript 起的 root shell 里 `python3` | 被 TCC 拦住（`PermissionError` in importlib）→ 集成测试改用 `plutil -extract` |
| root shell 读 `~/Documents` 下的脚本 | `Operation not permitted`（TCC 对 root 同样生效）→ 特权脚本需放 `/tmp` 或 App bundle 内 |

## 当前系统状态

- LidAwake 已装：`/Applications/LidAwake.app`、`/Library/PrivilegedHelperTools/lidawaked`、
  `/usr/local/bin/lidawake`、`/usr/local/bin/lidawake-probe`
- 菜单栏 App 正在运行
- 当前会话：**已关闭**，`SleepDisabled = 0`（系统休眠行为完全正常）
- 「登录时启动」**未开启**（需要你自己在菜单里勾一下）
