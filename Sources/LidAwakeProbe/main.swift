import Foundation
import Darwin
import LidAwakeCore

// MARK: - 原理
//
// mach_absolute_time() 在系统睡眠期间**停止推进**，mach_continuous_time() **继续推进**。
// 两者之差 = 开机以来的累计睡眠时长。因此"刚才那次合盖到底睡没睡、睡了多久"
// 可以被精确、确定性地测出来，不依赖日志解析、不依赖主观感受。

let usage = """
lidawake-probe \(LidAwakeInfo.version) — 合盖连续性探针

用法:
  lidawake-probe start [--interval <秒>] [--tcp <host:port>] [--tag <名字>]
  lidawake-probe stop
  lidawake-probe report [--expect awake|sleep] [--json]
  lidawake-probe status
  lidawake-probe run ...        # 内部使用（前台采样循环）

典型用法:
  lidawake-probe start          # 然后合盖 60 秒，再打开
  lidawake-probe report --expect awake
"""

let home = FileManager.default.homeDirectoryForCurrentUser.path
let baseDir = home + "/.lidawake-probe"
let pidFile = baseDir + "/current.pid"
let currentFile = baseDir + "/current.run"

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)

func ticksToSeconds(_ ticks: UInt64) -> Double {
    Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
}

struct Sample: Codable {
    var t: Double        // wall clock (epoch)
    var abs: Double      // mach_absolute_time，睡眠时暂停
    var cont: Double     // mach_continuous_time，睡眠时继续
    var iface: String?   // 有 IPv4 的活动网卡
    var lid: Bool?       // true = 合上
    var tcp: Int?        // 1 成功 / 0 失败 / nil 未测
}

// MARK: - 系统探测

func activeIPv4Interface() -> String? {
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0 else { return nil }
    defer { freeifaddrs(addrs) }
    var ptr = addrs
    while let p = ptr {
        let ifa = p.pointee
        if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
            let flags = Int32(ifa.ifa_flags)
            if flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 {
                return String(cString: ifa.ifa_name)
            }
        }
        ptr = ifa.ifa_next
    }
    return nil
}

func tcpReachable(host: String, port: String, timeoutMS: Int32 = 2000) -> Bool {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                         ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, port, &hints, &res) == 0, let info = res else { return false }
    defer { freeaddrinfo(res) }

    let fd = socket(info.pointee.ai_family, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

    let rc = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
    if rc == 0 { return true }
    guard errno == EINPROGRESS else { return false }

    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&pfd, 1, timeoutMS) == 1 else { return false }
    var soerr: Int32 = 0
    var len = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len) == 0 else { return false }
    return soerr == 0
}

// MARK: - 参数

var argv = Array(CommandLine.arguments.dropFirst())
let wantJSON = argv.contains("--json")
argv.removeAll { $0 == "--json" }

func optionValue(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    let v = argv[i + 1]
    argv.removeSubrange(i...(i + 1))
    return v
}

guard !argv.isEmpty, !argv.contains("-h"), !argv.contains("--help") else { print(usage); exit(0) }
let command = argv.removeFirst()
try? FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)

// MARK: - run（采样循环）

func runLoop(runPath: String, interval: Double, tcp: (String, String)?) -> Never {
    // 脱离控制终端：否则调用方的 shell 一关就会把采样进程一起 SIGHUP 掉，
    // 而采样必须跨越"合盖—开盖"整个过程。
    _ = setsid()
    guard let fh = FileHandle(forWritingAtPath: runPath) else { exit(1) }
    _ = try? fh.seekToEnd()
    let encoder = JSONEncoder()
    var i = 0
    // 不自己处理 SIGTERM：默认行为直接终止进程即可。
    // 每个采样点是一次完整的 write，半行不会写出去，report 也会跳过无法解析的行。
    while true {
        var s = Sample(t: Date().timeIntervalSince1970,
                       abs: ticksToSeconds(mach_absolute_time()),
                       cont: ticksToSeconds(mach_continuous_time()),
                       iface: activeIPv4Interface(),
                       lid: SystemInfo.clamshellClosed(),
                       tcp: nil)
        if let (h, p) = tcp, i % 5 == 0 { s.tcp = tcpReachable(host: h, port: p) ? 1 : 0 }
        if let line = try? encoder.encode(s) {
            try? fh.write(contentsOf: line + Data("\n".utf8))
        }
        i += 1
        Thread.sleep(forTimeInterval: interval)
    }
}

