import Foundation

/// XPC 客户端。App 与 CLI 共用。
/// 状态由守护进程**推送**（`onStateChange`），客户端不轮询 —— 这是能耗预算的关键。
public final class DaemonClient: NSObject, ClientAPI {

    public var onStateChange: ((StatusDTO) -> Void)?
    public var onDisconnect: ((String) -> Void)?

    private var connection: NSXPCConnection?
    private let lock = NSLock()

    public override init() { super.init() }

    public static var isDaemonInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\(LidAwakeInfo.daemonLabel).plist")
            && FileManager.default.fileExists(atPath: LidAwakeInfo.daemonPath)
    }

    @discardableResult
    private func ensureConnection() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: LidAwakeInfo.machServiceName, options: .privileged)
        c.remoteObjectInterface = XPCInterfaces.daemon()
        c.exportedInterface = XPCInterfaces.client()
        c.exportedObject = self
        c.invalidationHandler = { [weak self] in
            self?.drop(reason: "连接已失效（服务可能未安装）")
        }
        c.interruptionHandler = { [weak self] in
            self?.drop(reason: "连接被中断（服务重启中）")
        }
        c.resume()
        connection = c
        return c
    }

    private func drop(reason: String) {
        lock.lock()
        connection = nil
        lock.unlock()
        onDisconnect?(reason)
    }

    public func invalidate() {
        lock.lock()
        let c = connection
        connection = nil
        lock.unlock()
        c?.invalidate()
    }

    // MARK: ClientAPI（守护进程推送）

    public func stateDidChange(_ statusJSON: Data) {
        guard let s = try? JSON.decode(StatusDTO.self, statusJSON) else { return }
        onStateChange?(s)
    }

    // MARK: 异步调用

    private func proxy(_ onError: @escaping (Error) -> Void) -> DaemonAPI? {
        let c = ensureConnection()
        return c.remoteObjectProxyWithErrorHandler { err in onError(err) } as? DaemonAPI
    }

    public func statusAsync(_ completion: @escaping (Result<StatusDTO, Error>) -> Void) {
        guard let p = proxy({ completion(.failure($0)) }) else {
            completion(.failure(LidAwakeError.daemonUnavailable("无法建立代理"))); return
        }
        p.status { data, err in completion(Self.decode(data, err)) }
    }

    public func applyAsync(_ request: ApplyRequest,
                           _ completion: @escaping (Result<StatusDTO, Error>) -> Void) {
        do {
            let payload = try JSON.encode(request)
            guard let p = proxy({ completion(.failure($0)) }) else {
                completion(.failure(LidAwakeError.daemonUnavailable("无法建立代理"))); return
            }
            p.apply(payload) { data, err in completion(Self.decode(data, err)) }
        } catch {
            completion(.failure(error))
        }
    }

    public func setGuardsAsync(_ guards: Guards,
                               _ completion: @escaping (Result<StatusDTO, Error>) -> Void) {
        do {
            let payload = try JSON.encode(guards)
            guard let p = proxy({ completion(.failure($0)) }) else {
                completion(.failure(LidAwakeError.daemonUnavailable("无法建立代理"))); return
            }
            p.setGuards(payload) { data, err in completion(Self.decode(data, err)) }
        } catch {
            completion(.failure(error))
        }
    }

    private static func decode(_ data: Data?, _ err: String?) -> Result<StatusDTO, Error> {
        if let err { return .failure(LidAwakeError.applyFailed(err)) }
        guard let data else { return .failure(LidAwakeError.decoding("空响应")) }
        do { return .success(try JSON.decode(StatusDTO.self, data)) }
        catch { return .failure(LidAwakeError.decoding("\(error)")) }
    }

    // MARK: 同步调用（CLI 用；不要在 App 主线程用）

    private func sync(timeout: Double,
                      _ body: (@escaping (Result<StatusDTO, Error>) -> Void) -> Void) throws -> StatusDTO {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<StatusDTO, Error>?
        body { r in
            if result == nil { result = r }
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { throw LidAwakeError.timeout }
        switch result {
        case .success(let s): return s
        case .failure(let e): throw e
        case nil: throw LidAwakeError.timeout
        }
    }

    public func status(timeout: Double = 8) throws -> StatusDTO {
        try sync(timeout: timeout) { statusAsync($0) }
    }

    public func apply(_ r: ApplyRequest, timeout: Double = 8) throws -> StatusDTO {
        try sync(timeout: timeout) { applyAsync(r, $0) }
    }

    public func setGuards(_ g: Guards, timeout: Double = 8) throws -> StatusDTO {
        try sync(timeout: timeout) { setGuardsAsync(g, $0) }
    }
}
