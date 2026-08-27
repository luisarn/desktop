import Foundation
import os.log

private let log = Logger(subsystem: "lab.jawa.ahakeyconfig", category: "AgentManager")

// MARK: - 蓝牙占用方（AhaKey Studio 与 Agent 是两套独立进程，同一时刻只应有一个 GATT 连接键盘）

/// 由谁持有与键盘的 BLE 连接。
/// - `ahaKeyStudio`：主 App 连接，用于改键、LCD、本机 LED 测试等。
/// - `agentDaemon`：仅运行 `ahakeyconfig-agent`（Hook → Unix socket → 写 0x90 状态、读拨杆），由 LaunchAgent 拉起。
enum BluetoothConnectionOwner: String, CaseIterable, Identifiable {
    case ahaKeyStudio
    case agentDaemon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ahaKeyStudio: return "AhaKey Studio"
        case .agentDaemon: return "ahakeyconfig-agent"
        }
    }

    var shortDetail: String {
        switch self {
        case .ahaKeyStudio: return "This app connects to the keyboard over Bluetooth for configuration and sync. The Agent's LaunchJob is not loaded while the app is the owner, to avoid connection conflicts."
        case .agentDaemon: return "Only the Agent connects over Bluetooth. Claude/Cursor/Codex/Kimi Code CLI hooks can then drive the light bar and dial queries; this app cannot send BLE commands to the keyboard in this mode."
        }
    }
}

/// 管理 ahakeyconfig-agent 守护进程的安装、启停、状态查询
@MainActor
final class AgentManager: ObservableObject {
    static let shared = AgentManager()

    private static let bluetoothOwnerKey = "lab.jawa.ahakeyconfig.bluetoothConnectionOwner"
    private static var didApplyLaunchBluetoothPreference = false

    @Published private(set) var isInstalled = false
    @Published private(set) var isRunning = false
    @Published private(set) var isAgentBLEConnected = false   // agent 的 BLE 是否真正连上键盘
    @Published private(set) var hooksInstalled = false        // Claude / Cursor / Codex / Kimi hooks 是否装了任何一个
    @Published private(set) var claudeHooksInstalled = false
    @Published private(set) var cursorHooksInstalled = false
    @Published private(set) var codexHooksInstalled = false
    @Published private(set) var kimiHooksInstalled = false

    /// 用户选择的蓝牙占用方（存 UserDefaults，启动时应用一次）
    @Published var bluetoothConnectionOwner: BluetoothConnectionOwner = .agentDaemon

    /// 安装 / 启停 Agent、写 Hooks 等操作的结果说明；关闭弹窗后由 UI 置 `nil`。
    @Published var agentUserAlert: String?

    /// 正在执行安装或 launchctl 启停，用于界面显示进度，避免「点了没反应」。
    @Published private(set) var isAgentOperationInProgress = false

    private let label = "lab.jawa.ahakeyconfig.agent"
    private let socketPath = "/tmp/ahakey.sock"

    private var launchAgentsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private var plistPath: String {
        launchAgentsDirectoryURL.appendingPathComponent("\(label).plist").path
    }

    /// `~/Library/LaunchAgents` 在全新系统用户下可能尚不存在，必须先创建再写 plist，否则会报「folder doesn't exist」类错误。
    private func ensureLaunchAgentsDirectory() throws {
        try FileManager.default.createDirectory(at: launchAgentsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    }

    private var agentBinaryPath: String {
        // 发版优先使用 app bundle 内部的 agent。`swift run AhaKeyConfig` 是裸可执行文件，
        // 开发时回退到同一 SwiftPM build 目录里的 sibling agent，便于从源码安装 LaunchAgent。
        let bundled = "\(Bundle.main.bundlePath)/Contents/MacOS/ahakeyconfig-agent"
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        if Bundle.main.bundleURL.pathExtension != "app",
           let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            let development = executableDirectory.appendingPathComponent("ahakeyconfig-agent").path
            if FileManager.default.isExecutableFile(atPath: development) {
                return development
            }
        }
        return bundled
    }

    /// 供界面判断：包内是否带有 agent 可执行文件（发版缺拷贝时 LaunchAgent 无法真正运行）。
    var isAgentBinaryPresentInBundle: Bool {
        FileManager.default.isExecutableFile(atPath: agentBinaryPath)
    }

