import AppKit
import LidAwakeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MenuController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}

// 同一用户下只保留一个实例，避免菜单栏出现两个图标。
// 已经有别的实例在跑 → 本次启动直接退出（登录项 + 手动打开都可能触发）。
let others = NSRunningApplication
    .runningApplications(withBundleIdentifier: LidAwakeInfo.bundleID)
    .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
if !others.isEmpty { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 无 Dock 图标、无窗口
app.run()
