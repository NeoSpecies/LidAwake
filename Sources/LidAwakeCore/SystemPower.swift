import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import notify   // notify_register_dispatch，见 SDK usr/include/notify.h

// MARK: - Shell（仅用于 pmset 回退与诊断，不在热路径）

public enum Shell {
    @discardableResult
    public static func run(_ path: String, _ args: [String], timeout: Double = 10) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (-1, "无法执行 \(path): \(error)") }

        // 先读干管道再 wait，避免 64KB 管道写满导致子进程阻塞
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

// MARK: - L2：SleepDisabled（系统级，需 root）

public protocol SleepDisabledBackend {
    var name: String { get }
    func read() -> Bool?
    func write(_ on: Bool) -> Bool
}

/// 首选路径：IOKit 私有符号，通过 dlsym 动态解析（符号消失也不会导致启动失败）。
/// 这正是 /usr/bin/pmset 内部走的同一条路，耗时微秒级，无 fork。
public final class IOKitSleepDisabledBackend: SleepDisabledBackend {
    public let name = "IOKit"

    private typealias CopyFn = @convention(c) () -> CFDictionary?
    private typealias SetFn = @convention(c) (CFString, CFTypeRef) -> IOReturn

    private let copyFn: CopyFn?
    private let setFn: SetFn?

    public init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        if let h = handle, let s = dlsym(h, "IOPMCopySystemPowerSettings") {
            copyFn = unsafeBitCast(s, to: CopyFn.self)
        } else {
            copyFn = nil
        }
        if let h = handle, let s = dlsym(h, "IOPMSetSystemPowerSetting") {
            setFn = unsafeBitCast(s, to: SetFn.self)
        } else {
            setFn = nil
        }
    }

    public var isAvailable: Bool { copyFn != nil && setFn != nil }

    public func read() -> Bool? {
        guard let copyFn, let dict = copyFn() as? [String: Any] else { return nil }
        if let n = dict["SleepDisabled"] as? NSNumber { return n.boolValue }
        return nil
    }

    public func write(_ on: Bool) -> Bool {
        guard let setFn else { return false }
        let rc = setFn("SleepDisabled" as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse)!)
        return rc == kIOReturnSuccess
    }
}

/// 回退路径：/usr/bin/pmset。慢（~20ms fork+exec）但只依赖公开 CLI。
public final class PMSetSleepDisabledBackend: SleepDisabledBackend {
    public let name = "pmset"
    public init() {}

    public func read() -> Bool? {
        let (rc, out) = Shell.run("/usr/bin/pmset", ["-g"])
        guard rc == 0 else { return nil }
        return Format.parseSleepDisabled(from: out)
    }

    public func write(_ on: Bool) -> Bool {
        let (rc, _) = Shell.run("/usr/bin/pmset", ["-a", "disablesleep", on ? "1" : "0"])
        return rc == 0
    }
}

/// 组合控制器：IOKit 优先 → 回读校验 → 失败降级到 pmset → 再校验。
/// 任何"已开启"状态都以**回读结果**为准，不接受乐观假设。
public final class SleepDisabledController {
    public private(set) var lastBackendUsed: String = "-"
    public private(set) var lastError: String?

    private let primary: IOKitSleepDisabledBackend
    private let fallback: PMSetSleepDisabledBackend

    public init(primary: IOKitSleepDisabledBackend = IOKitSleepDisabledBackend(),
                fallback: PMSetSleepDisabledBackend = PMSetSleepDisabledBackend()) {
        self.primary = primary
        self.fallback = fallback
    }

    /// 读取系统真实值。
    public func read() -> Bool? {
        primary.read() ?? fallback.read()
    }

    /// 施加并校验。返回 true 表示系统真实值已等于目标值。
    @discardableResult
    public func set(_ on: Bool) -> Bool {
        lastError = nil
        if read() == on {
            lastBackendUsed = "noop"
            return true
        }
        if primary.isAvailable {
            if primary.write(on), read() == on {
                lastBackendUsed = primary.name
                return true
            }
            lastError = "IOKit 路径失败（可能非 root 或符号行为变化）"
        } else {
            lastError = "IOKit 符号不可用"
        }
        if fallback.write(on), read() == on {
            lastBackendUsed = fallback.name
            return true
        }
        lastError = (lastError.map { $0 + "；" } ?? "") + "pmset 回退同样失败"
        lastBackendUsed = "none"
        return false
    }
}

// MARK: - L1：IOPMAssertion（无需 root）

public final class AssertionHolder {
    public struct Kind {
        public static let idleSystem = "PreventUserIdleSystemSleep"
        public static let system = "PreventSystemSleep"
        public static let idleDisplay = "PreventUserIdleDisplaySleep"
    }

    private var ids: [String: IOPMAssertionID] = [:]
    private let displayName: String

    public init(displayName: String = LidAwakeInfo.assertionName) {
        self.displayName = displayName
    }

    public var held: [String] { ids.keys.sorted() }

    /// 幂等：只补齐缺的、只释放多余的。
    public func reconcile(to desired: Set<String>) {
        for type in desired where ids[type] == nil {
            var id: IOPMAssertionID = 0
            let rc = IOPMAssertionCreateWithName(type as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                displayName as CFString,
                                                &id)
            if rc == kIOReturnSuccess { ids[type] = id }
        }
        for (type, id) in ids where !desired.contains(type) {
            IOPMAssertionRelease(id)
            ids.removeValue(forKey: type)
        }
    }

