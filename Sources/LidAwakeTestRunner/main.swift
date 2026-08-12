import Foundation
import LidAwakeCore
import CoreGraphics

// CLT 环境下没有 XCTest / swift-testing（已实测），因此用极简 harness。
// 核心逻辑全部是纯函数，harness 足够。

var total = 0
var failed = 0
var currentSection = ""

func section(_ name: String) {
    currentSection = name
    print("\n── \(name)")
}

func check(_ ok: Bool, _ name: String, _ detail: String = "") {
    total += 1
    if ok {
        print("  ✅ \(name)")
    } else {
        failed += 1
        print("  ❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func eq<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    check(actual == expected, name, "得到 \(actual)，期望 \(expected)")
}

// MARK: - 固定基准时间（引擎不读时钟，所以可以完全确定）

let t0 = Date(timeIntervalSince1970: 1_700_000_000)
func env(_ offset: Double = 0,
         ac: Bool = false,
         battery: Int? = 80,
         thermal: ThermalLevel = .nominal) -> Env {
    Env(now: t0.addingTimeInterval(offset), onExternalPower: ac,
        batteryPercent: battery, thermal: thermal)
}
let noGuards = Guards(batteryFloorPercent: nil, requireExternalPower: false,
                      releaseOnCriticalThermal: false, maxSessionSeconds: nil)

// MARK: - 引擎优先级

section("决策引擎：优先级（TEST-PLAN #1–22）")

eq(Engine.evaluate(mode: .off, startedAt: nil, guards: Guards(), env: env()),
   .release(.userOff), "#1 off → userOff")

eq(Engine.evaluate(mode: .off, startedAt: t0, guards: Guards(batteryFloorPercent: 20),
                   env: env(battery: 3)),
   .release(.userOff), "#2 off + 低电量 → userOff（用户意图优先）")

eq(Engine.evaluate(mode: .indefinite, startedAt: t0, guards: noGuards, env: env()),
   .keepAwake, "#3 无限期 + 无守卫 → keepAwake")

eq(Engine.evaluate(mode: .until(t0.addingTimeInterval(60)), startedAt: t0,
                   guards: noGuards, env: env()),
   .keepAwake, "#4 定时未到 → keepAwake")

eq(Engine.evaluate(mode: .until(t0.addingTimeInterval(-1)), startedAt: t0,
                   guards: noGuards, env: env()),
   .release(.timerExpired), "#5 定时已过 → timerExpired")

eq(Engine.evaluate(mode: .until(t0), startedAt: t0, guards: noGuards, env: env()),
   .release(.timerExpired), "#6 定时正好到（含等号）→ timerExpired")

var g12h = noGuards; g12h.maxSessionSeconds = 12 * 3600
eq(Engine.evaluate(mode: .indefinite, startedAt: t0.addingTimeInterval(-13 * 3600),
                   guards: g12h, env: env()),
   .release(.maxSessionReached), "#7 超过最长时限 → maxSessionReached")

eq(Engine.evaluate(mode: .indefinite, startedAt: t0.addingTimeInterval(-(11 * 3600 + 59 * 60)),
                   guards: g12h, env: env()),
   .keepAwake, "#8 未超最长时限 → keepAwake")

eq(Engine.evaluate(mode: .until(t0.addingTimeInterval(3600)),
                   startedAt: t0.addingTimeInterval(-13 * 3600), guards: g12h, env: env()),
   .release(.maxSessionReached), "#9 定时未到但总时长超限 → maxSessionReached")

eq(Engine.evaluate(mode: .indefinite, startedAt: t0.addingTimeInterval(-100 * 3600),
                   guards: noGuards, env: env()),
   .keepAwake, "#10 无最长限制 + 跑了 100 小时 → keepAwake")

var gAC = noGuards; gAC.requireExternalPower = true
eq(Engine.evaluate(mode: .indefinite, startedAt: t0, guards: gAC, env: env(ac: false)),
   .release(.requiresExternalPower), "#11 需接电源 + 电池 → requiresExternalPower")
eq(Engine.evaluate(mode: .indefinite, startedAt: t0, guards: gAC, env: env(ac: true)),
   .keepAwake, "#12 需接电源 + 已接电 → keepAwake")

var gTherm = noGuards; gTherm.releaseOnCriticalThermal = true
eq(Engine.evaluate(mode: .indefinite, startedAt: t0, guards: gTherm, env: env(thermal: .critical)),
   .release(.criticalThermal), "#13 过热 + 守卫开 → criticalThermal")
eq(Engine.evaluate(mode: .indefinite, startedAt: t0, guards: noGuards, env: env(thermal: .critical)),
   .keepAwake, "#14 过热 + 守卫关 → keepAwake")
eq(Engine.evaluate(mode: .indefinite, startedAt: t0, guards: gTherm, env: env(thermal: .serious)),
   .keepAwake, "#15 serious（未到 critical）→ keepAwake")

var gBat = noGuards; gBat.batteryFloorPercent = 20
eq(Engine.evaluate(mode: .indefinite, startedAt: t0, guards: gBat, env: env(battery: 19)),
   .release(.batteryFloor), "#16 电池 19% < 20% → batteryFloor")
eq(Engine.evaluate(mode: .indefinite, startedAt: t0, guards: gBat, env: env(battery: 20)),
   .release(.batteryFloor), "#17 电池正好 20%（含等号）→ batteryFloor")
eq(Engine.evaluate(mode: .indefinite, startedAt: t0, guards: gBat, env: env(battery: 21)),
   .keepAwake, "#18 电池 21% → keepAwake")
eq(Engine.evaluate(mode: .indefinite, startedAt: t0, guards: gBat, env: env(ac: true, battery: 5)),
   .keepAwake, "#19 接电 + 5%（电量守卫只在电池供电时生效）→ keepAwake")
eq(Engine.evaluate(mode: .indefinite, startedAt: t0, guards: noGuards, env: env(battery: 1)),
   .keepAwake, "#20 未启用电量守卫 + 1% → keepAwake")
eq(Engine.evaluate(mode: .indefinite, startedAt: t0, guards: gBat, env: env(battery: nil)),
   .keepAwake, "#21 无电池机型 → keepAwake")

var gAll = Guards(batteryFloorPercent: 20, requireExternalPower: false,
                  releaseOnCriticalThermal: true, maxSessionSeconds: 12 * 3600)
eq(Engine.evaluate(mode: .until(t0.addingTimeInterval(-1)), startedAt: t0,
                   guards: gAll, env: env(battery: 5)),
   .release(.timerExpired), "#22 定时到期 + 低电量同时成立 → timerExpired（顺序即优先级）")

// MARK: - 定时计算

section("定时计算（#23–27）")

let deadline = t0.addingTimeInterval(3600)
eq(Engine.nextEvaluation(mode: .until(deadline), startedAt: t0, guards: noGuards),
   deadline, "#23 只有定时 → 取定时点")
eq(Engine.nextEvaluation(mode: .indefinite, startedAt: t0, guards: g12h),
   t0.addingTimeInterval(12 * 3600), "#24 只有最长时限 → 取 start+max")
eq(Engine.nextEvaluation(mode: .until(t0.addingTimeInterval(13 * 3600)),
                         startedAt: t0, guards: g12h),
   t0.addingTimeInterval(12 * 3600), "#25 两者都有 → 取更早的")
check(Engine.nextEvaluation(mode: .indefinite, startedAt: t0, guards: noGuards) == nil,
      "#26 无限期 + 无最长时限 → nil（不装定时器）")
check(Engine.nextEvaluation(mode: .off, startedAt: nil, guards: g12h) == nil,
      "#27 已关闭 → nil")

// MARK: - 编解码

section("编解码 / 校验 / 解析（#28–42）")

do {
    var s = PersistedState()
    s.mode = .until(t0.addingTimeInterval(1234.5678))
    s.startedAt = t0
    s.origin = "test"
    s.guards = Guards(batteryFloorPercent: 33, requireExternalPower: true,
                      releaseOnCriticalThermal: false, maxSessionSeconds: 7200,
                      keepDisplayAwake: true, persistAcrossReboot: true)
    s.bootTimeEpoch = 1_699_000_000.5
    s.lastReleaseReason = .batteryFloor
    s.lastReleaseAt = t0
    let d = try JSON.encode(s)
    let back = try JSON.decode(PersistedState.self, d)
    check(back == s, "#28 PersistedState round-trip 完全相等")
} catch {
    check(false, "#28 PersistedState round-trip", "\(error)")
}

do {
    for m in [Mode.off, .indefinite, .until(t0)] {
        let back = try JSON.decode(Mode.self, try JSON.encode(m))
        check(back == m, "#29 Mode round-trip: \(m.label)")
    }
} catch {
    check(false, "#29 Mode round-trip", "\(error)")
}

for bad in [0.0, -1.0, Double.nan, Double.infinity, 40 * 86400.0] {
    var threw = false
    do { _ = try ApplyRequest.until(seconds: bad, origin: "t").validated() }
    catch { threw = true }
    check(threw, "#30 拒绝非法时长 \(bad)")
}
for good in [5.0, 30 * 86400.0] {
    var ok = false
    do { _ = try ApplyRequest.until(seconds: good, origin: "t").validated(); ok = true }
    catch { ok = false }
    check(ok, "#31 接受边界时长 \(good)")
}

eq(Guards(batteryFloorPercent: 0).validated().batteryFloorPercent, 5, "#32a floor 0 → clamp 5")
eq(Guards(batteryFloorPercent: 200).validated().batteryFloorPercent, 90, "#32b floor 200 → clamp 90")
eq(Guards(maxSessionSeconds: 1).validated().maxSessionSeconds, 60, "#32c max 1s → clamp 60s")
eq(Guards(maxSessionSeconds: 999 * 86400).validated().maxSessionSeconds, 30 * 86400,
   "#32d max 999d → clamp 30d")
check(Guards(batteryFloorPercent: nil).validated().batteryFloorPercent == nil,
      "#32e floor=nil 保持停用")
eq(Guards(maxSessionSeconds: Double.nan).validated().maxSessionSeconds, 30 * 86400,
   "#32f max=nan → clamp 上限")

eq(Format.parseSleepDisabled(from: "System-wide power settings:\n SleepDisabled\t\t1\n"), true,
   "#33a 解析 tab 分隔 → true")
eq(Format.parseSleepDisabled(from: " SleepDisabled     0"), false,
   "#33b 解析多空格 → false")
check(Format.parseSleepDisabled(from: "Currently in use:\n sleep 1\n") == nil,
      "#33c 无该字段 → nil")

check(AuthPolicy.isAllowed(uid: 0, groups: []), "#34 root 允许")
check(AuthPolicy.isAllowed(uid: 501, groups: [20, 80, 12]), "#35 admin(80) 组成员允许")
check(!AuthPolicy.isAllowed(uid: 501, groups: [20, 12]), "#36 非 admin 拒绝")

eq(Format.hms(3661), "1:01:01", "#37a hms 3661")
eq(Format.hms(59), "0:00:59", "#37b hms 59")
eq(Format.hms(-5), "0:00:00", "#37c hms 负数")
eq(Format.hms(Double.nan), "0:00:00", "#37d hms nan")
eq(Format.compact(7200), "2h", "#37e compact 2h")
eq(Format.compact(5400), "1h30m", "#37f compact 1h30m")
eq(Format.compact(2700), "45m", "#37g compact 45m")
eq(Format.compact(50), "50s", "#37h compact 50s")

check(Engine.needsRebootReset(storedBootTime: 100, currentBootTime: 500,
                              mode: .indefinite, persistAcrossReboot: false),
      "#38 重启 + 不恢复 → 需要复位")
check(!Engine.needsRebootReset(storedBootTime: 100, currentBootTime: 500,
                               mode: .indefinite, persistAcrossReboot: true),
      "#39 重启 + 开启恢复 → 不复位")
check(!Engine.needsRebootReset(storedBootTime: 500, currentBootTime: 500,
                               mode: .indefinite, persistAcrossReboot: false),
      "#40 未重启 → 不复位")
check(!Engine.needsRebootReset(storedBootTime: 100, currentBootTime: 500,
                               mode: .off, persistAcrossReboot: false),
      "#40b 本来就是关闭 → 不需要复位")

do {
    let tmp = NSTemporaryDirectory() + "/lidawake-test-\(getpid())/state.json"
    let dir = (tmp as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try Data("{ 这不是合法 JSON".utf8).write(to: URL(fileURLWithPath: tmp))
    let store = StateStore(path: tmp)
    let loaded = store.load()
    check(loaded.wasCorrupt && loaded.state.mode == .off,
          "#41a 损坏文件 → 回落 off 且标记 corrupt")
    check(FileManager.default.fileExists(atPath: tmp + ".corrupt"),
          "#41b 损坏文件被隔离保留")

    var s = PersistedState()
    s.mode = .indefinite
    s.startedAt = t0
    try store.save(s)
    let reloaded = store.load()
    check(!reloaded.wasCorrupt && reloaded.state.mode == .indefinite,
          "#41c 保存后可正确读回")
    if let attrs = try? FileManager.default.attributesOfItem(atPath: tmp),
       let perms = attrs[.posixPermissions] as? NSNumber {
        eq(perms.intValue, 0o600, "#41d 状态文件权限 0600")
    } else {
        check(false, "#41d 状态文件权限 0600", "读不到属性")
    }
    try? FileManager.default.removeItem(atPath: dir)
} catch {
    check(false, "#41 StateStore", "\(error)")
}

check(Engine.shouldIdleExit(mode: .off, connectedClients: 0), "#42a off + 无客户端 → 可自退")
check(!Engine.shouldIdleExit(mode: .off, connectedClients: 1), "#42b off + 有客户端 → 不自退")
check(!Engine.shouldIdleExit(mode: .indefinite, connectedClients: 0),
      "#42c 会话激活 + 无客户端 → 绝不自退（否则定时器/守卫失效）")
check(!Engine.shouldIdleExit(mode: .until(t0), connectedClients: 0),
      "#42d 定时会话 + 无客户端 → 绝不自退")

section("时长解析")
eq(Format.duration("90"), 90, "90 → 90s")
eq(Format.duration("30s"), 30, "30s")
eq(Format.duration("15m"), 900, "15m")
eq(Format.duration("2h"), 7200, "2h")
eq(Format.duration("1h30m"), 5400, "1h30m")
eq(Format.duration("1d"), 86400, "1d")
check(Format.duration("abc") == nil, "abc → nil")
check(Format.duration("1h30") == nil, "1h30（结尾裸数字）→ nil")
check(Format.duration("") == nil, "空串 → nil")

section("诊断解析")
let pmsetAssertions = """
Assertion status system-wide:
   PreventUserIdleSystemSleep     1
Listed by owning process:
   pid 3481(Kaka): [0x00000cfb00058e97] 253:17:30 NoDisplaySleepAssertion named: "ShadowstarKit No Sleep"
   pid 83(powerd): [0x000bc706000195df] 00:14:50 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"
No kernel assertions.
"""
let foreign = Diagnostics.parseForeignAssertions(pmsetAssertions, excluding: LidAwakeInfo.assertionName)
eq(foreign.count, 2, "解析出 2 条第三方断言")
if foreign.count == 2 {
    eq(foreign[0].pid, "3481", "第一条 pid")
    eq(foreign[0].process, "Kaka", "第一条进程名")
    eq(foreign[0].type, "NoDisplaySleepAssertion", "第一条断言类型")
    eq(foreign[0].name, "ShadowstarKit No Sleep", "第一条断言名")
}
let own = """
Listed by owning process:
   pid 999(lidawaked): [0x1] 00:00:01 PreventUserIdleSystemSleep named: "\(LidAwakeInfo.assertionName)"
"""
eq(Diagnostics.parseForeignAssertions(own, excluding: LidAwakeInfo.assertionName).count, 0,
   "自己持有的断言不算第三方")

section("系统状态：速率计算（纯函数）")

func snap(_ t: Double, cpuUser: Double = 0, cpuSys: Double = 0, cpuIdle: Double = 0,
          diskR: UInt64 = 0, diskW: UInt64 = 0, rx: UInt64 = 0, tx: UInt64 = 0) -> StatsSnapshot {
    StatsSnapshot(cpuUser: cpuUser, cpuSystem: cpuSys, cpuIdle: cpuIdle, cpuNice: 0,
                  diskRead: diskR, diskWrite: diskW, netRx: rx, netTx: tx, timestamp: t)
}

do {
    let a = snap(100, cpuUser: 100, cpuSys: 50, cpuIdle: 850, diskR: 0, diskW: 0, rx: 0, tx: 0)
    let b = snap(102, cpuUser: 200, cpuSys: 100, cpuIdle: 1700, diskR: 2048, diskW: 4096,
                 rx: 20480, tx: 10240)
    let r = StatsRates.between(a, b)
    check(abs(r.cpuUser - 0.1) < 0.001, "CPU user 100/1000 ticks → 10%")
    check(abs(r.cpuSystem - 0.05) < 0.001, "CPU system 50/1000 ticks → 5%")
    check(abs(r.cpuBusy - 0.15) < 0.001, "CPU busy → 15%")
    eq(r.diskReadPerSec, 1024, "磁盘读 2048B / 2s → 1024B/s")
    eq(r.diskWritePerSec, 2048, "磁盘写 4096B / 2s → 2048B/s")
    eq(r.netRxPerSec, 10240, "网络下行 20480B / 2s → 10240B/s")
    eq(r.netTxPerSec, 5120, "网络上行 10240B / 2s → 5120B/s")
}
do {  // 计数器回绕（进程重启 / 网卡重置）绝不能产生负数或天文数字
    let a = snap(10, diskR: 1_000_000, rx: 999_999)
    let b = snap(11, diskR: 5, rx: 3)
    let r = StatsRates.between(a, b)
    eq(r.diskReadPerSec, 0, "磁盘计数器回绕 → 0（不是负数）")
    eq(r.netRxPerSec, 0, "网络计数器回绕 → 0")
}
do {  // dt 为 0 / 负 / 非有限
    let a = snap(50, cpuUser: 10, cpuIdle: 90, diskR: 100)
    eq(StatsRates.between(a, snap(50, diskR: 200)).diskReadPerSec, 0, "dt=0 → 速率 0")
    eq(StatsRates.between(a, snap(49, diskR: 200)).diskReadPerSec, 0, "dt<0 → 速率 0")
    let nanSnap = snap(Double.nan, diskR: 200)
    eq(StatsRates.between(a, nanSnap).diskReadPerSec, 0, "dt=nan → 速率 0")
}
do {  // CPU tick 完全没动（机器彻底空闲的极端情况）不能除 0
    let a = snap(1, cpuUser: 5, cpuIdle: 5)
    let r = StatsRates.between(a, snap(2, cpuUser: 5, cpuIdle: 5))
    eq(r.cpuBusy, 0, "CPU tick 无变化 → 0%（不是 nan）")
}
eq(MemoryInfo(used: 50, total: 100).fraction, 0.5, "内存占比")
eq(MemoryInfo(used: 50, total: 0).fraction, 0, "内存总量为 0 → 占比 0（不是 nan）")
eq(MemoryInfo(used: 200, total: 100).fraction, 1, "内存占比上限收敛到 1")
eq(DiskInfo(free: 25, total: 100).usedFraction, 0.75, "磁盘已用占比")
eq(DiskInfo(free: 0, total: 0).usedFraction, 0, "磁盘总量为 0 → 0")

section("字节 / 速率格式化")
eq(Format.bytes(0), "0 B", "0 字节")
eq(Format.bytes(512), "512 B", "512 B")
eq(Format.bytes(2048), "2 KB", "KB 不带小数")
eq(Format.bytes(5 * 1024 * 1024), "5 MB", "MB 不带小数")
eq(Format.bytes(3.5 * 1024 * 1024 * 1024), "3.5 GB", "GB 带一位小数")
eq(Format.bytes(Double.nan), "0 B", "nan → 0 B")
eq(Format.bytes(-5), "0 B", "负数 → 0 B")
eq(Format.rate(0), "0 B/s", "零速率")
eq(Format.rate(1024), "1 KB/s", "速率带 /s")
eq(Format.percent(0.156), "16%", "百分比四舍五入")
eq(Format.percent(-1), "0%", "百分比下限")
eq(Format.percent(2), "100%", "百分比上限")
eq(Format.percent(Double.nan), "0%", "nan → 0%")

section("菜单栏折叠：布局判定与分组")
eq(FoldState.folded.toggled, FoldState.expanded, "折叠状态取反")
eq(FoldState.expanded.toggled, FoldState.folded, "展开状态取反")

// 刘海机型：可用区左边界不是 0
check(MenuBarLayout.isOnScreen(frame: CGRect(x: 1200, y: 0, width: 30, height: 24),
                               visibleMinX: 1000), "在可见区内 → 可见")
check(!MenuBarLayout.isOnScreen(frame: CGRect(x: 900, y: 0, width: 30, height: 24),
                                visibleMinX: 1000), "在可见区左侧 → 被裁掉")
check(MenuBarLayout.isOnScreen(frame: CGRect(x: 1000, y: 0, width: 30, height: 24),
                               visibleMinX: 1000), "正好在边界上 → 可见")
check(!MenuBarLayout.isOnScreen(frame: CGRect(x: 1200, y: 0, width: 0, height: 24),
                               visibleMinX: 1000), "宽度为 0 → 不算可见")

func mkItem(_ app: String, x: CGFloat, onScreen: Bool, index: Int = 0,
            help: String? = nil, title: String? = nil) -> MenuBarItemInfo {
    MenuBarItemInfo(pid: 1, appName: app, bundleID: "x.\(app)", index: index,
                    title: title, help: help,
                    frame: CGRect(x: x, y: 0, width: 24, height: 24),
                    isPressable: true, isOnScreen: onScreen)
}

do {
    let items = [mkItem("Zebra", x: 1400, onScreen: true),
                 mkItem("Alpha", x: 1300, onScreen: true),
                 mkItem("Hidden", x: 200, onScreen: false)]
    let groups = MenuBarLayout.grouped(items)
    eq(groups.count, 3, "按 App 分成 3 组")
    eq(groups[0].app, "Hidden", "屏幕上放不下的排最前（那才是用户要找的）")
    eq(groups[1].app, "Alpha", "其余按名称排序")
    eq(groups[2].app, "Zebra", "其余按名称排序")
}
do {  // 同一 App 多个项：组内按菜单栏从左到右
    let items = [mkItem("Multi", x: 1400, onScreen: true, index: 1),
                 mkItem("Multi", x: 1300, onScreen: true, index: 0)]
    let groups = MenuBarLayout.grouped(items)
    eq(groups.count, 1, "同一 App 合成一组")
    eq(groups[0].items.first?.frame.minX, 1300, "组内按 x 从小到大")
}

check(!MenuBarLayout.shouldScan(bundleID: nil), "无 bundle id 不扫描")
check(!MenuBarLayout.shouldScan(bundleID: ""), "空 bundle id 不扫描")
check(!MenuBarLayout.shouldScan(bundleID: "com.apple.controlcenter"), "控制中心不扫描")
check(!MenuBarLayout.shouldScan(bundleID: "com.apple.WebKit.GPU"), "WebKit XPC 不扫描")
check(!MenuBarLayout.shouldScan(bundleID: "com.google.Chrome.helper"), ".helper 结尾不扫描")
check(MenuBarLayout.shouldScan(bundleID: "com.todesk.mac"), "普通第三方 App 要扫描")

section("菜单栏折叠：状态栏项宽度上限")
// 实测崩溃："attempt to set length of status bar item to 10030.00 (maximum is 10000)"
eq(MenuBarLayout.foldedLength(iconSize: 18, inset: 6), 10000, "折叠宽度夹在 10000 上限内")
eq(MenuBarLayout.foldedLength(iconSize: 0, inset: 0), 10000, "零图标也不超上限")
eq(MenuBarLayout.foldedLength(iconSize: 999, inset: 999), 10000, "超大图标同样夹紧")
check(MenuBarLayout.foldedLength(iconSize: 18, inset: 6) <= MenuBarLayout.maxStatusItemLength,
      "折叠宽度永远 ≤ 系统上限（否则 NSStatusItem 抛异常崩溃）")

section("菜单栏项：状态文字提取")
eq(mkItem("A", x: 0, onScreen: true, help: "已连接").statusText, "已连接", "优先取 tooltip")
eq(mkItem("A", x: 0, onScreen: true, title: "3").statusText, "3", "没有 tooltip 时取标题")
check(mkItem("飞书", x: 0, onScreen: true, help: "飞书").statusText == nil,
      "tooltip 就是 App 名字本身 → 不当作状态显示")
check(mkItem("A", x: 0, onScreen: true, help: "   ").statusText == nil, "空白 tooltip 忽略")
eq(mkItem("A", x: 0, onScreen: true, help: "  已同步  ").statusText, "已同步", "状态文字去空白")
eq(mkItem("A", x: 0, onScreen: true, index: 0).displayName, "A", "单项显示 App 名")
eq(mkItem("A", x: 0, onScreen: true, index: 2).displayName, "A · 3", "多项加序号")

section("风扇：决策引擎（纯函数）")
let fr = FanRange(minRPM: 1350, maxRPM: 5350)     // 与本机实测量程一致
let fp = FanPolicy()                              // 默认 balanced 分档

func dec(_ mode: FanMode, _ temp: Double?, _ st: FanEngine.StepState = .firmware,
         _ policy: FanPolicy = fp) -> FanDecision {
    FanEngine.decide(mode: mode, maxTempC: temp, range: fr, policy: policy, state: st).decision
}
func stepOf(_ mode: FanMode, _ temp: Double?, _ st: FanEngine.StepState = .firmware,
            _ policy: FanPolicy = fp) -> Int {
    FanEngine.decide(mode: mode, maxTempC: temp, range: fr, policy: policy, state: st).state.index
}

eq(dec(.auto, 50), .releaseToFirmware, "auto → 交还固件")
eq(dec(.auto, 105), .releaseToFirmware, "auto 模式下即使高温也不接管（固件自己处理）")
eq(dec(.full, 50), .setTarget(5350), "full → 最大转速")
eq(dec(.percent(50), 105), .setTarget(5350), "临界温度覆盖用户设置 → 全速")
eq(dec(.percent(0), 60), .setTarget(1350), "0% + 低温 → 最低转速（不低于 F0Mn）")
eq(dec(.percent(100), 60), .setTarget(5350), "100% → 最大转速")
eq(FanEngine.decide(mode: .auto, maxTempC: 60,
                    range: FanRange(minRPM: 0, maxRPM: 0), policy: fp).decision,
   .releaseToFirmware, "量程非法（无风扇）→ 交还固件")
eq(FanEngine.decide(mode: .full, maxTempC: 60,
                    range: FanRange(minRPM: 5000, maxRPM: 1000), policy: fp).decision,
   .releaseToFirmware, "量程颠倒 → 交还固件，不写任何值")

section("风扇：安全下限（只提速不降速）")
do {
    if case .setTarget(let rpm) = dec(.percent(10), 92) {
        let floor80 = 1350 + 0.80 * 4000
        check(rpm >= floor80 - 0.5, "92°C 时 10% 被顶到 ≥80%（得到 \(Int(rpm))）")
    } else { check(false, "92°C + 10% 应当接管") }
    if case .setTarget(let rpm) = dec(.percent(10), 60) {
        check(abs(rpm - (1350 + 0.10 * 4000)) < 0.5, "60°C 时 10% 不被顶高（低温不干预）")
    } else { check(false, "60°C + 10% 应当接管") }
}
eq(FanEngine.safetyFloor(1400, maxTempC: nil, range: fr, policy: fp), 1400,
   "温度读不到时不施加下限")
eq(FanEngine.safetyFloor(100, maxTempC: 60, range: fr, policy: fp), 1350, "请求低于 Mn → 夹到 Mn")
eq(FanEngine.safetyFloor(99999, maxTempC: 60, range: fr, policy: fp), 5350, "请求高于 Mx → 夹到 Mx")

section("风扇：分档 + 迟滞 + 最短停留")
// balanced = 60→30% 70→45% 78→60% 85→75% 92→90% 97→100%
eq(stepOf(.curve, 55), -1, "低于第一档 → 不接管")
eq(dec(.curve, 55), .releaseToFirmware, "低于第一档 → 交还固件")
eq(stepOf(.curve, 60), 0, "正好到第一档阈值 → 进第 0 档")
eq(stepOf(.curve, 77.9), 1, "77.9°C → 第 1 档（70 档）")
eq(stepOf(.curve, 78), 2, "78°C → 第 2 档")
eq(stepOf(.curve, 200), 5, "极高温 → 最高档")
eq(dec(.curve, nil), .releaseToFirmware, "读不到温度 → 交还固件")

// 升档立即
eq(stepOf(.curve, 92, FanEngine.StepState(index: 0, dwellSeconds: 0)), 4,
   "升档立即生效（第 0 档 → 第 4 档，不需要等停留时间）")

// 降档要迟滞 + 停留时间
do {
    let inStep3 = FanEngine.StepState(index: 3, dwellSeconds: 999)   // 85→75% 档
    eq(stepOf(.curve, 84, inStep3), 3, "降到 84°C 但未过迟滞（85−4=81）→ 保持原档")
    eq(stepOf(.curve, 81, inStep3), 2, "正好 81°C（阈值−迟滞）→ 降一档（边界含等号）")
    eq(stepOf(.curve, 81.1, inStep3), 3, "81.1°C 仍在迟滞区内 → 保持原档")
    let fresh = FanEngine.StepState(index: 3, dwellSeconds: 5)
    eq(stepOf(.curve, 60, fresh), 3, "温度大跌但停留不足 30s → 不降档")
    eq(stepOf(.curve, 60, FanEngine.StepState(index: 3, dwellSeconds: 31)), 2,
       "停留够久 → 一次只降一档（3 → 2，不会直接掉到 0）")
    eq(stepOf(.curve, 40, FanEngine.StepState(index: 0, dwellSeconds: 99)), -1,
       "从第 0 档继续降 → 交还固件")
}
// 停留时间在同档时要累计、换档时要清零
do {
    let r1 = FanEngine.decide(mode: .curve, maxTempC: 86, range: fr, policy: fp,
                              state: FanEngine.StepState(index: 3, dwellSeconds: 12))
    eq(r1.state.dwellSeconds, 12, "同档位 → 停留时间保留")
    let r2 = FanEngine.decide(mode: .curve, maxTempC: 93, range: fr, policy: fp,
                              state: FanEngine.StepState(index: 3, dwellSeconds: 12))
    eq(r2.state.dwellSeconds, 0, "换档位 → 停留时间清零")
}

section("风扇：策略校验与编解码")
eq(FanPolicy(hysteresisC: 0).validated().hysteresisC, 1, "迟滞下限夹紧")
eq(FanPolicy(hysteresisC: 99).validated().hysteresisC, 15, "迟滞上限夹紧")
eq(FanPolicy(minDwellSeconds: 1).validated().minDwellSeconds, 5, "停留时间下限夹紧")
eq(FanPolicy(criticalC: 999).validated().criticalC, 110, "临界温度上限夹紧")
eq(FanPolicy(hysteresisC: Double.nan).validated().hysteresisC, 4, "nan → 回落默认值")
do {   // 档位清洗：乱序、重复、百分比倒挂
    let messy = FanPolicy(steps: [FanStep(upAtC: 90, percent: 80),
                                  FanStep(upAtC: 60, percent: 30),
                                  FanStep(upAtC: 90.2, percent: 85),   // 太近，丢弃
                                  FanStep(upAtC: 95, percent: 50)])    // 倒挂，丢弃
        .validated()
    // 60→30 保留；90→80 保留；90.2→85 与前档只差 0.2°C 被丢；95→50 百分比倒挂被丢
    eq(messy.steps.count, 2, "档位清洗：太近的与倒挂的都被丢弃，剩 2 档")
    eq(messy.steps[0].upAtC, 60, "按温度升序排列")
    check(zip(messy.steps, messy.steps.dropFirst()).allSatisfy { $0.percent <= $1.percent },
          "百分比单调不降")
    eq(FanPolicy(steps: []).validated().steps.count, FanPolicy.balanced.count,
       "空档位 → 回落默认档位表")
}
eq(FanRequest(mode: .percent(500)).validated().mode, FanMode.percent(100), "百分比上限夹紧")
eq(FanRequest(mode: .percent(-20)).validated().mode, FanMode.percent(0), "百分比下限夹紧")
do {
    for m in [FanMode.auto, .full, .curve, .percent(42)] {
        check(try JSON.decode(FanMode.self, try JSON.encode(m)) == m,
              "FanMode round-trip: \(m.label)")
    }
    let p = FanPolicy(steps: FanPolicy.quiet, hysteresisC: 6, minDwellSeconds: 45, criticalC: 99)
    check(try JSON.decode(FanPolicy.self, try JSON.encode(p)) == p, "FanPolicy round-trip")
} catch { check(false, "风扇编解码", "\(error)") }

eq(FanEngine.reevaluateInterval(mode: .auto), 0, "auto 不需要定时器")
eq(FanEngine.reevaluateInterval(mode: .curve), 5, "曲线模式 5s 跟温度")
eq(FanEngine.reevaluateInterval(mode: .full), 20, "固定模式 20s 复查")

check(!Engine.shouldIdleExit(mode: .off, connectedClients: 0, fanMode: .full),
      "风扇手动模式下守护进程绝不自退（否则没人交还控制权）")
check(Engine.shouldIdleExit(mode: .off, connectedClients: 0, fanMode: .auto),
      "风扇 auto + 会话关闭 + 无客户端 → 可自退")

// MARK: - 汇总

print("\n────────────────────────────")
if failed == 0 {
    print("✅ 全部通过：\(total) 项")
    exit(0)
} else {
    print("❌ 失败 \(failed) / \(total) 项")
    exit(1)
}