    /// 兼容性：老版本通过 shell 脚本转发；现在直接调用 agent 二进制。保留路径用于卸载时清理。
    private var legacyHookScriptPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/hooks/ahakey-state.sh").path
    }

    private var claudeSettingsPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/settings.json").path
    }

    private var cursorHooksPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".cursor/hooks.json").path
    }

    private var codexConfigPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml").path
    }

    private var codexAppCliPath: String {
        "/Applications/Codex.app/Contents/Resources/codex"
    }

    private var kimiConfigPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi/config.toml").path
    }

    private var kimiCliFallbackRoot: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/uv/tools/kimi-cli").path
    }

    private var localBinDirectoryPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true).path
    }

    private var localCodexCliPath: String {
        (localBinDirectoryPath as NSString).appendingPathComponent("codex")
    }

    private var zshrcPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zshrc").path
    }

    /// `~/.cursor/cli-config.json`：Cursor **CLI** 的 `permissions`（`Shell(...)` 等）与 `approvalMode`。
    private var cursorCliConfigPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/cli-config.json").path
    }

    /// `~/.cursor/permissions.json`：IDE 内 **Agent 终端 TUI** 的 `terminalAllowlist`（与 cli-config 独立，见官方文档）。
    private var cursorPermissionsJsonPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/permissions.json").path
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.bluetoothOwnerKey),
           let stored = BluetoothConnectionOwner(rawValue: raw) {
            bluetoothConnectionOwner = stored
        } else {
            bluetoothConnectionOwner = .agentDaemon
            UserDefaults.standard.set(BluetoothConnectionOwner.agentDaemon.rawValue, forKey: Self.bluetoothOwnerKey)
        }
        refresh()
    }

    // MARK: - 状态刷新

    func refresh() {
        isInstalled = FileManager.default.fileExists(atPath: plistPath)
        isRunning = checkRunning()
        claudeHooksInstalled = detectClaudeHooksInstalled()
        cursorHooksInstalled = detectCursorHooksInstalled()
        codexHooksInstalled = detectCodexHooksInstalled()
        kimiHooksInstalled = detectKimiHooksInstalled()
        hooksInstalled = claudeHooksInstalled || cursorHooksInstalled || codexHooksInstalled || kimiHooksInstalled
        if isRunning {
            let socketPath = socketPath
            DispatchQueue.global(qos: .utility).async { [weak self, socketPath] in
                let bleConnected = Self.querySocketBLEConnected(socketPath: socketPath)
                DispatchQueue.main.async { self?.isAgentBLEConnected = bleConnected }
            }
        } else {
            isAgentBLEConnected = false
        }
    }

    /// 通知 agent 设置/清除虚拟拨杆覆盖。fire-and-forget；agent 会:
    /// 1) 落进 UserDefaults 持久化
    /// 2) 写入共享文件让主 App 立即看到
    /// 3) 不再发送旧 0x91；最新固件 0x91 用于灯效预览
    /// value=nil 表示清除覆盖（回到读真实 GPIO 值）。
    func sendSwitchOverride(_ value: UInt8?) {
        DispatchQueue.global(qos: .userInitiated).async { [socketPath] in
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            socketPath.withCString { src in
                withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                    _ = strcpy(UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self), src)
                }
            }
            let ok = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard ok == 0 else { return }
            let valuePart: String = value.map { "\($0)" } ?? "null"
            let payload = "{\"cmd\":\"set_switch_override\",\"value\":\(valuePart)}\n"
            guard let data = payload.data(using: .utf8) else { return }
            _ = data.withUnsafeBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return write(fd, base, ptr.count)
            }
            var buf = [UInt8](repeating: 0, count: 256)
            _ = read(fd, &buf, buf.count) // 等回包再关 fd，避免 agent 还没处理就被 reset
        }
    }

    /// 向 agent socket 发 status 命令，switchState 非 null 即代表 BLE 已连上键盘。
    /// 同步执行，需在后台线程调用。
    nonisolated private static func querySocketBLEConnected(socketPath: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                _ = strcpy(UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self), src)
            }
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { return false }

        guard let payload = "{\"cmd\":\"status\"}\n".data(using: .utf8) else { return false }
        let wrote = payload.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return write(fd, base, ptr.count)
        }
        guard wrote > 0 else { return false }

        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return false }

        guard let json = try? JSONSerialization.jsonObject(with: Data(buf[0..<n])) as? [String: Any] else {
            return false
        }
        return !(json["switchState"] is NSNull) && json["switchState"] != nil
    }

    // MARK: - 蓝牙占用方（App ↔ Agent 二选一）

    /// 启动主窗口时调用一次：按用户上次选择，要么由 App 连键盘，要么交给 Agent（不自动连 App）。
    func applyStoredBluetoothPreferenceOnLaunch(bleManager: AhaKeyBLEManager) {
        guard !Self.didApplyLaunchBluetoothPreference else { return }
        Self.didApplyLaunchBluetoothPreference = true
        applyBluetoothOwner(bluetoothConnectionOwner, bleManager: bleManager, isLaunch: true)
    }

    /// 用户在「设备信息」里切换占用方时调用。
    func setBluetoothConnectionOwner(_ owner: BluetoothConnectionOwner, bleManager: AhaKeyBLEManager) {
        guard owner != bluetoothConnectionOwner else { return }
        bluetoothConnectionOwner = owner
        UserDefaults.standard.set(owner.rawValue, forKey: Self.bluetoothOwnerKey)
        applyBluetoothOwner(owner, bleManager: bleManager, isLaunch: false)
    }

    private func applyBluetoothOwner(_ owner: BluetoothConnectionOwner, bleManager: AhaKeyBLEManager, isLaunch: Bool) {
        switch owner {
        case .ahaKeyStudio:
            bleManager.setSuppressedForAgentOwningKeyboard(false)
            unloadAgentLaunchJobRemovingSocket()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(isLaunch ? 700 : 600) * 1_000_000)
                guard !bleManager.isConnected, !bleManager.isScanning else { return }
                bleManager.connectAutomatically()
            }
        case .agentDaemon:
            bleManager.setSuppressedForAgentOwningKeyboard(true)
            bleManager.disconnect()
            guard isInstalled else {
                log.info("未安装 LaunchAgent，无法将蓝牙交给 Agent，临时允许 App 连接")
                bleManager.setSuppressedForAgentOwningKeyboard(false)
                if !isLaunch {
                    agentUserAlert = "The Agent is not installed, so you can't switch back to \"Keyboard Control\". Install and enable the Agent first in \"More → Device Info · Agent\"."
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(500) * 1_000_000)
                    if !bleManager.isConnected, !bleManager.isScanning {
                        bleManager.connectAutomatically()
                    }
                }
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(isLaunch ? 500 : 550) * 1_000_000)
                _ = runLaunchctlQuiet(["load", plistPath])
                _ = runLaunchctlQuiet(["start", label])
                self.refresh()

                // plist 存在 ≠ agent 真能跑：路径失效 / 崩溃时 launchctl start 不会报错，但 socket
                // 永远不出现，键盘会卡在「Agent 占用中」无人连接。等 socket 出现，超时仍无则回退
                // App 直连，保证键盘可用（修：残留/失效 LaunchAgent plist 导致开机卡住）。
                var agentUp = false
                let socketPath = self.socketPath
                for _ in 0..<10 {   // 最多约 2.5s
                    try? await Task.sleep(nanoseconds: 250 * 1_000_000)
                    if Self.agentSocketAlive(socketPath: socketPath) { agentUp = true; break }
                }
                if !agentUp {
                    log.info("Agent 已安装但未能启动（socket 未出现），临时回退由 App 直连键盘")
                    bleManager.setSuppressedForAgentOwningKeyboard(false)
                    if !isLaunch {
                        self.agentUserAlert = "The Agent is installed but failed to start, so the app is temporarily connecting to the keyboard directly. Check or reinstall the Agent in \"More → Device Info · Agent\"."
                    }
                    if !bleManager.isConnected, !bleManager.isScanning {
                        bleManager.connectAutomatically()
                    }
                    self.refresh()
                }
            }
        }
        if !isLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                self?.refresh()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.refresh()
            }
        }
    }

    /// 从 launchd 卸载 Agent（比 `stop` 更彻底：`KeepAlive` 下 stop 会立刻重启进程，仍占着蓝牙）。
    private func unloadAgentLaunchJobRemovingSocket() {
        guard FileManager.default.fileExists(atPath: plistPath) else {
            removeStaleSocketIfNeeded()
            return
        }
        _ = runLaunchctlQuiet(["unload", plistPath])
        removeStaleSocketIfNeeded()
    }

    private func removeStaleSocketIfNeeded() {
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    private func detectClaudeHooksInstalled() -> Bool {
        guard let settings = loadClaudeSettings(),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            guard let eventHooks = value as? [[String: Any]] else { continue }
            for entry in eventHooks {
                let cmds = entry["hooks"] as? [[String: Any]] ?? []
                if cmds.contains(where: { isAhakeyHookCommand(($0["command"] as? String) ?? "") }) {
                    return true
                }
            }
        }
        return false
    }

    private func detectCursorHooksInstalled() -> Bool {
        guard let settings = loadCursorSettings(),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            if entries.contains(where: { isAhakeyHookCommand(($0["command"] as? String) ?? "") }) {
                return true
            }
        }
        return false
    }

    private func detectCodexHooksInstalled() -> Bool {
        guard let text = try? String(contentsOfFile: codexConfigPath, encoding: .utf8) else {
            return false
        }
        // AhaKey 写入的 BEGIN/END 块即可判定（不依赖文件中是否仍能匹配到 ahakeyconfig-agent 字面量，避免因路径别名/重装 App 路径变化导致误判未装）
        if text.contains(codexHookBlockStart), text.contains(codexHookBlockEnd) {
            return true
        }
        return isAhakeyHookCommand(text)
            && (text.contains("hook Codex") || text.contains("CodexPermissionRequest"))
    }

    private func detectKimiHooksInstalled() -> Bool {
        guard let text = try? String(contentsOfFile: kimiConfigPath, encoding: .utf8) else {
            return false
        }
        return text.contains(kimiHookBlockStart)
            && text.contains(kimiHookBlockEnd)
            && isAhakeyHookCommand(text)
    }

    private func isAhakeyHookCommand(_ command: String) -> Bool {
        command.contains("ahakeyconfig-agent") || command.contains("ahakey-state")
    }

    /// 真去 connect 一下 agent socket，区分「活着的 agent」和「残留死 socket」。
    /// `checkRunning()` 只看 socket 文件是否存在，会被进程已死但 socket 残留的情况误判。
    nonisolated static func agentSocketAlive(socketPath: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                _ = strcpy(UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self), src)
            }
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return ok == 0
    }

    private func checkRunning() -> Bool {
        // 检查 socket 是否存在（agent 运行时会创建）
        var statBuf = stat()
        return stat(socketPath, &statBuf) == 0 && (statBuf.st_mode & S_IFSOCK) != 0
    }

    // MARK: - 安装/卸载 LaunchAgent

    private func launchAgentPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(agentBinaryPath)</string>
                <string>--socket</string>
                <string>\(socketPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logFilePath)</string>
            <key>StandardErrorPath</key>
            <string>\(logFilePath)</string>
        </dict>
        </plist>
        """
    }

    @discardableResult
    private func writeLaunchAgentPlist() -> Bool {
        do {
            try ensureLaunchAgentsDirectory()
            try launchAgentPlist().write(toFile: plistPath, atomically: true, encoding: .utf8)
            log.info("LaunchAgent 已安装: \(self.plistPath)")
            return true
        } catch {
            log.error("LaunchAgent 安装失败: \(error)")
            agentUserAlert = "Could not write the LaunchAgent configuration file: \(error.localizedDescription)\n\nTarget: \(plistPath)\nAttempted to create directory: \(launchAgentsDirectoryURL.path)\nIf it still fails, check write permission for \"~/Library\", or whether a device management policy prohibits user LaunchAgents."
            return false
        }
    }

    private func installedAgentBinaryPath() -> String? {
        guard let plist = NSDictionary(contentsOfFile: plistPath),
              let args = plist["ProgramArguments"] as? [String],
              let first = args.first else { return nil }
        return first
    }

    private func launchAgentNeedsRewrite() -> Bool {
        installedAgentBinaryPath() != agentBinaryPath
    }

    func install() {
        agentUserAlert = nil
        isAgentOperationInProgress = true
        defer { isAgentOperationInProgress = false }

        guard isAgentBinaryPresentInBundle else {
            agentUserAlert = "No executable ahakeyconfig-agent found in the app bundle (path: …/Contents/MacOS/ahakeyconfig-agent). Make sure the release script includes this binary in the .app; the daemon cannot be installed with the main app alone."
            return
        }

        // 1. 先卸载旧 job，再写入 plist。否则同 Label 已加载时 launchd 可能继续持有旧 ProgramArguments。
        unloadAgentLaunchJobRemovingSocket()
        guard writeLaunchAgentPlist() else { return }

        // 2. 仅当用户希望 Agent 持有蓝牙时才 load（否则只写入 plist，避免装完立刻抢 GATT）
        var loadFailed = false
        if bluetoothConnectionOwner == .agentDaemon {
            let load = runLaunchctlDetailed(["load", plistPath])
            if !load.ok && !isBenignLaunchctlLoadMessage(load.mergedOutput) {
                loadFailed = true
                log.error("launchctl load failed: \(load.mergedOutput)")
                let out = load.mergedOutput.isEmpty ? "(no output, non-zero exit)" : load.mergedOutput
                agentUserAlert = "The LaunchAgent plist was saved, but launchctl load failed; the daemon was not loaded.\n\nlaunchctl output:\n\(out)\n\nCommon causes: the same label already exists, the plist is invalid, or ~/Library/LaunchAgents is not writable. Try clicking \"Uninstall\" and installing again, or search for \(label) in Console."
            }
        }

        // 3. 安装 Claude / Cursor / Codex / Kimi hooks（直接指向 agent 二进制 hook 子命令）
        let claudeLine = installClaudeHooks()
        let cursorLine = installCursorHooks()
        let codexLine = installCodexHooks()
        let kimiLine = installKimiHooks()

        refresh()

        var lines: [String] = []
        if bluetoothConnectionOwner == .agentDaemon, !loadFailed {
            lines.append("launchctl load was executed. If \"Running\" doesn't appear after a few seconds, click \"View Log\".")
        }
        if !claudeLine.isEmpty { lines.append(claudeLine) }
        if !cursorLine.isEmpty { lines.append(cursorLine) }
        if !codexLine.isEmpty { lines.append(codexLine) }
        if !kimiLine.isEmpty { lines.append(kimiLine) }
        let tail = lines.joined(separator: "\n\n")
        if let err = agentUserAlert {
            agentUserAlert = err + (tail.isEmpty ? "" : "\n\n——\n\n" + tail)
        } else {
            agentUserAlert = tail.isEmpty ? "Installation complete." : tail
        }
    }

    func uninstall(bleManager: AhaKeyBLEManager? = nil) {
        // 1. 卸载 LaunchAgent
        _ = runLaunchctlQuiet(["unload", plistPath])
        try? FileManager.default.removeItem(atPath: plistPath)

        // 2. 清理老版本 shell hook 脚本（如果存在）
        try? FileManager.default.removeItem(atPath: legacyHookScriptPath)

        // 3. 移除 Claude / Cursor / Codex / Kimi hooks 中的 ahakey 条目（同时覆盖老 shell 脚本与新二进制命令）
        removeClaudeHooks()
        removeCursorHooks()
        removeCodexHooks()
        _ = removeKimiHooks()

        // 4. 清理 socket
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        bluetoothConnectionOwner = .ahaKeyStudio
        UserDefaults.standard.set(BluetoothConnectionOwner.ahaKeyStudio.rawValue, forKey: Self.bluetoothOwnerKey)
        bleManager?.setSuppressedForAgentOwningKeyboard(false)

        log.info("已卸载 agent + hooks")
        refresh()
    }

    /// 启动 Agent 守护进程（先确保 Job 已 load，再 start；适合「已安装但未运行」）。
    func start() {
        guard isInstalled else {
            agentUserAlert = "The LaunchAgent is not installed. Click \"Install & Enable\" first."
            return
        }
        if launchAgentNeedsRewrite() {
            unloadAgentLaunchJobRemovingSocket()
            guard writeLaunchAgentPlist() else { return }
        }
        isAgentOperationInProgress = true
        let loadRes = runLaunchctlDetailed(["load", plistPath])
        let startRes = runLaunchctlDetailed(["start", label])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self] in
            guard let self else { return }
            self.isAgentOperationInProgress = false
            self.refresh()
            if !self.isRunning {
                var m = "launchctl load / start was executed, but the Agent does not appear to be running (/tmp/ahakey.sock did not appear).\n\n"
                if !loadRes.ok && !isBenignLaunchctlLoadMessage(loadRes.mergedOutput) {
                    m += "load:\n\(loadRes.mergedOutput.isEmpty ? "(no output)" : loadRes.mergedOutput)\n\n"
                }
                if !startRes.ok {
                    m += "start:\n\(startRes.mergedOutput.isEmpty ? "(no output)" : startRes.mergedOutput)\n\n"
                }
                m += "Click \"View Log\" to inspect \(self.logFilePath); also make sure this app is allowed to use Bluetooth in System Settings → Privacy & Security. If the agent subprocess is launched via a LaunchAgent, the binary with the same signature must also be granted permission."
                self.agentUserAlert = m
            } else if (!loadRes.ok && !isBenignLaunchctlLoadMessage(loadRes.mergedOutput)) || !startRes.ok {
                self.agentUserAlert = "The Agent is running. Note: launchctl output — load: \(loadRes.mergedOutput) start: \(startRes.mergedOutput)"
            }
        }
    }

    /// 停止 Agent 并 **unload** 出 launchd，否则 `KeepAlive` 会让进程立刻重启并继续占蓝牙。
    func stop() {
        unloadAgentLaunchJobRemovingSocket()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Log

    var logFilePath: String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AhaKeyConfig/diagnostics")
        try? FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent.log").path
    }

    /// Hook 子进程在每次 Claude `PermissionRequest` 时追加 JSON 行，与 `HookClient` 中 diagnostics 路径一致。
    var permissionRequestLogPath: String {
        URL(fileURLWithPath: logFilePath).deletingLastPathComponent()
            .appendingPathComponent("permission-request.log")
            .path
    }

    /// Codex 所有 AhaKey hook 触发记录：状态 hook 与 PermissionRequest 都会追加 JSON 行。
    var codexHookLogPath: String {
        URL(fileURLWithPath: logFilePath).deletingLastPathComponent()
            .appendingPathComponent("codex-hook.log")
            .path
    }

    func readLog() -> String {
        (try? String(contentsOfFile: logFilePath, encoding: .utf8)) ?? "(No log)"
    }

    // MARK: - Cursor 用户级文件（可展示、可合并，非 Hook 子进程管理）

    /// 与「安装 Cursor Hooks」写入路径一致，便于在 UI 中展示或对照。
    var userCursorHooksJsonFilePath: String { cursorHooksPath }

    /// Codex 0.125 使用 `~/.codex/config.toml` 的 inline `[[hooks.Event]]`。
    var userCodexConfigFilePath: String { codexConfigPath }

    /// Kimi Code CLI（Beta）使用 `~/.kimi/config.toml` 的 `[[hooks]]`。
    var userKimiConfigFilePath: String { kimiConfigPath }

    /// Cursor CLI / Agent 的全局 `permissions` 等（控制 Shell 等是否仍弹层确认，与 `hooks.json` 独立）。
    var userCursorCliConfigFilePath: String { cursorCliConfigPath }

    /// 将 `~/.cursor/hooks.json` 以可读（pretty）形式读出；不存在时返回说明。
    func readUserCursorHooksJsonForDisplay() -> String {
        let path = cursorHooksPath
        guard FileManager.default.fileExists(atPath: path) else {
            return "(File does not exist: \(path))\n\nClick \"Install Cursor Hooks\" to create or merge it; if you only use a **project-level** `.cursor/hooks.json`, this path may remain empty."
        }
        return Self.prettyJsonString(atPath: path) ?? "(Exists but could not be parsed as JSON: \(path))"
    }

    /// 将 `~/.cursor/cli-config.json` 以可读（pretty）形式读出；不存在时提示。
    func readUserCursorCliConfigForDisplay() -> String {
        let path = cursorCliConfigPath
        guard FileManager.default.fileExists(atPath: path) else {
            return "(File does not exist: \(path))\n\nClick \"Merge Shell Allowlist + approvalMode=auto\" in the diagnostics panel to create it from scratch, or configure `permissions` yourself per the documentation."
        }
        return Self.prettyJsonString(atPath: path) ?? "(Exists but could not be parsed as JSON: \(path))"
    }

    /// 将 `~/.codex/config.toml` 原样读出；Codex hooks 是 TOML，不是 JSON。
    func readUserCodexConfigForDisplay() -> String {
        let path = codexConfigPath
        guard FileManager.default.fileExists(atPath: path) else {
            return "(File does not exist: \(path))\n\nClick \"Install Codex Hooks\" to create it and merge `[features].hooks` with the AhaKey hook block."
        }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? "(Exists but could not be read: \(path))"
    }

    /// `~/.kimi/config.toml` 原样读出（Kimi Hooks 配置为文本 TOML）。
    func readUserKimiConfigForDisplay() -> String {
        let path = kimiConfigPath
        guard FileManager.default.fileExists(atPath: path) else {
            return "(File does not exist: \(path))\n\nClick \"Install Kimi Hooks\" to create it and write the AhaKey marker block; Kimi Code CLI must be installed and in use: https://moonshotai.github.io/kimi-cli/"
        }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? "(Exists but could not be read: \(path))"
    }

    /// 备份当前 `cli-config` 后，合并 `permissions.allow`（不删你已有项），并设置 `approvalMode` 为 `auto`。
    /// 用于减轻「hook 已 allow 但 Cursor 仍要求再点一次」中 **Cursor 自己那一层** 的拦阻。
    /// - Returns: 给用户看的结果说明。
    func mergeUserCursorCliConfigForShellAutoApprove() -> String {
        let path = cursorCliConfigPath
        let cursorDir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: cursorDir, withIntermediateDirectories: true)
        } catch {
            return "Could not create directory \(cursorDir): \(error.localizedDescription)"
        }
        if FileManager.default.fileExists(atPath: path) {
            let bak = path + ".ahakey.bak"
            do {
                if FileManager.default.fileExists(atPath: bak) {
                    try FileManager.default.removeItem(atPath: bak)
                }
                try FileManager.default.copyItem(atPath: path, toPath: bak)
            } catch {
                return "\(path) already exists but could not be backed up to \(bak): \(error.localizedDescription)"
            }
        }
        var root = loadCursorCliConfig() ?? [:]
        if root["version"] == nil { root["version"] = 1 }

        var perms = root["permissions"] as? [String: Any] ?? [:]
        var allow = Self.stringArrayValue(perms["allow"])
        let additions: [String] = [
            "Shell(*)", "Shell(cd)", "Shell(swift)", "Shell(xcodebuild)", "Shell(git)", "Shell(python3)", "Shell(npm)", "Shell(cargo)", "Shell(curl)", "Shell(ls)",
        ]
        var merged = 0
        for a in additions {
            if !allow.contains(a) {
                allow.append(a)
                merged += 1
            }
        }
        perms["allow"] = allow
        if perms["deny"] == nil { perms["deny"] = [String]() }
        root["permissions"] = perms
        root["approvalMode"] = "auto"

        guard saveCursorCliConfig(root) else {
            return "Could not write the merged JSON back to: \(path)"
        }
        log.info("cli-config: merged Shell allow + approvalMode=auto at \(path)")
        return "Written back to: \(path)\n(If a file already existed at this path, it was backed up as \(path).ahakey.bak)\n\nMerged \(merged) common Shell(...) rules into permissions.allow (existing rules kept); approvalMode is now set to auto.\n\nIf a version still prompts, add the first word of the blocked command to the allowlist yourself per the docs:\nhttps://cursor.com/docs/cli/reference/permissions\nOr check whether the workspace .cursor/cli.json has additional restrictions."
    }

    /// 合并 `~/.cursor/permissions.json` 的 `terminalAllowlist`（**IDE「Not in allowlist」** 与 cli-config 无关）。
    func mergeUserCursorPermissionsJsonForAgentTUI() -> String {
        let path = cursorPermissionsJsonPath
        let cursorDir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: cursorDir, withIntermediateDirectories: true)
        } catch {
            return "Could not create directory \(cursorDir): \(error.localizedDescription)"
        }
        if FileManager.default.fileExists(atPath: path) {
            let bak = path + ".ahakey.bak"
            do {
                if FileManager.default.fileExists(atPath: bak) { try FileManager.default.removeItem(atPath: bak) }
                try FileManager.default.copyItem(atPath: path, toPath: bak)
            } catch {
                return "permissions.json exists but could not be backed up to \(bak): \(error.localizedDescription)"
            }
        }
        var root = loadCursorPermissionsJson() ?? [:]
        var list = Self.stringArrayValue(root["terminalAllowlist"])
        let additions = [
            "cd", "swift", "swift build", "xcodebuild", "git", "npm", "yarn", "pnpm", "bun", "deno", "node",
            "make", "cargo", "go", "python3", "python", "bash", "zsh", "sh", "curl", "ls",
        ]
        var n = 0
        for a in additions where !list.contains(a) {
            list.append(a)
            n += 1
        }
        root["terminalAllowlist"] = list
        guard saveCursorPermissionsJson(root) else {
            return "Could not write back to: \(path)"
        }
        log.info("permissions.json: merged terminalAllowlist at \(path)")
        return "Written back to: \(path) (backed up as \(path).ahakey.bak)\n\nMerged \(n) prefixes into terminalAllowlist; this covers the Agent's \"Not in allowlist\" layer, which is separate from cli-config's Shell(...). Docs:\nhttps://cursor.com/docs/reference/permissions"
    }

    private func loadCursorPermissionsJson() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: cursorPermissionsJsonPath),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return j
    }

    private func saveCursorPermissionsJson(_ root: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: cursorPermissionsJsonPath), options: .atomic)
            return true
        } catch {
            log.error("saveCursorPermissionsJson: \(error.localizedDescription)")
            return false
        }
    }

    private static func prettyJsonString(atPath path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: out, encoding: .utf8)
    }

    private static func stringArrayValue(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a }
        if let a = v as? [Any] { return a.compactMap { $0 as? String } }
        return []
    }

    private func loadCursorCliConfig() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: cursorCliConfigPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func saveCursorCliConfig(_ root: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: cursorCliConfigPath), options: .atomic)
            return true
        } catch {
            log.error("saveCursorCliConfig: \(error.localizedDescription)")
            return false
        }
    }

    /// 只读；由 `ahakeyconfig-agent` 在 `PermissionRequest` 与 Cursor 批准类 hook 中写入。
    func readPermissionRequestLog() -> String {
        (try? String(contentsOfFile: permissionRequestLogPath, encoding: .utf8))
            ?? "No records yet. Trigger a PermissionRequest in Claude, have the Agent call a tool/Shell/MCP in Cursor, or trigger a tool call in Kimi Code CLI, and a JSON line with `ide` / `hookEvent` will be appended here. If it stays empty, make sure the Agent and Hooks are installed, Bluetooth is owned by the Agent, and `~/Library/.../AhaKeyConfig/diagnostics/` is writable."
    }

    /// 只读；由 `ahakeyconfig-agent hook Codex*` 子进程写入，用于判断 Codex 客户端/终端是否真的触发了 hook。
    func readCodexHookLog() -> String {
        (try? String(contentsOfFile: codexHookLogPath, encoding: .utf8))
            ?? "No records yet. A JSON line should be appended here after Codex is triggered. If terminal Codex has records but the Codex client does not, the client has not loaded the current `~/.codex/config.toml` hooks — usually you need to restart the Codex client or open a new terminal and test again."
    }

    // MARK: - Claude hooks 追加

    /// Claude Code 支持的 hook 事件（和 HookClient.eventMap 对齐）
    private let hookEvents: [String] = [
        "Notification",
        "PermissionRequest",
        "PreToolUse",
        "PostToolUse",
        "Stop",
        "SubagentStop",  // Claude Code 拆分后：手动终止任务时触发此事件
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "TaskCompleted",
        "PreCompact",
    ]

    /// Shell 安全地引用一个路径（单引号包裹 + 转义内部单引号）
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 空串表示已写入；非空为「跳过 / 失败」说明，需展示给用户。
    private func installClaudeHooks() -> String {
        guard var settings = loadClaudeSettings() else {
            return "Claude Hooks: ~/.claude/settings.json not found, skipped. After using Claude Code and generating that file, click \"Install Claude Hooks\" again."
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let binQuoted = shellQuote(agentBinaryPath)

        for event in hookEvents {
            let ahakeyCmd = "\(binQuoted) hook \(event)"
            var eventHooks = hooks[event] as? [[String: Any]] ?? []

            // 先清掉老的 ahakey 条目，避免 shell 脚本 + 新二进制并存
            for i in eventHooks.indices {
                var entry = eventHooks[i]
                if var cmds = entry["hooks"] as? [[String: Any]] {
                    cmds.removeAll { isAhakeyHookCommand(($0["command"] as? String) ?? "") }
                    entry["hooks"] = cmds
                    eventHooks[i] = entry
                }
            }

            if let idx = eventHooks.firstIndex(where: { ($0["matcher"] as? String) == "" }) {
                var entry = eventHooks[idx]
                var cmds = entry["hooks"] as? [[String: Any]] ?? []
                cmds.append(["type": "command", "command": ahakeyCmd])
                entry["hooks"] = cmds
                eventHooks[idx] = entry
            } else {
                eventHooks.append([
                    "matcher": "",
                    "hooks": [["type": "command", "command": ahakeyCmd]],
                ])
            }
            hooks[event] = eventHooks
        }

        settings["hooks"] = hooks
        if saveClaudeSettings(settings) {
            log.info("Claude hooks 已写入 ahakeyconfig-agent hook 子命令")
            return ""
        }
        return "Claude Hooks: could not write to \(claudeSettingsPath). Check the permissions/read-only state of the file or its parent directory."
    }

    private func removeClaudeHooks() {
        guard var settings = loadClaudeSettings() else { return }
        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        for event in hookEvents {
            guard var eventHooks = hooks[event] as? [[String: Any]] else { continue }
            for i in eventHooks.indices {
                var entry = eventHooks[i]
                if var cmds = entry["hooks"] as? [[String: Any]] {
                    cmds.removeAll { isAhakeyHookCommand(($0["command"] as? String) ?? "") }
                    entry["hooks"] = cmds
                    eventHooks[i] = entry
                }
            }
            hooks[event] = eventHooks
        }

        settings["hooks"] = hooks
        if !saveClaudeSettings(settings) {
            log.error("removeClaudeHooks: 无法写回 settings")
        } else {
            log.info("Claude hooks 中 ahakey 条目已移除")
        }
    }

    private func loadClaudeSettings() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: claudeSettingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func saveClaudeSettings(_ settings: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: claudeSettingsPath), options: .atomic)
            return true
        } catch {
            log.error("saveClaudeSettings: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Cursor hooks

    /// Cursor 支持的 hook 事件（小驼峰，与 `HookClient` 一致）。
    /// 批准链集中在 `preToolUse`（在任意工具前调用，可 stdout `permission`）；若你在 `hooks.json` 里自行添加
    /// `beforeShellExecution` / `beforeMCPExecution` 并指向本 agent，其事件名在 `HookClient` 中同样支持拨杆。
    /// 安装时写入这些事件；**卸载**时会遍历 `hooks` 的**所有键**（含旧版/合并进的 `beforeReadFile`、`beforeSubmitPrompt` 等），避免只卸一半导致「没反应」。
    private let cursorHookEvents: [String] = [
        "sessionStart",
        "sessionEnd",
        "preToolUse",
        "beforeShellExecution",
        "beforeMCPExecution",
        "beforeReadFile",
        "beforeSubmitPrompt",
        "postToolUse",
        "stop",
    ]

    private let codexHookBlockStart = "# BEGIN AhaKey Codex Hooks"
    private let codexHookBlockEnd = "# END AhaKey Codex Hooks"
    private let codexHookEvents: [(event: String, agentEvent: String, timeout: Int)] = [
        ("SessionStart", "CodexSessionStart", 10),
        ("PostToolUse", "CodexPostToolUse", 10),
        ("PreToolUse", "CodexPreToolUse", 20),
        ("PermissionRequest", "CodexPermissionRequest", 20),
        ("UserPromptSubmit", "CodexUserPromptSubmit", 10),
        ("Stop", "CodexStop", 10),
    ]

    private let kimiHookBlockStart = "# BEGIN AhaKey Kimi Hooks"
    private let kimiHookBlockEnd = "# END AhaKey Kimi Hooks"
    private let kimiHookEntries: [(event: String, agentEvent: String, timeout: Int)] = [
        ("Notification", "KimiNotification", 10),
        ("SessionStart", "KimiSessionStart", 10),
        ("SessionEnd", "KimiSessionEnd", 10),
        ("PreToolUse", "KimiPreToolUse", 20),
        ("PostToolUse", "KimiPostToolUse", 10),
        ("UserPromptSubmit", "KimiUserPromptSubmit", 10),
        ("Stop", "KimiStop", 10),
    ]

    /// 单独安装 Claude hooks
    func installClaudeHooksOnly() {
        isAgentOperationInProgress = true
        defer { isAgentOperationInProgress = false }
        let s = installClaudeHooks()
        agentUserAlert = s.isEmpty ? "Claude Hooks written to ~/.claude/settings.json." : s
        refresh()
    }

    /// 单独移除 Claude hooks
    func removeClaudeHooksOnly() {
        removeClaudeHooks()
        refresh()
    }

    /// 单独安装 Cursor hooks（公开给 UI 用，例如只想补装 Cursor 时调用）
    func installCursorHooksOnly() {
        isAgentOperationInProgress = true
        defer { isAgentOperationInProgress = false }
        let s = installCursorHooks()
        agentUserAlert = s.isEmpty ? "Cursor Hooks written to ~/.cursor/hooks.json." : s
        refresh()
    }

    /// 单独安装 Codex hooks（Codex 0.125 为 inline TOML）。
    func installCodexHooksOnly() {
        isAgentOperationInProgress = true
        defer { isAgentOperationInProgress = false }
        let s = installCodexHooks()
        agentUserAlert = s.isEmpty ? "Codex Hooks written to ~/.codex/config.toml.\n\nInstallation complete. Restart the Codex terminal or client before use." : s
        refresh()
    }

    /// 单独移除 Cursor hooks
    func removeCursorHooksOnly() {
        isAgentOperationInProgress = true
        defer { isAgentOperationInProgress = false }
        agentUserAlert = performRemoveCursorHooksUserMessage()
        refresh()
    }

    /// 单独移除 Codex hooks。
    func removeCodexHooksOnly() {
        isAgentOperationInProgress = true
        defer { isAgentOperationInProgress = false }
        agentUserAlert = removeCodexHooks()
        refresh()
    }

    /// 单独安装 Kimi Code CLI hooks（`~/.kimi/config.toml`，Beta）。
    func installKimiHooksOnly() {
        isAgentOperationInProgress = true
        defer { isAgentOperationInProgress = false }
        let s = installKimiHooks()
        agentUserAlert = s.isEmpty
            ? """
            Kimi Hooks written to ~/.kimi/config.toml.

            **The AhaKey dial override will also be re-patched into the local kimi-cli**. If kimi is currently open, **fully quit and reopen it once**; after reopening, **dial 0/1 directly takes over auto-approval for the current session** — **no `/reload` and no `/yolo` needed**.
            If you later **upgrade kimi-cli**, click "Install Kimi Hooks" once more to reapply this dial override layer, then reopen kimi again.

            Installation complete. Hooks are Beta; behavior follows the official documentation.
            """
            : s
        refresh()
    }

    /// 单独移除 Kimi Hooks 标记块。
    func removeKimiHooksOnly() {
        isAgentOperationInProgress = true
        defer { isAgentOperationInProgress = false }
        agentUserAlert = removeKimiHooks()
        refresh()
    }

    private func installCursorHooks() -> String {
        // Cursor 的目录可能不存在，先建好
        let cursorDir = (cursorHooksPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: cursorDir, withIntermediateDirectories: true)
        } catch {
            return "Cursor Hooks: could not create directory \(cursorDir): \(error.localizedDescription)"
        }

        var settings = loadCursorSettings() ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let binQuoted = shellQuote(agentBinaryPath)

        for event in cursorHookEvents {
            let cmd = "\(binQuoted) hook \(event)"
            // Cursor：`{ "hooks": { "<event>": [{ "command": "...", "timeout": N }] } }`
            // 读拨杆/写状态略慢，长超时与 `HookClient` 一致
            let t: Int
            if event == "beforeSubmitPrompt" { t = 30 }
            else if ["preToolUse", "beforeShellExecution", "beforeMCPExecution", "beforeReadFile", "sessionStart"].contains(event) { t = 20 }
            else { t = 10 }
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.removeAll { isAhakeyHookCommand(($0["command"] as? String) ?? "") }
            entries.append(["command": cmd, "timeout": t])
            hooks[event] = entries
        }

        settings["hooks"] = hooks
        if settings["version"] == nil {
            settings["version"] = 1
        }
        if saveCursorSettings(settings) {
            log.info("Cursor hooks 已写入")
            return ""
        }
        return "Cursor Hooks: could not write to \(cursorHooksPath). Check permissions or disk space."
    }

    private func installCodexHooks() -> String {
        let codexDir = (codexConfigPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
        } catch {
            return "Codex Hooks: could not create directory \(codexDir): \(error.localizedDescription)"
        }

        var config = (try? String(contentsOfFile: codexConfigPath, encoding: .utf8)) ?? ""
        config = removeCodexHookBlock(from: config)
        config = ensureCodexHooksFeatureEnabled(in: config)
        config = config.trimmingCharacters(in: .whitespacesAndNewlines)
        if !config.isEmpty { config += "\n\n" }
        config += buildCodexHookBlock()
        config += "\n"

        do {
            try config.write(toFile: codexConfigPath, atomically: true, encoding: .utf8)
            guard FileManager.default.fileExists(atPath: codexConfigPath),
                  let written = try? String(contentsOfFile: codexConfigPath, encoding: .utf8),
                  written.contains(codexHookBlockStart),
                  written.contains(codexHookBlockEnd) else {
                log.error("installCodexHooks: 写入后校验失败 \(self.codexConfigPath)")
                return "Codex Hooks: attempted to write \(codexConfigPath), but the AhaKey marker block was not found during verification. Make sure \"~/.codex\" in the home directory is writable, or close other programs using the file."
            }
            log.info("Codex hooks 已写入 ~/.codex/config.toml")
            let cliRepair = repairCodexCliPathIfNeeded()
            return cliRepair.isEmpty
                ? ""
                : "Codex Hooks written to ~/.codex/config.toml.\n\n\(cliRepair)\n\nInstallation complete. Restart the Codex terminal or client before use."
        } catch {
            log.error("installCodexHooks: \(error.localizedDescription)")
            return "Codex Hooks: could not write to \(codexConfigPath): \(error.localizedDescription)"
        }
    }

    private func repairCodexCliPathIfNeeded() -> String {
        if isExecutableOnPath("codex") {
            return ""
        }
        guard FileManager.default.isExecutableFile(atPath: codexAppCliPath) else {
            return "The `codex` command was not found in PATH, and the Codex app's bundled CLI was not found either: \(codexAppCliPath). The hook configuration is installed; to use Codex in the terminal, install or update the Codex client first."
        }

        do {
            try FileManager.default.createDirectory(atPath: localBinDirectoryPath, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: localCodexCliPath) {
                try FileManager.default.removeItem(atPath: localCodexCliPath)
            }
            try FileManager.default.createSymbolicLink(atPath: localCodexCliPath, withDestinationPath: codexAppCliPath)
        } catch {
            return "Detected that `codex` is unavailable in the terminal, but could not create \(localCodexCliPath): \(error.localizedDescription). The hook configuration is installed."
        }

        let zshLine = #"export PATH="$HOME/.local/bin:$PATH""#
        do {
            var zshrc = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
            if !zshrc.contains("HOME/.local/bin") && !zshrc.contains("$HOME/.local/bin") {
                if FileManager.default.fileExists(atPath: zshrcPath) {
                    let bak = zshrcPath + ".ahakey.bak"
                    if FileManager.default.fileExists(atPath: bak) {
                        try FileManager.default.removeItem(atPath: bak)
                    }
                    try FileManager.default.copyItem(atPath: zshrcPath, toPath: bak)
                }
                zshrc = zshrc.trimmingCharacters(in: .whitespacesAndNewlines)
                if !zshrc.isEmpty { zshrc += "\n" }
                zshrc += zshLine + "\n"
                try zshrc.write(toFile: zshrcPath, atomically: true, encoding: .utf8)
                return "Detected the Codex app's bundled CLI and repaired the terminal command:\n\(localCodexCliPath) → \(codexAppCliPath)\n\nAdded `~/.local/bin` to ~/.zshrc (if the file existed, it was backed up as ~/.zshrc.ahakey.bak)."
            }
        } catch {
            return "Created \(localCodexCliPath), but could not update ~/.zshrc: \(error.localizedDescription). Add `~/.local/bin` to PATH manually."
        }

        return "Detected the Codex app's bundled CLI and created the terminal command:\n\(localCodexCliPath) → \(codexAppCliPath)"
    }

    private func isExecutableOnPath(_ command: String) -> Bool {
        executablePathOnPath(command) != nil
    }

    private func executablePathOnPath(_ command: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    @discardableResult
    private func removeCodexHooks() -> String {
        let path = codexConfigPath
        guard FileManager.default.fileExists(atPath: path) else {
            return "\(path) not found; nothing to remove for Codex Hooks."
        }
        guard let config = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "Could not read \(path); check permissions."
        }
        let next = removeCodexHookBlock(from: config)
        guard next != config else {
            return "No AhaKey Codex hook marker block found in \(path)."
        }
        do {
            try next.write(toFile: path, atomically: true, encoding: .utf8)
            log.info("Codex hooks 中 AhaKey 标记块已移除")
            return "Removed AhaKey Codex Hooks from \(path)."
        } catch {
            return "Generated the updated content, but could not write it back to \(path): \(error.localizedDescription)"
        }
    }

    private func buildCodexHookBlock() -> String {
        let binQuoted = shellQuote(agentBinaryPath)
        var lines: [String] = [
            codexHookBlockStart,
            "# Managed by AhaKey Studio. Codex 0.125 uses inline TOML hooks; each command hook needs type = \"command\".",
        ]
        for item in codexHookEvents {
            lines.append("")
            lines.append("[[hooks.\(item.event)]]")
            lines.append("matcher = \"\"")
            lines.append("")
            lines.append("[[hooks.\(item.event).hooks]]")
            lines.append("type = \"command\"")
            lines.append("command = \"\(escapeTomlBasicString("/bin/zsh -lc \(shellQuote("\(binQuoted) hook \(item.agentEvent)"))"))\"")
            lines.append("timeout = \(item.timeout)")
        }
        lines.append("")
        lines.append(codexHookBlockEnd)
        return lines.joined(separator: "\n")
    }

    private func removeCodexHookBlock(from config: String) -> String {
        var lines = config.components(separatedBy: .newlines)
        while let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == codexHookBlockStart }),
              let end = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == codexHookBlockEnd }) {
            lines.removeSubrange(start...end)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func ensureCodexHooksFeatureEnabled(in config: String) -> String {
        var lines = config.components(separatedBy: .newlines)
        var featuresStart: Int?
        for (idx, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces) == "[features]" {
                featuresStart = idx
                break
            }
        }

        guard let start = featuresStart else {
            var next = config.trimmingCharacters(in: .whitespacesAndNewlines)
            if !next.isEmpty { next += "\n\n" }
            next += "[features]\nhooks = true\n"
            return next
        }

        var sectionEnd = lines.count
        if start + 1 < lines.count {
            for idx in (start + 1)..<lines.count {
                let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    sectionEnd = idx
                    break
                }
            }
        }

        // Codex 新版用 `hooks`；旧版写过已废弃的 `codex_hooks`（会触发 deprecation 警告）。
        // 两者都识别：保留/改写第一个命中为 `hooks = true`，其余（含所有 `codex_hooks`）删除。
        let keyPattern = #"^\s*(codex_)?hooks\s*="#
        let regex = try? NSRegularExpression(pattern: keyPattern)
        var matchedIndices: [Int] = []
        for idx in (start + 1)..<sectionEnd {
            let line = lines[idx]
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if regex?.firstMatch(in: line, range: range) != nil {
                matchedIndices.append(idx)
            }
        }

        guard let first = matchedIndices.first else {
            lines.insert("hooks = true", at: start + 1)
            return lines.joined(separator: "\n")
        }

        lines[first] = "hooks = true"
        for idx in matchedIndices.dropFirst().reversed() {
            lines.remove(at: idx)
        }
        return lines.joined(separator: "\n")
    }

    private func escapeTomlBasicString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func installKimiHooks() -> String {
        let kimiDir = (kimiConfigPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: kimiDir, withIntermediateDirectories: true)
        } catch {
            return "Kimi Hooks: could not create directory \(kimiDir): \(error.localizedDescription)"
        }

        var config = (try? String(contentsOfFile: kimiConfigPath, encoding: .utf8)) ?? ""
        config = removeKimiHookBlock(from: config)
        config = removeLegacyKimiHookEntries(from: config)
        config = config.trimmingCharacters(in: .whitespacesAndNewlines)
        if !config.isEmpty { config += "\n\n" }
        config += buildKimiHookBlock()
        config += "\n"

        do {
            try config.write(toFile: kimiConfigPath, atomically: true, encoding: .utf8)
            log.info("Kimi hooks 已写入 ~/.kimi/config.toml")
            return patchInstalledKimiCliForAhaKeyDialControl()
        } catch {
            log.error("installKimiHooks: \(error.localizedDescription)")
            return "Kimi Hooks: could not write to \(kimiConfigPath): \(error.localizedDescription)"
        }
    }

    private struct KimiCliPatchTargets {
        let approvalPyPath: String
        let slashPyPath: String
        let sourceHint: String
    }

    private enum KimiCliPatchStatus {
        case alreadyPatched
        case patched
    }

    private func patchInstalledKimiCliForAhaKeyDialControl() -> String {
        guard let targets = resolveKimiCliPatchTargets() else {
            return """
            Kimi Hooks written to ~/.kimi/config.toml, but **no local kimi-cli installation was found to patch**.

            Make sure the `kimi` command exists in the terminal, then click "Install Kimi Hooks" again to retry the dial override patch.
            """
        }

        do {
            _ = try patchKimiApprovalPy(atPath: targets.approvalPyPath)
            _ = try patchKimiSlashPy(atPath: targets.slashPyPath)
            log.info("Kimi CLI dial-control patch ensured at \(targets.sourceHint)")
            return ""
        } catch {
            log.error("patchInstalledKimiCliForAhaKeyDialControl: \(error.localizedDescription)")
            return """
            Kimi Hooks written to ~/.kimi/config.toml, but **the local kimi-cli dial override patch did not complete**:
            \(error.localizedDescription)

            After confirming `kimi` is executable, click "Install Kimi Hooks" again to retry.
            """
        }
    }

    private func resolveKimiCliPatchTargets() -> KimiCliPatchTargets? {
        if let kimiPath = executablePathOnPath("kimi"),
           let targets = resolveKimiCliPatchTargets(fromKimiEntryPath: kimiPath) {
            return targets
        }

        let fallbackRoot = URL(fileURLWithPath: kimiCliFallbackRoot, isDirectory: true)
        if let targets = resolveKimiCliPatchTargets(fromEnvRoot: fallbackRoot, sourceHint: fallbackRoot.path) {
            return targets
        }
        return nil
    }

    private func resolveKimiCliPatchTargets(fromKimiEntryPath path: String) -> KimiCliPatchTargets? {
        guard let wrapper = try? String(contentsOfFile: path, encoding: .utf8),
              let firstLine = wrapper.components(separatedBy: .newlines).first,
              firstLine.hasPrefix("#!") else {
            return nil
        }
        let shebang = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shebang.isEmpty else { return nil }
        let pythonPath = shebang.components(separatedBy: .whitespaces).first ?? shebang
        let envRoot = URL(fileURLWithPath: pythonPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return resolveKimiCliPatchTargets(fromEnvRoot: envRoot, sourceHint: path)
    }

    private func resolveKimiCliPatchTargets(fromEnvRoot envRoot: URL, sourceHint: String) -> KimiCliPatchTargets? {
        let libRoot = envRoot.appendingPathComponent("lib", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(at: libRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard child.lastPathComponent.hasPrefix("python") else { continue }
            let pkgRoot = child.appendingPathComponent("site-packages/kimi_cli", isDirectory: true)
            let approval = pkgRoot.appendingPathComponent("soul/approval.py").path
            let slash = pkgRoot.appendingPathComponent("soul/slash.py").path
            if FileManager.default.fileExists(atPath: approval),
               FileManager.default.fileExists(atPath: slash) {
                return KimiCliPatchTargets(
                    approvalPyPath: approval,
                    slashPyPath: slash,
                    sourceHint: sourceHint
                )
            }
        }
        return nil
    }

    private func patchKimiApprovalPy(atPath path: String) throws -> KimiCliPatchStatus {
        let marker = "_AHAKEY_SOCKET_PATH = \"/tmp/ahakey.sock\""
        let helperAnchor = "type Response = Literal[\"approve\", \"approve_for_session\", \"reject\"]\n"
        let helperBlock = """
        type Response = Literal["approve", "approve_for_session", "reject"]

        _AHAKEY_SOCKET_PATH = "/tmp/ahakey.sock"
        _AHAKEY_APPROVAL_CACHE_TTL_S = 0.35
        _ahakey_cache_at = 0.0
        _ahakey_cache_value: dict[str, object] | None = None


        def _load_ahakey_override_uncached() -> dict[str, object] | None:
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                    sock.settimeout(2.0)
                    sock.connect(_AHAKEY_SOCKET_PATH)
                    sock.sendall(b'{"cmd":"approval_status"}\\n')

                    chunks: list[bytes] = []
                    while True:
                        part = sock.recv(4096)
                        if not part:
                            break
                        chunks.append(part)
                        if b"\\n" in part:
                            break
            except OSError:
                return None

            raw = b"".join(chunks).decode("utf-8", errors="ignore").strip()
            if not raw:
                return None
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError:
                return None
            switch_state = payload.get("switchState")
            if not isinstance(switch_state, int):
                return None
            return {
                "switch_state": switch_state,
                "is_auto": switch_state == 0,
                "mode_label": "auto" if switch_state == 0 else "manual",
            }


        def get_ahakey_approval_override(*, force_refresh: bool = False) -> dict[str, object] | None:
            global _ahakey_cache_at, _ahakey_cache_value

            now = time.monotonic()
            if not force_refresh and (now - _ahakey_cache_at) < _AHAKEY_APPROVAL_CACHE_TTL_S:
                return _ahakey_cache_value

            value = _load_ahakey_override_uncached()
            _ahakey_cache_at = now
            _ahakey_cache_value = value
            return value
        """
        let oldImports = "import uuid\n"
        let newImports = """
        import json
        import socket
        import time
        import uuid
        """
        let oldApprovalLogic = """
                if self.is_auto_approve():
                    from kimi_cli.telemetry import track

                    track(
                        "tool_approved",
                        tool_name=tool_call.function.name,
                        approval_mode="afk" if self.is_afk() else "yolo",
                    )
                    return ApprovalResult(approved=True)

                if action in self._state.auto_approve_actions:
                    from kimi_cli.telemetry import track

                    track(
                        "tool_approved",
                        tool_name=tool_call.function.name,
                        approval_mode="auto_session",
                    )
                    return ApprovalResult(approved=True)
        """
        let newApprovalLogic = """
                ahakey_override = get_ahakey_approval_override(force_refresh=True)
                if ahakey_override is not None and bool(ahakey_override["is_auto"]):
                    from kimi_cli.telemetry import track

                    track(
                        "tool_approved",
                        tool_name=tool_call.function.name,
                        approval_mode="ahakey_dial_auto",
                    )
                    return ApprovalResult(approved=True)

                ahakey_manual_lock = ahakey_override is not None and not bool(ahakey_override["is_auto"])

                if not ahakey_manual_lock and self.is_auto_approve():
                    from kimi_cli.telemetry import track

                    track(
                        "tool_approved",
                        tool_name=tool_call.function.name,
                        approval_mode="afk" if self.is_afk() else "yolo",
                    )
                    return ApprovalResult(approved=True)

                if not ahakey_manual_lock and action in self._state.auto_approve_actions:
                    from kimi_cli.telemetry import track

                    track(
                        "tool_approved",
                        tool_name=tool_call.function.name,
                        approval_mode="auto_session",
                    )
                    return ApprovalResult(approved=True)
        """
        return try patchTextFile(
            atPath: path,
            marker: marker,
            replacements: [
                (oldImports, newImports + "\n"),
                (helperAnchor, helperBlock + "\n"),
                (oldApprovalLogic, newApprovalLogic),
            ],
            friendlyName: "kimi_cli/soul/approval.py"
        )
    }

    private func patchKimiSlashPy(atPath path: String) throws -> KimiCliPatchStatus {
        let marker = "from kimi_cli.soul.approval import get_ahakey_approval_override"
        let oldImport = "from kimi_cli import logger\n"
        let newImport = """
        from kimi_cli import logger
        from kimi_cli.soul.approval import get_ahakey_approval_override
        """
        let oldYoloLead = """
            # Inspect only the yolo flag: afk is independent and is toggled by /afk.
        """
        let newYoloLead = """
            ahakey_override = get_ahakey_approval_override(force_refresh=True)
            if ahakey_override is not None:
                mode_label = "自动批准" if bool(ahakey_override["is_auto"]) else "手动批准"
                wire_send(
                    TextPart(
                        text=(
                            f"AhaKey 拨杆接管中：当前为{mode_label}。"
                            "请直接拨动键盘上的物理拨杆切换；`/yolo` 不会覆盖拨杆。"
                        )
                    )
                )
                return

            # Inspect only the yolo flag: afk is independent and is toggled by /afk.
        """
        return try patchTextFile(
            atPath: path,
            marker: marker,
            replacements: [
                (oldImport, newImport + "\n"),
                (oldYoloLead, newYoloLead),
            ],
            friendlyName: "kimi_cli/soul/slash.py"
        )
    }

    private func patchTextFile(
        atPath path: String,
        marker: String,
        replacements: [(String, String)],
        friendlyName: String
    ) throws -> KimiCliPatchStatus {
        let url = URL(fileURLWithPath: path)
        var text = try String(contentsOf: url, encoding: .utf8)
        if text.contains(marker) {
            return .alreadyPatched
        }
        for (old, new) in replacements {
            guard text.contains(old) else {
                throw NSError(
                    domain: "AhaKeyKimiPatch",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No replaceable upstream anchor found in \(friendlyName); the kimi-cli version may have changed."]
                )
            }
            text = text.replacingOccurrences(of: old, with: new)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return .patched
    }

    @discardableResult
    private func removeKimiHooks() -> String {
        let path = kimiConfigPath
        guard FileManager.default.fileExists(atPath: path) else {
            return "\(path) not found; nothing to remove for Kimi Hooks."
        }
        guard let config = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "Could not read \(path); check permissions."
        }
        let next = removeLegacyKimiHookEntries(from: removeKimiHookBlock(from: config))
        guard next != config else {
            return "No AhaKey Kimi hook marker block or legacy bare hooks found in \(path)."
        }
        do {
            try next.write(toFile: path, atomically: true, encoding: .utf8)
            log.info("Kimi hooks 中 AhaKey 标记块与旧版裸 hook 已移除")
            return "Removed AhaKey Kimi Hooks from \(path)."
        } catch {
            return "Generated the updated content, but could not write it back to \(path): \(error.localizedDescription)"
        }
    }

    private func buildKimiHookBlock() -> String {
        let binQuoted = shellQuote(agentBinaryPath)
        var lines: [String] = [
            kimiHookBlockStart,
            "# Managed by AhaKey Studio. Kimi CLI (Beta): multiple [[hooks]] entries; each runs with JSON on stdin.",
            "# Dial integration is managed by AhaKey Studio. Re-click 'Install Kimi Hooks' after kimi-cli upgrades, then reopen kimi once.",
        ]
        for item in kimiHookEntries {
            let cmdToml = escapeTomlBasicString("/bin/zsh -lc \(shellQuote("\(binQuoted) hook \(item.agentEvent)"))")
            lines.append("")
            lines.append("[[hooks]]")
            lines.append("event = \"\(item.event)\"")
            lines.append("matcher = \"\"")
            lines.append("command = \"\(cmdToml)\"")
            lines.append("timeout = \(item.timeout)")
        }
        lines.append("")
        lines.append(kimiHookBlockEnd)
        return lines.joined(separator: "\n")
    }

    private func removeKimiHookBlock(from config: String) -> String {
        var lines = config.components(separatedBy: .newlines)
        while let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == kimiHookBlockStart }),
              let end = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == kimiHookBlockEnd }) {
            lines.removeSubrange(start...end)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// 清理未包在 BEGIN/END 标记块中的旧版 AhaKey Kimi hook，避免同一事件重复触发两次。
    private func removeLegacyKimiHookEntries(from config: String) -> String {
        let lines = config.components(separatedBy: .newlines)
        var kept: [String] = []
        var idx = 0

        while idx < lines.count {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            guard trimmed == "[[hooks]]" else {
                kept.append(lines[idx])
                idx += 1
                continue
            }

            var block = [lines[idx]]
            idx += 1
            while idx < lines.count {
                let nextTrimmed = lines[idx].trimmingCharacters(in: .whitespaces)
                if nextTrimmed == "[[hooks]]" || nextTrimmed == kimiHookBlockStart || nextTrimmed == kimiHookBlockEnd {
                    break
                }
                block.append(lines[idx])
                idx += 1
            }

            let joined = block.joined(separator: "\n")
            if isAhakeyHookCommand(joined), joined.contains("hook Kimi") {
                continue
            }
            kept.append(contentsOf: block)
        }

        return kept.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// 供「卸载主流程」等内部调用，无 UI 提示。
    private func removeCursorHooks() {
        _ = performRemoveCursorHooksUserMessage(writeAndLog: true, preferCompactMessage: true)
    }

    /// 从 `~/.cursor/hooks.json` 的 **全部** 事件里删掉指向 ahakey 的条目，并写回文件。
    /// - Returns: 给用户看的说明（弹窗用）；`writeAndLog==false` 时仍返回文案但不写盘（当前未用）。
    private func performRemoveCursorHooksUserMessage(writeAndLog: Bool = true, preferCompactMessage: Bool = false) -> String {
        let path = cursorHooksPath
        guard FileManager.default.fileExists(atPath: path) else {
            return "User-level \(path) not found.\n\nIf you only merged `.cursor/hooks.json` at the **project** level, manually edit or delete the AhaKey entries in that project root — there is nothing to remove at the user level."
        }
        guard var settings = loadCursorSettings() else {
            return "Could not parse \(path) (invalid JSON or corrupted). Open it in an editor to fix it and try again, or restore from a backup."
        }
        guard var hooks = settings["hooks"] as? [String: Any], !hooks.isEmpty else {
            return "hooks.json has no \"hooks\" section or it is empty; there are no AhaKey entries to remove."
        }

        var removedCount = 0
        for event in Array(hooks.keys).sorted() {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            let before = entries.count
            entries.removeAll { isAhakeyHookCommand(($0["command"] as? String) ?? "") }
            removedCount += before - entries.count
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        if removedCount == 0 {
            return "**No** `command` containing `ahakeyconfig-agent` or `ahakey-state` was found in \(path).\n\nIf the hooks are in a **project-level** `.cursor/hooks.json`, delete them manually in that repository; this button only modifies the user-level `~/.cursor/hooks.json`."
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        if writeAndLog {
            if !saveCursorSettings(settings) {
                log.error("removeCursorHooks: 无法写回 hooks.json")
                return "The AhaKey entries were removed in memory, but **could not be written back** to \(path). Check write permission for \".cursor\" in your home directory, or close other apps using the file and try again."
            }
            log.info("Cursor hooks: removed \(removedCount) ahakey command(s)")
        }

        if preferCompactMessage { return "" }
        return "Removed AhaKey entries from the user-level Cursor Hooks (\(removedCount) subcommands in total).\n\nFile: \(path)\n\nIf a repository still has a **project-level** `.cursor/hooks.json` containing this tool, it may take precedence and must be removed or merged within that project as well."
    }

    private func loadCursorSettings() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: cursorHooksPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func saveCursorSettings(_ settings: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: cursorHooksPath), options: .atomic)
            return true
        } catch {
            log.error("saveCursorSettings: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - launchctl

    private struct LaunchctlResult {
        let ok: Bool
        let mergedOutput: String
    }

    private func runLaunchctlDetailed(_ args: [String]) -> LaunchctlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return LaunchctlResult(ok: process.terminationStatus == 0, mergedOutput: text)
        } catch {
            return LaunchctlResult(ok: false, mergedOutput: error.localizedDescription)
        }
    }

    /// 再次 load 时系统常提示「已加载」类信息，不当作致命错误。
    private func isBenignLaunchctlLoadMessage(_ message: String) -> Bool {
        let m = message.lowercased()
        if m.isEmpty { return false }
        if m.contains("already") { return true }
        if m.contains("repeated load") { return true }
        if m.contains("service already") { return true }
        return false
    }

    @discardableResult
    private func runLaunchctlQuiet(_ args: [String]) -> Bool {
        runLaunchctlDetailed(args).ok
    }
}
