import Foundation
import IOKit

/// AppleSMC 访问。
///
/// 读取不需要任何权限（实测非 root 可打开并读到 3668 个键）；
/// **写入需要 root**，所以只有 `lidawaked` 会调用写接口。
///
/// 协议要点：打开 `AppleSMC` 服务后用 selector 2（kSMCHandleYPCEvent）做结构体调用，
/// 先用 `data8=9` 取键信息（类型/长度），再用 `data8=5` 读、`data8=6` 写。
public final class SMC {

    // MARK: SMC 协议结构体（布局必须和内核一致）

    private struct Version { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0
                             var reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct LimitData { var version: UInt16 = 0; var length: UInt16 = 0
                               var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0
                               var memPLimit: UInt32 = 0 }
    private struct KeyInfoData { var dataSize: IOByteCount32 = 0; var dataType: UInt32 = 0
                                 var dataAttributes: UInt8 = 0 }
    private struct ParamStruct {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = LimitData()
        var keyInfo = KeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private enum Selector: UInt8 {
        case readKey = 5
        case writeKey = 6
        case keyFromIndex = 8
        case keyInfo = 9
    }

    private var connection: io_connect_t = 0
    private var keyInfoCache: [String: KeyInfoData] = [:]
    private let lock = NSLock()

    public private(set) var isOpen = false

    public init() { open() }
    deinit { close() }

    private func open() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        isOpen = IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS
    }

    public func close() {
        guard isOpen else { return }
        IOServiceClose(connection)
        isOpen = false
    }

    // MARK: 基础调用

    private static func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for c in s.utf8.prefix(4) { r = (r << 8) | UInt32(c) }
        return r
    }

