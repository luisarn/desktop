import SwiftUI

struct DeviceInfoView: View {
    @ObservedObject var bleManager: AhaKeyBLEManager
    @StateObject private var agentManager = AgentManager.shared
    @State private var isEditingName = false
    @State private var editableName = ""
    @State private var showAgentLog = false
    @State private var agentLogPanel = 0
    @State private var logPanelContentTick = 0
    @State private var showAgentRequiredForAgentBLE = false

    var body: some View {
        Form {
            // MARK: - 设备信息
            Section {
                HStack(spacing: 0) {
                    infoCell("Battery", value: "\(bleManager.batteryLevel)%")
                    Divider()
                    infoCell("Firmware", value: "v\(bleManager.firmwareMainVersion).\(bleManager.firmwareSubVersion)")
                    Divider()
                    infoCell("Device Name", value: bleManager.deviceName ?? "—")
                }
                .frame(height: 50)

                HStack(spacing: 0) {
                    infoCell("Work Mode", value: workModeName(bleManager.workMode))
                    Divider()
                    infoCell("Light", value: lightModeName(bleManager.lightMode))
                    Divider()
                    infoCell("Signal", value: "\(bleManager.signalStrength) dBm")
                }
                .frame(height: 50)
            } header: {
                Text("Device Info")
            }

            // MARK: - 蓝牙连接（App 与 Agent 二选一）
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Only this app or the Agent can connect to the keyboard at a time. Switch here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        ForEach(BluetoothConnectionOwner.allCases) { owner in
                            let selected = agentManager.bluetoothConnectionOwner == owner
                            let disableAgent = owner == .agentDaemon && !agentManager.isInstalled
                            Button {
                                if owner == .agentDaemon && !agentManager.isInstalled {
                                    showAgentRequiredForAgentBLE = true
                                } else {
                                    agentManager.setBluetoothConnectionOwner(owner, bleManager: bleManager)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(owner.title)
                                        .fontWeight(selected ? .semibold : .regular)
                                    Text(owner == .ahaKeyStudio
                                         ? "Key remapping, LCD, sync, local lighting test (USB wired configuration not yet supported on macOS)"
                                         : "Claude/Cursor/Codex/Kimi hooks, light bar status, switch position query")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(disableAgent)
                        }
                    }
                    CompatLabeledContent("Current") {
                        HStack(spacing: 6) {
                            Text(bleManager.isConnected ? "This App is connected via Bluetooth" : "This App is not connected")
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(agentBluetoothStatusText())
                        }
                        .font(.callout)
                    }
                }
            } header: {
                Text("Bluetooth Connection")
            }
            .alert("Agent Required First", isPresented: $showAgentRequiredForAgentBLE) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Before handing Bluetooth over to `ahakeyconfig-agent`, complete \"Install & Enable\" below to create the LaunchAgent.")
            }

            // MARK: - 拨杆状态
            Section {
                HStack {
                    Text("Switch Position")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(bleManager.switchState == 0 ? Color.green : Color.indigo)
                            .frame(width: 10, height: 10)
                            .animation(.easeInOut(duration: 0.1), value: bleManager.switchState)
                        Text(switchStateLabel(bleManager.switchState))
                    }
                }
            } header: {
                Text("Switch Position")
            }

            // MARK: - LED 状态同步
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(agentManager.isRunning ? Color.green : Color.gray.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text("LED Follows IDE State")
                            Text(agentBluetoothShortLabel())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            hookBadge("Claude", installed: agentManager.claudeHooksInstalled)
                            hookBadge("Cursor", installed: agentManager.cursorHooksInstalled)
                            hookBadge("Codex", installed: agentManager.codexHooksInstalled)
                            hookBadge("Kimi", installed: agentManager.kimiHooksInstalled)
                        }
                        .font(.caption)
                    }
                    Spacer()
                    if agentManager.isInstalled {
                        Button(agentManager.isRunning ? "Stop" : "Start") {
                            if agentManager.isRunning {
                                agentManager.stop()
                            } else {
                                agentManager.start()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(agentManager.bluetoothConnectionOwner == .ahaKeyStudio)
                        .help(agentManager.bluetoothConnectionOwner == .ahaKeyStudio
                              ? "Bluetooth is currently used by this App, so the Agent should not be loaded. Select Agent under \"Bluetooth Connection\" above before starting or stopping the daemon."
                              : "Load and start / unload and stop the Agent process via launchd.")

                        Button("Uninstall", role: .destructive) {
                            agentManager.uninstall(bleManager: bleManager)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        HStack(spacing: 8) {
                            if agentManager.isAgentOperationInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Button("Install & Enable") {
                                agentManager.install()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(agentManager.isAgentOperationInProgress)
                        }
                    }
                }

                if agentManager.isInstalled {
                    HStack(spacing: 10) {
                        Button("View Logs") {
                            showAgentLog.toggle()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)

                        Spacer()

                        if agentManager.claudeHooksInstalled {
                            Button("Remove Claude Hooks") { agentManager.removeClaudeHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        } else {
                            Button("Install Claude Hooks") { agentManager.installClaudeHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        if agentManager.cursorHooksInstalled {
                            Button("Remove Cursor Hooks") { agentManager.removeCursorHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        } else {
                            Button("Install Cursor Hooks") { agentManager.installCursorHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        if agentManager.codexHooksInstalled {
                            Button("Remove Codex Hooks") { agentManager.removeCodexHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        } else {
                            Button("Install Codex Hooks") { agentManager.installCodexHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        if agentManager.kimiHooksInstalled {
                            Button("Remove Kimi Hooks") { agentManager.removeKimiHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        } else {
                            Button("Install Kimi Hooks") { agentManager.installKimiHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }
                }
            } header: {
                Text("LED Status Sync · Hook Integration")
            } footer: {
                if !agentManager.isAgentBinaryPresentInBundle {
                    Text("The release bundle does not include ahakeyconfig-agent, so the daemon is unavailable. Use the full \"AhaKey Studio.app\" or contact the developer.")
                        .foregroundStyle(.orange)
                } else if agentManager.isInstalled, agentManager.bluetoothConnectionOwner == .ahaKeyStudio, !agentManager.isRunning {
                    Text("Bluetooth is used by this App: to let the Agent take over, set \"Bluetooth Connection\" to ahakeyconfig-agent.")
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $showAgentLog) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Diagnostic Log")
                            .font(.headline)
                        Spacer()
                        Button("Close") { showAgentLog = false }
                    }
                    Picker("Content", selection: $agentLogPanel) {
                        Text("ahakeyconfig-agent Main Log").tag(0)
                        Text("Tool Approvals (permission-request.log)").tag(1)
                        Text("~/.cursor/hooks.json").tag(2)
                        Text("~/.cursor/cli-config.json").tag(3)
                        Text("~/.codex/config.toml").tag(4)
                        Text("Codex Hook (codex-hook.log)").tag(5)
                        Text("~/.kimi/config.toml").tag(6)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    HStack {
                        Button("Refresh") {
                            logPanelContentTick += 1
                            agentManager.refresh()
                        }
                        if agentLogPanel == 3 {
                            Button("Merge CLI + IDE Terminal Allowlist") {
                                let a = agentManager.mergeUserCursorCliConfigForShellAutoApprove()
                                let b = agentManager.mergeUserCursorPermissionsJsonForAgentTUI()
                                agentManager.agentUserAlert = a + "\n\n——\n\n" + b
                            }
                            .help("Writes cli-config (CLI) and the terminalAllowlist in permissions.json (the Agent TUI \"Not in allowlist\" layer); see the official documentation for each. Both are backed up as .ahakey.bak first.")
                        }
                        Spacer()
                    }
                    .font(.caption)
                    ScrollView {
                        logPanelContent
                            .id(logPanelContentTick)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .frame(width: 540, height: 380)
            }

            // MARK: - LED 测试
            if bleManager.isConnected {
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        ForEach(Array(IDEState.allCases.enumerated()), id: \.offset) { _, state in
                            Button {
                                bleManager.updateIDEState(state)
                            } label: {
                                Text(state.label)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text("LED Test")
                } footer: {
                    Text("Click a button to send the corresponding state to the keyboard and watch the LED change.")
                }
            }

            // MARK: - BLE 连接状态
            Section {
                CompatLabeledContent("Connection") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(bleManager.isConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(bleManager.bleConnectionStatus)
                    }
                }
                CompatLabeledContent("Device Name") {
                    if isEditingName {
                        HStack(spacing: 4) {
                            TextField("Max 15 bytes", text: $editableName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                                .onSubmit { submitNameChange() }
                            Button("Save") { submitNameChange() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            Button("Cancel") { isEditingName = false }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Text(bleManager.deviceName ?? "—")
                                .textSelection(.enabled)
                            if bleManager.isConnected {
                                Button {
                                    editableName = bleManager.deviceName ?? ""
                                    isEditingName = true
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                CompatLabeledContent("UUID") {
                    Text(bleManager.bleDeviceUUID)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                HStack {
                    CompatLabeledContent("Characteristics") {
                        HStack(spacing: 8) {
                            charBadge("DATA", ready: bleManager.dataCharReady)
                            charBadge("CMD", ready: bleManager.commandCharReady)
                            charBadge("NOTIFY", ready: bleManager.notifyCharReady)
                        }
                    }
                }
            } header: {
                Text("BLE Connection Status")
            }

            // MARK: - 操作
            Section {
                HStack {
                    if !bleManager.isConnected {
                        Button(bleManager.isScanning ? "Scanning…" : "Connect Device") {
                            bleManager.userInitiatedConnect()
                        }
                        .buttonStyle(.bordered)
                        .disabled(bleManager.isScanning || agentManager.bluetoothConnectionOwner == .agentDaemon)
                        .help(agentManager.bluetoothConnectionOwner == .agentDaemon
                              ? "Bluetooth is currently assigned to ahakeyconfig-agent. Switch to AhaKey Studio under \"Bluetooth Connection\" above, or use the \"Device Info · Agent\" menu bar item to switch."
                              : "This App actively connects to the keyboard.")
                    } else {
                        Button("Query Status") {
                            bleManager.queryDeviceStatus()
                        }
                        .buttonStyle(.bordered)
                        .help("Send AA BB 00 CC DD to query device status")

                        Button("Probe Protocol") {
                            bleManager.sendProbeCommands()
                        }
                        .buttonStyle(.bordered)
                        .help("Send probe commands to the device and watch the callbacks in the communication log")

                        Spacer()

                        Button("Disconnect", role: .destructive) {
                            bleManager.disconnect()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            // MARK: - 通信日志
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(bleManager.commLog) { entry in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(entry.formattedTime)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 80, alignment: .leading)
                                        Text(entry.message)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(entry.isError ? .red : .secondary)
                                            .textSelection(.enabled)
                                    }
                                    .id(entry.id)
                                }
                            }
                            .padding(8)
                        }
                        .frame(height: 150)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onChange(of: bleManager.commLog.count) { _ in
                            if let last = bleManager.commLog.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Copy All") {
                            let text = bleManager.commLog.map { "[\($0.formattedTime)] \($0.message)" }.joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        Button("Clear") {
                            bleManager.clearLog()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(.top, 4)
                }
            } header: {
                Text("Communication Log")
            }
        }
        // 「设备信息」在 sheet 中展示时，父视图的 `.alert` 往往不会置顶显示，导致 Hooks 安装/报错像「无反应」。在此重复绑定以确保可见。
        .alert("Agent", isPresented: Binding(
            get: { agentManager.agentUserAlert != nil },
            set: { if !$0 { agentManager.agentUserAlert = nil } }
        )) {
            Button("OK", role: .cancel) {
                agentManager.agentUserAlert = nil
            }
        } message: {
            Text(agentManager.agentUserAlert ?? "")
        }

    }

    // MARK: - Components

    private func infoCell(_ label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }

    private func hookBadge(_ label: String, installed: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(installed ? .green : .secondary)
            Text("\(label) Hooks")
                .foregroundStyle(installed ? .primary : .secondary)
        }
    }

    private func charBadge(_ label: String, ready: Bool) -> some View {
        Text(label)
            .font(.system(.caption2, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(ready ? Color.green.opacity(0.15) : Color.gray.opacity(0.1))
            )
            .foregroundStyle(ready ? Color.green : Color.secondary)
    }

    private func switchStateLabel(_ state: Int) -> String {
        state == 0 ? "Auto Approve" : "Manual Approve"
    }

    private func agentBluetoothStatusText() -> String {
        if agentManager.isRunning && agentManager.isAgentBLEConnected { return "Agent is connected via Bluetooth" }
        if agentManager.isRunning { return "Agent running (BLE not connected)" }
        if agentManager.isInstalled { return "Agent not running" }
        return "Agent not installed"
    }

    private func agentBluetoothShortLabel() -> String {
        if agentManager.isRunning && agentManager.isAgentBLEConnected { return "BLE connected" }
        if agentManager.isRunning { return "BLE not connected" }
        if agentManager.isInstalled { return "Not running" }
        return "Agent not installed"
    }

    private func workModeName(_ mode: Int) -> String {
        switch mode {
        case 0: return "Mode 1 / Claude"
        case 1: return "Mode 2 / Cursor"
        case 2: return "Mode 3 / Codex"
        case 3: return "Mode 4 / custom"
        default: return "Mode \(mode)"
        }
    }

    private func lightModeName(_ mode: Int) -> String {
        switch mode {
        case 0: return "Off"
        case 1: return "Steady"
        case 2: return "Breathing"
        default: return "\(mode)"
        }
    }

    @ViewBuilder
    private var logPanelContent: some View {
        switch agentLogPanel {
        case 0:
            Text(agentManager.readLog())
        case 1:
            Text(agentManager.readPermissionRequestLog())
        case 2:
            Text(agentManager.readUserCursorHooksJsonForDisplay())
        case 3:
            Text(agentManager.readUserCursorCliConfigForDisplay())
        case 4:
            Text(agentManager.readUserCodexConfigForDisplay())
        case 5:
            Text(agentManager.readCodexHookLog())
        case 6:
            Text(agentManager.readUserKimiConfigForDisplay())
        default:
            Text("")
        }
    }

    private func submitNameChange() {
        let name = editableName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        bleManager.changeDeviceName(name)
        isEditingName = false
    }
}