// MARK: - 报告

struct Report {
    var samples = 0
    var firstT: Double = 0
    var lastT: Double = 0
    var sleptSeconds: Double = 0
    var maxWallGap: Double = 0
    var ifaceName: String?
    var ifaceMissing = 0
    var lidClosedSeconds: Double = 0
    var lidEverClosed = false
    var tcpOK = 0
    var tcpFail = 0
}

func analyze(_ path: String) -> Report? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let decoder = JSONDecoder()
    var samples: [Sample] = []
    for line in text.split(separator: "\n") where !line.isEmpty {
        if let s = try? decoder.decode(Sample.self, from: Data(line.utf8)) { samples.append(s) }
    }
    guard samples.count >= 2 else { return nil }

    var r = Report()
    r.samples = samples.count
    r.firstT = samples[0].t
    r.lastT = samples[samples.count - 1].t
    for (idx, s) in samples.enumerated() {
        if s.iface == nil { r.ifaceMissing += 1 } else if r.ifaceName == nil { r.ifaceName = s.iface }
        if s.lid == true { r.lidEverClosed = true }
        if let t = s.tcp { if t == 1 { r.tcpOK += 1 } else { r.tcpFail += 1 } }
        guard idx > 0 else { continue }
        let prev = samples[idx - 1]
        let sleepDelta = (s.cont - s.abs) - (prev.cont - prev.abs)
        if sleepDelta > 0.2 { r.sleptSeconds += sleepDelta }
        r.maxWallGap = max(r.maxWallGap, s.t - prev.t)
        if prev.lid == true { r.lidClosedSeconds += (s.t - prev.t) }
    }
    return r
}

func latestRunPath() -> String? {
    if let p = try? String(contentsOfFile: currentFile, encoding: .utf8) {
        let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
        if FileManager.default.fileExists(atPath: trimmed) { return trimmed }
    }
    let files = (try? FileManager.default.contentsOfDirectory(atPath: baseDir))?
        .filter { $0.hasSuffix(".jsonl") }.sorted() ?? []
    return files.last.map { baseDir + "/" + $0 }
}

func readPID() -> Int32? {
    guard let s = try? String(contentsOfFile: pidFile, encoding: .utf8),
          let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return kill(pid, 0) == 0 ? pid : nil
}

// MARK: - 命令

