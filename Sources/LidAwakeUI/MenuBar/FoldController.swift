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
        // 纯边界标记：不接任何动作。面板只有「〉」一个入口，避免两个图标行为重复。
        spacer.button?.toolTip = "LidAwake 折叠边界\n按住 ⌘ 拖动可调整位置\n它左边的图标属于被折叠的那一组"
        spacer.autosaveName = "com.cogito.LidAwake.foldSpacer"

        toggle.button?.target = self
        toggle.button?.action = #selector(toggleClicked)
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
            toggle.button?.image = Symbols.image(["square.grid.2x2.fill", "square.grid.2x2"],
                                                 description: "菜单栏图标面板")
            toggle.button?.toolTip = "菜单栏图标已折叠\n单击打开面板"
        case .expanded:
            spacer.length = expandedWidth
            spacer.button?.image = Symbols.image(["line.3.vertical", "ellipsis"],
                                                 description: "折叠边界")
            toggle.button?.image = Symbols.image(["square.grid.2x2", "square.grid.2x2.fill"],
                                                 description: "菜单栏图标面板")
            toggle.button?.toolTip = "单击打开面板（列出全部菜单栏图标）"
        }
    }

    /// 这个按钮只做一件事：打开面板。
    /// 折叠/展开是设置项，放在 LidAwake 主菜单里 —— 一个图标一个职责。
    @objc private func toggleClicked() {
        onOpenPanel?()
    }

    /// 菜单要贴着这个按钮下方弹出
    var anchorButton: NSStatusBarButton? { toggle.button }
}
