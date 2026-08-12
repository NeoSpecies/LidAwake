import Foundation

/// 风扇控制模型与决策引擎。
///
/// 实测结论（M5 Max / macOS 26，见 docs/FAN.md）：
/// - `F0md`（**小写 md**）是 Apple Silicon 上的风扇模式键：0=固件自动，1=手动
/// - 只写 `F0Tg` 而不先写 `F0md=1`，SMC **会返回成功但几秒内被固件覆盖回去** —— 静默失效
/// - 写 `md=1` 后写 `F0Tg`，转速立刻跟随并稳定保持
/// - 写回原 `Tg` 并把 `md` 置 0，固件会立刻收回控制权
///
/// 安全立场：**只提速，不降速。** 用户要的是更凉快；"把风扇压到比固件认为需要的还低"
/// 才是能把机器捂坏的方向，本实现从构造上就不提供。
public enum FanMode: Equatable, Sendable {
    /// 交还固件（默认）
    case auto
    /// 固定百分比（在 min…max 量程内插值）
    case percent(Int)
    /// 全速
    case full
    /// 按温度自动爬升
    case curve

    public var label: String {
        switch self {
        case .auto: return "auto"
        case .percent(let p): return "percent(\(p))"
        case .full: return "full"
        case .curve: return "curve"
        }
    }

    public var chinese: String {
        switch self {
        case .auto: return "自动（系统控制）"
        case .percent(let p): return "固定 \(p)%"
        case .full: return "全速"
        case .curve: return "按温度自动"
        }
    }

    public var isManual: Bool { self != .auto }
}

extension FanMode: Codable {
    private enum CodingKeys: String, CodingKey { case kind, percent }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto: try c.encode("auto", forKey: .kind)
        case .full: try c.encode("full", forKey: .kind)
        case .curve: try c.encode("curve", forKey: .kind)
        case .percent(let p):
            try c.encode("percent", forKey: .kind)
            try c.encode(p, forKey: .percent)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "auto": self = .auto
        case "full": self = .full
        case "curve": self = .curve
        case "percent": self = .percent(try c.decode(Int.self, forKey: .percent))
        case let k:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "未知风扇模式: \(k)")
        }
    }
}

/// 温度曲线与安全阈值。全部可调，但都有硬性下限，服务端会 clamp。
public struct FanPolicy: Codable, Equatable, Sendable {
    /// 曲线起点：低于该温度不干预（交还固件）
    public var curveStartC: Double
    /// 曲线终点：达到该温度全速
    public var curveFullC: Double
    /// 无条件全速的临界温度 —— 任何模式下都覆盖用户设置
    public var criticalC: Double

    public static let startRange: ClosedRange<Double> = 50...90
    public static let fullRange: ClosedRange<Double> = 60...105
    public static let criticalRange: ClosedRange<Double> = 80...110

    public init(curveStartC: Double = 70, curveFullC: Double = 95, criticalC: Double = 100) {
        self.curveStartC = curveStartC
        self.curveFullC = curveFullC
        self.criticalC = criticalC
    }

    public func validated() -> FanPolicy {
        func clamp(_ v: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double {
            guard v.isFinite else { return fallback }
            return min(max(v, r.lowerBound), r.upperBound)
        }
        var p = self
        p.curveStartC = clamp(curveStartC, FanPolicy.startRange, 70)
        p.curveFullC = clamp(curveFullC, FanPolicy.fullRange, 95)
        p.criticalC = clamp(criticalC, FanPolicy.criticalRange, 100)
        // 终点必须高于起点，否则曲线无意义
        if p.curveFullC <= p.curveStartC { p.curveFullC = min(105, p.curveStartC + 10) }
        return p
    }
}

public struct FanRange: Equatable, Sendable {
    public var minRPM: Double
    public var maxRPM: Double
    public init(minRPM: Double, maxRPM: Double) {
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }
    public var isValid: Bool { minRPM > 0 && maxRPM > minRPM }
}

/// 一次决策的结果。
public enum FanDecision: Equatable, Sendable {
    /// 交还固件控制（写 md=0）
    case releaseToFirmware
    /// 接管并把目标设为该转速（写 md=1 + Tg）
    case setTarget(Double)
}

public enum FanEngine {