    public func releaseAll() { reconcile(to: []) }

    deinit { releaseAll() }
}

// MARK: - 电源 / 电量 / 温度 / 上盖

public enum SystemInfo {

    public struct PowerState {
        public var onExternalPower: Bool
        public var batteryPercent: Int?
    }

    public static func powerState() -> PowerState {
        guard let blobRef = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blobRef)?.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty else {
            // 无电池（台式机）视为一直接通电源
            return PowerState(onExternalPower: true, batteryPercent: nil)
        }
        var onAC = false
        var percent: Int?
        var foundInternalBattery = false
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(blobRef, src)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            // 只认内置电池：接了 UPS 的台式机也会出现在这个列表里
            if let type = d[kIOPSTypeKey] as? String, type != kIOPSInternalBatteryType { continue }
            foundInternalBattery = true
            if let state = d[kIOPSPowerSourceStateKey] as? String {
                onAC = (state == kIOPSACPowerValue)
            }
            if let cur = d[kIOPSCurrentCapacityKey] as? Int,
               let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                percent = Int((Double(cur) / Double(max) * 100).rounded())
            }
            break
        }
        // 没有内置电池（台式机 / 只有 UPS）→ 视为一直接通电源，
        // 否则 requireExternalPower 守卫会在这类机器上永远误触发。
        guard foundInternalBattery else {
            return PowerState(onExternalPower: true, batteryPercent: nil)
        }
        return PowerState(onExternalPower: onAC, batteryPercent: percent)
    }

    /// true = 盖子合上。读不到返回 nil。
    public static func clamshellClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                 IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let v = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                      kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return v.boolValue
    }

    public static func bootTimeEpoch() -> Double {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }

    public static func env(now: Date = Date()) -> Env {
        let p = powerState()
        return Env(now: now,
                   onExternalPower: p.onExternalPower,
                   batteryPercent: p.batteryPercent,
                   thermal: ThermalLevel.current())
    }
}

// MARK: - 事件源（全部 dispatch 驱动，无轮询）

public final class SystemEventMonitor {
    /// IOKit 电源通知键，见 SDK IOKit/ps/IOPowerSources.h
    private static let powerSourceKey = "com.apple.system.powersources.source"
    private static let percentKey = "com.apple.system.powersources.percent"
    /// 见 SDK libkern/OSThermalNotification.h
    private static let thermalKey = "com.apple.system.thermalpressurelevel"

    private var tokens: [Int32] = []
    private let queue: DispatchQueue

    public init(queue: DispatchQueue) { self.queue = queue }

    public func start(onChange: @escaping (String) -> Void) {
        for key in [Self.powerSourceKey, Self.percentKey, Self.thermalKey] {
            var token: Int32 = 0
            let rc = notify_register_dispatch(key, &token, queue) { _ in onChange(key) }
            if rc == NOTIFY_STATUS_OK { tokens.append(token) }
        }
    }

    public func stop() {
        for t in tokens { notify_cancel(t) }
        tokens.removeAll()
    }

    deinit { stop() }
}

// MARK: - 诊断：谁在阻止休眠

public enum Diagnostics {
    public struct ForeignAssertion {
        public var pid: String
        public var process: String
        public var type: String
        public var name: String
    }

    /// 解析 `pmset -g assertions` 的 "Listed by owning process" 段。
    public static func parseForeignAssertions(_ output: String, excluding ownName: String) -> [ForeignAssertion] {
        var result: [ForeignAssertion] = []
        var inList = false
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.contains("Listed by owning process") { inList = true; continue }
            guard inList else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("pid ") else { continue }
            guard let openParen = t.firstIndex(of: "("),
                  let closeParen = t.firstIndex(of: ")") , openParen < closeParen else { continue }
            let pid = String(t[t.index(t.startIndex, offsetBy: 4)..<openParen])
            let proc = String(t[t.index(after: openParen)..<closeParen])
            var type = "", name = ""
            if let bracketEnd = t.range(of: "] ", range: closeParen..<t.endIndex) {
                let tail = t[bracketEnd.upperBound...]
                if let namedIdx = tail.range(of: " named: ") {
                    let head = tail[..<namedIdx.lowerBound]
                    type = head.split(separator: " ").last.map(String.init) ?? ""
                    name = String(tail[namedIdx.upperBound...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                } else {
                    type = String(tail).trimmingCharacters(in: .whitespaces)
                }
            }
            // 排除自己：守护进程、以及受限模式下 App 自己挂的断言
            if name == ownName || name.hasPrefix("LidAwake") || proc == "lidawaked" { continue }
            result.append(ForeignAssertion(pid: pid, process: proc, type: type, name: name))
        }
        return result
    }

    public static func foreignAssertions() -> [ForeignAssertion] {
        let (rc, out) = Shell.run("/usr/bin/pmset", ["-g", "assertions"])
        guard rc == 0 else { return [] }
        return parseForeignAssertions(out, excluding: LidAwakeInfo.assertionName)
    }
}
