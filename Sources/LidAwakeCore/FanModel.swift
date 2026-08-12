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

/// 一个温度档位：温度升到 `upAtC` 时进入该档，风扇跑 `percent`。
public struct FanStep: Codable, Equatable, Sendable {
    public var upAtC: Double
    public var percent: Int

    public init(upAtC: Double, percent: Int) {
        self.upAtC = upAtC
        self.percent = percent
    }
}

/// 温度分档策略。
///
/// **为什么是分档而不是线性连续**：温度本身是抖的（实测同一负载下在 89.6–93.4°C 之间波动），
/// 线性映射会把这个抖动原样放大到转速上，风扇音调持续起伏 —— 人耳对变化的敏感度
/// 远高于绝对音量，听感上比恒定高转速更烦。分档 + 迟滞 + 最短停留可以把它稳住。
public struct FanPolicy: Codable, Equatable, Sendable {
    /// 有序档位（按 upAtC 升序）。低于第一档的温度不干预，交还固件。
    public var steps: [FanStep]
    /// 回落迟滞：降档要求温度低于「进入该档的阈值 − 迟滞」
    public var hysteresisC: Double
    /// 降档最短停留时间：刚升上来的档位至少待这么久才允许降
    public var minDwellSeconds: Double
    /// 无条件全速的临界温度 —— 任何模式下都覆盖用户设置
    public var criticalC: Double

    public static let hysteresisRange: ClosedRange<Double> = 1...15
    public static let dwellRange: ClosedRange<Double> = 5...300
    public static let criticalRange: ClosedRange<Double> = 80...110
    public static let stepTempRange: ClosedRange<Double> = 40...105

    /// 均衡（默认）
    public static let balanced: [FanStep] = [
        FanStep(upAtC: 60, percent: 30),
        FanStep(upAtC: 70, percent: 45),
        FanStep(upAtC: 78, percent: 60),
        FanStep(upAtC: 85, percent: 75),
        FanStep(upAtC: 92, percent: 90),
        FanStep(upAtC: 97, percent: 100),
    ]
    /// 安静：更晚介入、爬得更缓
    public static let quiet: [FanStep] = [
        FanStep(upAtC: 68, percent: 25),
        FanStep(upAtC: 78, percent: 40),
        FanStep(upAtC: 86, percent: 60),
        FanStep(upAtC: 93, percent: 80),
        FanStep(upAtC: 98, percent: 100),
    ]
    /// 激进：更早介入、爬得更快
    public static let aggressive: [FanStep] = [
        FanStep(upAtC: 52, percent: 40),
        FanStep(upAtC: 62, percent: 60),
        FanStep(upAtC: 70, percent: 75),
        FanStep(upAtC: 78, percent: 90),
        FanStep(upAtC: 86, percent: 100),
    ]

    public init(steps: [FanStep] = FanPolicy.balanced,
                hysteresisC: Double = 4,
                minDwellSeconds: Double = 30,
                criticalC: Double = 100) {
        self.steps = steps
        self.hysteresisC = hysteresisC
        self.minDwellSeconds = minDwellSeconds
        self.criticalC = criticalC
    }

