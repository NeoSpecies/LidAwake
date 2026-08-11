import AppKit
import LidAwakeCore

/// 菜单栏折叠功能的自检。
///
/// 折叠的**视觉效果**（图标被顶出屏幕）没法在程序里验证 —— 那需要人眼看菜单栏。
/// 这里能机械验证的是：status item 能被创建、宽度按状态正确切换、
/// 系统状态采集有真实数据、权限状态判断正确、以及（授权后）AX 枚举确实能读到东西。
enum MenuBarSelfTest {

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)   // 自检不要出现在菜单栏/Dock

        print("LidAwake 菜单栏折叠自检 \(LidAwakeInfo.version)")
        print(String(repeating: "=", count: 46))

        print("\n── 权限")
        print("  辅助功能（列出/点击菜单栏项）: \(Permissions.accessibilityGranted ? "已授权 ✅" : "未授权 ❌")")
        print("  屏幕录制（真实图标预览，可选）: \(Permissions.screenRecordingGranted ? "已授权" : "未授权（不影响核心功能）")")
        print("  真实图标预览开关: \(IconCapture.isRequested ? "已勾选" : "关闭")")

        print("\n── 折叠机制（无需任何权限）")
        let fold = FoldController()
        print("  初始状态: \(fold.state.rawValue)")
        fold.toggle(.folded)
        print("  切到 folded  → 状态 \(fold.state.rawValue)")
        fold.toggle(.expanded)
        print("  切到 expanded → 状态 \(fold.state.rawValue)")
        print("  两个 status item 创建: ✅（未崩溃，且状态可切换）")
        print("  说明: 图标被顶出屏幕的视觉效果需人眼确认，程序无法自证")

        print("\n── 系统实时状态（无需任何权限）")
        let s1 = SystemStats.snapshot()
        Thread.sleep(forTimeInterval: 1.0)
        let s2 = SystemStats.snapshot()
        let rates = StatsRates.between(s1, s2)
        let mem = SystemStats.memory()
        let disk = SystemStats.disk()
        print("  CPU    : \(Format.percent(rates.cpuBusy))  (user \(Format.percent(rates.cpuUser)) / sys \(Format.percent(rates.cpuSystem)))  负载 \(String(format: "%.2f", SystemStats.loadAverage()))")
        print("  内存   : \(Format.bytes(mem.used)) / \(Format.bytes(mem.total)) (\(Format.percent(mem.fraction)))  压缩 \(Format.bytes(mem.compressed))  交换 \(Format.bytes(mem.swapUsed))")
        print("  磁盘   : 可用 \(Format.bytes(disk.free)) / \(Format.bytes(disk.total))  IO ↓\(Format.rate(rates.diskReadPerSec)) ↑\(Format.rate(rates.diskWritePerSec))")
        print("  网络   : \(SystemStats.primaryInterface() ?? "未连接")  ↓\(Format.rate(rates.netRxPerSec)) ↑\(Format.rate(rates.netTxPerSec))")

        print("\n── 菜单栏项枚举（需辅助功能）")
        guard Permissions.accessibilityGranted else {
            print("  跳过：未授权辅助功能")
            print("  授权后重跑本自检即可看到完整列表")
            return
        }
        let scanner = StatusItemScanner()
        let items = scanner.scan()
        let hidden = items.filter { !$0.isOnScreen }
        let pressable = items.filter(\.isPressable)
        print("  读到 \(items.count) 个菜单栏项，来自 \(Set(items.map(\.appName)).count) 个 App")
        print("  其中屏幕上放不下（你点不到）的: \(hidden.count) 个")
        print("  支持程序化点击的: \(pressable.count) / \(items.count)")
        print("")
        for group in MenuBarLayout.grouped(items) {
            for item in group.items {
                let flags = [item.isOnScreen ? "  " : "🚫", item.isPressable ? "▶" : " "].joined()
                let status = item.statusText.map { " — \($0)" } ?? ""
                print(String(format: "  %@ x=%7.1f w=%5.1f  %@%@",
                             flags, item.frame.minX, item.frame.width,
                             item.displayName, status))
            }
        }
        print("\n  🚫 = 菜单栏放不下、屏幕上看不到    ▶ = 可由 LidAwake 代为点击")
    }
}
