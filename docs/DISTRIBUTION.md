# 分发与上架

## 先说结论：LidAwake 现在这个形态**上不了 Mac App Store**

不是"还没做"，是架构上被规则排除。四条各自独立、任何一条都足以被拒：

| 障碍 | 具体规则 / 事实 |
|---|---|
| 1. App Sandbox 是 MAS 的强制要求 | 沙盒进程无法安装、也无法连接系统域（system domain）的特权 LaunchDaemon。我们的整套机制建立在 `NSXPCConnection(machServiceName:, options: .privileged)` 上 |
| 2. `SleepDisabled` 需要 root | `IOPMSetSystemPowerSetting` 非 root 调用返回 `kIOReturnNotPrivileged`（本机已实测）。MAS 应用不允许要求管理员权限 |
| 3. 用到了私有符号 | `IOPMSetSystemPowerSetting` / `IOPMCopySystemPowerSettings` **不在公开头文件里**（只导出了符号）。App Review 明确禁止私有 API |
| 4. 往系统目录写文件 | `/Library/LaunchDaemons`、`/Library/PrivilegedHelperTools`、`/usr/local/bin` 全部超出沙盒容器 |

这也正好解释了 Amphetamine 为什么能上架：**它只用断言层**，所以它的官方文档必须写"需要接电源 / 外接显示器 / 外接键鼠之一"。上架的代价就是失去纯电池合盖能力。

所以真实可选的路是下面三条。

---

## 路线 A：Developer ID + 公证（推荐，保留全部能力）

这是所有需要特权组件的 Mac 工具的标准路线（Homebrew、Docker Desktop、Little Snitch 都走这条）。

### 需要准备

| 项 | 说明 | 成本 |
|---|---|---|
| Apple Developer Program 会员 | 个人或公司均可；公司需要 D-U-N-S 编号 | **$99 / 年** |
| `Developer ID Application` 证书 | 签 `.app` 和里面所有可执行文件 | 含在会员内 |
| `Developer ID Installer` 证书 | 签 `.pkg` 安装包 | 含在会员内 |
| App 专用密码（app-specific password） | 给 `notarytool` 提交公证用 | 免费 |
| 图标 `.icns` | 16/32/128/256/512 @1x@2x 全套 | — |

**好消息**：公证工具链在本机已经具备，不需要装完整 Xcode ——
`notarytool 1.1.2` 和 `stapler` 都在 `/Library/Developer/CommandLineTools/usr/bin/`。
拿到证书后现有 `scripts/make-pkg.sh` 会**自动**检测并签名（脚本里已经写好了这段判断）。

### 流程

```bash
# 1. 签 app 内所有可执行文件 + app 本身（启用 Hardened Runtime）
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: <你的名字> (<TEAMID>)" \
  build/LidAwake.app/Contents/Resources/lidawaked \
  build/LidAwake.app/Contents/Resources/lidawake \
  build/LidAwake.app/Contents/Resources/lidawake-probe
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: <你的名字> (<TEAMID>)" build/LidAwake.app

# 2. 打包并签安装包
./scripts/make-pkg.sh          # 会自动用 Developer ID Installer 证书 productsign

# 3. 公证 + 装订票据
xcrun notarytool submit build/LidAwake-1.0.0.pkg \
  --apple-id <你的 Apple ID> --team-id <TEAMID> \
  --password <app-specific-password> --wait
xcrun stapler staple build/LidAwake-1.0.0.pkg
spctl -a -vvv -t install build/LidAwake-1.0.0.pkg   # 应输出 accepted / Notarized Developer ID
```

### 有了真签名之后**应该顺手做的两个架构升级**

这两点现在做不了，纯粹是因为本机 0 个签名身份（见 `docs/SPEC.md` §1）：

1. **改用 `SMAppService.daemon`**（macOS 13+）替代手写 LaunchDaemon。
   好处：安装不再需要 `osascript` 提权，用户在「系统设置 → 通用 → 登录项」里授权，可随时开关；
   卸载也由系统托管。当前实现之所以走经典 `/Library/LaunchDaemons`，就是因为 `SMAppService.daemon`
   要求 app 有有效签名，ad-hoc 签名下不可靠。

