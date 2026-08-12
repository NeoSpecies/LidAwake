import AppKit
import LidAwakeCore

/// 菜单栏折叠 —— **复用 App 自己那一个状态栏图标**，不额外占格子。
///
/// 原理（不需要任何权限）：菜单栏项从右往左排，塞不下的从左端被裁掉。
/// 把我们自己这一项撑到超过屏幕宽度，它**左边**的所有图标就被顶出可见区；收窄就回来。
///
/// 关键细节：项被撑宽后，它的右边缘仍然贴着控制中心，可见的是**最右侧那一小段**。
/// 所以图标必须钉在右边缘（`autoresizingMask = .minXMargin`，弹性左边距），
/// 否则默认居中会把图标画到屏幕外去。
final class FoldController {

    private let iconSize: CGFloat = 18
    private let iconInset: CGFloat = 6

    private weak var statusItem: NSStatusItem?
    private let iconView = NSImageView()

    private(set) var state: FoldState {
        didSet {
            UserDefaults.standard.set(state.rawValue, forKey: Keys.state)
            apply()
            onChange?(state)
        }
    }

    var onChange: ((FoldState) -> Void)?
    /// 展开态下由 MenuController 负责画图标与倒计时，这里回调它重画
    var onRestoreNormalAppearance: (() -> Void)?

    private enum Keys { static let state = "menubar.foldState" }

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        state = FoldState(rawValue: UserDefaults.standard.string(forKey: Keys.state) ?? "")
            ?? .expanded

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isHidden = true
        // 弹性左边距 = 钉右边缘。用 springs-and-struts 而不是 Auto Layout：
        // 状态栏按钮的尺寸由系统改，约束链在这里更容易出意外。
        iconView.autoresizingMask = [.minXMargin]
        if let button = statusItem.button {
            iconView.frame = NSRect(x: button.bounds.width - iconSize - iconInset,
                                    y: (button.bounds.height - iconSize) / 2,
                                    width: iconSize, height: iconSize)
            button.addSubview(iconView)
        }
        apply()
    }

    func toggle(_ newState: FoldState? = nil) {
        state = newState ?? state.toggled
    }

    /// 折叠图标（折叠态显示在右边缘的那个）
    func setFoldedIcon(_ image: NSImage?) {
        iconView.image = image
        iconView.image?.isTemplate = true
    }

    private func apply() {
        guard let statusItem, let button = statusItem.button else { return }
        switch state {
        case .folded:
            // 折叠态：自己变得极宽把左边图标顶出去；只显示钉在右边缘的图标
            button.image = nil
            button.title = ""
            iconView.isHidden = false
            // 必须夹在 10000 以内：超了 NSStatusItem 会抛异常直接崩溃
            statusItem.length = MenuBarLayout.foldedLength(iconSize: iconSize, inset: iconInset)
            DispatchQueue.main.async { [weak self] in self?.pinIconToTrailingEdge() }
        case .expanded:
            iconView.isHidden = true
            statusItem.length = NSStatusItem.variableLength
            onRestoreNormalAppearance?()
        }
    }

    /// 极宽状态下 autoresizing 有时来不及，显式再钉一次
    private func pinIconToTrailingEdge() {
        guard let button = statusItem?.button else { return }
        iconView.frame = NSRect(x: button.bounds.width - iconSize - iconInset,
                                y: (button.bounds.height - iconSize) / 2,
                                width: iconSize, height: iconSize)
    }
}
