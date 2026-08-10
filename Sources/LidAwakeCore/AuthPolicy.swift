import Foundation

/// XPC 客户端鉴权。
///
/// 已知局限（docs/SPEC.md §7）：本机无 Developer ID，无法用 code requirement
/// 校验调用方签名，因此策略是"root 或 admin 组成员"。接口能力上限只有"阻止休眠"，
/// 而 admin 用户本来就能 `sudo pmset -a disablesleep 1`，故不构成提权。
public enum AuthPolicy {

    public static let adminGID: gid_t = 80

    /// 纯函数形式，便于单测。
    public static func isAllowed(uid: uid_t, groups: [gid_t]) -> Bool {
        if uid == 0 { return true }
        return groups.contains(adminGID)
    }

    /// 真机形式：查 uid 的补充组列表。
    public static func isAllowed(uid: uid_t) -> Bool {
        if uid == 0 { return true }
        return isAllowed(uid: uid, groups: groups(forUID: uid))
    }

    public static func userName(forUID uid: uid_t) -> String? {
        guard let pw = getpwuid(uid) else { return nil }
        return String(cString: pw.pointee.pw_name)
    }

    public static func groups(forUID uid: uid_t) -> [gid_t] {
        guard let pw = getpwuid(uid) else { return [] }
        let name = String(cString: pw.pointee.pw_name)
        let primary = pw.pointee.pw_gid

        var count: Int32 = 32
        var gids = [gid_t](repeating: 0, count: Int(count))
        var rc = name.withCString { cName in
            gids.withUnsafeMutableBufferPointer { buf -> Int32 in
                buf.baseAddress!.withMemoryRebound(to: Int32.self, capacity: Int(count)) { p in
                    getgrouplist(cName, Int32(bitPattern: primary), p, &count)
                }
            }
        }
        if rc == -1, count > 0, count < 4096 {
            gids = [gid_t](repeating: 0, count: Int(count))
            rc = name.withCString { cName in
                gids.withUnsafeMutableBufferPointer { buf -> Int32 in
                    buf.baseAddress!.withMemoryRebound(to: Int32.self, capacity: Int(count)) { p in
                        getgrouplist(cName, Int32(bitPattern: primary), p, &count)
                    }
                }
            }
        }
        guard rc != -1, count >= 0 else { return [primary] }
        return Array(gids.prefix(Int(count)))
    }
}
