import AppKit
import Carbon.HIToolbox

/// 全局快捷键。
///
/// 用 Carbon 的 `RegisterEventHotKey` 而不是 `CGEventTap` —— 前者**不需要辅助功能权限**，
/// 后者需要。对一个"唤起面板"的快捷键来说，不该为此多要一个权限。
final class HotKey {

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id: UInt32 = 0x4C41_4B31   // 'LAK1'
    private var action: (() -> Void)?

    /// 默认 ⌥⌘B（B = Bar）。macOS 里这个组合默认没被占用。
    static let defaultKeyCode = UInt32(kVK_ANSI_B)
    static let defaultModifiers = UInt32(optionKey | cmdKey)

    private enum Keys {
        static let enabled = "menubar.hotkeyEnabled"
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    var displayName: String { "⌥⌘B" }

    @discardableResult
    func register(action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            guard hkID.id == me.id else { return noErr }
            DispatchQueue.main.async { me.action?() }
            return noErr
        }, 1, &spec, selfPtr, &handler)
        guard status == noErr else { return false }

        let hkID = EventHotKeyID(signature: OSType(0x4C494441), id: id)   // 'LIDA'
        let rc = RegisterEventHotKey(Self.defaultKeyCode, Self.defaultModifiers,
                                     hkID, GetApplicationEventTarget(), 0, &ref)
        return rc == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    deinit { unregister() }
}