    private static func typeString(_ v: UInt32) -> String {
        let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                 UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return (String(bytes: b.filter { $0 != 0 }, encoding: .ascii) ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func call(_ input: inout ParamStruct) -> ParamStruct? {
        guard isOpen else { return nil }
        var output = ParamStruct()
        var size = MemoryLayout<ParamStruct>.stride
        let rc = withUnsafePointer(to: &input) { ptr in
            IOConnectCallStructMethod(connection, 2, ptr,
                                      MemoryLayout<ParamStruct>.stride, &output, &size)
        }
        guard rc == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    private func info(for key: String) -> KeyInfoData? {
        lock.lock()
        if let cached = keyInfoCache[key] { lock.unlock(); return cached }
        lock.unlock()

        var p = ParamStruct()
        p.key = Self.fourCC(key)
        p.data8 = Selector.keyInfo.rawValue
        guard let out = call(&p) else { return nil }

        lock.lock()
        keyInfoCache[key] = out.keyInfo
        lock.unlock()
        return out.keyInfo
    }

    private func rawBytes(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard let ki = info(for: key) else { return nil }
        var p = ParamStruct()
        p.key = Self.fourCC(key)
        p.keyInfo = ki
        p.data8 = Selector.readKey.rawValue
        guard let out = call(&p) else { return nil }
        let size = min(Int(ki.dataSize), 32)
        var bytes = [UInt8]()
        withUnsafeBytes(of: out.bytes) { raw in
            for i in 0..<size { bytes.append(raw[i]) }
        }
        return (Self.typeString(ki.dataType), bytes)
    }

    // MARK: 读

    /// SMC 的 `flt` 是小端 IEEE754
    public func readFloat(_ key: String) -> Double? {
        guard let r = rawBytes(key), r.type == "flt", r.bytes.count >= 4 else { return nil }
        let v = r.bytes.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }
        return v.isFinite ? Double(v) : nil
    }

    public func readUInt8(_ key: String) -> UInt8? {
        guard let r = rawBytes(key), r.bytes.count >= 1 else { return nil }
        return r.bytes[0]
    }

    /// 枚举全部键名。开销较大（本机 3668 个），只在启动时做一次。
    public func allKeys() -> [String] {
        guard let ki = info(for: "#KEY") else { return [] }
        var p = ParamStruct()
        p.key = Self.fourCC("#KEY")
        p.keyInfo = ki
        p.data8 = Selector.readKey.rawValue
        guard let out = call(&p) else { return [] }
        var count = 0
        withUnsafeBytes(of: out.bytes) { raw in
            count = Int((UInt32(raw[0]) << 24) | (UInt32(raw[1]) << 16)
                        | (UInt32(raw[2]) << 8) | UInt32(raw[3]))
        }
        guard count > 0, count < 20000 else { return [] }

        var keys: [String] = []
        keys.reserveCapacity(count)
        for i in 0..<count {
            var q = ParamStruct()
            q.data8 = Selector.keyFromIndex.rawValue
            q.data32 = UInt32(i)
            guard let o = call(&q) else { continue }
            keys.append(Self.typeString(o.key))
        }
        return keys
    }

    // MARK: 写（需要 root）

    @discardableResult
    public func writeFloat(_ key: String, _ value: Double) -> Bool {
        guard let ki = info(for: key), Self.typeString(ki.dataType) == "flt" else { return false }
        var p = ParamStruct()
        p.key = Self.fourCC(key)
        p.keyInfo = ki
        p.data8 = Selector.writeKey.rawValue
        let bits = Float32(value).bitPattern.littleEndian
        withUnsafeBytes(of: bits) { src in
            withUnsafeMutableBytes(of: &p.bytes) { dst in
                for i in 0..<4 { dst[i] = src[i] }
            }
        }
        return call(&p) != nil
    }

    @discardableResult
    public func writeUInt8(_ key: String, _ value: UInt8) -> Bool {
        guard let ki = info(for: key) else { return false }
        var p = ParamStruct()
        p.key = Self.fourCC(key)
        p.keyInfo = ki
        p.data8 = Selector.writeKey.rawValue
        withUnsafeMutableBytes(of: &p.bytes) { $0[0] = value }
        return call(&p) != nil
    }
}

// MARK: - 风扇与温度读取（不需要 root）

public final class FanSensors {

    private let smc: SMC
    /// 温度传感器有 300+ 个，全读太贵。启动时枚举一次挑出最热的一批，之后只读这些。
    private var temperatureKeys: [String] = []

    public init(smc: SMC = SMC()) {
        self.smc = smc
        discoverTemperatureKeys()
    }

    public var isAvailable: Bool { smc.isOpen }

    public var fanCount: Int { Int(smc.readUInt8("FNum") ?? 0) }

    public func range() -> FanRange {
        FanRange(minRPM: smc.readFloat("F0Mn") ?? 0, maxRPM: smc.readFloat("F0Mx") ?? 0)
    }

    public func actualRPM() -> [Double] {
        (0..<fanCount).compactMap { smc.readFloat("F\($0)Ac") }
    }

    public func targetRPM() -> [Double] {
        (0..<fanCount).compactMap { smc.readFloat("F\($0)Tg") }
    }

    /// 各风扇当前是否处于手动模式（`F0md`，**小写**）
    public func manualModes() -> [Bool] {
        (0..<fanCount).compactMap { smc.readUInt8("F\($0)md").map { $0 != 0 } }
    }

    /// 当前最高温度及其传感器名
    public func hottest() -> (sensor: String, celsius: Double)? {
        var best: (String, Double)?
        for key in temperatureKeys {
            guard let v = smc.readFloat(key), v > 5, v < 130 else { continue }
            if best == nil || v > best!.1 { best = (key, v) }
        }
        return best.map { (sensor: $0.0, celsius: $0.1) }
    }

    /// 启动时枚举一次，挑出**真实**的温度传感器。
    ///
    /// 踩过的坑：最初按"读数最高"挑，结果选中的全是**限值寄存器**而不是温度 ——
    /// 本机 322 个候选里有 28 个恒定不动，其中 `Tf06` 永远是 97.3°C、`Tf16` 永远是 95.1°C。
    /// 用它们驱动温度曲线，会让风扇永远全速（看起来在工作，实际逻辑是错的）。
    ///
    /// 正确做法是**按变化量识别**：隔 2 秒采样两次，只保留读数发生变化的键。
    /// 实测真实最高温约 80°C（TVDc / TCMb / Tp00），而不是那个假的 97.3°C。
    private func discoverTemperatureKeys() {
        guard smc.isOpen else { return }

        var first: [String: Double] = [:]
        for key in smc.allKeys() where key.hasPrefix("T") {
            guard let v = smc.readFloat(key), v > 5, v < 130 else { continue }
            first[key] = v
        }
        guard !first.isEmpty else { return }

        Thread.sleep(forTimeInterval: 2.0)

        var moving: [(String, Double)] = []
        var frozen: [String] = []
        for (key, old) in first {
            guard let now = smc.readFloat(key) else { continue }
            if abs(now - old) > 0.05 { moving.append((key, now)) } else { frozen.append(key) }
        }
        constantKeyCount = frozen.count

        // 兜底：机器完全空闲时可能什么都不动，那就退回"核心/GPU 传感器"前缀白名单。
        // 这些是 Apple Silicon 上确定的真实温度源。
        if moving.count < 4 {
            let prefixes = ["Tp", "Te", "Tg"]
            for (key, v) in first where prefixes.contains(where: { key.hasPrefix($0) }) {
                if !moving.contains(where: { $0.0 == key }) { moving.append((key, v)) }
            }
        }

        moving.sort { $0.1 > $1.1 }
        temperatureKeys = moving.prefix(16).map(\.0)
    }

    /// 被判定为恒定（疑似限值寄存器）而排除掉的键数量，诊断用
    public private(set) var constantKeyCount = 0

    public var discoveredSensorCount: Int { temperatureKeys.count }
}

// MARK: - 风扇控制（需要 root，只有守护进程用）

public final class FanController {

    private let smc: SMC
    private let sensors: FanSensors
    /// 接管前各风扇的目标值，用于交还固件时精确写回
    private var originalTargets: [Double] = []
    private var hasTakenOver = false

    public init(smc: SMC = SMC()) {
        self.smc = smc
        self.sensors = FanSensors(smc: smc)
    }

    public var isAvailable: Bool { smc.isOpen && sensors.fanCount > 0 }
    public var fanCount: Int { sensors.fanCount }
    public var readOnly: FanSensors { sensors }

    /// 施加一次决策。返回是否全部成功。
    @discardableResult
    public func apply(_ decision: FanDecision) -> Bool {
        guard isAvailable else { return false }
        switch decision {
        case .releaseToFirmware:
            return release()
        case .setTarget(let rpm):
            return takeOver(rpm)
        }
    }

    private func takeOver(_ rpm: Double) -> Bool {
        let count = sensors.fanCount
        if !hasTakenOver {
            originalTargets = sensors.targetRPM()
            hasTakenOver = true
        }
        var ok = true
        for i in 0..<count {
            // 顺序很重要：必须先置 md=1 取得控制权，否则写 Tg 会被固件静默覆盖
            if !smc.writeUInt8("F\(i)md", 1) { ok = false }
            if !smc.writeFloat("F\(i)Tg", rpm) { ok = false }
        }
        return ok
    }

    /// 交还固件：写回原目标值，再把 md 置 0。
    /// 失效安全的核心 —— 退出、崩溃、卸载、重启都必须走到这里。
    @discardableResult
    public func release() -> Bool {
        guard isAvailable else { return true }
        var ok = true
        for i in 0..<sensors.fanCount {
            if i < originalTargets.count {
                _ = smc.writeFloat("F\(i)Tg", originalTargets[i])
            }
            if !smc.writeUInt8("F\(i)md", 0) { ok = false }
        }
        hasTakenOver = false
        originalTargets = []
        return ok
    }

    public func status(mode: FanMode, policy: FanPolicy) -> FanStatus {
        guard isAvailable else {
            return FanStatus(supported: false, note: "这台机器没有可控风扇（或 SMC 不可用）")
        }
        let r = sensors.range()
        let hot = sensors.hottest()
        let manual = sensors.manualModes().contains(true)
        return FanStatus(supported: true,
                         fanCount: sensors.fanCount,
                         mode: mode,
                         policy: policy,
                         actualRPM: sensors.actualRPM(),
                         minRPM: r.minRPM,
                         maxRPM: r.maxRPM,
                         targetRPM: manual ? sensors.targetRPM().first : nil,
                         maxTempC: hot?.celsius,
                         hottestSensor: hot?.sensor)
    }
}
