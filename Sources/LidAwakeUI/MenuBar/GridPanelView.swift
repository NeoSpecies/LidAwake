import AppKit
import LidAwakeCore

/// 网格面板视图 —— 类似启动台 / 程序 hub 的布局。
///
/// **所有尺寸都用显式 frame 算，不用 Auto Layout。**
/// 上一版用 NSPanel + NSStackView + NSScrollView 拼，宽度约束链一断整个面板就塌成
/// "又窄又长的空条"。这里几何完全确定，可以用 `geometryDump()` 在没有屏幕的情况下验证。
final class GridPanelView: NSView {

    // MARK: 布局常量
    static let width: CGFloat = 404
    private let pad: CGFloat = 14
    private let columns = 4
    private let tileGap: CGFloat = 8
    private let tileHeight: CGFloat = 84
    private let headerHeight: CGFloat = 20
    private let statsRowHeight: CGFloat = 34
    private let sectionGap: CGFloat = 10

    private var tileWidth: CGFloat {
        (Self.width - pad * 2 - tileGap * CGFloat(columns - 1)) / CGFloat(columns)
    }

    private let items: [MenuBarItemInfo]
    private let status: StatusDTO?
    private let foldState: FoldState
    private let onSelect: (MenuBarItemInfo) -> Void
    private let onGrantAccessibility: () -> Void
    private let onToggleAwake: (Mode) -> Void
    private let onSetFan: (FanMode) -> Void
    private let onToggleFold: () -> Void

    private var statsValueLabels: [NSTextField] = []
    private var statsCaptionLabels: [NSTextField] = []
    private var statsTimer: Timer?
    private var lastSnapshot: StatsSnapshot?

    /// 供自检使用：把算出来的几何打印出来
    private(set) var geometryLog: [String] = []

