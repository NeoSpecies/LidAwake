import AppKit
import LidAwakeCore

/// 菜单栏折叠 + 面板 + 快捷键。
///
/// **只占 App 自己那一个状态栏图标** —— 一个"为了减少菜单栏图标"的工具
/// 自己占三个格子是说不过去的。折叠靠把这同一项撑宽实现。
///
/// 与守护进程的边界：辅助功能 / 截屏权限只在 App 进程内使用，
/// root 守护进程既不链接 ApplicationServices 也不链接 ScreenCaptureKit。
final class FoldFeature {

    private var fold: FoldController?
    private let barMenu = BarMenuController()
    private let hotkey = HotKey()
    private weak var statusItem: NSStatusItem?

    var onStateChange: (() -> Void)?
    /// 面板需要读当前状态、切合盖续跑、切风扇 —— 由 MenuController 注入
    var statusProvider: (() -> StatusDTO?)?
    var onToggleAwake: ((Mode) -> Void)?
    var onSetFan: ((FanMode) -> Void)?

    func attach(to item: NSStatusItem, restoreAppearance: @escaping () -> Void) {
        statusItem = item
        let controller = FoldController(statusItem: item)
        controller.onChange = { [weak self] _ in self?.onStateChange?() }
        controller.onRestoreNormalAppearance = restoreAppearance
        controller.setFoldedIcon(Symbols.image(["square.grid.2x2.fill", "square.grid.2x2"],
                                               description: "LidAwake"))
        fold = controller

        barMenu.statusProvider = { [weak self] in self?.statusProvider?() }
        barMenu.onToggleAwake = { [weak self] m in self?.onToggleAwake?(m) }
        barMenu.onSetFan = { [weak self] m in self?.onSetFan?(m) }
        barMenu.onToggleFold = { [weak self] in
            self?.fold?.toggle()
            self?.onStateChange?()
        }
        barMenu.foldStateProvider = { [weak self] in self?.fold?.state ?? .expanded }

        if HotKey.isEnabled {
            hotkey.register { [weak self] in self?.openPanel() }
        }
    }

    var foldState: FoldState { fold?.state ?? .expanded }
    var hotKeyName: String { hotkey.displayName }

    func openPanel() {
        barMenu.present(from: statusItem?.button)
    }

    func toggleFold() {
        fold?.toggle()
        onStateChange?()
    }

    func debugMenuDump() -> String { barMenu.debugDump() }

    func shutdown() {
        hotkey.unregister()
        fold?.toggle(.expanded)
        fold = nil
    }

    func setHotKeyEnabled(_ on: Bool) {
        HotKey.isEnabled = on
        if on { hotkey.register { [weak self] in self?.openPanel() } }
        else { hotkey.unregister() }
        onStateChange?()
    }

    var accessibilityGranted: Bool { Permissions.accessibilityGranted }
    var realIconEnabled: Bool { IconCapture.isEnabled }
    var realIconRequested: Bool { IconCapture.isRequested }

    func setRealIconPreview(_ on: Bool) {
        if on {
            IconCapture.isEnabled = true
            if !Permissions.screenRecordingGranted {
                if !Permissions.requestScreenRecording() {
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
