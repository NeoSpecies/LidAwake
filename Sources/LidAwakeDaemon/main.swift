import Foundation
import LidAwakeCore

setvbuf(stderr, nil, _IONBF, 0)

let args = Array(CommandLine.arguments.dropFirst())

if args.contains("--version") {
    print("lidawaked \(LidAwakeInfo.version)")
    exit(0)
}

// 供安装脚本/集成测试用的自检：不启动 XPC 监听，只报告能力。
if args.contains("--check") {
    let io = IOKitSleepDisabledBackend()
    let ctl = SleepDisabledController()
    print("version: \(LidAwakeInfo.version)")
    print("uid: \(getuid())")
    print("iokit-symbols: \(io.isAvailable ? "ok" : "missing")")
    print("sleepDisabled: \(ctl.read().map { $0 ? "1" : "0" } ?? "unknown")")
    let p = SystemInfo.powerState()
    print("externalPower: \(p.onExternalPower)")
    print("battery: \(p.batteryPercent.map(String.init) ?? "-")")
    print("thermal: \(ThermalLevel.current().rawValue)")
    print("clamshellClosed: \(SystemInfo.clamshellClosed().map(String.init) ?? "-")")
    exit(0)
}

let daemon = Daemon()
daemon.start()
dispatchMain()
