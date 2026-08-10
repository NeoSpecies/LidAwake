import AppKit
import LidAwakeCore

/// 带闭包的菜单项，避免为每个动作写一个 @objc selector。
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String,
         key: String = "",
         modifiers: NSEvent.ModifierFlags = .command,
         enabled: Bool = true,
         state: NSControl.StateValue? = nil,
         handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        self.target = self
        self.keyEquivalentModifierMask = modifiers
        self.isEnabled = enabled
        if let state { self.state = state }
    }

    required init(coder: NSCoder) { fatalError("不支持从 nib 加载") }

    @objc private func fire() { handler() }
}

extension NSMenu {
    func addDisabled(_ title: String, monospaced: Bool = false) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if monospaced {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
        }
        addItem(item)
    }

    @discardableResult
    func addAction(_ title: String,
                   key: String = "",
                   modifiers: NSEvent.ModifierFlags = .command,
                   enabled: Bool = true,
                   state: NSControl.StateValue? = nil,
                   handler: @escaping () -> Void) -> ActionItem {
        let item = ActionItem(title, key: key, modifiers: modifiers,
                             enabled: enabled, state: state, handler: handler)
        addItem(item)
        return item
    }

    @discardableResult
    func addSubmenu(_ title: String, build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        build(sub)
        item.submenu = sub
        addItem(item)
        return item
    }
}

enum Symbols {
    /// SF Symbol 名可能随系统版本变化，逐个回退，最后兜底文字图标。
    static func image(_ candidates: [String], description: String) -> NSImage? {
        for name in candidates {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: description) {
                img.isTemplate = true
                return img
            }
        }
        return nil
    }
}

enum Alerts {
    static func show(_ title: String, _ info: String, style: NSAlert.Style = .informational) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: "好")
        a.runModal()
    }

    static func confirm(_ title: String, _ info: String,
                        ok: String = "继续", cancel: String = "取消") -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: ok)
        a.addButton(withTitle: cancel)
        return a.runModal() == .alertFirstButtonReturn
    }

    /// 滚动文本框（诊断/自检报告用）。
    static func showText(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = body
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        a.accessoryView = scroll
        a.addButton(withTitle: "好")
        a.addButton(withTitle: "复制")
        if a.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
        }
    }

    /// 自定义时长输入。
    static func askDuration() -> Double? {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "自定义时长"
        a.informativeText = "支持写法：90（秒）、30s、45m、2h、1h30m、1d"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "例如 3h"
        a.accessoryView = field
        a.addButton(withTitle: "开启")
        a.addButton(withTitle: "取消")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        guard let secs = Format.duration(field.stringValue) else {
            show("无法识别的时长", "「\(field.stringValue)」解析失败。请用 30s / 45m / 2h / 1h30m 这类写法。",
                 style: .warning)
            return nil
        }
        return secs
    }
}
