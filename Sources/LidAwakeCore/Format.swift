import Foundation

public enum Format {

    /// 剩余时间 → "H:MM:SS"，负数与 nan 收敛为 "0:00:00"。
    public static func hms(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// 菜单栏用的紧凑形式："2h" / "45m" / "50s"。
    public static func compact(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0s" }
        let t = Int(seconds.rounded(.down))
        if t >= 3600 {
            let h = t / 3600, m = (t % 3600) / 60
            return m == 0 ? "\(h)h" : "\(h)h\(m)m"
        }
        if t >= 60 { return "\(t / 60)m" }
        return "\(t)s"
    }

    /// 解析 CLI 时长：`90` `30s` `15m` `2h` `1h30m` `1d`。
    public static func duration(_ text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        if let plain = Double(s) { return plain.isFinite ? plain : nil }

        var total: Double = 0
        var number = ""
        var sawUnit = false
        for ch in s {
            if ch.isNumber || ch == "." {
                number.append(ch)
                continue
            }
            guard let n = Double(number), n.isFinite else { return nil }
            let mult: Double
            switch ch {
            case "s": mult = 1
            case "m": mult = 60
            case "h": mult = 3600
            case "d": mult = 86400
            default: return nil
            }
            total += n * mult
            number = ""
            sawUnit = true
        }
        // 结尾还有数字残留（如 "1h30"）视为非法，避免歧义
        guard sawUnit, number.isEmpty else { return nil }
        return total
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f
    }()

    public static func timestamp(_ d: Date = Date()) -> String { iso.string(from: d) }

    /// 从 `pmset -g` 输出里提取 SleepDisabled 的值（回退路径的校验用）。
    public static func parseSleepDisabled(from pmsetOutput: String) -> Bool? {
        for rawLine in pmsetOutput.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("SleepDisabled") else { continue }
            let rest = line.dropFirst("SleepDisabled".count)
                .trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("1") { return true }
            if rest.hasPrefix("0") { return false }
            return nil
        }
        return nil
    }
}
