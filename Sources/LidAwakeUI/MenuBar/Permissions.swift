import AppKit
import ApplicationServices
import CoreGraphics

/// 权限协调。
///
/// 设计原则：**每个权限在 UI 上都要明确写清"换来什么能力"**，
/// 并且不给权限时功能要能降级运行，而不是弹个框逼用户。
enum Permissions {

    // MARK: 辅助功能（列出并点击其它 App 的菜单栏项）

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// 弹出系统提示（带"打开系统设置"按钮）。不会阻塞。
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: 屏幕录制（仅用于显示图标真实像素，默认不需要）

    /// 不会弹窗的检查。
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// 会弹一次系统授权框。只在用户主动打开「真实图标预览」时调用。
    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: 说明文案（面板和菜单里复用，保证口径一致）

    static let accessibilityRationale = """
        列出并点击其它 App 的菜单栏图标需要「辅助功能」权限。

        开启后 LidAwake 能：
        • 列出全部菜单栏项，包括被系统裁掉、你点不到的那些
        • 读出它们的状态文字（多数 App 会写在 tooltip 里）
        • 替你点击它们，弹出那个 App 自己真正的菜单

        LidAwake 不会读取窗口内容，也不会记录键盘输入。
        这个权限只在 App 内使用，与后台守护进程无关。
        """

    static let screenRecordingRationale = """
        「真实图标预览」需要「屏幕录制」权限，因为 macOS 没有任何 API 能
        读到别的 App 的菜单栏图标图像 —— 只能复制屏幕上那一小块像素。

        不开启也能正常用：面板会用 App 的应用图标 + 文字状态来展示。
        开启后仅截取菜单栏那一条，不截取任何窗口内容。

        这是可选项，默认关闭。
        """
}
