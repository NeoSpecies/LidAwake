import Foundation
import LidAwakeCore

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

// MARK: - 汇总

print("\n────────────────────────────")
if failed == 0 {
    print("✅ 全部通过：\(total) 项")
    exit(0)
} else {
    print("❌ 失败 \(failed) / \(total) 项")
    exit(1)
}
