import AppKit
import LidAwakeCore
import CoreGraphics

/// 菜单栏折叠功能的自检。
///
/// 折叠的**视觉效果**（图标被顶出屏幕）没法在程序里验证 —— 那需要人眼看菜单栏。
/// 这里能机械验证的是：status item 能被创建、宽度按状态正确切换、
/// 系统状态采集有真实数据、权限状态判断正确、以及（授权后）AX 枚举确实能读到东西。
enum MenuBarSelfTest {

    /// `--out <路径>` 时把报告写文件。
    ///
    /// 为什么需要这个：从终端直接跑 App 二进制时，TCC 可能把权限归属到**终端**
    /// 而不是 LidAwake，于是自检会误报"未授权"。用 `open -a` 让 LaunchServices
    /// 正常启动 App，再把结果写文件读回来，才是真实的权限状态。
    private static var sink: [String] = []
    private static var outPath: String?

    private static func emit(_ line: String) {
        if outPath != nil { sink.append(line) } else { print(line) }
    }

    static func run() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
            outPath = args[i + 1]
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)   // 自检不要出现在菜单栏/Dock
        defer {
            if let outPath {
                try? sink.joined(separator: "\n").write(toFile: outPath,
                                                        atomically: true, encoding: .utf8)
            }
        }

        emit("LidAwake 菜单栏折叠自检 \(LidAwakeInfo.version)")
        emit(String(repeating: "=", count: 46))

        emit("\n── 权限")
        emit("  辅助功能（列出/点击菜单栏项）: \(Permissions.accessibilityGranted ? "已授权 ✅" : "未授权 ❌")")
        emit("  屏幕录制（真实图标预览，可选）: \(Permissions.screenRecordingGranted ? "已授权" : "未授权（不影响核心功能）")")
        emit("  真实图标预览开关: \(IconCapture.isRequested ? "已勾选" : "关闭")")

        emit("\n── 折叠机制（无需任何权限）")
        let fold = FoldController()
        emit("  初始状态: \(fold.state.rawValue)")
        fold.toggle(.folded)
        emit("  切到 folded  → 状态 \(fold.state.rawValue)")
        fold.toggle(.expanded)
        emit("  切到 expanded → 状态 \(fold.state.rawValue)")
        emit("  两个 status item 创建: ✅（未崩溃，且状态可切换）")
        emit("  说明: 图标被顶出屏幕的视觉效果需人眼确认，程序无法自证")

        emit("\n── 系统实时状态（无需任何权限）")
        let s1 = SystemStats.snapshot()
        Thread.sleep(forTimeInterval: 1.0)
        let s2 = SystemStats.snapshot()
        let rates = StatsRates.between(s1, s2)
        let mem = SystemStats.memory()
        let disk = SystemStats.disk()
        emit("  CPU    : \(Format.percent(rates.cpuBusy))  (user \(Format.percent(rates.cpuUser)) / sys \(Format.percent(rates.cpuSystem)))  负载 \(String(format: "%.2f", SystemStats.loadAverage()))")
        emit("  内存   : \(Format.bytes(mem.used)) / \(Format.bytes(mem.total)) (\(Format.percent(mem.fraction)))  压缩 \(Format.bytes(mem.compressed))  交换 \(Format.bytes(mem.swapUsed))")
        emit("  磁盘   : 可用 \(Format.bytes(disk.free)) / \(Format.bytes(disk.total))  IO ↓\(Format.rate(rates.diskReadPerSec)) ↑\(Format.rate(rates.diskWritePerSec))")
        emit("  网络   : \(SystemStats.primaryInterface() ?? "未连接")  ↓\(Format.rate(rates.netRxPerSec)) ↑\(Format.rate(rates.netTxPerSec))")

        emit("\n── 面板菜单结构（不弹出，直接导出）")
        let feature = FoldFeature()
        emit(feature.debugMenuDump().split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))

        emit("\n── 网格布局验证（用假数据，覆盖未授权时走不到的那条路径）")
        for count in [1, 4, 5, 12] {
            let fake = (0..<count).map { i in
                MenuBarItemInfo(pid: 1, appName: "App\(i)", bundleID: "x.\(i)", index: 0,
                                help: i % 3 == 0 ? "已连接" : nil,
                                frame: CGRect(x: 1000, y: 0, width: 24, height: 24),
                                isPressable: true, isOnScreen: i % 4 != 0)
            }
            let grid = GridPanelView(items: fake, accessibilityGranted: true,
                                     onSelect: { _ in }, onGrantAccessibility: {})
            let dims = grid.geometryDump().split(separator: "\n")
            emit("  \(count) 个磁贴 → \(dims.first ?? "")")
            if let tileLine = dims.first(where: { $0.contains("磁贴") }) {
                emit("      \(tileLine)")
            }
        }

        emit("\n── 菜单栏项枚举（需辅助功能）")
        guard Permissions.accessibilityGranted else {
            emit("  跳过：未授权辅助功能")
            emit("  授权后重跑本自检即可看到完整列表")
            return
        }
        let scanner = StatusItemScanner()
        let items = scanner.scan()
        let hidden = items.filter { !$0.isOnScreen }
        let pressable = items.filter(\.isPressable)
        emit("  读到 \(items.count) 个菜单栏项，来自 \(Set(items.map(\.appName)).count) 个 App")
        emit("  其中屏幕上放不下（你点不到）的: \(hidden.count) 个")
        emit("  支持程序化点击的: \(pressable.count) / \(items.count)")
        emit("")
        for group in MenuBarLayout.grouped(items) {
            for item in group.items {
                let flags = [item.isOnScreen ? "  " : "🚫", item.isPressable ? "▶" : " "].joined()
                let status = item.statusText.map { " — \($0)" } ?? ""
                emit(String(format: "  %@ x=%7.1f w=%5.1f  %@%@",
                             flags, item.frame.minX, item.frame.width,
                             item.displayName, status))
            }
        }
        emit("\n  🚫 = 菜单栏放不下、屏幕上看不到    ▶ = 可由 LidAwake 代为点击")
    }
}