    init(items: [MenuBarItemInfo],
         accessibilityGranted: Bool,
         status: StatusDTO?,
         foldState: FoldState,
         onSelect: @escaping (MenuBarItemInfo) -> Void,
         onGrantAccessibility: @escaping () -> Void,
         onToggleAwake: @escaping (Mode) -> Void,
         onSetFan: @escaping (FanMode) -> Void,
         onToggleFold: @escaping () -> Void) {
        self.items = items
        self.status = status
        self.foldState = foldState
        self.onSelect = onSelect
        self.onGrantAccessibility = onGrantAccessibility
        self.onToggleAwake = onToggleAwake
        self.onSetFan = onSetFan
        self.onToggleFold = onToggleFold
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))

        // 从底部往上排（AppKit 原点在左下）
        var y = pad
        y = layoutStats(bottomY: y)
        y += sectionGap
        y = layoutSeparator(bottomY: y)
        y += sectionGap
        if let fan = status?.fan, fan.supported {
            y = layoutFan(bottomY: y, fan: fan)
            y += sectionGap
            y = layoutSeparator(bottomY: y)
            y += sectionGap
        }

        if accessibilityGranted {
            y = layoutTiles(bottomY: y)
        } else {
            y = layoutPermissionBlock(bottomY: y)
        }
        y += 6
        y = layoutHeader(bottomY: y, accessibilityGranted: accessibilityGranted)
        y += sectionGap
        y = layoutSeparator(bottomY: y)
        y += sectionGap
        y = layoutAwake(bottomY: y)
        y += pad

        setFrameSize(NSSize(width: Self.width, height: y))
        geometryLog.insert("面板尺寸 \(Int(Self.width)) × \(Int(y))", at: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 各区块（全部返回"排完之后的顶部 y"）

    /// 顶部：合盖续跑（App 的主功能，必须一键可达）
    private func layoutAwake(bottomY: CGFloat) -> CGFloat {
        let active = status?.active ?? false
        let w = Self.width - pad * 2

        var buttons: [(String, Mode)] = []
        if active {
            buttons = [("关闭", .off)]
        } else {
            buttons = [("开启", .indefinite),
                       ("2 小时", .until(Date().addingTimeInterval(7200))),
                       ("8 小时", .until(Date().addingTimeInterval(28800)))]
        }
        let bw = (w - CGFloat(buttons.count - 1) * 6) / CGFloat(buttons.count)
        for (i, item) in buttons.enumerated() {
            let b = ClosureButton(title: item.0) { [weak self] in
                self?.dismissMenu()
                self?.onToggleAwake(item.1)
            }
            b.bezelStyle = .rounded
            b.controlSize = .regular
            b.frame = NSRect(x: pad + CGFloat(i) * (bw + 6), y: bottomY, width: bw, height: 26)
            addSubview(b)
        }

        let dot = NSView(frame: NSRect(x: pad, y: bottomY + 36, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = (active ? NSColor.systemGreen : NSColor.tertiaryLabelColor).cgColor
        addSubview(dot)

        var text = "合盖续跑 · 已关闭"
        if active {
            text = "合盖续跑 · 已开启"
            if let r = status?.remainingSeconds { text += "，剩余 \(Format.hms(r))" }
        }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.frame = NSRect(x: pad + 14, y: bottomY + 32, width: w - 14, height: 16)
        addSubview(label)

        geometryLog.append("合盖续跑区：\(buttons.count) 个按钮，单个宽 \(Int(bw))")
        return bottomY + 54
    }

    /// 风扇：状态 + 一排快捷档位
    private func layoutFan(bottomY: CGFloat, fan: FanStatus) -> CGFloat {
        let w = Self.width - pad * 2
        let presets: [(String, FanMode)] = [
            ("自动", .auto), ("按温度", .curve), ("60%", .percent(60)),
            ("80%", .percent(80)), ("全速", .full),
        ]
        let bw = (w - CGFloat(presets.count - 1) * 5) / CGFloat(presets.count)
        for (i, item) in presets.enumerated() {
            let b = ClosureButton(title: item.0) { [weak self] in
                self?.dismissMenu()
                self?.onSetFan(item.1)
            }
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            // 当前档位高亮
            if fan.mode == item.1 {
                b.bezelColor = NSColor.controlAccentColor
                b.contentTintColor = .white
            }
            b.frame = NSRect(x: pad + CGFloat(i) * (bw + 5), y: bottomY, width: bw, height: 22)
            addSubview(b)
        }

        let rpm = fan.actualRPM.map { String(format: "%.0f", $0) }.joined(separator: " / ")
        var line = "风扇 · \(fan.mode.chinese) · \(rpm) RPM"
        if let t = fan.maxTempC { line += String(format: " · 最高温 %.0f°C", t) }
        let label = NSTextField(labelWithString: line)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.frame = NSRect(x: pad, y: bottomY + 28, width: w, height: 16)
        addSubview(label)

        // 转速占量程的比例条
        let track = NSView(frame: NSRect(x: pad, y: bottomY + 26, width: w, height: 2))
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(track)
        let fillW = max(2, w * CGFloat(fan.loadFraction))
        let fill = NSView(frame: NSRect(x: pad, y: bottomY + 26, width: fillW, height: 2))
        fill.wantsLayer = true
        fill.layer?.backgroundColor = (fan.loadFraction > 0.8 ? NSColor.systemOrange
                                       : NSColor.controlAccentColor).cgColor
        addSubview(fill)

        geometryLog.append("风扇区：\(presets.count) 档按钮，单个宽 \(Int(bw))，"
                           + "转速条 \(Int(fillW))/\(Int(w))")
        return bottomY + 46
    }

    private func layoutStats(bottomY: CGFloat) -> CGFloat {
        let colWidth = (Self.width - pad * 2) / 4
        for (i, caption) in ["CPU", "内存", "磁盘", "网络"].enumerated() {
            let x = pad + CGFloat(i) * colWidth
            let value = NSTextField(labelWithString: "—")
            value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            value.alignment = .center
            value.frame = NSRect(x: x, y: bottomY + 14, width: colWidth, height: 17)
            addSubview(value)
            statsValueLabels.append(value)

            let cap = NSTextField(labelWithString: caption)
            cap.font = .systemFont(ofSize: 9, weight: .medium)
            cap.textColor = .tertiaryLabelColor
            cap.alignment = .center
            cap.frame = NSRect(x: x, y: bottomY, width: colWidth, height: 13)
            addSubview(cap)
            statsCaptionLabels.append(cap)
        }
        geometryLog.append("系统状态条 4 列，每列宽 \(Int(colWidth))，高 \(Int(statsRowHeight))")
        refreshStats(rates: nil)
        return bottomY + statsRowHeight
    }

    private func layoutSeparator(bottomY: CGFloat) -> CGFloat {
        let line = NSBox(frame: NSRect(x: pad, y: bottomY, width: Self.width - pad * 2, height: 1))
        line.boxType = .separator
        addSubview(line)
        return bottomY + 1
    }

    private func layoutTiles(bottomY: CGFloat) -> CGFloat {
        guard !items.isEmpty else {
            let empty = NSTextField(labelWithString: "没有读到任何菜单栏项")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            empty.frame = NSRect(x: pad, y: bottomY + 10, width: Self.width - pad * 2, height: 16)
            addSubview(empty)
            geometryLog.append("磁贴 0 个（空态）")
            return bottomY + 36
        }

        let rows = Int(ceil(Double(items.count) / Double(columns)))
        let gridHeight = CGFloat(rows) * tileHeight + CGFloat(rows - 1) * tileGap

        for (index, item) in items.enumerated() {
            let row = index / columns
            let col = index % columns
            // 第 0 行画在最上面 → y 要从网格顶部往下减
            let x = pad + CGFloat(col) * (tileWidth + tileGap)
            let y = bottomY + gridHeight - CGFloat(row + 1) * tileHeight - CGFloat(row) * tileGap
            let tile = TileView(item: item,
                                frame: NSRect(x: x, y: y, width: tileWidth, height: tileHeight)) {
                [weak self] in self?.select(item)
            }
            addSubview(tile)
        }
        geometryLog.append("磁贴 \(items.count) 个：\(columns) 列 × \(rows) 行，"
                           + "单个 \(Int(tileWidth))×\(Int(tileHeight))，网格高 \(Int(gridHeight))")
        return bottomY + gridHeight
    }

    private func layoutPermissionBlock(bottomY: CGFloat) -> CGFloat {
        let w = Self.width - pad * 2
        let button = ClosureButton(title: "开启辅助功能权限…") { [weak self] in
            self?.dismissMenu()
            self?.onGrantAccessibility()
        }
        button.bezelStyle = .rounded
        button.frame = NSRect(x: pad, y: bottomY, width: w, height: 26)
        addSubview(button)

        let body = NSTextField(wrappingLabelWithString:
            "开启后可以列出全部菜单栏图标（包括被系统裁掉、屏幕上看不到的那些）、"
            + "读出它们的状态文字，并直接点击它们。\n"
            + "LidAwake 不读取窗口内容，也不记录键盘输入。")
        body.font = .systemFont(ofSize: 11)
        body.textColor = .secondaryLabelColor
        body.frame = NSRect(x: pad, y: bottomY + 34, width: w, height: 54)
        addSubview(body)

        let title = NSTextField(labelWithString: "需要「辅助功能」权限")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.frame = NSRect(x: pad, y: bottomY + 92, width: w, height: 16)
        addSubview(title)

        geometryLog.append("权限引导块 \(Int(w))×112")
        return bottomY + 112
    }

    private func layoutHeader(bottomY: CGFloat, accessibilityGranted: Bool) -> CGFloat {
        let hidden = items.filter { !$0.isOnScreen }.count
        let text: String
        if !accessibilityGranted {
            text = "菜单栏图标"
        } else if hidden > 0 {
            text = "菜单栏图标 \(items.count) 个 · \(hidden) 个屏幕上放不下"
        } else {
            text = "菜单栏图标 \(items.count) 个"
        }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: pad, y: bottomY, width: Self.width - pad * 2, height: headerHeight)
        addSubview(label)
        geometryLog.append("标题「\(text)」")
        return bottomY + headerHeight
    }

    // MARK: 交互

    private func select(_ item: MenuBarItemInfo) {
        dismissMenu()
        onSelect(item)
    }

    private func dismissMenu() {
        enclosingMenuItem?.menu?.cancelTracking()
    }

    // MARK: 系统状态

    func startStats() {
        lastSnapshot = SystemStats.snapshot()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = SystemStats.snapshot()
            let rates = self.lastSnapshot.map { StatsRates.between($0, now) }
            self.lastSnapshot = now
            self.refreshStats(rates: rates)
        }
        t.tolerance = 0.2
        // .common 含 NSEventTrackingRunLoopMode —— 菜单追踪期间定时器才会跑
        RunLoop.main.add(t, forMode: .common)
        statsTimer = t
    }

    func stopStats() {
        statsTimer?.invalidate()
        statsTimer = nil
        lastSnapshot = nil
    }

    private func refreshStats(rates: StatsRates?) {
        guard statsValueLabels.count == 4 else { return }
        let mem = SystemStats.memory()
        let disk = SystemStats.disk()

        statsValueLabels[0].stringValue = rates.map { Format.percent($0.cpuBusy) } ?? "—"
        statsCaptionLabels[0].stringValue = String(format: "CPU · 负载 %.1f", SystemStats.loadAverage())

        statsValueLabels[1].stringValue = Format.percent(mem.fraction)
        statsCaptionLabels[1].stringValue = "内存 · \(Format.bytes(mem.used))/\(Format.bytes(mem.total))"

        statsValueLabels[2].stringValue = rates.map {
            "↓\(Format.rate($0.diskReadPerSec))"
        } ?? Format.percent(disk.usedFraction)
        statsCaptionLabels[2].stringValue = "磁盘 · 可用 \(Format.bytes(disk.free))"

        statsValueLabels[3].stringValue = rates.map { "↓\(Format.rate($0.netRxPerSec))" } ?? "—"
        statsCaptionLabels[3].stringValue = "网络 · \(SystemStats.primaryInterface() ?? "未连接")"
    }

    func geometryDump() -> String { geometryLog.joined(separator: "\n") }
}

