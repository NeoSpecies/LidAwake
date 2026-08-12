import Foundation
import LidAwakeCore

/// 特权守护进程。全部状态操作串行在 main queue 上；所有触发都是事件驱动，无轮询。
final class Daemon: NSObject, NSXPCListenerDelegate, DaemonAPI {

    private let q = DispatchQueue.main
    private let store = StateStore()
    private let sleepCtl = SleepDisabledController()
    private let assertions = AssertionHolder()
    private let fan = FanController()
    private let listener = NSXPCListener(machServiceName: LidAwakeInfo.machServiceName)

    private var state = PersistedState()
    private var clients: [NSXPCConnection] = []
    private var monitor: SystemEventMonitor?
    private var signalSources: [DispatchSourceSignal] = []

    private var deadlineTimer: DispatchSourceTimer?
    private var fanTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?

    private var degradedNote: String?
    private var terminating = false
    /// 最近一次施加的风扇目标。SMC 回读有几秒滞后，立即回显用这个值才准确。
    private var lastFanTarget: Double?
    /// 分档状态：引擎是纯函数，档位与停留时间由这里保存
    private var fanStep = FanEngine.StepState.firmware
    private var fanStepChangedAt = Date()

    /// 关闭状态下空闲多久自退（零常驻开销）。launchd 会在下次连接时按需拉起。
    private let idleExitSeconds: Double = 120
    /// 会话激活期间的兜底心跳（电量/温度本身由通知驱动，这里只是保险）。
    private let heartbeatSeconds: Double = 300

    // MARK: - 生命周期

    func start() {
        Log.shared.configure(path: LidAwakeInfo.logPath)
        Log.info("lidawaked \(LidAwakeInfo.version) 启动 pid=\(getpid()) uid=\(getuid())")
        if getuid() != 0 {
            Log.warn("非 root 运行：SleepDisabled 无法施加，将只有断言层生效")
        }

        if fan.isAvailable {
            let r = fan.readOnly.range()
            Log.info("风扇可控: \(fan.fanCount) 个，量程 \(Int(r.minRPM))–\(Int(r.maxRPM)) RPM，"
                     + "温度传感器 \(fan.readOnly.discoveredSensorCount) 个")
        } else {
            Log.info("风扇不可控（无风扇或 SMC 不可用）")
        }
        loadStateWithBootReconcile()
        installSignalHandlers()

        let m = SystemEventMonitor(queue: q)
        m.start { [weak self] key in
            self?.q.async { self?.reconcile(trigger: "notify:\(key.split(separator: ".").last ?? "?")") }
        }
        monitor = m

        listener.delegate = self
        listener.resume()

        reconcile(trigger: "start")
    }

