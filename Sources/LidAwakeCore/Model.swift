import Foundation

public enum LidAwakeInfo {
    public static let version = "1.0.0"
    public static let bundleID = "com.cogito.LidAwake"
    public static let machServiceName = "com.cogito.lidawaked"
    public static let daemonLabel = "com.cogito.lidawaked"
    public static let agentLabel = "com.cogito.LidAwake"
    /// 必须是纯 ASCII：实测非 ASCII 的断言名传给 IOPMAssertionCreateWithName 之后，
    /// `pmset -g assertions` 里显示为 `named: ""`（名字丢了），
    /// 诊断和集成测试都靠这个名字定位自己持有的断言。
    public static let assertionName = "LidAwake lid-close keep-awake"
    public static let daemonPath = "/Library/PrivilegedHelperTools/lidawaked"
    public static let statePath = "/Library/Application Support/LidAwake/state.json"
    public static let logPath = "/var/log/lidawaked.log"
}

// MARK: - Mode

public enum Mode: Equatable, Sendable {
    case off
    case indefinite
    case until(Date)

    public var isActive: Bool { self != .off }

    public var deadline: Date? {
        if case .until(let d) = self { return d }
        return nil
    }

    public var label: String {
        switch self {
        case .off: return "off"
        case .indefinite: return "indefinite"
        case .until: return "until"
        }
    }
}

extension Mode: Codable {
    private enum CodingKeys: String, CodingKey { case kind, deadline }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .off:
            try c.encode("off", forKey: .kind)
        case .indefinite:
            try c.encode("indefinite", forKey: .kind)
        case .until(let d):
            try c.encode("until", forKey: .kind)
            try c.encode(d.timeIntervalSince1970, forKey: .deadline)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "off":
            self = .off
        case "indefinite":
            self = .indefinite
        case "until":
            let t = try c.decode(Double.self, forKey: .deadline)
            guard t.isFinite else {
                throw DecodingError.dataCorruptedError(forKey: .deadline, in: c,
                                                       debugDescription: "deadline 非有限数")
            }
            self = .until(Date(timeIntervalSince1970: t))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "未知 mode: \(kind)")
        }
    }
}

// MARK: - Thermal

public enum ThermalLevel: String, Codable, Sendable {
    case nominal, fair, serious, critical

    public static func current() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    public var chinese: String {
        switch self {
        case .nominal: return "正常"
        case .fair: return "偏热"
        case .serious: return "较热"
        case .critical: return "过热"
        }
    }
}

// MARK: - Guards

public struct Guards: Codable, Equatable, Sendable {
    /// 电量低于（含）该百分比时自动关闭；仅在电池供电时判定。nil = 不启用。
    public var batteryFloorPercent: Int?
    /// 仅在接通电源时保持唤醒。
    public var requireExternalPower: Bool
    /// 机身温度到 critical 时自动关闭。
    public var releaseOnCriticalThermal: Bool
    /// 单次会话最长时长（秒）。nil = 无限制。
    public var maxSessionSeconds: Double?
    /// 合盖时同时保持屏幕唤醒（更费电、更热，默认关）。
    public var keepDisplayAwake: Bool
    /// 重启后恢复上次会话（默认关 = 失效安全）。
    public var persistAcrossReboot: Bool

    public static let batteryFloorRange = 5...90
    public static let maxSessionRange: ClosedRange<Double> = 60...(30 * 86400)

    public init(batteryFloorPercent: Int? = 20,
                requireExternalPower: Bool = false,
                releaseOnCriticalThermal: Bool = true,
                maxSessionSeconds: Double? = 12 * 3600,
                keepDisplayAwake: Bool = false,
                persistAcrossReboot: Bool = false) {
        self.batteryFloorPercent = batteryFloorPercent
        self.requireExternalPower = requireExternalPower
        self.releaseOnCriticalThermal = releaseOnCriticalThermal
        self.maxSessionSeconds = maxSessionSeconds
        self.keepDisplayAwake = keepDisplayAwake
        self.persistAcrossReboot = persistAcrossReboot
    }

    /// 把越界数值收敛到合法范围（服务端调用，不信任客户端）。
    public func validated() -> Guards {
        var g = self
        if let f = g.batteryFloorPercent {
            g.batteryFloorPercent = min(max(f, Guards.batteryFloorRange.lowerBound),
                                        Guards.batteryFloorRange.upperBound)
        }
        if let m = g.maxSessionSeconds {
            g.maxSessionSeconds = m.isFinite
                ? min(max(m, Guards.maxSessionRange.lowerBound), Guards.maxSessionRange.upperBound)
                : Guards.maxSessionRange.upperBound
        }
        return g
    }

