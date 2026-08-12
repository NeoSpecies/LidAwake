import Foundation
import LidAwakeCore

let usage = """
LidAwake \(LidAwakeInfo.version) — 合盖续跑（macOS 原生）

用法:
  lidawake status [--json]
  lidawake on  [--for <时长>] [--require-ac] [--origin <名字>]
  lidawake off
  lidawake guards [--battery-floor <N|off>] [--max <时长|off>]
                  [--require-ac <on|off>] [--thermal <on|off>]
                  [--display-awake <on|off>] [--persist-reboot <on|off>]
  lidawake fan auto|full|<百分比>|curve [--start <°C>] [--full-at <°C>] [--critical <°C>]
  lidawake doctor
  lidawake --version

时长写法: 90 | 30s | 15m | 2h | 1h30m | 1d
全局开关: --json 机器可读输出   --timing 打印往返耗时

退出码: 0 成功 / 1 用法错误 / 2 服务不可用 / 3 请求被安全策略立即拦下

示例（给 Agent / 脚本用）:
  lidawake on --for 2h --origin build.sh && make -j && lidawake off
"""

// MARK: - 参数解析

var argv = Array(CommandLine.arguments.dropFirst())
let wantJSON = argv.contains("--json")
let wantTiming = argv.contains("--timing")
argv.removeAll { $0 == "--json" || $0 == "--timing" }

func fail(_ msg: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("错误: " + msg + "\n").utf8))
    exit(code)
}

func optionValue(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name) else { return nil }
    guard i + 1 < argv.count else { fail("\(name) 缺少参数值", code: 1) }
    let v = argv[i + 1]
    argv.removeSubrange(i...(i + 1))
    return v
}

func flag(_ name: String) -> Bool {
    guard let i = argv.firstIndex(of: name) else { return false }
    argv.remove(at: i)
    return true
}

func onOff(_ raw: String, _ name: String) -> Bool {
    switch raw.lowercased() {
    case "on", "yes", "true", "1": return true
    case "off", "no", "false", "0": return false
    default: fail("\(name) 只能是 on/off", code: 1)
    }
}

if argv.contains("--version") { print("lidawake \(LidAwakeInfo.version)"); exit(0) }
if argv.isEmpty || argv.contains("-h") || argv.contains("--help") { print(usage); exit(0) }

let command = argv.removeFirst()
let started = Date()

// MARK: - 输出

func printStatusHuman(_ s: StatusDTO) {
    let modeText: String
    switch s.mode {
    case .off: modeText = "已关闭"
    case .indefinite: modeText = "已开启（无限期）"
    case .until: modeText = "已开启（定时）"
    }
    var lines: [String] = []
    lines.append("状态          : \(modeText)")
    if s.active {
        lines.append("机制          : \(s.mechanism.chinese)")
        if let r = s.remainingSeconds {
            // 无限期模式下这个"剩余"来自"单次最长时限"守卫，不是用户设的定时
            let label = s.mode.deadline == nil ? "最长剩余      " : "剩余          "
            lines.append("\(label): \(Format.hms(r))")
        }
        if let o = s.origin, !o.isEmpty { lines.append("发起方        : \(o)") }
    }
    lines.append("SleepDisabled : \(s.sleepDisabled.map { $0 ? "1" : "0" } ?? "未知")")
    if !s.assertionsHeld.isEmpty {
        lines.append("持有断言      : \(s.assertionsHeld.joined(separator: ", "))")
    }
    let power = s.onExternalPower ? "接通电源" : "电池"
    let pct = s.batteryPercent.map { " \($0)%" } ?? ""
    lines.append("电源          : \(power)\(pct)")
    lines.append("温度          : \(s.thermal.chinese)")
    if let c = s.clamshellClosed { lines.append("上盖          : \(c ? "合上" : "打开")") }
    let g = s.guards
    lines.append("安全策略      : 电量下限 \(g.batteryFloorPercent.map { "\($0)%" } ?? "关") / "
                 + "最长 \(g.maxSessionSeconds.map { Format.compact($0) } ?? "无限制") / "
                 + "需接电源 \(g.requireExternalPower ? "是" : "否") / "
                 + "过热保护 \(g.releaseOnCriticalThermal ? "是" : "否") / "
                 + "保持屏幕 \(g.keepDisplayAwake ? "是" : "否") / "
                 + "重启后恢复 \(g.persistAcrossReboot ? "是" : "否")")
    if let r = s.lastReleaseReason {
        let when = s.lastReleaseAt.map { " (\(Format.timestamp($0)))" } ?? ""
        lines.append("上次结束      : \(r.chinese)\(when)")
    }
    if let note = s.degradedNote { lines.append("⚠️ 降级        : \(note)") }
    if let f = s.fan, f.supported {
        let rpm = f.actualRPM.map { String(format: "%.0f", $0) }.joined(separator: "/")
        var line = "风扇          : \(f.mode.chinese)  \(rpm) RPM"
        if let t = f.maxTempC { line += String(format: "  最高温 %.1f°C", t) }
        lines.append(line)
    }
    lines.append("服务 PID      : \(s.daemonPID)")
    print(lines.joined(separator: "\n"))
}

