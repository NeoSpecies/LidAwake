import Foundation
import CoreGraphics

/// 菜单栏项的描述。
///
/// 重要边界：**这个文件里没有任何 Accessibility 代码**。
/// LidAwakeCore 被 root 守护进程链接，守护进程不该、也不需要碰辅助功能 API。
/// 真正的 AX 扫描在 LidAwakeUI 里（普通用户权限、App 进程内）。
public struct MenuBarItemInfo: Sendable, Equatable, Identifiable {
    public var id: String { "\(pid)#\(index)" }

    public var pid: pid_t
    public var appName: String
    public var bundleID: String?
    /// 在该 App 的 extras menu bar 中的序号
    public var index: Int
    /// AXTitle —— 很多 App 会把简短状态放这里（如 "3"、"12%"）
    public var title: String?
    /// AXHelp（= tooltip）—— 状态信息最常出现的地方
    public var help: String?
    /// AXDescription / AXRoleDescription
    public var descriptionText: String?
    public var frame: CGRect
    /// 是否支持 AXPress（不支持的只能靠"临时展开让用户自己点"）
    public var isPressable: Bool
    /// 是否落在菜单栏的可见区域内（超出的就是被系统裁掉、你点不到的那些）
    public var isOnScreen: Bool

    public init(pid: pid_t, appName: String, bundleID: String? = nil, index: Int,
                title: String? = nil, help: String? = nil, descriptionText: String? = nil,
                frame: CGRect = .zero, isPressable: Bool = false, isOnScreen: Bool = true) {
        self.pid = pid
        self.appName = appName
        self.bundleID = bundleID
        self.index = index
        self.title = title
        self.help = help
        self.descriptionText = descriptionText
        self.frame = frame
        self.isPressable = isPressable
        self.isOnScreen = isOnScreen
    }

    /// 面板上显示的状态文字。优先级：tooltip > 标题 > 描述。
    /// 这是"把图标自带的状态反映出来"在**不截屏**的前提下能做到的部分。
    public var statusText: String? {
        for candidate in [help, title, descriptionText] {
            guard let s = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty else { continue }
            // 一堆 App 的 tooltip 就是 App 名字本身，那不是状态，别显示
            if s.caseInsensitiveCompare(appName) == .orderedSame { continue }
            return s
        }
        return nil
    }

    /// 同一个 App 有多个项时，用它区分（如 "飞书 · 2"）
    public var displayName: String {
        index == 0 ? appName : "\(appName) · \(index + 1)"
    }
}

public enum MenuBarLayout {

    /// 判断一个项是否在可见区域内。
    ///
    /// 菜单栏项从右往左排，塞不下的从**左端**被裁掉。所以只要项的左边缘
    /// 落在"可用起点"左侧，它就是够不到的那批。
    /// - Parameters:
    ///   - frame: 项的屏幕坐标
    ///   - visibleMinX: 菜单栏可摆放区域的左边界（刘海机型要把刘海算进去）
    public static func isOnScreen(frame: CGRect, visibleMinX: CGFloat) -> Bool {
        guard frame.width > 0 else { return false }
        return frame.minX >= visibleMinX - 0.5
    }

    /// 按 App 分组，组内按菜单栏从左到右排序，组间按"是否有被裁掉的项"优先。
    /// 被裁掉的排前面 —— 那才是用户打开面板要找的东西。
    public static func grouped(_ items: [MenuBarItemInfo]) -> [(app: String, items: [MenuBarItemInfo])] {
        var buckets: [String: [MenuBarItemInfo]] = [:]
        for item in items {
            buckets[item.appName, default: []].append(item)
        }
        return buckets
            .map { (app: $0.key, items: $0.value.sorted { $0.frame.minX < $1.frame.minX }) }
            .sorted { lhs, rhs in
                let lHidden = lhs.items.contains { !$0.isOnScreen }
                let rHidden = rhs.items.contains { !$0.isOnScreen }
                if lHidden != rHidden { return lHidden }        // 够不到的排前面
                return lhs.app.localizedStandardCompare(rhs.app) == .orderedAscending
            }
    }

    /// 这些 App / bundle id 是系统的菜单栏基础设施，列出来只会制造噪音。
    /// （实测 `activationPolicy == .accessory` 会把 59 个进程都算进来，
    ///   其中大部分是 WebKit GPU / Networking 这类 XPC 服务）
    public static let ignoredBundleIDs: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.apple.TextInputMenuAgent",
        "com.apple.TextInputSwitcher",
        "com.apple.WebKit.GPU",
        "com.apple.WebKit.Networking",
        "com.apple.WebKit.WebContent",
        "com.apple.dock",
        "com.apple.dock.extra",
        "com.apple.dock.helper",
        "com.apple.Spotlight",
        "com.apple.notificationcenterui",
        "com.apple.wallpaper.agent",
        "com.apple.WindowManager",
        "com.apple.loginwindow",
        "com.apple.universalcontrol",
        "com.apple.AirPlayUIAgent",
    ]

    public static func shouldScan(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if ignoredBundleIDs.contains(bundleID) { return false }
        // XPC / 辅助进程一律跳过
        if bundleID.hasSuffix(".helper") || bundleID.contains(".WebKit.") { return false }
        return true
    }
}

/// 折叠状态。
public enum FoldState: String, Codable, Sendable {
    /// 折叠中：被管理的那组图标被顶到屏幕外
    case folded
    /// 展开中
    case expanded

    public var toggled: FoldState { self == .folded ? .expanded : .folded }
}
