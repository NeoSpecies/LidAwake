import Foundation
import LidAwakeCore

/// 特权服务的安装 / 卸载。
///
/// 走 `osascript ... with administrator privileges` 弹**系统原生授权框**
/// （用户可用触控 ID）。密码由系统对话框收集，本进程完全接触不到。
/// 装完之后所有开关操作都通过 XPC，不会再要授权。
enum Installer {

    static func resourceScript(_ name: String) -> String? {
        Bundle.main.path(forResource: name, ofType: "sh")
    }

    static func toolPath(_ name: String) -> String {
        let installed = "/usr/local/bin/\(name)"
        if FileManager.default.isExecutableFile(atPath: installed) { return installed }
        if let bundled = Bundle.main.path(forResource: name, ofType: nil) { return bundled }
        return installed
    }

    struct Result {
        var ok: Bool
        var output: String
    }

    private static func runPrivileged(script: String) -> Result {
        // AppleScript 字符串里用单引号包裹 shell 路径，避免空格与引号问题
        let apple = "do shell script \"'\(script)' 2>&1\" with administrator privileges"
        let (rc, out) = Shell.run("/usr/bin/osascript", ["-e", apple], timeout: 180)
        if out.contains("User canceled") || out.contains("用户已取消") {
            return Result(ok: false, output: "已取消授权")
        }
        return Result(ok: rc == 0, output: out)
    }

    static func installService() -> Result {
        guard let script = resourceScript("install-helper") else {
            return Result(ok: false, output: "App 内缺少 install-helper.sh，请用 scripts/install.sh 安装")
        }
        return runPrivileged(script: script)
    }

    static func uninstallService() -> Result {
        guard let script = resourceScript("uninstall-helper") else {
            return Result(ok: false, output: "App 内缺少 uninstall-helper.sh")
        }
        return runPrivileged(script: script)
    }
}

/// 登录时启动：用 ~/Library/LaunchAgents 的 LaunchAgent，不需要任何授权。
/// （`SMAppService.mainApp` 在 ad-hoc 签名下不可靠，见 docs/SPEC.md §4）
enum LoginItem {
    static var plistPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/LaunchAgents/\(LidAwakeInfo.agentLabel).plist"
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    static func setEnabled(_ on: Bool) -> String? {
        let dir = (plistPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let domain = "gui/\(getuid())"
        if on {
            let exe = Bundle.main.executablePath ?? "/Applications/LidAwake.app/Contents/MacOS/LidAwake"
            let plist: [String: Any] = [
                "Label": LidAwakeInfo.agentLabel,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
            ]
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                             format: .xml, options: 0)
                try data.write(to: URL(fileURLWithPath: plistPath))
            } catch {
                return "写入登录项失败: \(error.localizedDescription)"
            }
            _ = Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(LidAwakeInfo.agentLabel)"])
            let (rc, out) = Shell.run("/bin/launchctl", ["bootstrap", domain, plistPath])
            return rc == 0 ? nil : "launchctl bootstrap 失败: \(out)"
        } else {
            _ = Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(LidAwakeInfo.agentLabel)"])
            try? FileManager.default.removeItem(atPath: plistPath)
            return nil
        }
    }
}
