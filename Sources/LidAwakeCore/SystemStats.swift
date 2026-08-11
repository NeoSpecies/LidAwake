import Foundation
import Darwin
import IOKit

/// 系统实时状态采集。
///
/// 全部使用公开 API，**不需要任何权限**：
///   CPU     host_processor_info(PROCESSOR_CPU_LOAD_INFO)
///   内存    host_statistics64(HOST_VM_INFO64) + sysctl hw.memsize
///   磁盘容量 statfs("/")
///   磁盘 IO  IOKit IOBlockStorageDriver 的 Statistics
///   网络     getifaddrs 的 if_data（ifi_ibytes / ifi_obytes）
///
/// 设计上分成"原始计数器快照"和"两次快照求出的速率"两层：
/// 求速率是纯函数，可以单测；采样本身依赖系统状态，不可测。
public struct StatsSnapshot: Sendable, Equatable {
    /// 单调递增的 CPU tick 累计
    public var cpuUser: Double
    public var cpuSystem: Double
    public var cpuIdle: Double
    public var cpuNice: Double
    /// 单调递增的字节累计
    public var diskRead: UInt64
    public var diskWrite: UInt64
    public var netRx: UInt64
    public var netTx: UInt64
    /// 采样时刻（用 mach_continuous_time 换算的秒，不受系统时间调整影响）
    public var timestamp: Double

    public init(cpuUser: Double = 0, cpuSystem: Double = 0, cpuIdle: Double = 0, cpuNice: Double = 0,
                diskRead: UInt64 = 0, diskWrite: UInt64 = 0,
                netRx: UInt64 = 0, netTx: UInt64 = 0, timestamp: Double = 0) {
        self.cpuUser = cpuUser
        self.cpuSystem = cpuSystem
        self.cpuIdle = cpuIdle
        self.cpuNice = cpuNice
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.netRx = netRx
        self.netTx = netTx
        self.timestamp = timestamp
    }
}

public struct StatsRates: Sendable, Equatable {
    /// 0…1
    public var cpuBusy: Double
    public var cpuUser: Double
    public var cpuSystem: Double
    /// 字节 / 秒
    public var diskReadPerSec: Double
    public var diskWritePerSec: Double
    public var netRxPerSec: Double
    public var netTxPerSec: Double

    public init(cpuBusy: Double = 0, cpuUser: Double = 0, cpuSystem: Double = 0,
                diskReadPerSec: Double = 0, diskWritePerSec: Double = 0,
                netRxPerSec: Double = 0, netTxPerSec: Double = 0) {
        self.cpuBusy = cpuBusy
        self.cpuUser = cpuUser
        self.cpuSystem = cpuSystem
        self.diskReadPerSec = diskReadPerSec
        self.diskWritePerSec = diskWritePerSec
        self.netRxPerSec = netRxPerSec
        self.netTxPerSec = netTxPerSec
    }

    /// 纯函数：两次快照 → 速率。
    /// 计数器回绕（进程重启 / 网卡重置 / 磁盘热插拔）时该项按 0 处理，绝不产生负数或天文数字。
    public static func between(_ old: StatsSnapshot, _ new: StatsSnapshot) -> StatsRates {
        var r = StatsRates()

        let dUser = max(0, new.cpuUser - old.cpuUser)
        let dSys = max(0, new.cpuSystem - old.cpuSystem)
        let dIdle = max(0, new.cpuIdle - old.cpuIdle)
        let dNice = max(0, new.cpuNice - old.cpuNice)
        let total = dUser + dSys + dIdle + dNice
        if total > 0 {
            r.cpuUser = (dUser + dNice) / total
            r.cpuSystem = dSys / total
            r.cpuBusy = min(1, r.cpuUser + r.cpuSystem)
        }

        let dt = new.timestamp - old.timestamp
        guard dt > 0.001, dt.isFinite else { return r }
        func rate(_ a: UInt64, _ b: UInt64) -> Double {
            b >= a ? Double(b - a) / dt : 0        // 回绕 → 0
        }
        r.diskReadPerSec = rate(old.diskRead, new.diskRead)
        r.diskWritePerSec = rate(old.diskWrite, new.diskWrite)
        r.netRxPerSec = rate(old.netRx, new.netRx)
        r.netTxPerSec = rate(old.netTx, new.netTx)
        return r
    }
}

public struct MemoryInfo: Sendable, Equatable {
    public var used: Double
    public var total: Double
    public var compressed: Double
    public var swapUsed: Double
    public var fraction: Double { total > 0 ? min(1, used / total) : 0 }

    public init(used: Double = 0, total: Double = 0, compressed: Double = 0, swapUsed: Double = 0) {
        self.used = used
        self.total = total
        self.compressed = compressed
        self.swapUsed = swapUsed
    }
}

public struct DiskInfo: Sendable, Equatable {
    public var free: Double
    public var total: Double
    public var usedFraction: Double { total > 0 ? min(1, (total - free) / total) : 0 }

    public init(free: Double = 0, total: Double = 0) {
        self.free = free
        self.total = total
    }
}

public enum SystemStats {

    // MARK: 快照

