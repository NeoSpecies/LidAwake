import AppKit
import ApplicationServices
import LidAwakeCore

/// 用 Accessibility 枚举全部 App 的菜单栏项。
///
/// 关键 API：每个 App 的 AX 元素上有 `AXExtrasMenuBar` 属性，它的 children
/// 就是该 App 的 NSStatusItem —— **包括被系统裁掉、屏幕上看不到的那些**。
///
/// 拿不到的东西：图标图像。整个 AX 属性表（203 个常量）里没有任何图像类属性，
/// 图标是各 App 自己画在自己窗口上的像素。所以面板用 App 应用图标 + 文字状态展示，
/// 想要真实图标只能走屏幕录制（可选项，见 IconCapture）。
final class StatusItemScanner {

    /// AX 调用是同步 IPC，遇到没响应的 App 会卡住。给每个目标设一个短超时。
    private let messagingTimeout: Float = 0.25

    /// 上一次扫描结果，用于在权限被撤销等情况下保留一份可显示的内容
    private(set) var lastResult: [MenuBarItemInfo] = []

    /// 菜单栏可摆放区域的左边界。刘海机型要把刘海让出来，否则会把正常项误判成"被裁掉"。
    static func menuBarVisibleMinX(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return 0 }
        // auxiliaryTopLeftArea / auxiliaryTopRightArea 在刘海机型上给出刘海两侧的可用区
        if let right = screen.auxiliaryTopRightArea {
            return right.minX
        }
        return screen.frame.minX
    }

    /// 扫描。必须在后台队列调用 —— AX 是同步 IPC，别卡主线程。
    func scan() -> [MenuBarItemInfo] {
        guard Permissions.accessibilityGranted else { return [] }

        let screen = NSScreen.screens.first { $0.frame.minY == 0 } ?? NSScreen.main
        let visibleMinX = Self.menuBarVisibleMinX(for: screen)
        // AX 用的是"左上原点"坐标系，NSScreen 用左下原点；菜单栏在顶部，
        // 这里只比较 X，不需要做 Y 转换。
        var result: [MenuBarItemInfo] = []

        for app in NSWorkspace.shared.runningApplications {
            guard MenuBarLayout.shouldScan(bundleID: app.bundleIdentifier) else { continue }
            let pid = app.processIdentifier
            guard pid > 0 else { continue }

            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, messagingTimeout)

            var extras: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXExtrasMenuBarAttribute as CFString,
                                               &extras) == .success,
                  let bar = extras as! AXUIElement? else { continue }

            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString,
                                               &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement], !children.isEmpty else { continue }

            let appName = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
            for (index, element) in children.enumerated() {
                AXUIElementSetMessagingTimeout(element, messagingTimeout)
                let frame = Self.frame(of: element)
                let info = MenuBarItemInfo(
                    pid: pid,
                    appName: appName,
                    bundleID: app.bundleIdentifier,
                    index: index,
                    title: Self.string(element, kAXTitleAttribute),
                    help: Self.string(element, kAXHelpAttribute),
                    descriptionText: Self.string(element, kAXDescriptionAttribute),
                    frame: frame,
                    isPressable: Self.actions(element).contains(kAXPressAction),
                    isOnScreen: MenuBarLayout.isOnScreen(frame: frame, visibleMinX: visibleMinX))
                // 完全没有尺寸的项通常是占位/隐藏项，不值得列
                if info.frame.width <= 0 && info.statusText == nil { continue }
                result.append(info)
            }
        }

        lastResult = result
        return result
    }

    /// 替用户点击某个菜单栏项。返回是否成功发出。
    /// 注意：这会让那个 App 弹出它自己的菜单 —— 我们不解析也不代理那个菜单，
    /// 用户看到的是原汁原味的界面。
    @discardableResult
    func press(_ item: MenuBarItemInfo) -> Bool {
        guard Permissions.accessibilityGranted else { return false }
        let axApp = AXUIElementCreateApplication(item.pid)
        AXUIElementSetMessagingTimeout(axApp, messagingTimeout)

        var extras: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXExtrasMenuBarAttribute as CFString,
                                           &extras) == .success,
              let bar = extras as! AXUIElement? else { return false }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString,
                                           &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement],
              item.index < children.count else { return false }

        let target = children[item.index]
        AXUIElementSetMessagingTimeout(target, messagingTimeout)
        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    }

    // MARK: AX 读取小工具

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &v) == .success
        else { return nil }
        guard let s = v as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private static func frame(of element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &v) == .success,
           let value = v, CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgPoint, &origin)
        }
        v = nil
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &v) == .success,
           let value = v, CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }
}
