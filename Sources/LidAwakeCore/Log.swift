import Foundation

/// 极简日志：只记状态转换与错误，不记周期性心跳（避免无意义写盘）。
public final class Log {
    public enum Level: String { case info = "INFO", warn = "WARN", error = "ERROR" }

    public static let shared = Log()

    private var path: String?
    private let lock = NSLock()
    private let maxBytes = 2 * 1024 * 1024
    private let keepBytes = 512 * 1024

    public func configure(path: String?) {
        lock.lock(); defer { lock.unlock() }
        self.path = path
        guard let path else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil,
                                          attributes: [.posixPermissions: 0o644])
        }
    }

    public func write(_ level: Level, _ message: String) {
        let line = "\(Format.timestamp()) [\(level.rawValue)] \(message)\n"

        lock.lock(); defer { lock.unlock() }
        // 有日志文件时不再往 stderr 重复写一份：launchd 会把 stderr 收进
        // lidawaked.err.log，两边都写等于同一条日志存两遍。
        guard let path, let data = line.data(using: .utf8) else {
            FileHandle.standardError.write(Data(line.utf8))
            return
        }
        guard let fh = FileHandle(forWritingAtPath: path) else {
            FileHandle.standardError.write(data)   // 写不进文件时至少别丢日志
            return
        }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
        rotateIfNeededLocked(path: path)
    }

    private func rotateIfNeededLocked(path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(size - keepBytes))
        let tail = (try? fh.readToEnd()) ?? Data()
        try? tail.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func info(_ m: String) { shared.write(.info, m) }
    public static func warn(_ m: String) { shared.write(.warn, m) }
    public static func error(_ m: String) { shared.write(.error, m) }
}