2. **补上 XPC 客户端签名校验**，关掉 `docs/SPEC.md` §7 记录的那个已知局限。
   代码里 `AuthPolicy` 已经留好扩展点，加上：

   ```swift
   // 在 listener(_:shouldAcceptNewConnection:) 里
   var code: SecCode?
   SecCodeCopyGuestWithAttributes(
       nil,
       [kSecGuestAttributeAudit: newConnection.auditToken] as CFDictionary,
       [], &code)
   var req: SecRequirement?
   SecRequirementCreateWithString(
       "anchor apple generic and certificate leaf[subject.OU] = \"<TEAMID>\"" as CFString,
       [], &req)
   guard let code, let req,
         SecCodeCheckValidity(code, [], req) == errSecSuccess else { return false }
   ```

   加上这个之后，就从"任何 admin 进程都能调用"收紧到"只有我签名的进程能调用"。
   （需要把 `NSXPCConnection.auditToken` 通过一个小的 ObjC 桥暴露出来，它是私有属性；
   或者用 `xpc_connection_get_audit_token` 走 C API。）

### 分发渠道

- GitHub Releases 挂签名+公证过的 `.pkg`
- Homebrew Cask：`brew install --cask lidawake`（公证过的包提交 cask 很顺）
- 自动更新：接 [Sparkle](https://sparkle-project.org/)（MAS 之外的事实标准）

---

## 路线 B：真要上 App Store —— 只能做「精简版」

技术上唯一可行的 MAS 形态：**砍掉守护进程，只保留断言层**。

- 能力退化到和 Amphetamine 一样：**需要接电源 / 外接显示器 / 外接键鼠之一**，纯电池合盖照样睡
- 代码上是现成的：`Sources/LidAwakeUI/LimitedController.swift` 就是这个形态（受限模式），
  它现在已经在守护进程缺失时作为降级路径在跑
- 要额外准备的东西：
  - App Sandbox entitlement（`com.apple.security.app-sandbox`）
  - 删掉所有 `dlsym` 私有符号调用、删掉 `Shell.run` 对 `pmset`/`launchctl` 的调用（沙盒内不允许）
  - 删掉 CLI 工具（MAS 不允许往 `/usr/local/bin` 装东西）
  - App Store Connect 记录：应用名（需查重）、副标题、关键词、描述、
    **1280×800 或 2560×1600 截图至少 1 张**、分级问卷、
    **隐私政策 URL**（即使一条数据都不收集也必须提供）、支持 URL
  - `Info.plist` 补 `LSApplicationCategoryType = public.app-category.utilities`
  - 图标全套 `.icns`
  - 本地化：至少 en + zh-Hans
  - 首次上架审核周期一般 1–3 天，被拒后迭代

**我的建议：不要为了上架砍掉核心能力。** LidAwake 唯一比现成方案强的地方就是"纯电池也能合盖续跑"，
砍掉之后它就只是又一个 Amphetamine 而已。要上架的话，把它作为独立的 "LidAwake Lite" 发布，
并在 App 里明确说明能力边界和完整版在哪。

---

## 路线 C：现状（GitHub Releases 的未签名 `.pkg`）

现在 `scripts/make-pkg.sh` 产出的就是这个。功能完整，代价是 Gatekeeper 摩擦：

```bash
# 方式一：命令行安装（推荐，不受 Gatekeeper 拦截）
sudo installer -pkg LidAwake-1.0.0.pkg -target /

# 方式二：图形界面
# 右键点 .pkg →「打开」→ 在弹窗里再点「打开」
# 或先去掉隔离属性：
xattr -d com.apple.quarantine LidAwake-1.0.0.pkg
```

适合：自己用、团队内部用、开源用户自行构建。

---

## 三条路线对比

| | 路线 A（Developer ID） | 路线 B（App Store Lite） | 路线 C（现状） |
|---|---|---|---|
| 纯电池合盖续跑 | ✅ | ❌ | ✅ |
| 年费 | $99 | $99 | 0 |
| 用户安装摩擦 | 无 | 无 | 需右键打开或用命令行 |
| 审核 | 无（只需公证，自动化，几分钟） | 有（人工，1–3 天，可能被拒） | 无 |
| 自动更新 | Sparkle | 系统托管 | 手动 |
| 可收费 | 需自建支付 | App Store 内购/付费下载 | — |

**推荐顺序：C（现在）→ A（要给别人用就上这条）→ B（只有在明确想吃 App Store 流量时才考虑，且必须接受能力阉割）**
