import Foundation
import LidAwakeCore

/// 受限模式：守护进程未安装时，App 用自己的普通权限只挂 L1 断言。
/// 这条路**只在接通电源时可能拦住合盖休眠**（等价 `caffeinate -s`，
/// 也是 Amphetamine 的能力边界），纯电池不保证 —— UI 必须如实告知用户。
final class LimitedController {
    private let assertions = AssertionHolder(displayName: LidAwakeInfo.assertionName + " [limited]")
    private var timer: DispatchSourceTimer?

    private(set) var mode: Mode = .off
    private(set) var startedAt: Date?
    var onChange: (() -> Void)?

    var remaining: Double? {
        guard case .until(let d) = mode else { return nil }
        return max(0, d.timeIntervalSinceNow)
    }

    var heldAssertions: [String] { assertions.held }

    func apply(_ newMode: Mode) {
        mode = newMode
        startedAt = newMode.isActive ? Date() : nil
        timer?.cancel(); timer = nil

        if newMode.isActive {
            assertions.reconcile(to: [AssertionHolder.Kind.idleSystem,
                                     AssertionHolder.Kind.system])
            if case .until(let deadline) = newMode {
                let t = DispatchSource.makeTimerSource(queue: .main)
                t.schedule(deadline: .now() + max(0.05, deadline.timeIntervalSinceNow),
                           leeway: .milliseconds(200))
                t.setEventHandler { [weak self] in self?.apply(.off) }
                t.resume()
                timer = t
            }
        } else {
            assertions.releaseAll()
        }
        onChange?()
    }

    /// App 退出前必须释放，否则断言会随进程消失但状态语义不清。
    func shutdown() {
        timer?.cancel(); timer = nil
        assertions.releaseAll()
    }
}
