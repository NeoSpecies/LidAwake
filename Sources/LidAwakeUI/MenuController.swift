import AppKit
import LidAwakeCore

final class MenuController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let client = DaemonClient()
    private let limited = LimitedController()

    /// 来自守护进程的真实状态；nil = 未连上（受限模式）
    private var status: StatusDTO?
    private var lastError: String?
    private var titleTimer: Timer?
    private var probeRunning = false
    private var menuIsOpen = false
    private var installing = false
    private let foldFeature = FoldFeature()

    private var daemonInstalled: Bool { DaemonClient.isDaemonInstalled }
    private var isActive: Bool { status?.active ?? limited.mode.isActive }
    private var currentMode: Mode { status?.mode ?? limited.mode }
    private var remaining: Double? { status?.remainingSeconds ?? limited.remaining }
    private var mechanism: Mechanism {
        if let s = status { return s.mechanism }
        return limited.mode.isActive ? .assertionsOnly : .none
    }

    override init() {
        super.init()
        menu.delegate = self
        // 不把 menu 直接挂到 statusItem 上 —— 那样左键会弹菜单。
        // 我们要的是：**左键出面板，右键出菜单**，所以自己路由点击。
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        client.onStateChange = { [weak self] s in
            DispatchQueue.main.async {
                guard let self else { return }
                self.status = s
                self.lastError = nil
                // 守护进程接管了，受限模式的本地断言必须撤掉，否则两边都在挂
                if self.limited.mode.isActive { self.limited.apply(.off) }
                self.applyStateToUI()
            }
        }
        client.onDisconnect = { [weak self] reason in
            DispatchQueue.main.async {
                guard let self else { return }
                self.status = nil
                self.lastError = reason
                self.applyStateToUI()
            }
        }
        limited.onChange = { [weak self] in self?.applyStateToUI() }
        foldFeature.onStateChange = { [weak self] in
            DispatchQueue.main.async { self?.applyStateToUI() }
        }

        foldFeature.statusProvider = { [weak self] in self?.status }
        foldFeature.onToggleAwake = { [weak self] mode in self?.setMode(mode) }
        foldFeature.onSetFan = { [weak self] mode in self?.setFan(mode) }
        foldFeature.attach(to: statusItem) { [weak self] in self?.updateAppearance() }

        refresh()
        applyStateToUI()
    }

    /// 左键 → 面板（默认动作，装这个 App 最常用的就是它）
    /// 右键 / ⌃ 点击 → 菜单（全部设置项）
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRight {
            rebuild(menu)
            // 标准做法：临时挂上 menu 让系统弹，弹完立刻摘掉，
            // 否则下次左键会被系统直接弹菜单而走不到我们的路由。
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            foldFeature.openPanel()
        }
    }

    /// 状态变化后统一走这里：更新图标，并且如果菜单正开着就就地重建条目
    /// （异步拿到的状态不能等下次开菜单才生效，否则用户看到的是上一次的值）。
    private func applyStateToUI() {
        updateAppearance()
        if menuIsOpen { rebuild(menu) }
    }

    func shutdown() {
        foldFeature.shutdown()
        titleTimer?.invalidate()
        limited.shutdown()
        client.invalidate()
    }

    // MARK: - 状态刷新

    private func refresh() {
        guard daemonInstalled else {
            status = nil
            applyStateToUI()
            return
        }
        client.statusAsync { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let s):
                    self.status = s
                    self.lastError = nil
                    if self.limited.mode.isActive { self.limited.apply(.off) }
                case .failure(let e):
                    self.status = nil
                    self.lastError = e.localizedDescription
                }
                self.applyStateToUI()
            }
        }
    }

    private func updateAppearance() {
        let names: [String]
        if !isActive {
            names = ["powersleep", "moon.zzz", "bed.double"]
        } else if mechanism == .assertionsOnly {
            names = ["exclamationmark.triangle.fill", "exclamationmark.triangle"]
        } else if currentMode.deadline != nil {
            names = ["timer", "clock.fill"]
        } else {
            names = ["infinity.circle.fill", "infinity", "bolt.circle.fill"]
        }
        guard foldFeature.foldState == .expanded else { return }   // 折叠态外观由 FoldController 管
        let image = Symbols.image(names, description: "LidAwake")
        statusItem.button?.image = image

        // SF Symbol 全部取不到时用文字兜底，别让菜单栏出现一个看不见的空图标
        var title = image == nil ? (isActive ? "醒" : "睡") : ""
        if isActive, let r = remaining {
            title += (title.isEmpty ? " " : " ") + Format.compact(r)
        }
        statusItem.button?.title = title
        statusItem.button?.toolTip = tooltip()
        scheduleTitleTimer()
    }

    private func tooltip() -> String {
        guard isActive else { return "LidAwake：已关闭（合盖会正常休眠）" }
        var t = "LidAwake：合盖续跑已开启\n机制：\(mechanism.chinese)"
        if let r = remaining { t += "\n剩余：\(Format.hms(r))" }
        return t
    }

    /// 只在"有倒计时"时才装定时器，30s 一次 + 10s 容差，能耗可忽略。
    private func scheduleTitleTimer() {
        let needed = isActive && remaining != nil
        if !needed {
            titleTimer?.invalidate()
            titleTimer = nil
            return
        }
        guard titleTimer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let r = self.remaining, r <= 0 { self.refresh() }
            self.updateAppearance()
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        titleTimer = t
    }

    // MARK: - 动作

    private func setMode(_ mode: Mode) {
        // 没装守护进程 → 只能走受限模式（App 自己挂断言）
        guard daemonInstalled else {
            limited.apply(mode)
            return
        }
        // 装了就一定走守护进程；失败时才退回受限模式，并明确告知用户
        if limited.mode.isActive { limited.apply(.off) }
        let request: ApplyRequest
        switch mode {
        case .off: request = .off
        case .indefinite: request = .indefinite(origin: "menubar")
        case .until(let d): request = .until(seconds: max(5, d.timeIntervalSinceNow), origin: "menubar")
        }
        client.applyAsync(request) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let s):
                    self?.status = s
                    self?.applyStateToUI()
                    if !s.active, let reason = s.lastReleaseReason, mode.isActive {
                        Alerts.show("未能开启", reason.chinese + "\n\n可以在「安全策略」里调整对应选项。",
                                    style: .warning)
                    } else if s.mechanism == .assertionsOnly {
                        Alerts.show("已开启，但只有断言层生效",
                                    (s.degradedNote ?? "SleepDisabled 未能施加")
                                    + "\n\n这种情况下只有接通电源时才可能拦住合盖休眠。"
                                    + "请从菜单运行「安装 / 修复后台服务」。", style: .warning)
                    }
                case .failure(let e):
                    self?.status = nil
                    // 退回受限模式，但绝不假装成功
                    if mode.isActive { self?.limited.apply(mode) }
                    self?.applyStateToUI()
                    Alerts.show("后台服务无法通信，已退回受限模式",
                                e.localizedDescription
                                + "\n\n受限模式只挂断言层：仅在接通电源时可能拦住合盖休眠，"
                                + "纯电池不保证。\n请从菜单运行「修复后台服务」。", style: .warning)
                }
            }
        }
    }

    private func setFan(_ mode: FanMode) {
        client.setFanAsync(FanRequest(mode: mode)) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let s):
                    self?.status = s
                    self?.applyStateToUI()
                    if mode == .full {
                        Alerts.show("风扇已设为全速",
                                    "会明显变响。任何时候可以从菜单选「自动（交还系统）」还回去。\n\n"
                                    + "LidAwake 退出、崩溃、卸载或重启时都会自动交还固件控制。")
                    }
                case .failure(let e):
                    Alerts.show("风扇设置失败", e.localizedDescription, style: .warning)
                }
            }
        }
    }

    private func updateGuards(_ transform: (inout Guards) -> Void) {
        guard var g = status?.guards else {
            Alerts.show("需要后台服务", "安全策略由后台服务负责执行。请先运行「安装 / 修复后台服务」。",
                        style: .warning)
            return
        }
        transform(&g)
        client.setGuardsAsync(g) { [weak self] result in
            DispatchQueue.main.async {
                if case .success(let s) = result {
                    self?.status = s
                    self?.applyStateToUI()
                } else if case .failure(let e) = result {
                    Alerts.show("保存安全策略失败", e.localizedDescription, style: .warning)
                }
            }
        }
    }

    private func installService() {
        NSApp.activate(ignoringOtherApps: true)
        guard Alerts.confirm("安装后台服务",
                             "接下来会弹出 macOS 系统授权框（可用触控 ID）。\n\n"
                             + "只需要授权这一次：之后所有开关操作都不再需要密码。\n\n"
                             + "安装内容：\n"
                             + "• \(LidAwakeInfo.daemonPath)\n"
                             + "• /Library/LaunchDaemons/\(LidAwakeInfo.daemonLabel).plist\n"
                             + "• /usr/local/bin/lidawake、lidawake-probe（命令行工具）",
                             ok: "继续安装") else { return }

        // 授权框可能停在屏幕上很久，安装放到后台线程做，主线程不能被 osascript 卡住
        guard !installing else { return }
        installing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Installer.installService()
            DispatchQueue.main.async {
                self?.installing = false
                if result.ok {
                    Alerts.showText("安装完成", result.output.isEmpty ? "后台服务已就绪。" : result.output)
                    self?.refresh()
                } else {
                    Alerts.showText("安装失败", result.output)
                }
            }
        }
    }

    private func showDiagnostics() {
        var lines: [String] = []
        lines.append("LidAwake \(LidAwakeInfo.version)")
        lines.append("守护进程已安装 : \(daemonInstalled ? "是" : "否")")
        if let s = status {
            lines.append("XPC 连接       : 正常（服务 pid \(s.daemonPID)）")
            lines.append("模式           : \(s.mode.label)")
            lines.append("机制           : \(s.mechanism.chinese)")
            lines.append("SleepDisabled  : \(s.sleepDisabled.map { $0 ? "1" : "0" } ?? "未知")")
            lines.append("持有断言       : \(s.assertionsHeld.isEmpty ? "无" : s.assertionsHeld.joined(separator: ", "))")
            lines.append("电源           : \(s.onExternalPower ? "接通电源" : "电池")"
                         + (s.batteryPercent.map { " \($0)%" } ?? ""))
            lines.append("温度           : \(s.thermal.chinese)")
            lines.append("上盖           : \(s.clamshellClosed.map { $0 ? "合上" : "打开" } ?? "未知")")
            if let r = s.lastReleaseReason {
                lines.append("上次结束原因   : \(r.chinese)")
            }
            if let n = s.degradedNote { lines.append("降级说明       : \(n)") }
        } else {
            lines.append("XPC 连接       : 未连接 \(lastError.map { "（\($0)）" } ?? "")")
            let ctl = SleepDisabledController()
            lines.append("SleepDisabled  : \(ctl.read().map { $0 ? "1" : "0" } ?? "未知")")
            lines.append("受限模式断言   : \(limited.heldAssertions.isEmpty ? "无" : limited.heldAssertions.joined(separator: ", "))")
        }
        lines.append("")
        let foreign = Diagnostics.foreignAssertions()
        if foreign.isEmpty {
            lines.append("其他阻止休眠的进程：无")
        } else {
            lines.append("其他阻止休眠的进程（\(foreign.count)）：")
            for f in foreign {
                lines.append("  pid \(f.pid) \(f.process)")
                lines.append("      \(f.type)\(f.name.isEmpty ? "" : " 「\(f.name)」")")
            }
        }
        Alerts.showText("诊断信息", lines.joined(separator: "\n"))
    }

    // MARK: - 自检

    private func startSelfTest() {
        let probe = Installer.toolPath("lidawake-probe")
        guard FileManager.default.isExecutableFile(atPath: probe) else {
            Alerts.show("找不到探针工具", "缺少 lidawake-probe。请先运行「安装 / 修复后台服务」。",
                        style: .warning)
            return
        }
        guard Alerts.confirm("合盖连续性自检",
                             "原理：mach_absolute_time 在系统睡眠时停表，mach_continuous_time 不停。"
                             + "两者之差就是这段时间真实睡了多久 —— 结论是可量化的，不靠感觉。\n\n"
                             + "步骤：\n"
                             + "1. 点「开始采样」\n"
                             + "2. 合上盖子至少 60 秒\n"
                             + "3. 打开盖子，回到本菜单点「查看自检报告」",
                             ok: "开始采样") else { return }
        let (rc, out) = Shell.run(probe, ["start"], timeout: 20)
        probeRunning = (rc == 0)
        Alerts.showText(rc == 0 ? "采样已开始" : "采样启动失败", out)
    }

    private func showSelfTestReport() {
        let probe = Installer.toolPath("lidawake-probe")
        let (_, report) = Shell.run(probe, ["report"], timeout: 30)
        _ = Shell.run(probe, ["stop"], timeout: 10)
        probeRunning = false
        Alerts.showText("自检报告", report)
    }

    // MARK: - 菜单构建

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()          // 异步；结果回来后 applyStateToUI() 会就地重建条目
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        // ── 状态区
        switch (isActive, currentMode.deadline) {
        case (false, _):
            menu.addDisabled("已关闭 · 合盖会正常休眠")
        case (true, .some):
            menu.addDisabled("已开启 · 剩余 \(Format.hms(remaining ?? 0))", monospaced: true)
        case (true, .none):
            // 无限期模式下若配了"单次最长时限"，把上限剩余也说清楚
            if let r = remaining {
                menu.addDisabled("已开启 · 无限期（最长剩余 \(Format.hms(r))）", monospaced: true)
            } else {
                menu.addDisabled("已开启 · 无限期")
            }
        }
        if isActive {
            menu.addDisabled("机制: \(mechanism.chinese)")
        }
        if !daemonInstalled {
            menu.addDisabled("⚠️ 后台服务未安装 —— 当前为受限模式")
        } else if status == nil {
            menu.addDisabled("⚠️ 无法连接后台服务")
        }
        if let s = status, let note = s.degradedNote {
            menu.addDisabled("⚠️ \(note)")
        }
        if let s = status, !s.active, let r = s.lastReleaseReason, r != .userOff {
            menu.addDisabled("上次: \(r.chinese)")
        }

        menu.addItem(.separator())

        // ── 开关区
        menu.addAction("开启（无限期）", state: isActive && currentMode.deadline == nil ? .on : .off) {
            [weak self] in self?.setMode(.indefinite)
        }
        menu.addSubmenu("定时开启") { sub in
            for (label, secs) in [("15 分钟", 900.0), ("30 分钟", 1800.0), ("1 小时", 3600.0),
                                  ("2 小时", 7200.0), ("4 小时", 14400.0), ("8 小时", 28800.0)] {
                sub.addAction(label) { [weak self] in
                    self?.setMode(.until(Date().addingTimeInterval(secs)))
                }
            }
            sub.addItem(.separator())
            sub.addAction("自定义…") { [weak self] in
                if let s = Alerts.askDuration() {
                    self?.setMode(.until(Date().addingTimeInterval(s)))
                }
            }
        }
        menu.addAction("关闭", key: ".", state: isActive ? .off : .on) { [weak self] in
            self?.setMode(.off)
        }

        menu.addItem(.separator())

        // ── 安全策略
        menu.addSubmenu("安全策略") { sub in
            let g = status?.guards ?? Guards()
            sub.addSubmenu("电量下限：" + (g.batteryFloorPercent.map { "\($0)%" } ?? "关闭")) { s2 in
                for p in [10, 15, 20, 30, 40, 50] {
                    s2.addAction("\(p)%", state: g.batteryFloorPercent == p ? .on : .off) {
                        [weak self] in self?.updateGuards { $0.batteryFloorPercent = p }
                    }
                }
                s2.addItem(.separator())
                s2.addAction("关闭该保护", state: g.batteryFloorPercent == nil ? .on : .off) {
                    [weak self] in self?.updateGuards { $0.batteryFloorPercent = nil }
                }
            }
            sub.addSubmenu("单次最长：" + (g.maxSessionSeconds.map { Format.compact($0) } ?? "无限制")) { s2 in
                for (label, secs) in [("2 小时", 7200.0), ("4 小时", 14400.0), ("8 小时", 28800.0),
                                      ("12 小时", 43200.0), ("24 小时", 86400.0)] {
                    s2.addAction(label, state: g.maxSessionSeconds == secs ? .on : .off) {
                        [weak self] in self?.updateGuards { $0.maxSessionSeconds = secs }
                    }
                }
                s2.addItem(.separator())
                s2.addAction("无限制", state: g.maxSessionSeconds == nil ? .on : .off) {
                    [weak self] in self?.updateGuards { $0.maxSessionSeconds = nil }
                }
            }
            sub.addAction("仅在接通电源时保持", state: g.requireExternalPower ? .on : .off) {
                [weak self] in self?.updateGuards { $0.requireExternalPower.toggle() }
            }
            sub.addAction("机身过热时自动关闭", state: g.releaseOnCriticalThermal ? .on : .off) {
                [weak self] in self?.updateGuards { $0.releaseOnCriticalThermal.toggle() }
            }
            sub.addAction("合盖时同时保持屏幕唤醒（费电）", state: g.keepDisplayAwake ? .on : .off) {
                [weak self] in self?.updateGuards { $0.keepDisplayAwake.toggle() }
            }
            sub.addAction("重启后恢复上次会话", state: g.persistAcrossReboot ? .on : .off) {
                [weak self] in self?.updateGuards { $0.persistAcrossReboot.toggle() }
            }
        }

        if let fan = status?.fan, fan.supported {
            let rpm = fan.actualRPM.map { String(format: "%.0f", $0) }.joined(separator: "/")
            let temp = fan.maxTempC.map { String(format: " · %.0f°C", $0) } ?? ""
            menu.addSubmenu("风扇：\(fan.mode.chinese)  \(rpm) RPM\(temp)") { sub in
                sub.addDisabled(String(format: "量程 %.0f–%.0f RPM · 当前 %@ RPM%@",
                                       fan.minRPM, fan.maxRPM, rpm as NSString, temp as NSString))
                if let t = fan.targetRPM {
                    sub.addDisabled(String(format: "LidAwake 接管中，目标 %.0f RPM", t))
                } else {
                    sub.addDisabled("固件控制中")
                }
                sub.addItem(.separator())
                sub.addAction("自动（交还系统）", state: fan.mode == .auto ? .on : .off) {
                    [weak self] in self?.setFan(.auto)
                }
                sub.addAction("按温度自动提速", state: fan.mode == .curve ? .on : .off) {
                    [weak self] in self?.setFan(.curve)
                }
                sub.addItem(.separator())
                for pct in [40, 55, 70, 85] {
                    let rpmAt = fan.minRPM + Double(pct) / 100 * (fan.maxRPM - fan.minRPM)
                    sub.addAction(String(format: "%d%%（约 %.0f RPM）", pct, rpmAt),
                                  state: fan.mode == .percent(pct) ? .on : .off) {
                        [weak self] in self?.setFan(.percent(pct))
                    }
                }
                sub.addAction("全速", state: fan.mode == .full ? .on : .off) {
                    [weak self] in self?.setFan(.full)
                }
                sub.addItem(.separator())
                sub.addDisabled("只提速不降速：温度越高允许的最低转速越高")
                sub.addDisabled(String(format: "≥%.0f°C 无条件全速", fan.policy.criticalC))
                if let sensor = fan.hottestSensor {
                    sub.addDisabled("最热传感器: \(sensor)")
                }
            }
        }
        menu.addAction("诊断信息…") { [weak self] in self?.showDiagnostics() }

        menu.addItem(.separator())

        // ── 维护
        menu.addAction("登录时启动", state: LoginItem.isEnabled ? .on : .off) {
            let want = !LoginItem.isEnabled
            if let err = LoginItem.setEnabled(want) {
                Alerts.show("设置登录项失败", err, style: .warning)
            }
        }
        menu.addAction(daemonInstalled ? "修复后台服务…" : "安装后台服务…") {
            [weak self] in self?.installService()
        }
        menu.addSubmenu("菜单栏折叠") { sub in
            sub.addAction(self.foldFeature.foldState == .folded
                          ? "展开菜单栏图标（当前已折叠）" : "折叠左侧菜单栏图标") {
                [weak self] in self?.foldFeature.toggleFold()
            }
            sub.addDisabled("折叠会把本图标左边的图标顶出可见区")
            sub.addItem(.separator())
            sub.addAction("打开面板（\(self.foldFeature.hotKeyName)）") {
                [weak self] in self?.foldFeature.openPanel()
            }
            sub.addAction("全局快捷键 \(self.foldFeature.hotKeyName)",
                          state: HotKey.isEnabled ? .on : .off) { [weak self] in
                self?.foldFeature.setHotKeyEnabled(!HotKey.isEnabled)
            }
            sub.addItem(.separator())
            let axOK = self.foldFeature.accessibilityGranted
            sub.addDisabled("辅助功能权限: \(axOK ? "已授权" : "未授权")")
            if !axOK {
                sub.addAction("授权辅助功能…（列出并点击菜单栏图标）") { [weak self] in
                    self?.foldFeature.requestAccessibility()
                }
            }
            sub.addAction("真实图标预览（需屏幕录制）",
                          state: self.foldFeature.realIconEnabled ? .on : .off) { [weak self] in
                guard let self else { return }
                self.foldFeature.setRealIconPreview(!self.foldFeature.realIconRequested)
            }
        }
        menu.addAction("自检（合盖连续性测试）…") { [weak self] in self?.startSelfTest() }
        if probeRunning {
            menu.addAction("查看自检报告…") { [weak self] in self?.showSelfTestReport() }
        }

        menu.addItem(.separator())
        menu.addAction("关于 LidAwake") {
            Alerts.show("LidAwake \(LidAwakeInfo.version)",
                        "让 Mac 合盖后继续联网运行。\n\n"
                        + "机制：IOPMAssertion（断言层）+ SleepDisabled（系统层，需一次授权）。\n"
                        + "命令行：lidawake on --for 2h / lidawake off / lidawake doctor")
        }
        menu.addItem(.separator())
        menu.addDisabled("左键点图标 = 打开面板 · 右键 = 本菜单")
        menu.addAction("退出", key: "q") { NSApp.terminate(nil) }
    }
}
