import AppKit
import LidAwakeCore

/// 折叠面板：列出全部菜单栏项（含被系统裁掉、点不到的那些）+ 底部系统实时状态。
///
/// 能耗约定：面板**关闭时完全不采样、不扫描**。系统状态的 1 秒定时器只在面板可见期间存在。
final class BarPanelController: NSObject, NSWindowDelegate {

    private let panel: NSPanel
    private let scanner = StatusItemScanner()
    private let listStack = NSStackView()
    private let footer = StatsFooter()
    private let headerLabel = NSTextField(labelWithString: "菜单栏项目")
    private let scrollView = NSScrollView()
    private var contentStack = NSStackView()

    private var statsTimer: Timer?
    private var lastSnapshot: StatsSnapshot?
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private let scanQueue = DispatchQueue(label: "com.cogito.LidAwake.axscan", qos: .userInitiated)

    var onToggleFold: (() -> Void)?
    var foldStateProvider: (() -> FoldState)?

    private let panelWidth: CGFloat = 360

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true

        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 2
        listStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = listStack

        let divider = NSBox()
        divider.boxType = .separator

        contentStack = NSStackView(views: [headerLabel, scrollView, divider, footer])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 6
        contentStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 2, right: 10)

        blur.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: blur.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            footer.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -20),
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -20),
            listStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
        panel.contentView = blur
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: 显示 / 隐藏

    func toggle(near rect: NSRect?) {
        isVisible ? hide() : show(near: rect)
    }

    func show(near anchor: NSRect?) {
        rebuild()
        position(near: anchor)
        panel.orderFrontRegardless()
        startStats()
        installMonitors()
    }

    func hide() {
        stopStats()
        removeMonitors()
        panel.orderOut(nil)
    }

    private func position(near anchor: NSRect?) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor?.origin ?? .zero) })
                ?? NSScreen.main else { return }
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: panelWidth, height: 320)
        let height = min(max(size.height, 200), screen.visibleFrame.height - 40)
        var x = (anchor?.midX ?? screen.frame.midX) - panelWidth / 2
        x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - panelWidth - 8)
        let y = (anchor?.minY ?? screen.visibleFrame.maxY) - height - 6
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: height), display: true)
    }

    /// 点面板外面或按 ESC 就收起 —— 和系统菜单的行为一致。
    private func installMonitors() {
        removeMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isVisible else { return }
            if !self.panel.frame.contains(NSEvent.mouseLocation) {
                DispatchQueue.main.async { self.hide() }
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {         // ESC
                self?.hide()
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideClickMonitor = nil
        keyMonitor = nil
    }

    // MARK: 内容

    private func rebuild() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard Permissions.accessibilityGranted else {
            headerLabel.stringValue = "菜单栏项目 —— 需要授权"
            let card = PermissionCard(title: "开启「辅助功能」以列出菜单栏图标",
                                      body: Permissions.accessibilityRationale,
                                      buttonTitle: "打开系统设置授权") {
                Permissions.requestAccessibility()
                Permissions.openAccessibilitySettings()
            }
            listStack.addView(card, in: .top)
            card.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            addFoldRow()
            refreshStatsOnce()
            return
        }

        headerLabel.stringValue = "正在读取菜单栏…"
        scanQueue.async { [weak self] in
            guard let self else { return }
            let items = self.scanner.scan()
            DispatchQueue.main.async { self.render(items) }
        }
        refreshStatsOnce()
    }

    private func render(_ items: [MenuBarItemInfo]) {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let hidden = items.filter { !$0.isOnScreen }.count
        headerLabel.stringValue = hidden > 0
            ? "菜单栏项目 \(items.count) 个 · 其中 \(hidden) 个屏幕上放不下"
            : "菜单栏项目 \(items.count) 个"

        if items.isEmpty {
            let empty = NSTextField(wrappingLabelWithString:
                "没有读到任何菜单栏项。\n如果刚授权完辅助功能，可能需要重启 LidAwake 才能生效。")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            listStack.addView(empty, in: .top)
        }

        var rows: [String: ItemRow] = [:]
        for group in MenuBarLayout.grouped(items) {
            for item in group.items {
                let row = ItemRow(item: item,
                                  icon: NSRunningApplication(processIdentifier: item.pid)?.icon) {
                    [weak self] in self?.activate(item)
                }
                listStack.addView(row, in: .top)
                row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
                rows[item.id] = row
            }
        }
        addFoldRow()
        position(near: nil)

        // 真实图标是可选项，而且要走一次异步截屏 —— 先用 App 图标把界面立刻显示出来，
        // 截到了再替换，绝不为了它让面板变慢。
        IconCapture.captureVisibleIcons(for: items) { images in
            for (id, image) in images { rows[id]?.setIcon(image) }
        }
    }

    /// 面板底部的折叠开关 —— 对于不支持 AXPress 的项，这是唯一能触达的办法
    private func addFoldRow() {
        let folded = foldStateProvider?() == .folded
        let button = ClosureButton(title: folded ? "展开菜单栏图标" : "折叠菜单栏图标") { [weak self] in
            self?.onToggleFold?()
            self?.hide()
        }
        button.bezelStyle = .rounded
        button.controlSize = .small
        listStack.addView(button, in: .bottom)
    }

    private func activate(_ item: MenuBarItemInfo) {
        hide()
        guard item.isPressable else {
            Alerts.show("这一项不支持程序化点击",
                        "\(item.appName) 的这个菜单栏项没有提供 AXPress 动作。\n\n"
                        + "请先用「展开菜单栏图标」把它显示出来，再手动点击。",
                        style: .informational)
            return
        }
        // 稍等一下再按：让面板先收起来，否则弹出的菜单会被面板挡住
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            if !self.scanner.press(item) {
                Alerts.show("点击失败",
                            "无法激活 \(item.appName) 的这个菜单栏项。\n"
                            + "可能是该 App 刚重启（序号变了），重新打开面板再试。",
                            style: .warning)
            }
        }
    }

    // MARK: 系统状态（只在面板可见时采样）

    private func startStats() {
        stopStats()
        lastSnapshot = SystemStats.snapshot()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickStats()
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        statsTimer = t
    }

    private func stopStats() {
        statsTimer?.invalidate()
        statsTimer = nil
        lastSnapshot = nil
    }

    private func tickStats() {
        let now = SystemStats.snapshot()
        let rates = lastSnapshot.map { StatsRates.between($0, now) } ?? StatsRates()
        lastSnapshot = now
        footer.update(rates: rates, memory: SystemStats.memory(),
                      disk: SystemStats.disk(), iface: SystemStats.primaryInterface())
    }

    /// 刚打开时先显示一次瞬时值（内存/磁盘不需要两次采样）
    private func refreshStatsOnce() {
        footer.update(rates: StatsRates(), memory: SystemStats.memory(),
                      disk: SystemStats.disk(), iface: SystemStats.primaryInterface())
    }

    func windowDidResignKey(_ notification: Notification) {
        // nonactivating panel 一般不会成为 key window，这里只是兜底
        hide()
    }
}