switch command {
case "run":
    let runPath = optionValue("--out") ?? { print("run 需要 --out"); exit(1) }()
    let interval = optionValue("--interval").flatMap(Double.init) ?? 1.0
    var tcp: (String, String)?
    if let spec = optionValue("--tcp") {
        let parts = spec.split(separator: ":")
        if parts.count == 2 { tcp = (String(parts[0]), String(parts[1])) }
    }
    runLoop(runPath: runPath, interval: interval, tcp: tcp)

case "start":
    if let pid = readPID() {
        print("已有探针在运行 (pid \(pid))。先 lidawake-probe stop 或直接 report。")
        exit(1)
    }
    let interval = optionValue("--interval") ?? "1"
    let tcp = optionValue("--tcp")
    let tag = optionValue("--tag") ?? "run"
    let stamp = Int(Date().timeIntervalSince1970)
    let runPath = "\(baseDir)/\(stamp)-\(tag).jsonl"
    FileManager.default.createFile(atPath: runPath, contents: nil)
    try? runPath.write(toFile: currentFile, atomically: true, encoding: .utf8)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    var childArgs = ["run", "--out", runPath, "--interval", interval]
    if let tcp { childArgs += ["--tcp", tcp] }
    p.arguments = childArgs
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch {
        print("无法启动采样进程: \(error)"); exit(1)
    }
    try? "\(p.processIdentifier)".write(toFile: pidFile, atomically: true, encoding: .utf8)
    print("""
    探针已启动 (pid \(p.processIdentifier))，采样间隔 \(interval)s
    数据文件: \(runPath)

    现在请：合上盖子 ≥ 60 秒，然后打开。
    回来后运行: lidawake-probe report
    """)

case "stop":
    if let pid = readPID() {
        kill(pid, SIGTERM)
        print("已停止探针 (pid \(pid))")
    } else {
        print("没有正在运行的探针")
    }
    try? FileManager.default.removeItem(atPath: pidFile)

case "status":
    if let pid = readPID() { print("探针运行中 (pid \(pid))") } else { print("探针未运行") }
    if let p = latestRunPath() { print("最近数据文件: \(p)") }

case "report":
    let expect = optionValue("--expect")
    guard let path = latestRunPath(), let r = analyze(path) else {
        print("没有足够的采样数据（至少需要 2 个采样点）"); exit(1)
    }
    let slept = r.sleptSeconds > 0.5
    let duration = r.lastT - r.firstT

    if wantJSON {
        let obj: [String: Any] = [
            "file": path, "samples": r.samples, "durationSeconds": duration,
            "slept": slept, "sleptSeconds": r.sleptSeconds, "maxWallGap": r.maxWallGap,
            "iface": r.ifaceName ?? "", "ifaceMissingSamples": r.ifaceMissing,
            "lidEverClosed": r.lidEverClosed, "lidClosedSeconds": r.lidClosedSeconds,
            "tcpOK": r.tcpOK, "tcpFail": r.tcpFail,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: obj,
                                              options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) { print(s) }
    } else {
        print("LidAwake 连续性报告")
        print("--------------------")
        print(String(format: "采样            : %d 个点，跨度 %.1fs（%@）", r.samples, duration, path))
        print(String(format: "睡眠检测        : slept=%@   累计睡眠 %.2fs", slept ? "true" : "false", r.sleptSeconds))
        print(String(format: "最大采样间隔    : %.2fs %@", r.maxWallGap,
                     r.maxWallGap > 5 ? "（进程曾被冻结）" : ""))
        if r.lidEverClosed {
            print(String(format: "上盖            : 检测到合盖，合上约 %.0fs", r.lidClosedSeconds))
        } else {
            print("上盖            : ⚠️ 采样期间未检测到合盖 —— 本次测试无效")
        }
        let ifaceName = r.ifaceName ?? "无"
        print("网卡连续性      : \(ifaceName)，\(r.ifaceMissing)/\(r.samples) 个采样点无 IPv4 "
              + (r.ifaceMissing == 0 ? "✅" : "⚠️"))
        if r.tcpOK + r.tcpFail > 0 {
            print("TCP 连通性      : \(r.tcpOK) 成功 / \(r.tcpFail) 失败 "
                  + (r.tcpFail == 0 ? "✅" : "⚠️"))
        }
        if let expect {
            let wantAwake = (expect == "awake")
            // 期望"不睡眠"时必须证明盖子真的合过，否则 slept=false 毫无意义。
            // 期望"发生睡眠"时，睡眠本身就是证据 —— 合盖瞬间系统可能在下一个
            // 采样点之前就睡了，采不到 lid=true 是正常的，不该判 FAIL。
            let pass = wantAwake ? (!slept && r.lidEverClosed) : slept
            print("期望            : \(wantAwake ? "不睡眠（且盖子确实合过）" : "发生睡眠")")
            print("判定            : \(pass ? "✅ PASS" : "❌ FAIL")"
                  + (wantAwake && !r.lidEverClosed ? "（未检测到合盖，测试无效）" : ""))
            exit(pass ? 0 : 1)
        }
    }

default:
    print(usage); exit(1)
}

exit(0)