    private func loadStateWithBootReconcile() {
        let loaded = store.load()
        var s = loaded.state
        if loaded.wasCorrupt { Log.warn("状态文件损坏，已回落为关闭状态") }

        let boot = SystemInfo.bootTimeEpoch()
        if Engine.needsRebootReset(storedBootTime: s.bootTimeEpoch,
                                   currentBootTime: boot,
                                   mode: s.mode,
                                   persistAcrossReboot: s.guards.persistAcrossReboot) {
            Log.info("检测到重启且未开启「重启后恢复」，会话复位为关闭")
            s.mode = .off
            s.startedAt = nil
            s.origin = nil
            s.lastReleaseReason = .rebootReset
            s.lastReleaseAt = Date()
        }
        // 风扇控制**永远不跨重启保留** —— 开机后必须由固件接管，
        // 否则一旦守护进程起不来，风扇就被锁在上次的转速上了。
        if s.fanMode.isManual {
            Log.info("开机复位：风扇模式 \(s.fanMode.label) → auto")
            s.fanMode = .auto
        }
        s.bootTimeEpoch = boot
        s.guards = s.guards.validated()
        s.fanPolicy = s.fanPolicy.validated()
        state = s
        _ = fan.release()
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: q)
            src.setEventHandler { [weak self] in self?.terminate(signal: sig) }
            src.resume()
            signalSources.append(src)
        }
    }

    /// 失效安全：卸载 / 关机 / `launchctl bootout` 都会走到这里，
    /// 必须先把 SleepDisabled 放开再退出，绝不能留下"永不休眠"的系统。
    private func terminate(signal sig: Int32) {
        guard !terminating else { return }
        terminating = true
        let wasActive = state.mode.isActive
        // 开启了"重启后恢复"时，保留会话记录（下次启动会重新施加），
        // 但**无论如何**都要先放开 SleepDisabled，不能挡住关机/卸载。
        let keepSession = state.guards.persistAcrossReboot
        if wasActive && !keepSession {
            state.lastReleaseReason = .daemonTerminating
            state.lastReleaseAt = Date()
            state.mode = .off
            state.startedAt = nil
            state.origin = nil
        }
        assertions.releaseAll()
        let fanOK = fan.release()
        if state.fanMode.isManual {
            state.fanMode = .auto
            Log.info("风扇控制权已交还固件 \(fanOK ? "✅" : "❌")")
        }
        let ok = sleepCtl.set(false)
        persist()
        Log.info("收到信号 \(sig)：已释放断言，SleepDisabled 复位\(ok ? "成功" : "失败(!)")"
                 + (wasActive && keepSession ? "，会话已保留待重启后恢复" : "") + "，退出")
        exit(0)
    }

    private func gracefulIdleExit() {
        guard !terminating else { return }
        terminating = true
        assertions.releaseAll()
        _ = fan.release()
        _ = sleepCtl.set(false)
        persist()
        Log.info("空闲 \(Int(idleExitSeconds))s 自动退出（关闭状态零常驻开销）")
        exit(0)
    }

    // MARK: - 核心收敛

    private func reconcile(trigger: String) {
        guard !terminating else { return }
        // 关闭状态下，电量/温度变化没有任何可判定的东西 —— 直接跳过，
        // 省掉每 1% 电量变化都做一轮 IOKit 读取和状态广播。
        if !state.mode.isActive && trigger.hasPrefix("notify:") { return }
        let env = SystemInfo.env()
        let decision = Engine.evaluate(mode: state.mode,
                                       startedAt: state.startedAt,
                                       guards: state.guards,
                                       env: env)
        switch decision {
        case .keepAwake:
            applyActive()
        case .release(let reason):
            if state.mode.isActive {
                state.lastReleaseReason = reason
                state.lastReleaseAt = env.now
                Log.info("会话结束（\(reason.rawValue)）trigger=\(trigger) 电源=\(env.onExternalPower ? "AC" : "电池") 电量=\(env.batteryPercent.map(String.init) ?? "-") 温度=\(env.thermal.rawValue)")
                state.mode = .off
                state.startedAt = nil
                state.origin = nil
            }
            applyInactive()
        }
        reconcileFan()
        persist()
        scheduleTimers()
        armIdleExit()
        pushStatus()
    }

    /// 风扇决策与施加。纯函数算目标，这里只负责写 SMC。
    private func reconcileFan() {
        guard fan.isAvailable else { return }
        var input = fanStep
        input.dwellSeconds = Date().timeIntervalSince(fanStepChangedAt)
        let result = FanEngine.decide(mode: state.fanMode,
                                      maxTempC: fan.readOnly.hottest()?.celsius,
                                      range: fan.readOnly.range(),
                                      policy: state.fanPolicy,
                                      state: input)
        if result.state.index != fanStep.index {
            fanStepChangedAt = Date()
            if state.fanMode == .curve {
                let pct = result.state.index >= 0
                    && result.state.index < state.fanPolicy.validated().steps.count
                    ? "\(state.fanPolicy.validated().steps[result.state.index].percent)%"
                    : "交还固件"
                Log.info("风扇档位 \(fanStep.index) → \(result.state.index)（\(pct)）"
                         + " 温度 \(fan.readOnly.hottest().map { String(format: "%.1f°C", $0.celsius) } ?? "?")")
            }
        }
        fanStep = result.state
        if !fan.apply(result.decision) {
            Log.error("风扇指令施加失败（\(state.fanMode.label)）")
        }
        switch result.decision {
        case .setTarget(let rpm): lastFanTarget = rpm
        case .releaseToFirmware: lastFanTarget = nil
        }
    }

    private func applyActive() {
        let ok = sleepCtl.set(true)
        var desired: Set<String> = [AssertionHolder.Kind.idleSystem, AssertionHolder.Kind.system]
        if state.guards.keepDisplayAwake { desired.insert(AssertionHolder.Kind.idleDisplay) }
        assertions.reconcile(to: desired)

        if ok {
            if degradedNote != nil {
                Log.info("SleepDisabled 已恢复正常（后端=\(sleepCtl.lastBackendUsed)）")
            }
            degradedNote = nil
        } else {
            let note = sleepCtl.lastError ?? "SleepDisabled 施加失败"
            if degradedNote != note { Log.error("降级为仅断言层：\(note)") }
            degradedNote = note
        }
    }

    private func applyInactive() {
        assertions.releaseAll()
        if sleepCtl.set(false) {
            degradedNote = nil
        } else {
            let note = "SleepDisabled 复位失败：\(sleepCtl.lastError ?? "未知")"
            if degradedNote != note { Log.error(note) }
            degradedNote = note
        }
    }

    private func persist() {
        do { try store.save(state) }
        catch { Log.error("状态写入失败: \(error)") }
    }

    // MARK: - 定时器

    private func scheduleTimers() {
        deadlineTimer?.cancel(); deadlineTimer = nil
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        // 风扇定时器独立于合盖会话：只开风扇不开合盖续跑也要能工作
        scheduleFanTimer()
        guard state.mode.isActive else { return }

        if let deadline = Engine.nextEvaluation(mode: state.mode,
                                               startedAt: state.startedAt,
                                               guards: state.guards) {
            let delay = max(0.05, deadline.timeIntervalSinceNow)
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + delay, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in self?.reconcile(trigger: "deadline") }
            t.resume()
            deadlineTimer = t
        }

        let hb = DispatchSource.makeTimerSource(queue: q)
        hb.schedule(deadline: .now() + heartbeatSeconds,
                    repeating: heartbeatSeconds,
                    leeway: .seconds(30))
        hb.setEventHandler { [weak self] in self?.reconcile(trigger: "heartbeat") }
        hb.resume()
        heartbeatTimer = hb
    }

    /// 曲线模式要跟温度走（5s）；固定模式只需偶尔复查，防止固件把 md 复位（20s）。
    private func scheduleFanTimer() {
        fanTimer?.cancel(); fanTimer = nil
        let interval = FanEngine.reevaluateInterval(mode: state.fanMode)
        guard interval > 0, fan.isAvailable else { return }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.reconcileFan() }
        t.resume()
        fanTimer = t
    }

    private func armIdleExit() {
        idleTimer?.cancel(); idleTimer = nil
        guard Engine.shouldIdleExit(mode: state.mode, connectedClients: clients.count,
                                    fanMode: state.fanMode) else { return }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + idleExitSeconds, leeway: .seconds(5))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if Engine.shouldIdleExit(mode: self.state.mode, connectedClients: self.clients.count,
                                     fanMode: self.state.fanMode) {
                self.gracefulIdleExit()
            }
        }
        t.resume()
        idleTimer = t
    }

    // MARK: - 状态

    private func makeStatus() -> StatusDTO {
        let env = SystemInfo.env()
        let deadline = Engine.effectiveDeadline(mode: state.mode,
                                               startedAt: state.startedAt,
                                               guards: state.guards)
        let sd = sleepCtl.read()
        let active = state.mode.isActive
        let mechanism: Mechanism = active ? (sd == true ? .full : .assertionsOnly) : .none
        return StatusDTO(version: LidAwakeInfo.version,
                         mode: state.mode,
                         active: active,
                         startedAt: state.startedAt,
                         origin: state.origin,
                         effectiveDeadline: deadline,
                         remainingSeconds: deadline.map { max(0, $0.timeIntervalSince(env.now)) },
                         mechanism: mechanism,
                         sleepDisabled: sd,
                         assertionsHeld: assertions.held,
                         guards: state.guards,
                         onExternalPower: env.onExternalPower,
                         batteryPercent: env.batteryPercent,
                         thermal: env.thermal,
                         clamshellClosed: SystemInfo.clamshellClosed(),
                         lastReleaseReason: state.lastReleaseReason,
                         lastReleaseAt: state.lastReleaseAt,
                         daemonPID: getpid(),
                         degradedNote: degradedNote,
                         fan: fan.isAvailable ? fanStatus() : FanStatus(
                            supported: false, note: "这台机器没有可控风扇"))
    }

    private func fanStatus() -> FanStatus {
        var s = fan.status(mode: state.fanMode, policy: state.fanPolicy)
        // 用刚决定的目标覆盖 SMC 回读（回读有滞后，刚设完会显示旧值）
        if state.fanMode.isManual { s.targetRPM = lastFanTarget ?? s.targetRPM }
        else { s.targetRPM = nil }
        return s
    }

    private func pushStatus() {
        guard !clients.isEmpty, let data = try? JSON.encode(makeStatus()) else { return }
        for c in clients {
            let proxy = c.remoteObjectProxyWithErrorHandler { _ in } as? ClientAPI
            proxy?.stateDidChange(data)
        }
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let uid = newConnection.effectiveUserIdentifier
        guard AuthPolicy.isAllowed(uid: uid) else {
            Log.warn("拒绝连接 pid=\(newConnection.processIdentifier) uid=\(uid)（非 root 且不在 admin 组）")
            return false
        }
        newConnection.exportedInterface = XPCInterfaces.daemon()
        newConnection.exportedObject = self
        newConnection.remoteObjectInterface = XPCInterfaces.client()
        newConnection.invalidationHandler = { [weak self] in
            self?.q.async { self?.removeClient(newConnection) }
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.q.async { self?.removeClient(newConnection) }
        }
        newConnection.resume()
        q.async { [weak self] in
            guard let self else { return }
            self.clients.append(newConnection)
            self.armIdleExit()
        }
        return true
    }

    private func removeClient(_ c: NSXPCConnection) {
        clients.removeAll { $0 === c }
        armIdleExit()
    }

    // MARK: - DaemonAPI

    func ping(reply: @escaping (String) -> Void) {
        reply("lidawaked \(LidAwakeInfo.version)")
    }

    func status(reply: @escaping (Data?, String?) -> Void) {
        q.async { [weak self] in
            guard let self else { reply(nil, "服务正在退出"); return }
            do { reply(try JSON.encode(self.makeStatus()), nil) }
            catch { reply(nil, "状态序列化失败: \(error)") }
        }
    }

    func apply(_ requestJSON: Data, reply: @escaping (Data?, String?) -> Void) {
        let request: ApplyRequest
        do {
            request = try JSON.decode(ApplyRequest.self, requestJSON).validated()
        } catch {
            reply(nil, (error as? LidAwakeError)?.errorDescription ?? "请求非法: \(error)")
            return
        }
        q.async { [weak self] in
            guard let self, !self.terminating else { reply(nil, "服务正在退出"); return }
            let wasActive = self.state.mode.isActive
            let now = Date()
            switch request {
            case .off:
                self.state.mode = .off
                self.state.startedAt = nil
                self.state.origin = nil
                if wasActive {
                    self.state.lastReleaseReason = .userOff
                    self.state.lastReleaseAt = now
                }
            case .indefinite(let origin):
                self.state.mode = .indefinite
                self.state.startedAt = now
                self.state.origin = origin
                self.state.lastReleaseReason = nil
                self.state.lastReleaseAt = nil
            case .until(let seconds, let origin):
                self.state.mode = .until(now.addingTimeInterval(seconds))
                self.state.startedAt = now
                self.state.origin = origin
                self.state.lastReleaseReason = nil
                self.state.lastReleaseAt = nil
            }
            Log.info("apply \(request.kindLabel) origin=\(request.origin)")
            self.reconcile(trigger: "apply")
            do { reply(try JSON.encode(self.makeStatus()), nil) }
            catch { reply(nil, "状态序列化失败: \(error)") }
        }
    }

    func setGuards(_ guardsJSON: Data, reply: @escaping (Data?, String?) -> Void) {
        let incoming: Guards
        do { incoming = try JSON.decode(Guards.self, guardsJSON).validated() }
        catch { reply(nil, "安全策略解析失败: \(error)"); return }

        q.async { [weak self] in
            guard let self, !self.terminating else { reply(nil, "服务正在退出"); return }
            self.state.guards = incoming
            Log.info("setGuards floor=\(incoming.batteryFloorPercent.map(String.init) ?? "off") ac=\(incoming.requireExternalPower) thermal=\(incoming.releaseOnCriticalThermal) max=\(incoming.maxSessionSeconds.map { Int($0) }.map(String.init) ?? "off") display=\(incoming.keepDisplayAwake) persist=\(incoming.persistAcrossReboot)")
            self.reconcile(trigger: "setGuards")
            do { reply(try JSON.encode(self.makeStatus()), nil) }
            catch { reply(nil, "状态序列化失败: \(error)") }
        }
    }
    func setFan(_ fanJSON: Data, reply: @escaping (Data?, String?) -> Void) {
        let request: FanRequest
        do { request = try JSON.decode(FanRequest.self, fanJSON).validated() }
        catch { reply(nil, "风扇请求解析失败: \(error)"); return }

        q.async { [weak self] in
            guard let self, !self.terminating else { reply(nil, "服务正在退出"); return }
            guard self.fan.isAvailable else {
                reply(nil, "这台机器没有可控风扇（或 SMC 不可用）"); return
            }
            if self.state.fanMode != request.mode {
                self.fanStep = .firmware          // 换模式就重新起算档位与停留时间
                self.fanStepChangedAt = Date()
            }
            self.state.fanMode = request.mode
            if let p = request.policy { self.state.fanPolicy = p }
            let vp = self.state.fanPolicy.validated()
            Log.info("setFan \(request.mode.label) 档位="
                     + vp.steps.map { "\(Int($0.upAtC))→\($0.percent)%" }.joined(separator: ",")
                     + " 迟滞=\(Int(vp.hysteresisC))°C 停留=\(Int(vp.minDwellSeconds))s"
                     + " 临界=\(Int(vp.criticalC))°C")
            self.reconcileFan()
            self.persist()
            self.scheduleFanTimer()
            self.armIdleExit()
            self.pushStatus()
            do { reply(try JSON.encode(self.makeStatus()), nil) }
            catch { reply(nil, "状态序列化失败: \(error)") }
        }
    }
}

private extension ApplyRequest {
    var kindLabel: String {
        switch self {
        case .off: return "off"
        case .indefinite: return "indefinite"
        case .until(let s, _): return "until(\(Int(s))s)"
        }
    }
}