    // 手工 Codable：区分"键缺失"(用默认值) 与 "键为 null"(显式停用)。
    private enum CodingKeys: String, CodingKey {
        case batteryFloorPercent, requireExternalPower, releaseOnCriticalThermal
        case maxSessionSeconds, keepDisplayAwake, persistAcrossReboot
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Guards()
        batteryFloorPercent = c.contains(.batteryFloorPercent)
            ? try c.decodeIfPresent(Int.self, forKey: .batteryFloorPercent)
            : d.batteryFloorPercent
        maxSessionSeconds = c.contains(.maxSessionSeconds)
            ? try c.decodeIfPresent(Double.self, forKey: .maxSessionSeconds)
            : d.maxSessionSeconds
        requireExternalPower = try c.decodeIfPresent(Bool.self, forKey: .requireExternalPower)
            ?? d.requireExternalPower
        releaseOnCriticalThermal = try c.decodeIfPresent(Bool.self, forKey: .releaseOnCriticalThermal)
            ?? d.releaseOnCriticalThermal
        keepDisplayAwake = try c.decodeIfPresent(Bool.self, forKey: .keepDisplayAwake)
            ?? d.keepDisplayAwake
        persistAcrossReboot = try c.decodeIfPresent(Bool.self, forKey: .persistAcrossReboot)
            ?? d.persistAcrossReboot
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(batteryFloorPercent, forKey: .batteryFloorPercent)   // 可为 null
        try c.encode(maxSessionSeconds, forKey: .maxSessionSeconds)       // 可为 null
        try c.encode(requireExternalPower, forKey: .requireExternalPower)
        try c.encode(releaseOnCriticalThermal, forKey: .releaseOnCriticalThermal)
        try c.encode(keepDisplayAwake, forKey: .keepDisplayAwake)
        try c.encode(persistAcrossReboot, forKey: .persistAcrossReboot)
    }
}

// MARK: - Decision

public enum ReleaseReason: String, Codable, Sendable {
    case userOff
    case timerExpired
    case maxSessionReached
    case batteryFloor
    case requiresExternalPower
    case criticalThermal
    case daemonTerminating
    case rebootReset

    public var chinese: String {
        switch self {
        case .userOff: return "已手动关闭"
        case .timerExpired: return "定时结束，已自动关闭"
        case .maxSessionReached: return "达到单次最长时限，已自动关闭"
        case .batteryFloor: return "电量过低，已自动关闭"
        case .requiresExternalPower: return "未接电源，已自动关闭"
        case .criticalThermal: return "机身过热，已自动关闭"
        case .daemonTerminating: return "后台服务退出，已自动关闭"
        case .rebootReset: return "重启后已复位为关闭"
        }
    }
}

public enum Decision: Equatable, Sendable {
    case keepAwake
    case release(ReleaseReason)
}

public struct Env: Sendable {
    public var now: Date
    public var onExternalPower: Bool
    public var batteryPercent: Int?
    public var thermal: ThermalLevel

    public init(now: Date, onExternalPower: Bool, batteryPercent: Int?, thermal: ThermalLevel) {
        self.now = now
        self.onExternalPower = onExternalPower
        self.batteryPercent = batteryPercent
        self.thermal = thermal
    }
}

// MARK: - Persisted state

public struct PersistedState: Codable, Equatable, Sendable {
    public var version: Int
    public var mode: Mode
    public var startedAt: Date?
    public var origin: String?
    public var guards: Guards
    public var bootTimeEpoch: Double
    public var lastReleaseReason: ReleaseReason?
    public var lastReleaseAt: Date?

    public init(version: Int = 1,
                mode: Mode = .off,
                startedAt: Date? = nil,
                origin: String? = nil,
                guards: Guards = Guards(),
                bootTimeEpoch: Double = 0,
                lastReleaseReason: ReleaseReason? = nil,
                lastReleaseAt: Date? = nil) {
        self.version = version
        self.mode = mode
        self.startedAt = startedAt
        self.origin = origin
        self.guards = guards
        self.bootTimeEpoch = bootTimeEpoch
        self.lastReleaseReason = lastReleaseReason
        self.lastReleaseAt = lastReleaseAt
    }

    private enum CodingKeys: String, CodingKey {
        case version, mode, startedAt, origin, guards, bootTimeEpoch
        case lastReleaseReason, lastReleaseAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .off
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        guards = try c.decodeIfPresent(Guards.self, forKey: .guards) ?? Guards()
        bootTimeEpoch = try c.decodeIfPresent(Double.self, forKey: .bootTimeEpoch) ?? 0
        lastReleaseReason = try c.decodeIfPresent(ReleaseReason.self, forKey: .lastReleaseReason)
        lastReleaseAt = try c.decodeIfPresent(Date.self, forKey: .lastReleaseAt)
    }
}

// MARK: - Requests / DTO

public enum LidAwakeError: LocalizedError, Equatable {
    case invalidDuration(Double)
    case notAuthorized
    case daemonUnavailable(String)
    case timeout
    case decoding(String)
    case applyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDuration(let d):
            let shown = d.isFinite ? String(Int(d)) : "\(d)"
            return "时长非法: \(shown)（允许 \(Int(ApplyRequest.minSeconds))–\(Int(ApplyRequest.maxSeconds)) 秒）"
        case .notAuthorized:
            return "调用者未获授权"
        case .daemonUnavailable(let m):
            return "后台服务不可用: \(m)"
        case .timeout:
            return "与后台服务通信超时"
        case .decoding(let m):
            return "数据解析失败: \(m)"
        case .applyFailed(let m):
            return "施加失败: \(m)"
        }
    }
}