func emit(_ s: StatusDTO) {
    if wantJSON {
        if let d = try? JSON.encode(s, pretty: true), let str = String(data: d, encoding: .utf8) {
            print(str)
        }
    } else {
        printStatusHuman(s)
    }
    if wantTiming {
        let ms = Date().timeIntervalSince(started) * 1000
        FileHandle.standardError.write(Data(String(format: "往返耗时: %.1f ms\n", ms).utf8))
    }
}

// MARK: - doctor（不需要服务在线）

func doctor() {
    let fm = FileManager.default
    let plist = "/Library/LaunchDaemons/\(LidAwakeInfo.daemonLabel).plist"
    print("LidAwake doctor")
    print("---------------")
    print("守护进程二进制 : \(LidAwakeInfo.daemonPath) \(fm.fileExists(atPath: LidAwakeInfo.daemonPath) ? "✅" : "❌ 缺失")")
    print("LaunchDaemon   : \(plist) \(fm.fileExists(atPath: plist) ? "✅" : "❌ 缺失")")
    if let attrs = try? fm.attributesOfItem(atPath: LidAwakeInfo.daemonPath),
       let owner = attrs[.ownerAccountName] as? String,
       let perms = attrs[.posixPermissions] as? NSNumber {
        print("二进制属主/权限: \(owner) \(String(perms.intValue, radix: 8))\(owner == "root" ? " ✅" : " ❌ 必须是 root")")
    }
    let (_, launchctlOut) = Shell.run("/bin/launchctl", ["print", "system/\(LidAwakeInfo.daemonLabel)"])
    let running = launchctlOut.contains("state = running")
    print("launchd 已加载 : \(launchctlOut.contains("=> {") || launchctlOut.contains("state") ? "✅" : "❌ 未加载")")
    print("当前是否在跑   : \(running ? "是（会话激活或刚被调用）" : "否（空闲自退，属正常）")")

    let ctl = SleepDisabledController()
    print("SleepDisabled  : \(ctl.read().map { $0 ? "1（不会休眠）" : "0（正常休眠）" } ?? "读取失败")")
    print("IOKit 私有符号 : \(IOKitSleepDisabledBackend().isAvailable ? "可用" : "不可用（将回退 pmset）")")

    let foreign = Diagnostics.foreignAssertions()
    if foreign.isEmpty {
        print("其他阻止休眠的进程: 无")
    } else {
        print("其他阻止休眠的进程:")
        for f in foreign {
            print("  - pid \(f.pid) \(f.process): \(f.type) \(f.name.isEmpty ? "" : "「\(f.name)」")")
        }
    }

    let client = DaemonClient()
    do {
        let s = try client.status(timeout: 6)
        print("\nXPC 连通       : ✅")
        print("")
        printStatusHuman(s)
    } catch {
        print("\nXPC 连通       : ❌ \(error.localizedDescription)")
        print("提示: 运行 scripts/install.sh 安装后台服务（只需授权一次）")
    }
}

// MARK: - 执行

let client = DaemonClient()

func requireStatus() -> StatusDTO {
    do { return try client.status() }
    catch { fail("\(error.localizedDescription)\n提示: 后台服务可能未安装，运行 scripts/install.sh", code: 2) }
}

switch command {
case "status":
    emit(requireStatus())

case "on":
    let requireAC = flag("--require-ac")
    let origin = optionValue("--origin") ?? "cli"
    let durText = optionValue("--for")
    if let extra = argv.first { fail("未知参数: \(extra)", code: 1) }

    if requireAC {
        var g = requireStatus().guards
        g.requireExternalPower = true
        do { _ = try client.setGuards(g) }
        catch { fail("设置安全策略失败: \(error.localizedDescription)", code: 2) }
    }

    let request: ApplyRequest
    if let durText {
        guard let secs = Format.duration(durText) else { fail("无法解析时长: \(durText)", code: 1) }
        request = .until(seconds: secs, origin: origin)
    } else {
        request = .indefinite(origin: origin)
    }
    do {
        let s = try client.apply(request)
        emit(s)
        if !s.active {
            let why = s.lastReleaseReason?.chinese ?? "被安全策略拦下"
            FileHandle.standardError.write(Data("未能开启: \(why)\n".utf8))
            exit(3)
        }
        if s.mechanism == .assertionsOnly {
            FileHandle.standardError.write(Data("⚠️ 仅断言层生效，纯电池合盖可能仍会休眠。运行 lidawake doctor 查看原因\n".utf8))
        }
    } catch {
        fail(error.localizedDescription, code: 2)
    }

case "off":
    do { emit(try client.apply(.off)) }
    catch { fail(error.localizedDescription, code: 2) }

case "guards":
    var g = requireStatus().guards
    if let v = optionValue("--battery-floor") {
        if v.lowercased() == "off" { g.batteryFloorPercent = nil }
        else if let n = Int(v) { g.batteryFloorPercent = n }
        else { fail("--battery-floor 需要数字或 off", code: 1) }
    }
    if let v = optionValue("--max") {
        if v.lowercased() == "off" { g.maxSessionSeconds = nil }
        else if let s = Format.duration(v) { g.maxSessionSeconds = s }
        else { fail("--max 无法解析: \(v)", code: 1) }
    }
    if let v = optionValue("--require-ac") { g.requireExternalPower = onOff(v, "--require-ac") }
    if let v = optionValue("--thermal") { g.releaseOnCriticalThermal = onOff(v, "--thermal") }
    if let v = optionValue("--display-awake") { g.keepDisplayAwake = onOff(v, "--display-awake") }
    if let v = optionValue("--persist-reboot") { g.persistAcrossReboot = onOff(v, "--persist-reboot") }
    if let extra = argv.first { fail("未知参数: \(extra)", code: 1) }
    do { emit(try client.setGuards(g)) }
    catch { fail(error.localizedDescription, code: 2) }

case "fan":
    guard let sub = argv.first else {
        // 不带参数就报告当前状态
        let s = requireStatus()
        guard let f = s.fan, f.supported else {
            print("这台机器没有可控风扇（或 SMC 不可用）"); exit(0)
        }
        print("风扇模式    : \(f.mode.chinese)")
        print("风扇转速    : " + f.actualRPM.map { String(format: "%.0f RPM", $0) }
                                   .joined(separator: " / ")
              + String(format: "   量程 %.0f–%.0f", f.minRPM, f.maxRPM))
        if let t = f.targetRPM { print(String(format: "当前目标    : %.0f RPM（LidAwake 接管中）", t)) }
        else { print("当前目标    : 固件控制中") }
        if let t = f.maxTempC {
            print(String(format: "最高温度    : %.1f °C  (%@)", t, (f.hottestSensor ?? "?") as NSString))
        }
        print("温度曲线    : \(Int(f.policy.curveStartC))°C 起 → \(Int(f.policy.curveFullC))°C 全速"
              + "，\(Int(f.policy.criticalC))°C 无条件全速")
        exit(0)
    }
    argv.removeFirst()
    var policy: FanPolicy?
    func policyValue(_ name: String, _ apply: (inout FanPolicy, Double) -> Void) {
        guard let raw = optionValue(name) else { return }
        guard let v = Double(raw), v.isFinite else { fail("\(name) 需要数字", code: 1) }
        var p = policy ?? requireStatus().fan?.policy ?? FanPolicy()
        apply(&p, v)
        policy = p
    }
    policyValue("--start") { $0.curveStartC = $1 }
    policyValue("--full-at") { $0.curveFullC = $1 }
    policyValue("--critical") { $0.criticalC = $1 }

    let mode: FanMode
    switch sub.lowercased() {
    case "auto": mode = .auto
    case "full", "max": mode = .full
    case "curve": mode = .curve
    default:
        guard let pct = Int(sub.replacingOccurrences(of: "%", with: "")),
              (0...100).contains(pct) else {
            fail("风扇模式只能是 auto / full / curve / 0-100 的百分比", code: 1)
        }
        mode = .percent(pct)
    }
    if let extra = argv.first { fail("未知参数: \(extra)", code: 1) }
    do {
        let s = try client.setFan(FanRequest(mode: mode, policy: policy))
        if let f = s.fan, f.supported {
            print("已设为 \(f.mode.chinese)")
            if let t = f.targetRPM { print(String(format: "目标转速: %.0f RPM", t)) }
            if let t = f.maxTempC { print(String(format: "当前最高温: %.1f °C", t)) }
        } else {
            fail("这台机器没有可控风扇", code: 2)
        }
    } catch { fail(error.localizedDescription, code: 2) }

case "doctor":
    doctor()

default:
    fail("未知命令: \(command)\n\n\(usage)", code: 1)
}

client.invalidate()
exit(0)
