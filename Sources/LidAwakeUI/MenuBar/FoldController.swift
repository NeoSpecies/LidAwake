import AppKit
import LidAwakeCore

/// 菜单栏折叠。
///
/// 原理（不需要任何权限）：菜单栏项从右往左排，塞不下的从左端被裁掉。
/// 我们自己插一个可变宽度的"隔断"项 —— 把它撑到超过屏幕宽度，它**左边**的
/// 所有图标就被顶出可见区域；把它收窄，那些图标就回来。
///
/// 边界位置由用户 ⌘ 拖动隔断项自己决定，位置由 autosaveName 持久化。
final class FoldController {

    /// 撑开时的宽度。比任何显示器都宽即可。
    private let collapsedWidth: CGFloat = 10_000
    /// 展开时留一点宽度，好让用户能 ⌘ 拖动它调整边界
    private let expandedWidth: CGFloat = 22

    private let spacer: NSStatusItem
    private let toggle: NSStatusItem

    private(set) var state: FoldState {
        didSet {
            UserDefaults.standard.set(state.rawValue, forKey: Keys.state)
            applyState()
            onChange?(state)
        }
    }

    var onOpenPanel: (() -> Void)?
    var onChange: ((FoldState) -> Void)?

    private enum Keys {
        static let state = "menubar.foldState"
        static let enabled = "menubar.foldEnabled"
    }

    static var isFeatureEnabled: Bool {
        get {
            // 默认关闭：这个功能会往用户菜单栏里加两个图标，必须显式开启
            UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? false
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    init() {
        spacer = NSStatusBar.system.statusItem(withLength: expandedWidth)
        toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        state = FoldState(rawValue: UserDefaults.standard.string(forKey: Keys.state) ?? "")
            ?? .expanded

        // 隔断项：⌘ 拖它决定"哪些图标属于被折叠的那一组"
        spacer.button?.image = Symbols.image(["line.3.vertical", "ellipsis"],
                                             description: "折叠边界")
        spacer.button?.imagePosition = .imageOnly
        spacer.button?.target = self
        spacer.button?.action = #selector(spacerClicked)
        spacer.button?.toolTip = "LidAwake 折叠边界 —— 按住 ⌘ 拖动可调整\n它左边的图标会被折叠"
        spacer.autosaveName = "com.cogito.LidAwake.foldSpacer"

        toggle.button?.target = self
        toggle.button?.action = #selector(toggleClicked)
        toggle.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        toggle.autosaveName = "com.cogito.LidAwake.foldToggle"

        applyState()
    }

    deinit {
        NSStatusBar.system.removeStatusItem(spacer)
        NSStatusBar.system.removeStatusItem(toggle)
    }

    func toggle(_ newState: FoldState? = nil) {
        state = newState ?? state.toggled
    }

    private func applyState() {
        switch state {
        case .folded:
            spacer.length = collapsedWidth
            spacer.button?.image = nil
            toggle.button?.image = Symbols.image(["chevron.left", "chevron.compact.left"],
                                                 description: "展开菜单栏图标")
            toggle.button?.toolTip = "菜单栏图标已折叠\n单击展开 · 右键打开面板"
        case .expanded:
            spacer.length = expandedWidth
            spacer.button?.image = Symbols.image(["line.3.vertical", "ellipsis"],
                                                 description: "折叠边界")
            toggle.button?.image = Symbols.image(["chevron.right", "chevron.compact.right"],
                                                 description: "折叠菜单栏图标")
            toggle.button?.toolTip = "单击折叠左侧图标 · 右键打开面板"
        }
    }

    @objc private func toggleClicked() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        let optionHeld = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        if isRightClick || optionHeld {
            onOpenPanel?()
        } else {
            toggle()
        }
    }

    @objc private func spacerClicked() {
        // 点隔断项也打开面板：折叠状态下它是不可见的，展开状态下点它最直观
        onOpenPanel?()
    }

    /// 面板要贴着切换按钮下方弹出，所以需要它在屏幕上的位置。
    var toggleScreenRect: NSRect? {
        guard let window = toggle.button?.window else { return nil }
        return window.convertToScreen(toggle.button?.bounds ?? .zero)
    }
}