// MARK: - 单个磁贴

private final class TileView: NSView {
    private let item: MenuBarItemInfo
    private let onSelect: () -> Void
    private var hovering = false

    init(item: MenuBarItemInfo, frame: NSRect, onSelect: @escaping () -> Void) {
        self.item = item
        self.onSelect = onSelect
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10

        let iconSize: CGFloat = 34
        let icon = NSImageView(frame: NSRect(x: (frame.width - iconSize) / 2,
                                             y: frame.height - iconSize - 10,
                                             width: iconSize, height: iconSize))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = NSRunningApplication(processIdentifier: item.pid)?.icon
        icon.image?.isTemplate = false
        addSubview(icon)

        // 屏幕上放不下 → 右上角一个橙点，一眼看出"这个你点不到"
        if !item.isOnScreen {
            let dot = NSView(frame: NSRect(x: frame.width / 2 + iconSize / 2 - 6,
                                           y: frame.height - 14, width: 9, height: 9))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4.5
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            dot.layer?.borderWidth = 1.5
            dot.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
            addSubview(dot)
        }

        let name = NSTextField(labelWithString: item.appName)
        name.font = .systemFont(ofSize: 10.5)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle
        name.frame = NSRect(x: 2, y: frame.height - iconSize - 26, width: frame.width - 4, height: 14)
        addSubview(name)

        if let status = item.statusText {
            let sub = NSTextField(labelWithString: status)
            sub.font = .systemFont(ofSize: 9)
            sub.textColor = .secondaryLabelColor
            sub.alignment = .center
            sub.lineBreakMode = .byTruncatingTail
            sub.frame = NSRect(x: 2, y: frame.height - iconSize - 39,
                               width: frame.width - 4, height: 12)
            addSubview(sub)
        }

        var tip = [item.displayName]
        if let s = item.statusText { tip.append(s) }
        if !item.isOnScreen { tip.append("菜单栏放不下，屏幕上看不到这一项") }
        tip.append(item.isPressable ? "点击直接展开它的菜单"
                                    : "该项不支持程序化点击，需先展开菜单栏再手动点")
        toolTip = tip.joined(separator: "\n")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.20).cgColor
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
