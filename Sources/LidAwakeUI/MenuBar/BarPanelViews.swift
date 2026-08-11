import AppKit
import LidAwakeCore

// MARK: - 单个菜单栏项的行

final class ItemRow: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var hovering = false
    private let onSelect: () -> Void

    let item: MenuBarItemInfo

    init(item: MenuBarItemInfo, icon: NSImage?, onSelect: @escaping () -> Void) {
        self.item = item
        self.onSelect = onSelect
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        // 真实图标截图是彩色的，App 图标也是彩色的，都不要当模板色处理
        iconView.image?.isTemplate = false

        nameLabel.font = .systemFont(ofSize: 13, weight: .regular)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.stringValue = item.displayName

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.stringValue = item.statusText ?? ""
        statusLabel.isHidden = item.statusText == nil

        badge.font = .systemFont(ofSize: 10, weight: .medium)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.backgroundColor = NSColor.systemOrange.cgColor
        badge.stringValue = " 看不到 "
        badge.isHidden = item.isOnScreen

        chevron.image = Symbols.image(["chevron.right"], description: "")
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.isHidden = !item.isPressable

        let text = NSStackView(views: statusLabel.isHidden ? [nameLabel] : [nameLabel, statusLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [iconView, text, NSView(), badge, chevron])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        toolTip = tooltipText()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 真实图标截图晚一步到达时替换（见 IconCapture）
    func setIcon(_ image: NSImage) {
        image.isTemplate = false
        iconView.image = image
    }

    private func tooltipText() -> String {
        var lines = ["\(item.appName) (pid \(item.pid))"]
        if let s = item.statusText { lines.append(s) }
        if !item.isOnScreen { lines.append("⚠️ 菜单栏放不下，屏幕上看不到这一项") }
        lines.append(item.isPressable ? "点击可直接展开它的菜单" : "这一项不支持程序化点击，请用「展开菜单栏」后手动点")
        return lines.joined(separator: "\n")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        layer?.backgroundColor = nil
    }

    override func mouseUp(with event: NSEvent) {
        guard hovering else { return }
        onSelect()
    }
}

// MARK: - 底部系统状态条

final class StatsFooter: NSView {
    private struct Metric {
        let caption: NSTextField
        let value: NSTextField
    }

    private var metrics: [String: Metric] = [:]

    init() {
        super.init(frame: .zero)
        let order = ["CPU", "内存", "磁盘", "网络"]
        var columns: [NSView] = []
        for key in order {
            let caption = NSTextField(labelWithString: key)
            caption.font = .systemFont(ofSize: 9, weight: .medium)
            caption.textColor = .tertiaryLabelColor
            caption.alignment = .center
            let value = NSTextField(labelWithString: "—")
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.alignment = .center
            let col = NSStackView(views: [caption, value])
            col.orientation = .vertical
            col.spacing = 1
            columns.append(col)
            metrics[key] = Metric(caption: caption, value: value)
        }
        let stack = NSStackView(views: columns)
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(rates: StatsRates, memory: MemoryInfo, disk: DiskInfo, iface: String?) {
        metrics["CPU"]?.value.stringValue = Format.percent(rates.cpuBusy)
        metrics["CPU"]?.caption.stringValue = String(format: "CPU · 负载 %.1f", SystemStats.loadAverage())

        metrics["内存"]?.value.stringValue = Format.percent(memory.fraction)
        metrics["内存"]?.caption.stringValue =
            "内存 · \(Format.bytes(memory.used)) / \(Format.bytes(memory.total))"

        metrics["磁盘"]?.value.stringValue =
            "↓\(Format.rate(rates.diskReadPerSec)) ↑\(Format.rate(rates.diskWritePerSec))"
        metrics["磁盘"]?.caption.stringValue = "磁盘 · 可用 \(Format.bytes(disk.free))"

        metrics["网络"]?.value.stringValue =
            "↓\(Format.rate(rates.netRxPerSec)) ↑\(Format.rate(rates.netTxPerSec))"
        metrics["网络"]?.caption.stringValue = "网络 · \(iface ?? "未连接")"
    }
}

// MARK: - 权限引导卡片

final class PermissionCard: NSView {
    init(title: String, body: String, buttonTitle: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor

        let icon = NSImageView()
        icon.image = Symbols.image(["lock.shield"], description: "")
        icon.contentTintColor = .systemOrange

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.textColor = .secondaryLabelColor

        let button = ClosureButton(title: buttonTitle, action: action)
        button.controlSize = .small
        button.bezelStyle = .rounded

        let head = NSStackView(views: [icon, titleLabel])
        head.orientation = .horizontal
        head.spacing = 6

        let stack = NSStackView(views: [head, bodyLabel, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class ClosureButton: NSButton {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