    public func validated() -> FanPolicy {
        func clamp(_ v: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double {
            guard v.isFinite else { return fallback }
            return min(max(v, r.lowerBound), r.upperBound)
        }
        var p = self
        p.hysteresisC = clamp(hysteresisC, FanPolicy.hysteresisRange, 4)
        p.minDwellSeconds = clamp(minDwellSeconds, FanPolicy.dwellRange, 30)
        p.criticalC = clamp(criticalC, FanPolicy.criticalRange, 100)

        // 档位：夹紧数值、按温度排序、去掉温度重复的、保证百分比单调不降
        var cleaned = steps
            .map { FanStep(upAtC: clamp($0.upAtC, FanPolicy.stepTempRange, 70),
                           percent: min(max($0.percent, 0), 100)) }
            .sorted { $0.upAtC < $1.upAtC }
        var deduped: [FanStep] = []
        for step in cleaned {
            if let last = deduped.last {
                if step.upAtC - last.upAtC < 0.5 { continue }          // 太近的档位没意义
                if step.percent < last.percent { continue }            // 温度更高却转得更慢 → 丢弃
            }
            deduped.append(step)
        }
        cleaned = deduped.isEmpty ? FanPolicy.balanced : deduped
        p.steps = cleaned
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

    /// 分档决策的输入状态（由调用方保存，引擎本身保持纯函数）
    public struct StepState: Equatable, Sendable {
        /// 当前档位索引；-1 = 未接管（固件控制）
        public var index: Int
        /// 已在当前档位停留的秒数
        public var dwellSeconds: Double

        public init(index: Int = -1, dwellSeconds: Double = 0) {
            self.index = index
            self.dwellSeconds = dwellSeconds
        }

        public static let firmware = StepState(index: -1, dwellSeconds: 0)
    }

    /// 纯函数：模式 + 当前最高温 + 风扇量程 + 当前档位 → 决策与新档位。
    /// 不读 SMC、不读时钟，因此可以完全单测。
    public static func decide(mode: FanMode,
                              maxTempC: Double?,
                              range: FanRange,
                              policy: FanPolicy,
                              state: StepState = .firmware)
        -> (decision: FanDecision, state: StepState) {

        guard range.isValid else { return (.releaseToFirmware, .firmware) }
        let p = policy.validated()

        // 临界温度：任何手动模式下都无条件全速，覆盖用户设置。
        // auto 模式不接管 —— 固件自己会处理。
        if mode.isManual, let t = maxTempC, t.isFinite, t >= p.criticalC {
            return (.setTarget(range.maxRPM), StepState(index: p.steps.count - 1, dwellSeconds: 0))
        }

        switch mode {
        case .auto:
            return (.releaseToFirmware, .firmware)

        case .full:
            return (.setTarget(range.maxRPM), StepState(index: p.steps.count - 1, dwellSeconds: 0))

        case .percent(let raw):
            let pct = Double(min(max(raw, 0), 100)) / 100
            let target = range.minRPM + pct * (range.maxRPM - range.minRPM)
            return (.setTarget(safetyFloor(target, maxTempC: maxTempC, range: range, policy: p)),
                    state)

        case .curve:
            guard let t = maxTempC, t.isFinite else { return (.releaseToFirmware, .firmware) }
            let next = nextStepIndex(temp: t, policy: p, state: state)
            guard next >= 0, next < p.steps.count else {
                return (.releaseToFirmware, .firmware)
            }
            let pct = Double(p.steps[next].percent) / 100
            let target = range.minRPM + pct * (range.maxRPM - range.minRPM)
            let newState = StepState(index: next,
                                     dwellSeconds: next == state.index ? state.dwellSeconds : 0)
            return (.setTarget(safetyFloor(target, maxTempC: t, range: range, policy: p)), newState)
        }
    }

    /// 分档 + 迟滞 + 最短停留的核心判定。
    ///
    /// - **升档立即生效**（安全方向不能拖）
    /// - **降档要同时满足两个条件**：温度低于「进入该档的阈值 − 迟滞」，
    ///   且已在该档停留够久；并且一次只降一档，避免大幅跳变
    public static func nextStepIndex(temp: Double, policy: FanPolicy, state: StepState) -> Int {
        let steps = policy.steps
        guard !steps.isEmpty else { return -1 }

        // 温度对应的"目标档位"：满足 temp >= upAtC 的最高档
        var target = -1
        for (i, step) in steps.enumerated() where temp >= step.upAtC { target = i }

        let current = min(max(state.index, -1), steps.count - 1)
        if target > current { return target }        // 升档：立即
        if target == current { return current }

        // 降档：迟滞 + 停留时间都满足才降，且一次只降一档
        guard current >= 0 else { return -1 }
        let dropBelow = steps[current].upAtC - policy.hysteresisC
        guard temp <= dropBelow, state.dwellSeconds >= policy.minDwellSeconds else {
            return current
        }
        return current - 1
    }

    /// 安全下限：温度越高，允许的最低转速越高。
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

    /// 重新评估间隔。曲线模式要跟温度走，固定模式只需偶尔复查（防止固件把 md 复位）。
    public static func reevaluateInterval(mode: FanMode) -> TimeInterval {
        switch mode {
        case .auto: return 0
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
