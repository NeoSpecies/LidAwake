import AppKit
import LidAwakeCore

/// 把折叠 + 面板 + 快捷键打包成一个可整体开关的功能。
///
/// 默认关闭：启用后会往用户菜单栏里加两个图标（切换按钮 + 折叠边界），
/// 这种改动必须用户显式同意。关闭时两个图标会被彻底移除、快捷键注销，
/// 不留任何痕迹。
///
/// 与守护进程的边界：**这个功能完全不碰 lidawaked**。辅助功能权限只在
/// App 进程内使用，root 守护进程既不链接也不需要 Accessibility。
final class FoldFeature {

    private var fold: FoldController?
    private let barMenu = BarMenuController()
    private let hotkey = HotKey()

    var onStateChange: (() -> Void)?

    init() {
        if FoldController.isFeatureEnabled { activate() }
    }

    var isEnabled: Bool { fold != nil }
    var foldState: FoldState { fold?.state ?? .expanded }
    var hotKeyName: String { hotkey.displayName }

    func setEnabled(_ on: Bool) {
        FoldController.isFeatureEnabled = on
        on ? activate() : deactivate()
        onStateChange?()
    }

    func openPanel() {
        // 功能没启用时也允许开面板：列表 + 系统状态本身就有用，
        // 只是没有按钮可依附，就在鼠标位置弹出。
        barMenu.present(from: fold?.anchorButton)
    }

    /// 供自检使用：不弹出，只导出菜单结构
    func debugMenuDump() -> String { barMenu.debugDump() }

    func toggleFold() {
        guard let fold else {
            openPanel()
            return
        }
        fold.toggle()
        onStateChange?()
    }

    func shutdown() {
        deactivate()
    }

    // MARK: 内部

    private func activate() {
        guard fold == nil else { return }
        let controller = FoldController()
        controller.onOpenPanel = { [weak self] in self?.openPanel() }
        controller.onChange = { [weak self] _ in self?.onStateChange?() }
        fold = controller
        if HotKey.isEnabled {
            hotkey.register { [weak self] in self?.openPanel() }
        }
    }

    private func deactivate() {
        hotkey.unregister()
        fold = nil          // deinit 里会把两个 status item 摘掉
    }

    func setHotKeyEnabled(_ on: Bool) {
        HotKey.isEnabled = on
        if on, isEnabled {
            hotkey.register { [weak self] in self?.openPanel() }
        } else {
            hotkey.unregister()
        }
        onStateChange?()
    }

    /// 供菜单构建时展示权限状态
    var accessibilityGranted: Bool { Permissions.accessibilityGranted }
    var realIconEnabled: Bool { IconCapture.isEnabled }
    var realIconRequested: Bool { IconCapture.isRequested }

    func setRealIconPreview(_ on: Bool) {
        if on {
            IconCapture.isEnabled = true
            if !Permissions.screenRecordingGranted {
                let granted = Permissions.requestScreenRecording()
                if !granted {
                    Alerts.show("需要屏幕录制权限", Permissions.screenRecordingRationale,
                                style: .informational)
                    Permissions.openScreenRecordingSettings()
                }
            }
        } else {
            IconCapture.isEnabled = false
        }
        onStateChange?()
    }

    func requestAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }
}
