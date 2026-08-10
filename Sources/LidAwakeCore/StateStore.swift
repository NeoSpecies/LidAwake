import Foundation

/// 状态持久化。原子写（临时文件 + rename），0600 root:wheel。
/// 损坏的文件不会让守护进程崩溃：改名留证，回落到默认 off 状态。
public final class StateStore {
    public let path: String
    private let fm = FileManager.default

    public init(path: String = LidAwakeInfo.statePath) {
        self.path = path
    }

    public func load() -> (state: PersistedState, wasCorrupt: Bool) {
        guard let data = fm.contents(atPath: path), !data.isEmpty else {
            return (PersistedState(), false)
        }
        do {
            return (try JSON.decode(PersistedState.self, data), false)
        } catch {
            quarantine()
            return (PersistedState(), true)
        }
    }

    public func save(_ state: PersistedState) throws {
        let dir = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        let data = try JSON.encode(state, pretty: true)
        let tmp = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
        _ = try? fm.replaceItemAt(URL(fileURLWithPath: path),
                                  withItemAt: URL(fileURLWithPath: tmp))
        if fm.fileExists(atPath: tmp) {           // replaceItemAt 失败时的兜底
            try? fm.removeItem(atPath: path)
            try fm.moveItem(atPath: tmp, toPath: path)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    private func quarantine() {
        var n = 1
        var target = path + ".corrupt"
        while fm.fileExists(atPath: target) && n < 100 {
            target = path + ".corrupt-\(n)"
            n += 1
        }
        try? fm.moveItem(atPath: path, toPath: target)
        Log.warn("state.json 解析失败，已隔离为 \(target)")
    }
}
