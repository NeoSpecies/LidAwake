import AppKit
import ScreenCaptureKit
import LidAwakeCore

/// 可选功能：把菜单栏项的**真实图标像素**截出来。
///
/// 为什么必须截屏：macOS 的 Accessibility 属性表（203 个常量）里没有任何图像类属性，
/// 图标是各 App 自己画在自己窗口上的像素，系统不把它作为数据暴露给别人。
///
/// **重要局限**：被系统裁掉的那些项根本没有被绘制到屏幕上，所以截屏同样拿不到它们
/// —— 想拿只能"临时把它挪进可见区、截一张、再挪回去"（Ice / Bartender 就是这么做的），
/// 那会造成菜单栏可见的抖动。LidAwake 不做这件事：
/// 真实图标只对**当前可见**的项生效，隐藏项一律回退到 App 应用图标 + 文字状态。
/// 这也说明「App 图标 + 文字状态」才该是主表示，真实图标只是锦上添花。
///
/// 默认关闭。
enum IconCapture {

    private enum Keys {
        static let enabled = "menubar.realIconPreview"
    }

    /// 用户勾选过（不管权限当前是否有效）
    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: Keys.enabled)
    }

    static var isEnabled: Bool {
        get {
            guard isRequested else { return false }
            // 权限可能被事后撤销，每次都以系统真实状态为准
            return Permissions.screenRecordingGranted
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    /// 一次截取整条菜单栏，再按每个项的位置裁切 —— 只截一张，不是每个图标截一次。
    /// - Parameter completion: 主线程回调，key 是 `MenuBarItemInfo.id`
    static func captureVisibleIcons(for items: [MenuBarItemInfo],
                                    completion: @escaping ([String: NSImage]) -> Void) {
        guard isEnabled else { completion([:]); return }
        guard #available(macOS 15.2, *) else { completion([:]); return }

        // 只有屏幕上真实存在的项才可能被截到
        let visible = items.filter { $0.isOnScreen && $0.frame.width > 1 && $0.frame.height > 1 }
        guard !visible.isEmpty else { completion([:]); return }

        let strip = visible.reduce(CGRect.null) { $0.union($1.frame) }.integral
        guard strip.width > 1, strip.height > 1 else { completion([:]); return }

        SCScreenshotManager.captureImage(in: strip) { cgImage, error in
            guard let cgImage, error == nil else {
                DispatchQueue.main.async { completion([:]) }
                return
            }
            // 截图分辨率可能是逻辑尺寸的整数倍（Retina），按比例换算裁切坐标
            let scaleX = CGFloat(cgImage.width) / strip.width
            let scaleY = CGFloat(cgImage.height) / strip.height

            var result: [String: NSImage] = [:]
            for item in visible {
                let local = CGRect(x: (item.frame.minX - strip.minX) * scaleX,
                                   y: (item.frame.minY - strip.minY) * scaleY,
                                   width: item.frame.width * scaleX,
                                   height: item.frame.height * scaleY).integral
                guard local.width >= 1, local.height >= 1,
                      let cropped = cgImage.cropping(to: local) else { continue }
                result[item.id] = NSImage(cgImage: cropped,
                                          size: NSSize(width: item.frame.width,
                                                       height: item.frame.height))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
