import Foundation

/// 纯函数决策引擎：不读时钟、不读 IOKit、不写文件。
/// 所有环境事实由 `Env` 注入 —— 这是让"合盖是否休眠"这类逻辑可单测的关键。
public enum Engine {

    /// 判定顺序即优先级，顺序被单元测试锁定（见 docs/TEST-PLAN.md #1–#22）。
    public static func evaluate(mode: Mode, startedAt: Date?, guards: Guards, env: Env) -> Decision {
        // 1. 用户意图优先
        guard mode.isActive else { return .release(.userOff) }

        // 2. 定时到期
        if let deadline = mode.deadline, env.now >= deadline {
            return .release(.timerExpired)
        }

        // 3. 单次最长时限
        if let maxSec = guards.maxSessionSeconds, maxSec.isFinite {
            let start = startedAt ?? env.now
            if env.now >= start.addingTimeInterval(maxSec) {
                return .release(.maxSessionReached)
            }
        }

        // 4. 必须接通电源
        if guards.requireExternalPower && !env.onExternalPower {
            return .release(.requiresExternalPower)
        }

        // 5. 过热
        if guards.releaseOnCriticalThermal && env.thermal == .critical {
            return .release(.criticalThermal)
        }

        // 6. 电量下限（仅电池供电时判定）
        if let floor = guards.batteryFloorPercent,
           !env.onExternalPower,
           let pct = env.batteryPercent,
           pct <= floor {
            return .release(.batteryFloor)
        }

        return .keepAwake
    }

    /// 会话在时间维度上的实际截止点 = min(定时截止, 开始+最长时限)。
    /// 返回 nil 表示不需要装定时器（无限期 + 无最长时限，或已关闭）。
    public static func effectiveDeadline(mode: Mode, startedAt: Date?, guards: Guards) -> Date? {
        guard mode.isActive else { return nil }
        var candidates: [Date] = []
        if let d = mode.deadline { candidates.append(d) }
        if let maxSec = guards.maxSessionSeconds, maxSec.isFinite, let start = startedAt {
            candidates.append(start.addingTimeInterval(maxSec))
        }
        return candidates.min()
    }

    /// 下一次必须重新评估的时间点（等同于 effectiveDeadline）。
    public static func nextEvaluation(mode: Mode, startedAt: Date?, guards: Guards) -> Date? {
        effectiveDeadline(mode: mode, startedAt: startedAt, guards: guards)
    }

    /// 守护进程是否可以空闲自退（零常驻开销）。
    /// 会话激活时永不自退 —— 否则定时器和守卫就失效了。
    public static func shouldIdleExit(mode: Mode, connectedClients: Int) -> Bool {
        !mode.isActive && connectedClients == 0
    }

    /// 重启后是否需要复位会话（失效安全）。
    /// - Returns: 需要复位时返回 true。
    public static func needsRebootReset(storedBootTime: Double,
                                        currentBootTime: Double,
                                        mode: Mode,
                                        persistAcrossReboot: Bool) -> Bool {
        guard mode.isActive else { return false }
        let rebooted = abs(storedBootTime - currentBootTime) > 1.0
        return rebooted && !persistAcrossReboot
    }
}