public enum ApplyRequest: Codable, Equatable, Sendable {
    case off
    case indefinite(origin: String)
    case until(seconds: Double, origin: String)

    public static let minSeconds: Double = 5
    public static let maxSeconds: Double = 30 * 86400

    public var origin: String {
        switch self {
        case .off: return "user"
        case .indefinite(let o), .until(_, let o): return o
        }
    }

    /// 服务端必须调用；非法输入直接抛错，不做静默修正。
    public func validated() throws -> ApplyRequest {
        if case .until(let s, let o) = self {
            guard s.isFinite, s >= ApplyRequest.minSeconds, s <= ApplyRequest.maxSeconds else {
                throw LidAwakeError.invalidDuration(s)
            }
            return .until(seconds: s, origin: String(o.prefix(64)))
        }
        return self
    }

    private enum CodingKeys: String, CodingKey { case kind, seconds, origin }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .off:
            try c.encode("off", forKey: .kind)
        case .indefinite(let o):
            try c.encode("indefinite", forKey: .kind)
            try c.encode(o, forKey: .origin)
        case .until(let s, let o):
            try c.encode("until", forKey: .kind)
            try c.encode(s, forKey: .seconds)
            try c.encode(o, forKey: .origin)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? "unknown"
        switch try c.decode(String.self, forKey: .kind) {
        case "off": self = .off
        case "indefinite": self = .indefinite(origin: origin)
        case "until":
            self = .until(seconds: try c.decode(Double.self, forKey: .seconds), origin: origin)
        case let k:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "未知 request: \(k)")
        }
    }
}

public enum Mechanism: String, Codable, Sendable {
    /// 断言层 + SleepDisabled，含纯电池可靠。
    case full
    /// 仅断言层（守护进程缺失或 SleepDisabled 施加失败），只在接通电源时可能有效。
    case assertionsOnly
    case none

    public var chinese: String {
        switch self {
        case .full: return "SleepDisabled + 断言（完整）"
        case .assertionsOnly: return "仅断言（受限：需接通电源）"
        case .none: return "未生效"
        }
    }
}

public struct StatusDTO: Codable, Sendable {
    public var version: String
    public var mode: Mode
    public var active: Bool
    public var startedAt: Date?
    public var origin: String?
    public var effectiveDeadline: Date?
    public var remainingSeconds: Double?
    public var mechanism: Mechanism
    public var sleepDisabled: Bool?
    public var assertionsHeld: [String]
    public var guards: Guards
    public var onExternalPower: Bool
    public var batteryPercent: Int?
    public var thermal: ThermalLevel
    public var clamshellClosed: Bool?
    public var lastReleaseReason: ReleaseReason?
    public var lastReleaseAt: Date?
    public var daemonPID: Int32
    public var degradedNote: String?

    public init(version: String = LidAwakeInfo.version,
                mode: Mode = .off,
                active: Bool = false,
                startedAt: Date? = nil,
                origin: String? = nil,
                effectiveDeadline: Date? = nil,
                remainingSeconds: Double? = nil,
                mechanism: Mechanism = .none,
                sleepDisabled: Bool? = nil,
                assertionsHeld: [String] = [],
                guards: Guards = Guards(),
                onExternalPower: Bool = false,
                batteryPercent: Int? = nil,
                thermal: ThermalLevel = .nominal,
                clamshellClosed: Bool? = nil,
                lastReleaseReason: ReleaseReason? = nil,
                lastReleaseAt: Date? = nil,
                daemonPID: Int32 = 0,
                degradedNote: String? = nil) {
        self.version = version
        self.mode = mode
        self.active = active
        self.startedAt = startedAt
        self.origin = origin
        self.effectiveDeadline = effectiveDeadline
        self.remainingSeconds = remainingSeconds
        self.mechanism = mechanism
        self.sleepDisabled = sleepDisabled
        self.assertionsHeld = assertionsHeld
        self.guards = guards
        self.onExternalPower = onExternalPower
        self.batteryPercent = batteryPercent
        self.thermal = thermal
        self.clamshellClosed = clamshellClosed
        self.lastReleaseReason = lastReleaseReason
        self.lastReleaseAt = lastReleaseAt
        self.daemonPID = daemonPID
        self.degradedNote = degradedNote
    }
}

public enum JSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        if pretty { e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] }
        return e
    }
    public static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ v: T, pretty: Bool = false) throws -> Data {
        try encoder(pretty: pretty).encode(v)
    }
    public static func decode<T: Decodable>(_ t: T.Type, _ d: Data) throws -> T {
        try decoder.decode(t, from: d)
    }
}