    public static func snapshot() -> StatsSnapshot {
        var s = StatsSnapshot()
        if let c = cpuTicks() {
            s.cpuUser = c.user
            s.cpuSystem = c.system
            s.cpuIdle = c.idle
            s.cpuNice = c.nice
        }
        let io = diskIO()
        s.diskRead = io.read
        s.diskWrite = io.write
        let net = netBytes()
        s.netRx = net.rx
        s.netTx = net.tx
        s.timestamp = monotonicSeconds()
        return s
    }

    /// 用 mach_continuous_time：不受系统时间被 NTP 调整影响。
    public static func monotonicSeconds() -> Double {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(mach_continuous_time()) * Double(tb.numer) / Double(tb.denom) / 1_000_000_000
    }

    private static func cpuTicks() -> (user: Double, system: Double, idle: Double, nice: Double)? {
        var count = mach_msg_type_number_t(0)
        var cpus = natural_t(0)
        var info: processor_info_array_t?
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                 &cpus, &info, &count) == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
        }
        var u = 0.0, s = 0.0, i = 0.0, n = 0.0
        for c in 0..<Int(cpus) {
            let base = c * Int(CPU_STATE_MAX)
            u += Double(info[base + Int(CPU_STATE_USER)])
            s += Double(info[base + Int(CPU_STATE_SYSTEM)])
            i += Double(info[base + Int(CPU_STATE_IDLE)])
            n += Double(info[base + Int(CPU_STATE_NICE)])
        }
        return (u, s, i, n)
    }

    private static func diskIO() -> (read: UInt64, write: UInt64) {
        var r: UInt64 = 0, w: UInt64 = 0
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                          IOServiceMatching("IOBlockStorageDriver"),
                                          &iter) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iter) }
        while case let drive = IOIteratorNext(iter), drive != 0 {
            defer { IOObjectRelease(drive) }
            guard let props = IORegistryEntryCreateCFProperty(drive, "Statistics" as CFString,
                                                              kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            r += (props["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            w += (props["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (r, w)
    }

    private static func netBytes() -> (rx: UInt64, tx: UInt64) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return (0, 0) }
        defer { freeifaddrs(addrs) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var p = addrs
        while let cur = p {
            let ifa = cur.pointee
            if ifa.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               Int32(ifa.ifa_flags) & IFF_LOOPBACK == 0,
               let d = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rx += UInt64(d.pointee.ifi_ibytes)
                tx += UInt64(d.pointee.ifi_obytes)
            }
            p = ifa.ifa_next
        }
        return (rx, tx)
    }

    // MARK: 瞬时值（不需要两次采样）

    public static func memory() -> MemoryInfo {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride
                                           / MemoryLayout<integer_t>.stride)
        let rc = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var total: UInt64 = 0
        var sz = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &sz, nil, 0)
        guard rc == KERN_SUCCESS else { return MemoryInfo(used: 0, total: Double(total)) }

        let page = Double(vm_kernel_page_size)
        // 与"活动监视器 → 已用内存"口径一致：App 内存 + 联动内存 + 压缩内存
        let appMemory = Double(stats.internal_page_count &- stats.purgeable_count) * page
        let wired = Double(stats.wire_count) * page
        let compressed = Double(stats.compressor_page_count) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
            ? Double(swap.xsu_used) : 0

        return MemoryInfo(used: appMemory + wired + compressed,
                          total: Double(total),
                          compressed: compressed,
                          swapUsed: swapUsed)
    }

    public static func disk(path: String = "/") -> DiskInfo {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return DiskInfo() }
        return DiskInfo(free: Double(st.f_bavail) * Double(st.f_bsize),
                        total: Double(st.f_blocks) * Double(st.f_bsize))
    }

    public static func loadAverage() -> Double {
        var l = [Double](repeating: 0, count: 3)
        guard getloadavg(&l, 3) > 0 else { return 0 }
        return l[0]
    }

    /// 主用网卡名（有 IPv4 的非回环接口），用于面板上标注是哪张网卡。
    public static func primaryInterface() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return nil }
        defer { freeifaddrs(addrs) }
        var p = addrs
        while let cur = p {
            let ifa = cur.pointee
            if ifa.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
               Int32(ifa.ifa_flags) & IFF_UP != 0,
               Int32(ifa.ifa_flags) & IFF_RUNNING != 0,
               Int32(ifa.ifa_flags) & IFF_LOOPBACK == 0 {
                return String(cString: ifa.ifa_name)
            }
            p = ifa.ifa_next
        }
        return nil
    }
}

// MARK: - 格式化

public extension Format {
    /// 1024 进制，给容量用。
    static func bytes(_ v: Double, decimals: Int = 1) -> String {
        guard v.isFinite, v > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = v
        var i = 0
        while value >= 1024, i < units.count - 1 {
            value /= 1024
            i += 1
        }
        // 到 GB 以上才需要小数位，KB/MB 给整数更好读
        let d = i >= 3 ? decimals : 0
        return String(format: "%.\(d)f %@", value, units[i])
    }

    /// 给吞吐用，带 /s。
    static func rate(_ bytesPerSec: Double) -> String {
        guard bytesPerSec.isFinite, bytesPerSec >= 1 else { return "0 B/s" }
        return bytes(bytesPerSec, decimals: 1) + "/s"
    }

    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "0%" }
        return String(format: "%.0f%%", min(1, max(0, fraction)) * 100)
    }
}
