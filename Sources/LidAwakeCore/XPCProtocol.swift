import Foundation

/// 守护进程导出的接口。
///
/// 安全设计要点：请求体只能表达 off / indefinite / until(seconds)，
/// **没有任何字段可以表达路径、命令或 shell 参数**。即使鉴权被绕过，
/// 攻击面上限也只是"让这台机器不睡觉"。
@objc public protocol DaemonAPI {
    func ping(reply: @escaping (String) -> Void)
    func status(reply: @escaping (Data?, String?) -> Void)
    func apply(_ requestJSON: Data, reply: @escaping (Data?, String?) -> Void)
    func setGuards(_ guardsJSON: Data, reply: @escaping (Data?, String?) -> Void)
}

/// 客户端导出的接口，供守护进程反向推送状态（避免轮询）。
@objc public protocol ClientAPI {
    func stateDidChange(_ statusJSON: Data)
}

public enum XPCInterfaces {
    public static func daemon() -> NSXPCInterface { NSXPCInterface(with: DaemonAPI.self) }
    public static func client() -> NSXPCInterface { NSXPCInterface(with: ClientAPI.self) }
}
