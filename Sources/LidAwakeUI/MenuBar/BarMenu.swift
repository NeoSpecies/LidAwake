import AppKit
import LidAwakeCore

/// 面板宿主：用 `NSMenu` 承载**一个**自定义网格视图。
///
/// 为什么这么组合：
/// - NSMenu 负责定位、点外面消失、ESC、贴屏幕边、多屏 —— 这些自己写容易出错
/// - 网格内容用自定义视图 + 显式 frame，几何完全可控（上一版栽在 Auto Layout 上）
///
/// 面板是**左键点状态栏图标的默认落点**，承载三块内容：
/// 合盖续跑开关 · 菜单栏图标网格 · 风扇控制与系统状态。
/// 其余配置项走右键菜单 —— 配置归配置，面板只负责常用操作。
final class BarMenuController: NSObject, NSMenuDelegate {

    private let scanner = StatusItemScanner()
    private var gridView: GridPanelView?

    var onToggleFold: (() -> Void)?
    var foldStateProvider: (() -> FoldState)?
    var statusProvider: (() -> StatusDTO?)?
    var onToggleAwake: ((Mode) -> Void)?
    var onSetFan: ((FanMode) -> Void)?

    func present(from button: NSStatusBarButton?) {
        let items = Permissions.accessibilityGranted ? scanner.scan() : []
        let grid = GridPanelView(
            items: sortedForDisplay(items),
            accessibilityGranted: Permissions.accessibilityGranted,
            status: statusProvider?() ,
            foldState: foldStateProvider?() ?? .expanded,
            onSelect: { [weak self] item in self?.activate(item) },
            onGrantAccessibility: {
                Permissions.requestAccessibility()
                Permissions.openAccessibilitySettings()
            },
            onToggleAwake: { [weak self] m in self?.onToggleAwake?(m) },
            onSetFan: { [weak self] m in self?.onSetFan?(m) },
            onToggleFold: { [weak self] in self?.onToggleFold?() })
        gridView = grid

        let holder = NSMenuItem()
        holder.view = grid
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(holder)

        if let button {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.maxY + 5),
                       in: button)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    /// 屏幕上放不下的排最前 —— 那才是打开面板要找的东西
    private func sortedForDisplay(_ items: [MenuBarItemInfo]) -> [MenuBarItemInfo] {
        MenuBarLayout.grouped(items).flatMap(\.items)
    }

    /// 供自检：不弹出，只把几何和内容导出来
    func debugDump() -> String {
        let items = Permissions.accessibilityGranted ? scanner.scan() : []
        let grid = GridPanelView(items: sortedForDisplay(items),
                                 accessibilityGranted: Permissions.accessibilityGranted,
                                 status: statusProvider?(),
                                 foldState: foldStateProvider?() ?? .expanded,
                                 onSelect: { _ in }, onGrantAccessibility: {},
                                 onToggleAwake: { _ in }, onSetFan: { _ in },
                                 onToggleFold: {})
        var out = [grid.geometryDump()]
        if !items.isEmpty {
            out.append("磁贴内容：")
            for item in sortedForDisplay(items) {
                let flag = item.isOnScreen ? "  " : "🟠"
                let press = item.isPressable ? "▶" : " "
                out.append("  \(flag)\(press) \(item.displayName)"
                           + (item.statusText.map { " — \($0)" } ?? ""))
            }
        }
        return out.joined(separator: "\n")
    }

    private func activate(_ item: MenuBarItemInfo) {
        guard item.isPressable else {
            Alerts.show("这一项不支持程序化点击",
                        "\(item.appName) 的这个菜单栏项没有提供 AXPress 动作。\n\n"
                        + "请先从 LidAwake 菜单里「展开菜单栏图标」，再手动点击它。")
            return
        }
        // 等菜单彻底收起再按，否则目标 App 弹出的菜单会被我们的菜单抢掉
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            if !self.scanner.press(item) {
                Alerts.show("点击失败",
                            "无法激活 \(item.appName) 的这个菜单栏项。\n"
                            + "可能是该 App 刚重启导致序号变化，重新打开面板再试。",
                            style: .warning)
            }
        }
    }

    // MARK: NSMenuDelegate —— 系统状态只在面板打开期间采样

    func menuWillOpen(_ menu: NSMenu) { gridView?.startStats() }
    func menuDidClose(_ menu: NSMenu) { gridView?.stopStats() }
}