    /// 纯函数：模式 + 当前最高温 + 风扇量程 → 决策。
    /// 不读 SMC、不读时钟，因此可以完全单测（见 docs/TEST-PLAN.md）。
    public static func decide(mode: FanMode,
                              maxTempC: Double?,
                              range: FanRange,
                              policy: FanPolicy) -> FanDecision {
        guard range.isValid else { return .releaseToFirmware }
        let p = policy.validated()

        // 临界温度：任何手动模式下都无条件全速，覆盖用户设置。
        // 注意只在"我们已经接管"时生效 —— auto 模式下固件自己会处理。
        if mode.isManual, let t = maxTempC, t.isFinite, t >= p.criticalC {
            return .setTarget(range.maxRPM)
        }

        switch mode {
        case .auto:
            return .releaseToFirmware

        case .full:
            return .setTarget(range.maxRPM)

        case .percent(let raw):
            let pct = Double(min(max(raw, 0), 100)) / 100
            let target = range.minRPM + pct * (range.maxRPM - range.minRPM)
            return .setTarget(safetyFloor(target, maxTempC: maxTempC, range: range, policy: p))

        case .curve:
            guard let t = maxTempC, t.isFinite else { return .releaseToFirmware }
            // 低于起点不干预：宁可交还固件，也不要比它更保守
            guard t >= p.curveStartC else { return .releaseToFirmware }
            let span = max(1, p.curveFullC - p.curveStartC)
            let ratio = min(1, (t - p.curveStartC) / span)
            let target = range.minRPM + ratio * (range.maxRPM - range.minRPM)
            return .setTarget(safetyFloor(target, maxTempC: maxTempC, range: range, policy: p))
        }
    }

    /// 安全下限：温度越高，我们允许的最低转速越高。
    ///
    /// 这是"只提速不降速"承诺的实现方式 —— 用户即使把百分比设得很低，
    /// 高温时也会被这个下限顶上去，不可能因为设置不当把机器捂坏。
    public static func safetyFloor(_ requested: Double,
                                   maxTempC: Double?,
                                   range: FanRange,
                                   policy: FanPolicy) -> Double {
        var floorRatio = 0.0
        if let t = maxTempC, t.isFinite {
            switch t {
            case ..<75: floorRatio = 0
            case ..<85: floorRatio = 0.35
            case ..<90: floorRatio = 0.60
            case ..<95: floorRatio = 0.80
            default: floorRatio = 1.0
            }
        }
        let floor = range.minRPM + floorRatio * (range.maxRPM - range.minRPM)
        return min(range.maxRPM, max(range.minRPM, max(requested, floor)))
    }

    /// 当前决策下的重新评估间隔。曲线模式需要跟温度走，固定模式只需偶尔复查
    /// （防止固件把 md 复位）。
    public static func reevaluateInterval(mode: FanMode) -> TimeInterval {
        switch mode {
        case .auto: return 0            // 不需要定时器
        case .curve: return 5
        case .percent, .full: return 20
        }
    }
}

/// 状态展示用。
public struct FanStatus: Codable, Equatable, Sendable {
    public var supported: Bool
    public var fanCount: Int
    public var mode: FanMode
    public var policy: FanPolicy
    /// 每个风扇的实际转速
    public var actualRPM: [Double]
    public var minRPM: Double
    public var maxRPM: Double
    /// 当前生效的目标（nil = 固件控制中）
    public var targetRPM: Double?
    public var maxTempC: Double?
    /// 最热的那个传感器名，方便排查
    public var hottestSensor: String?
    public var note: String?

    public init(supported: Bool = false, fanCount: Int = 0, mode: FanMode = .auto,
                policy: FanPolicy = FanPolicy(), actualRPM: [Double] = [],
                minRPM: Double = 0, maxRPM: Double = 0, targetRPM: Double? = nil,
                maxTempC: Double? = nil, hottestSensor: String? = nil, note: String? = nil) {
        self.supported = supported
        self.fanCount = fanCount
        self.mode = mode
        self.policy = policy
        self.actualRPM = actualRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
        self.maxTempC = maxTempC
        self.hottestSensor = hottestSensor
        self.note = note
    }

    /// 当前转速占量程的比例，给 UI 画进度用
    public var loadFraction: Double {
        guard maxRPM > minRPM, let avg = averageRPM else { return 0 }
        return min(1, max(0, (avg - minRPM) / (maxRPM - minRPM)))
    }

    public var averageRPM: Double? {
        guard !actualRPM.isEmpty else { return nil }
        return actualRPM.reduce(0, +) / Double(actualRPM.count)
    }
}
