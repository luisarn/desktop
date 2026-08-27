import AppKit
import CoreImage
import Darwin
import SwiftUI
import UniformTypeIdentifiers

struct AhaKeyStudioView: View {
    @ObservedObject var bleManager: AhaKeyBLEManager
    @StateObject private var voiceRelay = VoiceRelayService.shared
    @StateObject private var nativeSpeech = NativeSpeechTranscriptionService.shared
    @StateObject private var ahaType = AhaTypeTextOptimizer.shared
    @StateObject private var cloudAccount = CloudAccountManager.shared
    @StateObject private var agentManager = AgentManager.shared

    @State private var studioDraft: AhaKeyStudioDraft
    @State private var lastSyncedDraft: AhaKeyStudioDraft
    @State private var selectedMode: AhaKeyModeSlot
    @State private var selectedPart: AhaKeyStudioPart
    @State private var lightBarPreview: IDEState
    @State private var modeCustomNames: [Int: String] = [:]
    @State private var lastSyncDate: Date?
    @State private var syncStatusMessage = "Changes are saved locally first, then synced once the device connects."
    @State private var isSyncing = false
    // AhaKeyStudio 交还蓝牙给 Agent 的过渡期：保持"已连接"显示，直到 Agent 接管或超时。
    @State private var isTransitioningToKeyboardControl = false
    @State private var showsOLEDPlaybackPreview = false
    @State private var showsDeviceInfo = false
    @State private var showsCloudAccount = false
    @State private var showsAhaTypeLoginRequiredToast = false
    @AppStorage(UnifiedOnboardingStorage.completedKey) private var unifiedOnboardingCompleted = false
    @State private var isEditingInspector = false
    @State private var showsDiagnostics = false
    @State private var showsKeyHelp = false
    @State private var selectedTriggerTab: Int = 0
    /// 每次主 App 自占 BLE 连接成功只跑一次默认 LCD 自动同步。
    /// .onChange(of: isConnected) 在断开时重置；下次重连时再触发一次。
    @State private var oledAutoSyncDoneForConnection: Bool = false
    @State private var showsHelpCenter = false
    @State private var showsGuidanceDetail = false
    @State private var editingModeSlot: AhaKeyModeSlot?
    @State private var editingModeName: String = ""
    @FocusState private var modeNameFieldFocused: Bool
    @State private var showsWriteResultAlert = false
    @State private var writeResultAlertMessage = ""

    init(bleManager: AhaKeyBLEManager) {
        self.bleManager = bleManager
        let initialDraft = AhaKeyStudioStore.load() ?? .default
        // 注意：不要在这里调用 VoiceRelayService.updateRoutes —— SwiftUI 会因 bleManager
        // 的 @Published 属性（workMode/电量/连接状态等）频繁重建 view，init 会跟着多次执行。
        // 任何在 init 里调用 updateRoutes 都会重置 functionRelay 的 holdingRoute（按住状态），
        // 导致微信等"按住说话"过几秒就自动结束。正确入口在下面的 .onAppear。
        _studioDraft = State(initialValue: initialDraft)
        _lastSyncedDraft = State(initialValue: initialDraft)
        let initialMode = AhaKeyModeSlot(rawValue: bleManager.workMode) ?? .mode0
        _selectedMode = State(initialValue: initialMode)
        _selectedPart = State(initialValue: .key1)
        _lightBarPreview = State(initialValue: .preToolUse)
        _modeCustomNames = State(initialValue: AhaKeyModeNameStore.load())
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                canvasPane
                Divider()
                inspectorPane
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 1180, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            agentManager.applyStoredBluetoothPreferenceOnLaunch(bleManager: bleManager)
            voiceRelay.start()
            nativeSpeech.start()
            bleManager.refreshBluetoothAuthorization()
            applyCursorRejectMacroSelfHealIfNeeded()
            voiceRelay.updateRoutes(from: studioDraft)
            SwitchStateNotifier.shared.bind(to: bleManager)
            NotificationCenter.default.post(
                name: .ahaKeyKeyboardWorkModeChanged,
                object: nil,
                userInfo: ["workMode": bleManager.workMode]
            )
            scheduleStartupPermissionOnboarding()
        }
        .onChange(of: studioDraft) { newValue in
            AhaKeyStudioStore.save(newValue)
            voiceRelay.updateRoutes(from: newValue)
        }
        // 键盘物理档位变化（BLE 查询/通知上报）→ 自动切到对应 Mode 标签，
        // 这样 LCD 预览、快捷键草稿、发出去的 updateState 三者一致。
        .onChange(of: bleManager.workMode) { newValue in
            if let slot = AhaKeyModeSlot(rawValue: newValue), slot != selectedMode {
                selectedMode = slot
            }
        }
        .onChange(of: selectedMode) { newValue in
            guard bleManager.isConnected,
                  bleManager.commandCharReady,
                  bleManager.workMode != newValue.rawValue else { return }
            bleManager.setWorkMode(UInt8(newValue.rawValue))
            syncStatusMessage = "Keyboard notified to switch to \(newValue.title)."
        }
        .onChange(of: bleManager.isConnected) { connected in
            if !connected { oledAutoSyncDoneForConnection = false }
        }
        .onChange(of: bleManager.keyboardPictureStates) { _ in
            guard !oledAutoSyncDoneForConnection else { return }
            // 四个 mode 都查回来才动手
            guard bleManager.keyboardPictureStates.count == AhaKeyModeSlot.allCases.count else { return }
            oledAutoSyncDoneForConnection = true
            Task { await autoSyncDefaultOLEDsIfNeeded() }
        }
        .onChange(of: bleManager.bluetoothPermissionGranted) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: bleManager.bluetoothPoweredOn) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: voiceRelay.inputMonitoringGranted) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: voiceRelay.accessibilityGranted) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: nativeSpeech.microphoneGranted) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: nativeSpeech.speechRecognitionGranted) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: nativeSpeech.siriEnabled) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: nativeSpeech.dictationEnabled) { _ in
            refreshStartupPermissionOnboarding()
        }
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
        .alert("AhaType Not Signed In", isPresented: $showsAhaTypeLoginRequiredToast) {
            Button("Got It", role: .cancel) {}
            Button("Sign Up / Log In") {
                showsCloudAccount = true
            }
        } message: {
            Text("Please sign up or log in to AhaType before enabling cloud cleanup.")
        }
        .sheet(isPresented: $showsOLEDPlaybackPreview) {
            OLEDMotionPreviewSheet(
                modeTitle: selectedMode.title,
                assetPath: currentModeDraft.oled.localAssetPath
            )
        }
        .sheet(isPresented: $showsDeviceInfo) {
            DeviceInfoSheetContainer(bleManager: bleManager)
                .frame(width: 720, height: 720)
        }
        .sheet(isPresented: $showsCloudAccount) {
            CloudAccountView()
                .frame(width: 520, height: 620)
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text("AhaKey Studio")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
            }
            .layoutPriority(1)

            HStack(spacing: 8) {
                infoPill(
                    title: isEffectivelyConnected ? "Connected" : (bleManager.isScanning ? "Scanning" : "Not Connected"),
                    // 未连接时不再笼统显示「等待设备」，而是给出细分链路诊断（Issue #34）。
                    subtitle: isEffectivelyConnected ? (bleManager.deviceName ?? "Connected") : bleManager.linkDiagnostic.shortMessage,
                    accent: isEffectivelyConnected ? .green : .orange,
                    width: 118
                )
                .help(isEffectivelyConnected ? "" : bleManager.linkDiagnostic.detail)
                infoPill(
                    title: "Battery",
                    subtitle: isEffectivelyConnected ? "\(bleManager.batteryLevel)%" : "—",
                    accent: .blue
                )
                infoPill(
                    title: "Switch",
                    subtitle: currentSwitchTitle,
                    accent: currentSwitchTitle == "Auto-Approve" ? .mint : .indigo
                )
            }
            .layoutPriority(2)

            Spacer(minLength: 0)

            if !bleManager.isConnected, agentManager.bluetoothConnectionOwner == .ahaKeyStudio {
                Button(bleManager.isScanning ? "Scanning…" : "Connect Device") {
                    bleManager.userInitiatedConnect()
                }
                .buttonStyle(.bordered)
                .disabled(bleManager.isScanning)
            }

            ahaTypeModeStatus

            configurationModeControl

            if shouldShowTopBarInstallStartButton {
                Button("Install & Start") {
                    installStartAgentFromTopBar()
                }
                .buttonStyle(.borderedProminent)
                .disabled(agentManager.isAgentOperationInProgress)
                .help("Install or repair the Agent and hooks, then start Agent keyboard control.")
            }

            Button {
                NSPasteboard.general.clearContents()
            } label: {
                Image(systemName: "arrow.counterclockwise.circle")
                    .imageScale(.medium)
            }
            .buttonStyle(.bordered)
            .help("Clear Clipboard")

            Menu {
                Button("Restore Current Mode Defaults") {
                    restoreCurrentModeDefaults()
                }
                Button("Reconnect Device") {
                    bleManager.disconnect()
                    bleManager.userInitiatedConnect()
                }
                Button("Device Info · Agent…") {
                    showsDeviceInfo = true
                }
                Divider()
                Button("Cloud Account · AhaType…") {
                    showsCloudAccount = true
                }
                Button("Refresh AhaType Status") {
                    ahaType.refreshFromDisk()
                }
                Divider()
                Button("Hide to Background") {
                    NSApp.keyWindow?.close()
                }
                Button("Quit AhaKey Studio") {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 32, height: 28)
            .help("More")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(chromeBarBackground)
    }

    private var configurationModeStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isEditingConfiguration ? Color.blue : Color.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(isEditingConfiguration ? "Editing Config" : "Keyboard Control")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(configurationModeDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Image(systemName: isEditingConfiguration ? "checkmark.circle" : "pencil.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEditingConfiguration ? Color.blue : Color.green)
        }
        .frame(width: 138, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var configurationModeControl: some View {
        Button(action: handleConfigurationModeButton) {
            configurationModeStatus
        }
        .buttonStyle(.plain)
        .disabled(isSyncing)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(configurationModeButtonTitle)
        .accessibilityHint(configurationModeButtonHelp)
        .help(configurationModeButtonHelp)
    }

    private var ahaTypeModeStatus: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(ahaType.isEnabled ? Color.green : Color.gray.opacity(0.55))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(ahaType.isEnabled ? "AhaType On" : "AhaType Off")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(ahaType.isEnabled ? "Cloud cleanup enabled" : "Voice results pasted directly")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Toggle("", isOn: Binding(
                get: { ahaType.isEnabled },
                set: { enabled in
                    if enabled, !cloudAccount.isLoggedIn {
                        showsAhaTypeLoginRequiredToast = true
                    } else {
                        ahaType.setEnabled(enabled)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .frame(width: 150, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .help("When on, native macOS voice transcription is cleaned up by AhaType cloud before being pasted at the cursor.")
    }

    private var canvasPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            modeEditorHeader

            VStack(alignment: .leading, spacing: 8) {
                AhaKeyKeyboardCanvasView(
                    modeDraft: currentModeDraft,
                    selectedPart: selectedPart,
                    lightBarPreview: lightBarPreview,
                    switchTitle: currentSwitchTitle,
                    dirtyParts: dirtyPartsForCurrentMode(),
                    onSelect: { selectedPart = $0 },
                    onModeSwitch: { cycleModeForward() },
                    onSwitchToggle: { toggleVirtualSwitch() },
                    liveLightMode: liveCanvasLightMode,
                    liveIDEStateValue: liveCanvasIDEStateValue,
                    switchState: liveCanvasSwitchState,
                    keyboardPictureFrameCount: bleManager.keyboardPictureStates[selectedMode.rawValue]?.frameCount
                )
                .aspectRatio(109.0 / 54.0, contentMode: .fit)
                .frame(maxWidth: .infinity)

                Text("Tap the light bar, screen, any of the four keys, or the switch to edit its settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func modeTabItem(_ mode: AhaKeyModeSlot) -> some View {
        let isSelected = selectedMode == mode
        let isEditing = editingModeSlot == mode

        if isEditing {
            TextField("", text: $editingModeName, onCommit: { commitModeNameEdit() })
                .textFieldStyle(.plain)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .focused($modeNameFieldFocused)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(Color.accentColor.opacity(0.15))
                .onExitCommand { commitModeNameEdit() }
                .onAppear { modeNameFieldFocused = true }
                .onChange(of: modeNameFieldFocused) { focused in
                    if !focused { commitModeNameEdit() }
                }
        } else {
            Text(modeCustomNames[mode.rawValue] ?? mode.defaultName)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    commitModeNameEdit()
                    editingModeName = modeCustomNames[mode.rawValue] ?? mode.defaultName
                    editingModeSlot = mode
                    selectedMode = mode
                }
                .onTapGesture(count: 1) {
                    commitModeNameEdit()
                    selectedMode = mode
                }
        }
    }

    private func commitModeNameEdit() {
        guard let slot = editingModeSlot else { return }
        let capped = String(editingModeName.prefix(30))
        if capped.isEmpty || capped == slot.defaultName {
            modeCustomNames.removeValue(forKey: slot.rawValue)
        } else {
            modeCustomNames[slot.rawValue] = capped
        }
        AhaKeyModeNameStore.save(modeCustomNames)
        editingModeSlot = nil
    }

    private var modeEditorHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("Keyboard Mode")
                    .font(.system(size: 17, weight: .semibold))

                HStack(spacing: 0) {
                    ForEach(AhaKeyModeSlot.allCases) { mode in
                        modeTabItem(mode)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .frame(width: 480)

                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(selectedMode.guidance)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let detail = selectedMode.guidanceHoverDetail {
                    Button {
                        showsGuidanceDetail.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                    .buttonStyle(.borderless)
                    .help(detail)
                    .onHover { showsGuidanceDetail = $0 }
                    .popover(isPresented: $showsGuidanceDetail, arrowEdge: .top) {
                        Text(detail)
                            .font(.callout)
                            .padding(14)
                            .frame(width: 320)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var inspectorPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if isEditingInspector {
                        Label(selectedPart.title, systemImage: selectedPart.systemImage)
                            .font(.system(size: 18, weight: .semibold))

                        Group {
                            switch selectedPart {
                            case .key1, .key2, .key3, .key4: keyInspector
                            case .oledDisplay: oledInspector
                            case .lightBar: lightBarInspector
                            case .toggleSwitch: switchInspector
                            }
                        }

                    } else {
                        inspectorHeader

                        VStack(alignment: .leading, spacing: 0) {
                            partSummaryContent
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.black.opacity(0.07), lineWidth: 1)
                                )
                        )

                        HStack {
                            Spacer()
                            Button {
                                enterEditingConfiguration()
                                withAnimation(.easeInOut(duration: 0.2)) { isEditingInspector = true }
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .keyboardShortcut("e", modifiers: .command)
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(24)
            }

            if isEditingInspector {
                Divider()
                HStack(spacing: 12) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isEditingInspector = false
                            returnToKeyboardControl()
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Spacer()

                    if selectedPart == .lightBar {
                        Button {
                            previewLightEffect(for: lightBarPreview)
                        } label: {
                            Label("Preview on Keyboard", systemImage: "play.fill")
                                .font(.callout.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(isSyncing || !bleManager.isConnected || !bleManager.commandCharReady)
                    }

                    Button {
                        writeToKeyboard()
                    } label: {
                        Label(isSyncing ? "Writing…" : "Write to Keyboard", systemImage: isSyncing ? "arrow.trianglehead.2.clockwise" : "square.and.arrow.down")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(isSyncing || !bleManager.isConnected)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 390)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .onChange(of: selectedPart) { _ in
            commitModeNameEdit()
            withAnimation(.easeInOut(duration: 0.18)) { isEditingInspector = false }
        }
        .onChange(of: selectedMode) { _ in
            if editingModeSlot != nil && editingModeSlot != selectedMode {
                commitModeNameEdit()
            }
        }
        .alert("Write Result", isPresented: $showsWriteResultAlert) {
            Button("Keep Editing", role: .cancel) {}
            Button("Done Editing") {
                if writeResultAlertMessage.contains("success") {
                    completeEditingAfterSuccessfulWrite()
                }
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(writeResultAlertMessage)
        }
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Label(selectedPart.title, systemImage: selectedPart.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                if partIsDirty(selectedPart) {
                    Label("Not Synced", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if selectedPart.isKey {
                    Button {
                        showsKeyHelp.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .imageScale(.medium)
                    }
                    .buttonStyle(.borderless)
                    .onHover { showsKeyHelp = $0 }
                    .popover(isPresented: $showsKeyHelp, arrowEdge: .leading) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("How to Use")
                                .font(.headline)
                            Divider()
                            Text("1. Click a key on the virtual keyboard to select it.")
                            Text("2. Pick a preset for the voice key; choose a single key or macro for the others as needed.")
                            Text("3. When finished, click \"Write to Keyboard\" to sync to the keyboard.")
                            Text("4. When switching modes, the LCD briefly shows the description, then returns to that mode's animation.")
                        }
                        .font(.callout)
                        .padding(16)
                        .frame(width: 270)
                    }
                }
            }
            Text(selectedPart.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 权限诊断弹窗

    private var diagnosticsSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Permission Diagnostics")
                        .font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Button("Close") { showsDiagnostics = false }
                        .buttonStyle(.bordered)
                }

                GroupBox("Background Voice Bridge") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(voiceRelay.isListening ? Color.green : Color.orange)
                                .frame(width: 10, height: 10)
                            Text(voiceRelay.isListening ? "Listening in Background" : "Waiting for System Permissions")
                                .font(.callout.weight(.semibold))
                            Spacer()
                        }
                        HStack(spacing: 10) {
                            permissionBadge(title: "Input Monitoring", granted: voiceRelay.inputMonitoringGranted)
                            permissionBadge(title: "Accessibility", granted: voiceRelay.accessibilityGranted)
                        }
                        Text(voiceRelay.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(voiceRelay.lastPermissionCheckSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(voiceRelay.activeRouteSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("Request Permissions Again") {
                                requestPermissionsThenOpenPrivacySettingsIfNeeded(
                                    bleManager: bleManager,
                                    voiceRelay: voiceRelay,
                                    nativeSpeech: nativeSpeech
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Recheck Permissions") {
                                voiceRelay.refreshPermissions(deferredTCCRequery: true)
                            }
                            .buttonStyle(.bordered)
                            RestartToApplyPermissionsButton()
                        }
                    }
                    .padding(.top, 4)
                }

                GroupBox("Apple Native Transcription") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(nativeSpeech.isRecording ? Color.red : (nativeSpeech.microphoneGranted && nativeSpeech.speechRecognitionGranted ? Color.green : Color.orange))
                                .frame(width: 10, height: 10)
                            Text(nativeSpeech.isRecording ? "Recording & Transcribing" : "Waiting for Trigger")
                                .font(.callout.weight(.semibold))
                            Spacer()
                        }
                        HStack(spacing: 10) {
                            permissionBadge(title: "Microphone", granted: nativeSpeech.microphoneGranted)
                            permissionBadge(title: "Speech Recognition", granted: nativeSpeech.speechRecognitionGranted)
                            permissionBadge(title: "Siri", granted: nativeSpeech.siriEnabled)
                            permissionBadge(title: "Dictation", granted: nativeSpeech.dictationEnabled)
                        }
                        Text(nativeSpeech.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(nativeSpeech.lastPermissionCheckSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Divider()

                        HStack(spacing: 10) {
                            Circle()
                                .fill(nativeSpeech.isRecording ? Color.red : Color.clear)
                                .frame(width: 8, height: 8)
                            Text(nativeSpeech.isRecording ? "Recording" : "Transcription Test")
                                .font(.callout.weight(.semibold))
                            Spacer()
                            if !nativeSpeech.transcriptPreview.isEmpty {
                                Text(nativeSpeech.transcriptPreview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else if !nativeSpeech.lastCommittedText.isEmpty {
                                Text("Last written: \(nativeSpeech.lastCommittedText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        HStack(spacing: 8) {
                            Button(nativeSpeech.isRecording ? "Stop & Insert" : "Start Recording") {
                                nativeSpeech.toggleRecordingFromVoiceKey()
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Recheck Permissions") {
                                nativeSpeech.refreshPermissions(deferredTCCRequery: true)
                            }
                            .buttonStyle(.bordered)
                            RestartToApplyPermissionsButton()
                            if !nativeSpeechPermissionsReady {
                                Button("Open System Settings") { openNativeSpeechPrivacySettings() }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                let voiceKey = currentModeDraft.key(for: .voice)
                if let preset = voiceKey.voicePreset, preset == .typeless {
                    GroupBox("Fn Voice Input Method") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Typeless / WeChat Voice / Doubao IME are triggered with F19, injecting Fn press and release.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("For troubleshooting, see voice-relay.log (matched · function relay · post fn). Path: ~/Library/Application Support/AhaKeyConfig/diagnostics/")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Button("Simulate Voice Key Tap") {
                                voiceRelay.simulateInspectorVoiceKeyTap(for: selectedMode)
                            }
                            .buttonStyle(.borderedProminent)
                            if let hint = voiceRelay.lastInspectorSimulateHint {
                                Text(hint)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                GroupBox("AhaType Status") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle(isOn: Binding(
                                get: { ahaType.isEnabled },
                                set: { ahaType.setEnabled($0) }
                            )) {
                                Text("AhaType Cloud Cleanup")
                                    .font(.callout.weight(.semibold))
                            }
                            .toggleStyle(.switch)
                            Spacer()
                            Button("Refresh") { ahaType.refreshFromDisk() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        Text(ahaType.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(ahaType.lastQuotaSummary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(24)
        }
        .frame(width: 500, height: 620)
    }

    // MARK: - Inspector Level 1 Summary

    private func summaryRow(_ title: String, value: String, dot: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            HStack(spacing: 5) {
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 7, height: 7)
                        .offset(y: -1)
                }
                Text(value)
                    .font(.callout)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var partSummaryContent: some View {
        switch selectedPart {
        case .key1:          voiceKeySummary
        case .key2, .key3, .key4: actionKeySummary
        case .oledDisplay:   oledSummary
        case .lightBar:      lightBarSummary
        case .toggleSwitch:  switchSummary
        }
    }

    @ViewBuilder
    private var voiceKeySummary: some View {
        let key = currentSelectedKey
        let preset = key.voicePreset ?? .custom
        summaryRow("Input Method", value: preset.title)
        summaryRow("Shortcut", value: key.displaySummary)
        if preset.isMacOSNativeFamily {
            summaryRow("Trigger", value: "Short Press + Long Press")
            let permCount = [nativeSpeech.microphoneGranted, nativeSpeech.speechRecognitionGranted,
                             nativeSpeech.siriEnabled, nativeSpeech.dictationEnabled].filter { $0 }.count
            summaryRow("Transcription Permissions", value: "\(permCount)/4 granted",
                       dot: permCount == 4 ? .green : .orange)
        }
        summaryRow("Voice Bridge", value: voiceRelay.isListening ? "Running" : "Waiting for Permissions",
                   dot: voiceRelay.isListening ? .green : .orange)
        summaryRow("Key Description", value: key.description.isEmpty ? "—" : key.description)
    }

    @ViewBuilder
    private var actionKeySummary: some View {
        let key = currentSelectedKey
        summaryRow("Binding", value: key.displaySummary)
        summaryRow("Type", value: key.usesMacro ? "Firmware Macro (\(key.macro.count) steps)" : "Single Key / Combo")
        summaryRow("Key Description", value: key.description.isEmpty ? "—" : key.description)
    }

    @ViewBuilder
    private var oledSummary: some View {
        let oled = currentModeDraft.oled
        summaryRow("Animation", value: oled.localAssetPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Default Animation")
        summaryRow("Playback Speed", value: "\(oled.framesPerSecond) FPS")
        summaryRow("Status Line", value: oled.statusLine.isEmpty ? "—" : String(oled.statusLine.prefix(32)))
    }

    @ViewBuilder
    private var lightBarSummary: some View {
        let lb = currentModeDraft.lightBar
        ForEach(IDEState.allCases) { state in
            summaryRow(state.shortLabel, value: lb.effect(for: state).title)
        }
        summaryRow("Brightness", value: "\(lb.brightness)%")
    }

    @ViewBuilder
    private var switchSummary: some View {
        let agentReady = agentManager.isInstalled && agentManager.isRunning && agentManager.hooksInstalled
        summaryRow("Current Position", value: currentSwitchTitle,
                   dot: currentSwitchTitle == "Auto-Approve" ? .green : .indigo)
        summaryRow("Agent", value: agentReady ? "Ready" : "Not Ready",
                   dot: agentReady ? .green : .orange)
        summaryRow("Applies To", value: "Claude · Cursor · Codex · Kimi")
    }

    // MARK: - Inspector Level 2 Detail

    private var keyInspector: some View {
        let key = currentSelectedKey
        return VStack(alignment: .leading, spacing: 16) {
            GroupBox("Key Description") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("e.g. Record / Accept / Reject / Backspace", text: selectedKeyDescriptionBinding)
                        .textFieldStyle(.roundedBorder)
                    if currentSelectedKey.description.containsNonASCII {
                        Text("The device LCD only reliably supports ASCII. Chinese, emoji, and full-width characters are automatically filtered out when writing, to avoid garbled text.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("Actually written to device: \(currentSelectedKeySanitizedDescription.isEmpty ? "blank" : currentSelectedKeySanitizedDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("After syncing to the keyboard, short-pressing a physical key to switch modes briefly shows this description on the LCD before returning to that mode's animation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if selectedMode == .mode0 {
                        Text("Mode 1 default text: Record / Accept / Reject / Backspace")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }

            if key.role == .voice {
                GroupBox("Voice Input Method") {
                    VStack(alignment: .leading, spacing: 12) {
                        VoicePresetPicker(
                            selectedPreset: key.voicePreset ?? .custom,
                            onSelect: applyVoicePreset
                        )
                        if (key.voicePreset ?? .custom).isMacOSNativeFamily {
                            Text("As long as AhaKey Studio runs in the background, the F18 sent by the Mode 1 factory voice key is routed directly to Apple native transcription. The system Dictation shortcut is no longer required.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("The voice key's input method is independent of the current Mode; the same voice input settings work in every Mode.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)
                }
            } else {
                GroupBox("Key Role") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(key.role.manualText)
                            .font(.callout)
                        Text("The shortcut and key description are written to the keyboard together. When switching modes, the device shows the description first, then returns to that mode's LCD animation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // ── 触发方式（短按 / 长按 Tab）──────────────────────────────
            GroupBox("Trigger") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("", selection: $selectedTriggerTab) {
                        Text("Short Press").tag(0)
                        Text("Long Press").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Divider()

                    if key.role == .voice {
                        // ── 语音键触发方式 ──────────────────────────────
                        if selectedTriggerTab == 0 {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Press once to start, press again to stop", systemImage: "hand.tap.fill")
                                    .font(.callout.weight(.semibold))
                                Text("After recording stops, the toggle below decides whether the result is cleaned up by AhaType before being inserted at the cursor.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Toggle(isOn: $nativeSpeech.shortPressAhaTypeEnabled) {
                                    HStack(spacing: 6) {
                                        Text("Use AhaType Cleanup")
                                            .font(.callout)
                                        if !ahaType.isEnabled {
                                            Text("(AhaType master switch is off)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .toggleStyle(.switch)
                                .disabled(!ahaType.isEnabled)

                                Divider()

                                // 绑定摘要（短按 = 语音键 HID 绑定）
                                HStack {
                                    Text(key.displaySummary)
                                        .font(.system(.callout, design: .rounded).weight(.semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(key.usesMacro ? "Firmware Macro" : "Raw HID")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Picker("", selection: selectedKeyBindingModeBinding) {
                                    Text("Single Key / Combo").tag(KeyBindingMode.shortcut)
                                    Text("Macro").tag(KeyBindingMode.macro)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .disabled((key.voicePreset ?? .custom) != .custom)
                                if key.usesMacro {
                                    macroEditor(for: key)
                                } else {
                                    ShortcutBindingEditor(shortcut: selectedKeyShortcutBinding)
                                }
                                Text(voicePresetDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if (key.voicePreset ?? .custom) != .custom {
                                    Text("Voice key presets always use a single-key binding; to record a macro, first change the preset to a custom shortcut.")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        } else {
                            // 长按 Tab（语音键）— 始终开启，仅配置 AhaType 与阈值
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Hold to record, release to send", systemImage: "hand.draw.fill")
                                    .font(.callout.weight(.semibold))
                                Text("Hold the keyboard record key to start recording; releasing it inserts the ASR result immediately, with faster response.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Toggle(isOn: $nativeSpeech.longPressAhaTypeEnabled) {
                                    HStack(spacing: 6) {
                                        Text("Use AhaType Cleanup")
                                            .font(.callout)
                                        if !ahaType.isEnabled {
                                            Text("(AhaType master switch is off)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .toggleStyle(.switch)
                                .disabled(!ahaType.isEnabled)
                                HStack(spacing: 10) {
                                    Text("Trigger Threshold")
                                        .font(.callout)
                                    Slider(
                                        value: Binding(
                                            get: { Double(nativeSpeech.longPressThresholdMs) },
                                            set: { nativeSpeech.longPressThresholdMs = Int($0) }
                                        ),
                                        in: 200...1000,
                                        step: 50
                                    )
                                    Text("\(nativeSpeech.longPressThresholdMs) ms")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 58, alignment: .trailing)
                                }
                            }
                        }
                    } else {
                        // ── 普通键触发方式 ──────────────────────────────
                        if selectedTriggerTab == 0 {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(key.displaySummary)
                                        .font(.system(.callout, design: .rounded).weight(.semibold))
                                        .lineLimit(2)
                                    Spacer()
                                    Text(key.usesMacro ? "Firmware Macro" : "Raw HID")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Picker("", selection: selectedKeyBindingModeBinding) {
                                    Text("Single Key / Combo").tag(KeyBindingMode.shortcut)
                                    Text("Macro").tag(KeyBindingMode.macro)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                if key.usesMacro {
                                    macroEditor(for: key)
                                } else {
                                    ShortcutBindingEditor(shortcut: selectedKeyShortcutBinding)
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Requires Firmware v2+", systemImage: "exclamationmark.triangle")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.orange)
                                Text("Binding a different shortcut to long-press requires a firmware upgrade; currently only the short-press binding is written to the device.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .onChange(of: selectedPart) { _ in selectedTriggerTab = 0 }

        }
    }

    // MARK: - 宏编辑器视图

    @ViewBuilder
    private func macroEditor(for key: AhaKeyKeyDraft) -> some View {
        let stepCount = key.macro.count
        let byteCount = stepCount * 2
        let overLimit = byteCount > 98 // 固件 payload 上限

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Steps (run in order)")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("\(stepCount) steps · \(byteCount) / 98 bytes")
                    .font(.caption)
                    .foregroundStyle(overLimit ? .red : .secondary)
            }

            if key.macro.isEmpty {
                Text("Empty macro. Click \"Add Step\" below to start recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(key.macro.enumerated()), id: \.element.id) { index, step in
                        macroStepRow(
                            index: index,
                            step: step,
                            totalCount: key.macro.count
                        )
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    appendMacroStep()
                } label: {
                    Label("Add Step", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(overLimit)

                Button(role: .destructive) {
                    updateSelectedKey { $0.macro = [] }
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(key.macro.isEmpty)
            }

            if overLimit {
                Text("Exceeds the firmware per-key macro limit of 98 bytes / 49 steps; sync will be rejected.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("The firmware sends steps serially in order; the delay unit is 3 ms (max 765 ms). Stack multiple delay steps for longer delays.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !key.macro.isEmpty {
                Text("Preview: \(key.macro.displaySummary)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func macroStepRow(index: Int, step: MacroStep, totalCount: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            Picker("", selection: macroStepActionBinding(id: step.id)) {
                ForEach(MacroAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 96)

            if step.action.takesKeycodeParam {
                Picker("", selection: macroStepKeycodeBinding(id: step.id)) {
                    Text("Not Set").tag(UInt8(0))
                    ForEach(HIDUsage.allOptions, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(minWidth: 96)
            } else if step.action.takesDelayParam {
                // 勿对带标题的 Stepper 用 labelsHidden()，否则连「15 ms」一并被藏掉。
                HStack(spacing: 8) {
                    Text("\(max(1, Int(step.param)) * 3) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                        .frame(minWidth: 44, alignment: .trailing)
                    Stepper(
                        "",
                        value: macroStepDelayBinding(id: step.id),
                        in: 1...255
                    )
                    .labelsHidden()
                }
                .frame(minWidth: 120)
            } else {
                Color.clear.frame(minWidth: 96, maxHeight: 1)
            }

            Spacer(minLength: 0)

            Button {
                moveMacroStep(from: index, by: -1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)

            Button {
                moveMacroStep(from: index, by: 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(index >= totalCount - 1)

            Button(role: .destructive) {
                removeMacroStep(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }

    private func macroStepActionBinding(id: UUID) -> Binding<MacroAction> {
        Binding(
            get: {
                currentSelectedKey.macro.first { $0.id == id }?.action ?? .noOp
            },
            set: { newAction in
                updateMacroStep(id: id) { step in
                    let previous = step.action
                    step.action = newAction
                    // 动作换类别后清零 param，避免把 "Enter 的 HID 码 0x28" 当成延时值 ×3ms 解读。
                    if previous.takesKeycodeParam != newAction.takesKeycodeParam
                        || previous.takesDelayParam != newAction.takesDelayParam
                    {
                        switch newAction {
                        case .delay:
                            step.param = 5 // 默认 15ms，比较通用
                        case .downKey, .upKey:
                            step.param = HIDUsage.enter
                        case .noOp, .upAllKeys:
                            step.param = 0
                        }
                    }
                }
            }
        )
    }

    private func macroStepKeycodeBinding(id: UUID) -> Binding<UInt8> {
        Binding(
            get: {
                currentSelectedKey.macro.first { $0.id == id }?.param ?? 0
            },
            set: { newValue in
                updateMacroStep(id: id) { $0.param = newValue }
            }
        )
    }

    private func macroStepDelayBinding(id: UUID) -> Binding<UInt8> {
        Binding(
            get: {
                currentSelectedKey.macro.first { $0.id == id }?.param ?? 0
            },
            set: { newValue in
                updateMacroStep(id: id) { $0.param = newValue }
            }
        )
    }

    private var oledInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("LCD Animation for Current Mode") {
                VStack(alignment: .leading, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.9))
                            .frame(height: 140)

                        if let image = currentOLEDPreviewImage {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 112)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            VStack(spacing: 10) {
                                Image(systemName: "photo.artframe")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.white.opacity(0.8))
                                Text("Only animations are supported for now")
                                    .foregroundStyle(.white.opacity(0.85))
                                Text("Text, token, and model status display are in development")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Choose GIF or Image") {
                            selectOLEDGIF()
                        }
                        .buttonStyle(.bordered)

                        Button("Preview Animation") {
                            showsOLEDPlaybackPreview = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(currentModeDraft.oled.localAssetPath == nil)

                        Button("Clear") {
                            clearCurrentOLED()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Text("Current target: \(selectedMode.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Stepper(value: oledFramesPerSecondBinding, in: 1 ... 30) {
                        Text("Playback Speed \(currentModeDraft.oled.framesPerSecond) FPS")
                    }

                    Text("Hard limits: source file ≤ 2 MB, FPS 1–30, max 70 frames per mode; Mode 1/2/3/4 are written to fixed slots 10/80/150/220.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(currentModeDraft.oled.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            GroupBox("Display Logic") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("When switching to this mode, the LCD first shows the mode's key descriptions, then returns to the mode animation after about 1 second.")
                    Text("Text status, token usage, model environment, and other info displays will be added later.")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var lightBarInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            if bleManager.supportsConfigurableLighting == false {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("The current keyboard firmware does not support writable lighting effects", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text("Old v1.0 firmware returns \"success\" for the unimplemented 0x84/0x85/0x91 commands but does not change the lights. Please flash firmware dated 2026-06-22 or later; the client no longer treats these fake ACKs as successful writes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if bleManager.supportsConfigurableLighting == true {
                Label("New lighting protocol ready (0x84 / 0x85 / 0x91)", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            GroupBox("Status Light Mapping") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(IDEState.workflowOrder) { state in
                        HStack {
                            Text(state.shortLabel)
                                .font(.callout.weight(.medium))
                                .frame(width: 80, alignment: .leading)
                            Picker("", selection: lightEffectBinding(for: state)) {
                                ForEach(LightEffectStyle.allCases) { effect in
                                    Text(effect.title).tag(effect)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.top, 4)
            }

            GroupBox("Brightness") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Slider(value: brightnessBinding, in: 1...100, step: 1)
                        Text("\(currentModeDraft.lightBar.brightness)%")
                            .font(.callout.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .padding(.top, 4)
            }

            GroupBox("State Preview") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(lightBarPreview.shortLabel)
                        .font(.system(.title3, design: .rounded).weight(.semibold))

                    Text("Canvas preview: \(currentModeDraft.lightBar.effect(for: lightBarPreview).title)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Clicking a state previews it on the virtual keyboard and temporarily on the device via 0x91; use the common button at the bottom to save.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                        ForEach(IDEState.workflowOrder) { state in
                            Button {
                                lightBarPreview = state
                                previewLightEffect(for: state)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(state.shortLabel)
                                        .font(.caption.weight(.semibold))
                                    Text(currentModeDraft.lightBar.effect(for: state).title)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(state == lightBarPreview ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(state == lightBarPreview ? Color.accentColor : Color.black.opacity(0.08), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var switchInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Live Position") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(currentSwitchTitle)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                        Spacer()
                        Circle()
                            .fill(currentSwitchTitle == "Auto-Approve" ? Color.green : Color.indigo)
                            .frame(width: 10, height: 10)
                    }
                    Text("The switch is a physical position, not a momentary press. Position 0 shows \"Auto-Approve\", position 1 shows \"Manual Approval\". This only reads the position reported by the keyboard and does not simulate physical toggling.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            switchEffectivenessBox

            if bleManager.switchState == 0 {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Auto-approve requires the Agent and hooks, and Bluetooth must be owned by the Agent", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout.weight(.semibold))
                        Text("Claude: PermissionRequest allow. Cursor: preToolUse etc. with cli-config. Codex: PermissionRequest allow. Kimi: after installing AhaKey Kimi Hooks, **the switch directly takes over auto-approval for the current session**; if you just installed or upgraded kimi-cli, please **fully quit and reopen kimi once**. The hook's stdout only has special interception semantics for **`permissionDecision: deny`**. The Agent must be running and own Bluetooth.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            GroupBox("Understanding This Part") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The switch applies to Claude / Cursor / Codex / Kimi **simultaneously**, regardless of the keyboard's current Mode. The Agent listens to all IDE hooks in the background; flipping the switch immediately changes approval behavior in all four IDEs.")
                    Divider()
                    Text("Auto-approve: **Claude / Codex PermissionRequest**, **Cursor preToolUse** (incl. cli-config). **Kimi**: after installing AhaKey Kimi Hooks, the switch directly takes over **the current session's** auto-approval; if you just installed or upgraded kimi-cli, reopen kimi once.")
                    Text("Manual approval: confirmation is handed back to the user/terminal. If Cursor, Codex, or Kimi still shows prompts, check the ide and diagnostic fields in diagnostics.")
                    Text("If manual prompts still appear: open \"Tool Approval Diagnostics\" in \"Device Info\" and check permission-request.log (includes ide, hookEvent, diagnostic, etc.).")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var switchEffectivenessBox: some View {
        let agentReady = agentManager.isInstalled && agentManager.isRunning && agentManager.hooksInstalled
        let hasAnyMissing = !agentManager.isInstalled || !agentManager.isRunning || !agentManager.hooksInstalled
        GroupBox(agentReady ? "Active" : "Inactive") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: agentReady ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(agentReady ? .green : .orange)
                    Text(agentReady
                         ? "When the Agent is ready, Claude/Cursor/Codex follow the switch for approvals. **Kimi**: after installing AhaKey Kimi Hooks, the switch directly takes over the current session; if you just installed or upgraded kimi-cli, reopen kimi once."
                         : "For the switch to take effect in IDEs, install the Agent and hooks first and hand Bluetooth to the Agent; otherwise it is only a status display.")
                        .font(.callout)
                }

                if hasAnyMissing {
                    VStack(alignment: .leading, spacing: 4) {
                        agentChecklistRow(label: "LaunchAgent installed", ok: agentManager.isInstalled)
                        agentChecklistRow(label: "Agent connected via Bluetooth", ok: agentManager.isRunning)
                        agentChecklistRow(label: "Claude / Cursor / Codex / Kimi hooks configured", ok: agentManager.hooksInstalled)
                    }
                    .padding(.leading, 4)

                    HStack(spacing: 8) {
                        if !agentManager.isInstalled {
                            Button("Install Agent + Hooks") {
                                agentManager.install()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        } else if !agentManager.isRunning {
                            // 与「设备信息 · Agent」相同：在 launchd 中 load + start 守护进程。
                            // 若当前由本 App 占用蓝牙，此处也应引导先去设备信息把「蓝牙连接」切给 Agent，否则与主流程二选一相冲突（故与 DeviceInfo 同样禁用直接启动）。
                            Button("Start Agent") {
                                agentManager.start()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(agentManager.bluetoothConnectionOwner == .ahaKeyStudio)
                            .help(
                                agentManager.bluetoothConnectionOwner == .ahaKeyStudio
                                ? "This app currently owns Bluetooth. Open \"Device Info…\" below, set \"Bluetooth Connection\" to \"Owned by Agent\", then start the Agent; same rule as the \"Start\" button in Device Info."
                                : "Same as Start in \"Device Info · Agent\": launchd loads and runs ahakeyconfig-agent."
                            )
                        }
                        Button("Device Info (Bluetooth / Start-Stop Agent)…") {
                            showsDeviceInfo = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func agentChecklistRow(label: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
                .font(.caption)
            Text(label)
                .font(.caption)
                .foregroundStyle(ok ? .primary : .secondary)
        }
    }


    private var statusBar: some View {
        HStack(spacing: 16) {
            Label("\(selectedPart.title) · \(selectedMode.title)", systemImage: selectedPart.systemImage)
                .font(.callout)
            Divider()
                .frame(height: 14)
            Text("Unsynced changes: \(dirtyCount)")
                .font(.callout)
            Divider()
                .frame(height: 14)
            Text(syncStatusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let lastSyncDate {
                Text("Last synced \(Self.timeFormatter.string(from: lastSyncDate))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Permission Diagnostics") {
                showsDiagnostics = true
            }
            .buttonStyle(.borderless)
            .help("View voice permission status and diagnostic logs")
            .sheet(isPresented: $showsDiagnostics) {
                diagnosticsSheet
            }

            Button("Onboarding") {
                voiceRelay.showsPermissionOnboarding = false
                unifiedOnboardingCompleted = false
            }
            .buttonStyle(.borderless)
            .help("Reopen the AhaKey Studio onboarding")

            Button("Help Center") {
                showsHelpCenter = true
            }
            .buttonStyle(.borderless)
            .help("Open the built-in Help Center")
            .sheet(isPresented: $showsHelpCenter) {
                HelpCenterSheet(
                    studioDraft: studioDraft,
                    selectedMode: selectedMode,
                    bleManager: bleManager
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(chromeBarBackground)
    }

    private var chromeBarBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    private var currentModeDraft: AhaKeyModeDraft {
        studioDraft.draft(for: selectedMode)
    }

    private var currentSelectedKey: AhaKeyKeyDraft {
        let role = selectedPart.keyRole ?? .voice
        return currentModeDraft.key(for: role)
    }

    private var currentSwitchTitle: String {
        // 用统一的 liveKeyboardSwitchState：主 App 自占 BLE 时是 bleManager.switchState，
        // 否则取 agent 共享文件里的值（含用户拨杆覆盖）。否则点了画布拨杆，
        // 因为 bleManager.switchState 一直是初始 0，画布会一直停留在「自动批准」。
        liveKeyboardSwitchState == 0 ? "Auto-Approve" : "Manual Approval"
    }

    /// 取键盘当前实时状态 (lightMode/switchState/workMode)：
    /// - 主 App 已自连 BLE（编辑配置时）→ 用主 App 自己的 BLE 读数
    /// - 主 App 未连，但 agent 仍占用 BLE 在写共享文件 → 读 agent 发布的缓存
    /// - 两者都没有 → nil（画布回落到模拟）
    private var liveKeyboardLightMode: Int? {
        if bleManager.isConnected { return bleManager.lightMode }
        return bleManager.agentLightMode
    }
    private var liveKeyboardSwitchState: Int {
        // 用户刚点完虚拟拨杆但 agent / BLE 还没回报新值时，优先用乐观值，按下立刻可见
        if let opt = bleManager.optimisticSwitchOverride { return opt }
        if bleManager.isConnected { return bleManager.switchState }
        return bleManager.agentSwitchState ?? 1
    }
    private var liveKeyboardWorkMode: Int? {
        if bleManager.isConnected { return bleManager.workMode }
        return bleManager.agentWorkMode
    }
    private var liveCanvasLightMode: Int? {
        guard let workMode = liveKeyboardWorkMode, selectedMode.rawValue == workMode else { return nil }
        return liveKeyboardLightMode
    }
    private var liveCanvasIDEStateValue: Int? {
        guard let workMode = liveKeyboardWorkMode, selectedMode.rawValue == workMode else { return nil }
        return bleManager.liveIDEStateValue
    }
    private var liveCanvasSwitchState: Int { liveKeyboardSwitchState }

    private func cycleModeForward() {
        let all = AhaKeyModeSlot.allCases
        let next = all[(all.firstIndex(of: selectedMode)! + 1) % all.count]
        selectedMode = next
    }

    /// 用户点击虚拟拨杆：在当前 effective switchState 基础上 0↔1 翻转，
    /// 只设置软件覆盖；最新固件中 0x91 是灯效预览，不再用于 sw_state。
    private func toggleVirtualSwitch() {
        let current = liveKeyboardSwitchState
        let next: UInt8 = current == 0 ? 1 : 0
        // 1) 立刻设乐观值 → 画布按钮即时翻转
        bleManager.applyOptimisticSwitchOverride(next)
        // 2) 保留调用入口，但 BLEManager 不会再发送旧 0x91，只写诊断日志
        if bleManager.isConnected {
            bleManager.setSwitchStateViaBLE(next)
        }
        // 3) 让 agent 设置软覆盖
        AgentManager.shared.sendSwitchOverride(next)
        // 4) 短延迟后强制重读共享文件，确认真实值已对齐（agent 写文件通常 < 100ms）
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak bleManager] in
            bleManager?.refreshAgentStateFromFileNow()
        }
        syncStatusMessage = next == 0
            ? "Virtual switch → Auto-Approve (hooks auto-allow; if the lighting does not change, flash firmware with 0x91 support first)"
            : "Virtual switch → Manual Approval (hooks hand confirmation back to the terminal)"
    }

    private var currentOLEDPreviewImage: NSImage? {
        guard let path = currentModeDraft.oled.localAssetPath else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private var currentOLEDAssetURL: URL? {
        guard let path = currentModeDraft.oled.localAssetPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var currentLightEffect: LightEffectStyle {
        currentModeDraft.lightBar.effect(for: lightBarPreview)
    }

    private var isEditingConfiguration: Bool {
        agentManager.bluetoothConnectionOwner == .ahaKeyStudio
    }

    // AhaKeyStudio 直连、Agent 已连上键盘、或正在交还蓝牙的过渡期，任一满足即视为设备已连接。
    private var isEffectivelyConnected: Bool {
        bleManager.isConnected || agentManager.isAgentBLEConnected || isTransitioningToKeyboardControl
    }

    private var shouldShowTopBarInstallStartButton: Bool {
        !agentManager.isInstalled || !agentManager.hooksInstalled
    }

    private var configurationModeDetail: String {
        if isEditingConfiguration {
            if bleManager.isConnected {
                return "AhaKey Studio is configuring the keyboard"
            }
            return bleManager.isScanning ? "AhaKey Studio is connecting to the keyboard" : "AhaKey Studio is waiting to connect"
        }
        // 蓝牙交给 Agent：若顶栏仍显示「安装启动」，说明 Hook/Agent 未齐备，勿与左侧「已连接」拼成「已可控制」。
        if !isEditingConfiguration && shouldShowTopBarInstallStartButton && isEffectivelyConnected {
            if agentManager.isRunning && agentManager.isAgentBLEConnected {
                return "Agent is controlling the keyboard"
            }
            return "Install & Start is required before controlling the keyboard"
        }
        // 蓝牙交给 Agent 时：与左侧 infoPill「已连接」口径一致（isEffectivelyConnected），避免出现「已连接」+「等待键盘」的互斥文案。
        if isEffectivelyConnected {
            if agentManager.isRunning && agentManager.isAgentBLEConnected {
                return "Agent is controlling the keyboard"
            }
            if agentManager.isRunning {
                return "Keyboard connected; syncing Agent connection state"
            }
            return "Keyboard connected"
        }
        if agentManager.isRunning {
            return "Agent running, waiting for keyboard connection"
        }
        if agentManager.isInstalled {
            return "Agent installed, preparing control"
        }
        return "Install the Agent to control the keyboard"
    }

    private var configurationModeButtonTitle: String {
        if isSyncing {
            return "Syncing…"
        }
        if isEditingConfiguration {
            return "Save Configuration"
        }
        return "Edit Configuration"
    }

    private var configurationModeButtonHelp: String {
        if isEditingConfiguration {
            if hasUnsyncedChanges {
                return "Sync the current draft to the keyboard, then hand Bluetooth back to the Agent."
            }
            return "No unsynced changes; hand Bluetooth back to the Agent directly."
        }
        return "Temporarily let AhaKey Studio take over Bluetooth for key remapping, LCD, syncing, and local lighting tests."
    }

    private var voicePresetDetail: String {
        let preset = currentSelectedKey.voicePreset ?? .custom
        return preset.detail
    }

    private func permissionBadge(title: String, granted: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(granted ? "On" : "Off")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 999)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var currentSelectedKeySanitizedDescription: String {
        currentSelectedKey.description.sanitizedASCII(maxLength: 20)
    }

    private var selectedKeyDescriptionBinding: Binding<String> {
        Binding(
            get: { currentSelectedKey.description },
            set: { newValue in
                updateSelectedKey { key in
                    key.description = String(newValue.prefix(20))
                }
            }
        )
    }

    private var selectedKeyShortcutBinding: Binding<ShortcutBinding> {
        Binding(
            get: { currentSelectedKey.shortcut },
            set: { newValue in
                updateSelectedKey { $0.shortcut = newValue }
            }
        )
    }

    private var oledFramesPerSecondBinding: Binding<Int> {
        Binding(
            get: { currentModeDraft.oled.framesPerSecond },
            set: { newValue in
                updateCurrentMode { mode in
                    mode.oled.framesPerSecond = min(30, max(1, newValue))
                }
            }
        )
    }

    private var hasUnsyncedChanges: Bool {
        dirtyCount > 0
    }

    private var dirtyCount: Int {
        AhaKeyModeSlot.allCases.reduce(into: 0) { count, mode in
            let current = studioDraft.draft(for: mode)
            let baseline = lastSyncedDraft.draft(for: mode)
            for role in AhaKeyKeyRole.allCases where current.key(for: role) != baseline.key(for: role) {
                count += 1
            }
            if current.oled != baseline.oled {
                count += 1
            }
            if current.lightBar != baseline.lightBar {
                count += 1
            }
        }
    }

    private func restoreCurrentModeDefaults() {
        let restored = AhaKeyModeDraft.default(for: selectedMode)
        var next = studioDraft
        next.updateMode(restored)
        studioDraft = next
        syncStatusMessage = "\(selectedMode.title) restored to defaults, waiting to sync."
    }

    private func clearCurrentOLED() {
        updateCurrentMode { mode in
            mode.oled.localAssetPath = nil
            mode.oled.statusLine = AhaKeyOLEDDraft.default(for: selectedMode).statusLine
        }
    }

    private func applyVoicePreset(_ preset: VoicePreset) {
        updateSelectedKey { key in
            key.voicePreset = preset
            if preset != .custom {
                key.shortcut = preset.defaultBinding
            }
            if key.description.isEmpty {
                key.description = key.role.defaultDescription
            }
        }
    }

    // MARK: - 宏编辑

    /// 按键当前处于 "宏" 还是 "快捷键" 录入模式。
    /// 状态仅由 `macro` 是否为空推导，避免多出一个独立 flag。
    private enum KeyBindingMode {
        case shortcut
        case macro
    }

    private var selectedKeyBindingModeBinding: Binding<KeyBindingMode> {
        Binding(
            get: { currentSelectedKey.usesMacro ? .macro : .shortcut },
            set: { newValue in
                switch newValue {
                case .shortcut:
                    updateSelectedKey { key in
                        key.macro = []
                    }
                case .macro:
                    updateSelectedKey { key in
                        guard key.macro.isEmpty else { return }
                        // Mode 0「No」键的 shortcut 故意为空，实际绑定是固件宏 ↓↓⏎；若仍用「空 shortcut → Enter 种子」，
                        // 从「单键」切回「宏」时会被误植成只按 Enter，覆盖用户刚配好的三键宏。
                        if selectedMode == .mode0, key.role == .reject {
                            key.macro = AhaKeyModeDraft.claudeNoMacroSteps.map { step in
                                MacroStep(action: step.action, param: step.param)
                            }
                            return
                        }
                        // 其它键：用当前 shortcut 的主键作种子（没配就用 Enter），避免空白宏列表。
                        let seed: UInt8 = key.shortcut.keyCode == 0 ? HIDUsage.enter : key.shortcut.keyCode
                        key.macro = [
                            MacroStep(action: .downKey, param: seed),
                            MacroStep(action: .upKey, param: seed),
                        ]
                    }
                }
            }
        )
    }

    private func appendMacroStep() {
        updateSelectedKey { key in
            // 默认追加 "按下 Enter"——多数用户添加步骤都是想按键，延时/松开可以再切。
            key.macro.append(MacroStep(action: .downKey, param: HIDUsage.enter))
        }
    }

    private func removeMacroStep(at index: Int) {
        updateSelectedKey { key in
            guard key.macro.indices.contains(index) else { return }
            key.macro.remove(at: index)
        }
    }

    private func moveMacroStep(from index: Int, by offset: Int) {
        updateSelectedKey { key in
            let target = index + offset
            guard key.macro.indices.contains(index), key.macro.indices.contains(target) else { return }
            key.macro.swapAt(index, target)
        }
    }

    private func updateMacroStep(id: UUID, transform: (inout MacroStep) -> Void) {
        updateSelectedKey { key in
            guard let idx = key.macro.firstIndex(where: { $0.id == id }) else { return }
            transform(&key.macro[idx])
        }
    }

    private func updateSelectedKey(_ transform: (inout AhaKeyKeyDraft) -> Void) {
        guard let role = selectedPart.keyRole else { return }
        updateCurrentMode { mode in
            var key = mode.key(for: role)
            transform(&key)
            mode.updateKey(key)
        }
    }

    private func updateCurrentMode(_ transform: (inout AhaKeyModeDraft) -> Void) {
        updateMode(selectedMode, transform)
    }

    private func updateMode(_ modeSlot: AhaKeyModeSlot, _ transform: (inout AhaKeyModeDraft) -> Void) {
        var next = studioDraft
        var mode = next.draft(for: modeSlot)
        transform(&mode)
        next.updateMode(mode)
        studioDraft = next
    }

    private func partIsDirty(_ part: AhaKeyStudioPart) -> Bool {
        let current = studioDraft.draft(for: selectedMode)
        let baseline = lastSyncedDraft.draft(for: selectedMode)
        switch part {
        case .key1, .key2, .key3, .key4:
            guard let role = part.keyRole else { return false }
            return current.key(for: role) != baseline.key(for: role)
        case .oledDisplay:
            return current.oled != baseline.oled
        case .lightBar:
            return current.lightBar != baseline.lightBar
        case .toggleSwitch:
            return false
        }
    }

    private func dirtyPartsForCurrentMode() -> Set<AhaKeyStudioPart> {
        Set(AhaKeyStudioPart.allCases.filter(partIsDirty(_:)))
    }

    private func selectOLEDGIF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif, .png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try OLEDFrameEncoder.validateGIFSourceFileSize(at: url)
                try OLEDFrameEncoder.validateFrameCount(at: url)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "The image file does not meet the upload limits."
                syncStatusMessage = msg
                updateCurrentMode { mode in
                    mode.oled.statusLine = msg
                }
                return
            }
            let frameCount = OLEDFrameEncoder.frameCount(at: url)
            updateCurrentMode { mode in
                mode.oled.localAssetPath = url.path
                mode.oled.statusLine = "Selected a \(max(frameCount, 1))-frame image preview; it will be uploaded to the fixed partition for \(selectedMode.title) on write."
            }
            syncStatusMessage = "Updated the LCD preview for \(selectedMode.title); use the common button at the bottom to write to the device."
        }
    }

    private func handleConfigurationModeButton() {
        if isEditingConfiguration {
            finishEditingConfiguration()
        } else {
            enterEditingConfiguration()
        }
    }

    private func installStartAgentFromTopBar() {
        if agentManager.bluetoothConnectionOwner != .agentDaemon {
            agentManager.setBluetoothConnectionOwner(.agentDaemon, bleManager: bleManager)
        }
        if !agentManager.isInstalled || !agentManager.hooksInstalled {
            agentManager.install()
        } else {
            agentManager.start()
        }
    }

    private func enterEditingConfiguration() {
        isTransitioningToKeyboardControl = false
        agentManager.setBluetoothConnectionOwner(.ahaKeyStudio, bleManager: bleManager)
        syncStatusMessage = "Entered configuration editing; AhaKey Studio temporarily takes over Bluetooth."
    }

    private func finishEditingConfiguration() {
        guard hasUnsyncedChanges else {
            returnToKeyboardControl()
            return
        }

        if bleManager.isConnected && bleManager.commandCharReady {
            syncAllModesToDevice(returnToKeyboardControlWhenDone: true)
        } else {
            syncStatusMessage = "Connecting to device; it will sync automatically and return to control mode once connected…"
            bleManager.userInitiatedConnect()
            waitForConnectionThenSync()
        }
    }

    private func writeToKeyboard() {
        performUnifiedDeviceWrite(returnToKeyboardControlWhenDone: false, showResultAlert: true)
    }

    private func completeEditingAfterSuccessfulWrite() {
        commitModeNameEdit()
        withAnimation(.easeInOut(duration: 0.18)) {
            isEditingInspector = false
        }
        returnToKeyboardControl()
    }

    // 轮询等待 BLE 连接且命令通道就绪（最多 10 秒），连接后自动同步并返回键盘控制。
    private func waitForConnectionThenSync() {
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if bleManager.isConnected && bleManager.commandCharReady {
                    syncAllModesToDevice(returnToKeyboardControlWhenDone: true)
                    return
                }
            }
            syncStatusMessage = "Connection timed out; nothing was written to the keyboard. Bluetooth has been released to the Agent — enter editing again and retry saving."
            returnToKeyboardControl()
        }
    }

    private func returnToKeyboardControl() {
        isTransitioningToKeyboardControl = true
        agentManager.setBluetoothConnectionOwner(.agentDaemon, bleManager: bleManager)
        syncStatusMessage = "Restoring keyboard control; the Agent is connecting to the keyboard…"
        monitorAgentReconnect()
    }

    // 返回键盘控制后每 2s 轮询一次 Agent BLE 状态（等待异步 socket 查询完成后再读值），
    // 最多等待 20s；超时后尝试重启 Agent。过渡期结束时清除 isTransitioningToKeyboardControl。
    private func monitorAgentReconnect() {
        Task { @MainActor in
            for i in 0..<10 {
                // 第一次等短些，让 Agent 有时间启动
                let waitMs: UInt64 = i == 0 ? 1_500_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: waitMs)
                agentManager.refresh()
                // 等待 refresh() 内部的异步 socket 查询写回主线程（最多 2.5s timeout）
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if agentManager.isAgentBLEConnected {
                    syncStatusMessage = "Returned to keyboard control; the Agent will take over Bluetooth."
                    isTransitioningToKeyboardControl = false
                    return
                }
                // 约 10s 后 Agent 仍未连上，尝试重启
                if i == 2, !agentManager.isAgentBLEConnected {
                    agentManager.start()
                }
            }
            syncStatusMessage = "Returned to keyboard control; the Agent will take over Bluetooth."
            isTransitioningToKeyboardControl = false
        }
    }

    private func syncAllModesToDevice(returnToKeyboardControlWhenDone: Bool = false) {
        performUnifiedDeviceWrite(returnToKeyboardControlWhenDone: returnToKeyboardControlWhenDone, showResultAlert: false)
    }

    private func performUnifiedDeviceWrite(returnToKeyboardControlWhenDone: Bool, showResultAlert: Bool) {
        guard bleManager.isConnected && bleManager.commandCharReady else {
            let message = showResultAlert ? "Device not connected; connect the keyboard and try again." : "Device not connected or command channel not ready; only the local draft was saved."
            syncStatusMessage = message
            if showResultAlert {
                writeResultAlertMessage = message
                showsWriteResultAlert = true
            }
            return
        }

        applyCursorRejectMacroSelfHealIfNeeded()
        isSyncing = true
        syncStatusMessage = "Preparing to write to device…"
        let returnAgent = returnToKeyboardControlWhenDone

        Task { @MainActor in
            do {
                let desiredBrightness = UInt8(max(1, min(100, studioDraft.draft(for: .mode0).lightBar.brightness)))
                syncStatusMessage = "Verifying keyboard lighting firmware…"
                try await bleManager.verifyConfigurableLightingSupport(brightness: desiredBrightness)

                let uploadedOLEDCount = try await uploadChangedOLEDsToDevice()
                var commands = commandsForModes(AhaKeyModeSlot.allCases)
                commands.append((data: AhaKeyCommand.saveConfig(), label: "保存全部配置到设备"))

                let total = commands.count
                if uploadedOLEDCount > 0 {
                    self.syncStatusMessage = "Uploaded \(uploadedOLEDCount) LCD animation(s); writing lighting and key configuration (about \(total) commands)…"
                } else {
                    self.syncStatusMessage = "Writing lighting and key configuration (about \(total) commands)…"
                }
                try await self.bleManager.writeCommandsConfirmingResponses(commands)
                // 最后的 0x04 已收到固件 ACK，略等再交还蓝牙。
                try? await Task.sleep(nanoseconds: UInt64(150) * 1_000_000)
                self.lastSyncedDraft = self.studioDraft
                self.lastSyncDate = Date()
                self.isSyncing = false
                self.syncStatusMessage = "All settings written to the device and saved (all commands confirmed)."
                if showResultAlert {
                    self.writeResultAlertMessage = "Configuration written to the keyboard successfully, with firmware confirmation."
                    self.showsWriteResultAlert = true
                }
                if returnAgent {
                    self.returnToKeyboardControl()
                }
            } catch {
                let message = "Failed to write to keyboard: \(error.localizedDescription)"
                self.isSyncing = false
                self.syncStatusMessage = message
                if showResultAlert {
                    self.writeResultAlertMessage = message
                    self.showsWriteResultAlert = true
                }
            }
        }
    }

    private func uploadChangedOLEDsToDevice() async throws -> Int {
        var uploadCount = 0

        for mode in AhaKeyModeSlot.allCases {
            let draft = studioDraft.draft(for: mode)
            guard let assetPath = draft.oled.localAssetPath else { continue }

            let baseline = lastSyncedDraft.draft(for: mode).oled
            let deviceFrameCount = bleManager.keyboardPictureStates[mode.rawValue]?.frameCount ?? 0
            guard draft.oled != baseline || deviceFrameCount == 0 else { continue }

            let assetURL = URL(fileURLWithPath: assetPath)
            try OLEDFrameEncoder.validateGIFSourceFileSize(at: assetURL)
            let frames = try OLEDFrameEncoder.frames(fromGIFAt: assetURL)

            updateMode(mode) { modeDraft in
                modeDraft.oled.statusLine = "Uploading animation to \(mode.title)…"
            }
            syncStatusMessage = "Uploading the LCD animation for \(mode.title)…"

            let startIndex = try await resolveOLEDUploadStartIndex(for: mode, frameCount: frames.count)
            try await bleManager.uploadOLEDFrames(
                frames,
                fps: draft.oled.framesPerSecond,
                mode: UInt8(mode.rawValue),
                startIndex: UInt16(startIndex)
            )

            updateMode(mode) { modeDraft in
                modeDraft.oled.statusLine = "Uploaded \(frames.count) frames to the device, slot start \(startIndex); switching modes shows the description first, then returns to the current mode's animation."
            }
            uploadCount += 1
        }

        return uploadCount
    }

    private func resendCurrentModeToDevice() {
        guard bleManager.isConnected && bleManager.commandCharReady else {
            syncStatusMessage = "Device not connected or command channel not ready; only the local draft was saved."
            return
        }

        applyCursorRejectMacroSelfHealIfNeeded()
        var commands = commandsForModes([selectedMode])
        commands.append((data: AhaKeyCommand.saveConfig(), label: "保存 \(selectedMode.title) 当前配置"))

        isSyncing = true
        syncStatusMessage = "Writing \(selectedMode.title)…"
        Task { @MainActor in
            do {
                let desiredBrightness = UInt8(max(1, min(100, currentModeDraft.lightBar.brightness)))
                try await bleManager.verifyConfigurableLightingSupport(brightness: desiredBrightness)
                try await bleManager.writeCommandsConfirmingResponses(commands)
                self.lastSyncDate = Date()
                self.isSyncing = false
                self.syncStatusMessage = "Rewrote \(self.selectedMode.title) (confirmed by firmware)."
            } catch {
                self.isSyncing = false
                self.syncStatusMessage = "Failed to write to keyboard: \(error.localizedDescription)"
            }
        }
    }

    /// Cursor 档「取消键」若仍为默认 ⌫ 却残留宏，同步会走 0x74 而非单键。清掉误残留宏并与迁移逻辑一致。
    private func applyCursorRejectMacroSelfHealIfNeeded() {
        var next = studioDraft
        var m1 = next.draft(for: .mode1)
        var reject = m1.key(for: .reject)
        let defaultR = AhaKeyModeDraft.default(for: .mode1).key(for: .reject)
        guard !reject.macro.isEmpty, reject.shortcut == defaultR.shortcut else { return }
        reject.macro = []
        m1.updateKey(reject)
        next.updateMode(m1)
        studioDraft = next
    }

    private func commandsForModes(_ modes: [AhaKeyModeSlot]) -> [(data: Data, label: String)] {
        var commands: [(data: Data, label: String)] = []

        for mode in modes {
            let draft = studioDraft.draft(for: mode)
            for role in AhaKeyKeyRole.allCases {
                let key = draft.key(for: role)
                let keyIndex = UInt8(role.rawValue)
                let modeByte = UInt8(mode.rawValue)

                if key.usesMacro {
                    // 固件对 0x73 快捷键、0x74 宏是分层存储的；从「快捷键」改「宏」时须先清掉旧快捷键，否则会残留。
                    commands.append((
                        data: AhaKeyCommand.setKeyMapping(
                            mode: modeByte,
                            keyIndex: keyIndex,
                            hidCodes: []
                        ),
                        label: "清除 \(mode.title) \(key.title) 快捷键层（将写入宏）"
                    ))
                    commands.append((
                        data: AhaKeyCommand.setKeyMacro(
                            mode: modeByte,
                            keyIndex: keyIndex,
                            macroData: key.macro.flattenedBytes
                        ),
                        label: "写入 \(mode.title) \(key.title) 宏: \(key.macro.displaySummary)"
                    ))
                } else {
                    // 从「宏」改「快捷键 / 无键」时须先发空 0x74，否则设备可能仍走旧宏（Cursor/其它 mode 上表现为改键不生效）。
                    commands.append((
                        data: AhaKeyCommand.setKeyMacro(
                            mode: modeByte,
                            keyIndex: keyIndex,
                            macroData: []
                        ),
                        label: "清除 \(mode.title) \(key.title) 宏层（将写入快捷键）"
                    ))
                    if !key.shortcut.hidCodes.isEmpty {
                        commands.append((
                            data: AhaKeyCommand.setKeyMapping(
                                mode: modeByte,
                                keyIndex: keyIndex,
                                hidCodes: key.shortcut.hidCodes
                            ),
                            label: "写入 \(mode.title) \(key.title) 快捷键: \(key.shortcut.displayLabel)"
                        ))
                    } else {
                        commands.append((
                            data: AhaKeyCommand.setKeyMapping(
                                mode: modeByte,
                                keyIndex: keyIndex,
                                hidCodes: []
                            ),
                            label: "清除 \(mode.title) \(key.title) 快捷键"
                        ))
                    }
                }

                let sanitizedDescription = key.description.sanitizedASCII(maxLength: 20)
                commands.append((
                    data: AhaKeyCommand.setKeyDescription(
                        mode: UInt8(mode.rawValue),
                        keyIndex: keyIndex,
                        text: key.description
                    ),
                    label: "写入 \(mode.title) \(key.title) 描述: \(sanitizedDescription.isEmpty ? "空白" : sanitizedDescription)"
                ))
            }
        }

        for mode in modes {
            let lb = studioDraft.draft(for: mode).lightBar
            let effects = IDEState.allCases.map { lb.effect(for: $0).firmwareIndex }
            commands.append((
                AhaKeyCommand.setLightMapping(mode: UInt8(mode.rawValue), stateEffects: effects),
                "灯效映射 \(mode.title)"
            ))
        }

        let brightness = UInt8(studioDraft.draft(for: modes[0]).lightBar.brightness)
        commands.append((AhaKeyCommand.setBrightness(brightness), "亮度 \(brightness)%"))

        return commands
    }

    /// 首次连接键盘后自动把 bundle 默认 GIF 推到没有上传过的 mode slot。
    /// 触发时机：bleManager.keyboardPictureStates 四个 mode 都查回来之后
    /// （由 .onChange(of: bleManager.keyboardPictureStates) 调度）。
    /// 守卫：
    /// - 只上传 picLength==0（slot 完全空）的 mode；非 0 视为用户已自定义或固件出厂图
    /// - 只在 draft 的 localAssetPath 仍指向 bundle 默认（用户没手动换过）时上传
    /// - 每次连接只跑一次（oledAutoSyncDoneForConnection 标志位由 .onChange(isConnected) 重置）
    private func autoSyncDefaultOLEDsIfNeeded() async {
        guard bleManager.isConnected else { return }
        // 四个 mode 全部 0x83 查询回来才动手，避免半截判断把已上传 slot 当成空
        guard bleManager.keyboardPictureStates.count == AhaKeyModeSlot.allCases.count else { return }

        for mode in AhaKeyModeSlot.allCases {
            guard let state = bleManager.keyboardPictureStates[mode.rawValue] else { continue }
            guard state.frameCount == 0 else { continue }
            guard let bundledPath = DefaultOLEDAssets.bundledAssetPath(for: mode) else { continue }
            let draft = studioDraft.draft(for: mode)
            guard let drafPath = draft.oled.localAssetPath,
                  DefaultOLEDAssets.isBundledPath(drafPath) else { continue }

            let assetURL = URL(fileURLWithPath: bundledPath)
            do {
                try OLEDFrameEncoder.validateGIFSourceFileSize(at: assetURL)
                let frames = try OLEDFrameEncoder.frames(fromGIFAt: assetURL)
                let startIndex = try await resolveOLEDUploadStartIndex(for: mode, frameCount: frames.count)
                try await bleManager.uploadOLEDFrames(
                    frames,
                    fps: draft.oled.framesPerSecond,
                    mode: UInt8(mode.rawValue),
                    startIndex: UInt16(startIndex)
                )
                updateMode(mode) { m in
                    m.oled.statusLine = "Default animation auto-synced (\(frames.count) frames)."
                }
            } catch {
                syncStatusMessage = "\(mode.title) default animation auto-sync failed: \(error.localizedDescription)"
            }
        }
    }

    private func resolveOLEDUploadStartIndex(for targetMode: AhaKeyModeSlot, frameCount: Int) async throws -> Int {
        guard frameCount <= AhaKeyCommand.oledMaxFramesPerMode else {
            throw OLEDUploadError.tooManyFrames(max: AhaKeyCommand.oledMaxFramesPerMode)
        }

        _ = try? await bleManager.readPictureState(mode: UInt8(targetMode.rawValue))
        return Int(AhaKeyCommand.oledStartIndex(forMode: UInt8(targetMode.rawValue)))
    }

    private func canPlacePictureRange(
        start: Int,
        count: Int,
        occupiedRegions: [(start: Int, end: Int)],
        maxCapacity: Int
    ) -> Bool {
        let end = start + count
        guard start >= 0, end <= maxCapacity else { return false }
        return occupiedRegions.allSatisfy { region in
            end <= region.start || start >= region.end
        }
    }

    private func findFreePictureSpace(
        occupiedRegions: [(start: Int, end: Int)],
        neededCount: Int,
        maxCapacity: Int
    ) -> Int? {
        guard !occupiedRegions.isEmpty else { return 0 }

        if occupiedRegions[0].start >= neededCount {
            return 0
        }

        for index in 0 ..< (occupiedRegions.count - 1) {
            let gapStart = occupiedRegions[index].end
            let gapEnd = occupiedRegions[index + 1].start
            if gapEnd - gapStart >= neededCount {
                return gapStart
            }
        }

        let lastEnd = occupiedRegions.last?.end ?? 0
        if lastEnd + neededCount <= maxCapacity {
            return lastEnd
        }

        return nil
    }

    private func lightEffectBinding(for state: IDEState) -> Binding<LightEffectStyle> {
        Binding(
            get: { currentModeDraft.lightBar.effect(for: state) },
            set: { newEffect in
                var draft = studioDraft
                var mode = draft.draft(for: selectedMode)
                if let idx = mode.lightBar.stateMappings.firstIndex(where: { $0.state == state }) {
                    mode.lightBar.stateMappings[idx].effect = newEffect
                }
                draft.updateMode(mode)
                studioDraft = draft
                AhaKeyStudioStore.save(studioDraft)
                lightBarPreview = state
                previewLightEffect(newEffect)
            }
        )
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { Double(currentModeDraft.lightBar.brightness) },
            set: { newValue in
                var draft = studioDraft
                var mode = draft.draft(for: selectedMode)
                mode.lightBar.brightness = Int(newValue)
                draft.updateMode(mode)
                studioDraft = draft
                AhaKeyStudioStore.save(studioDraft)
                previewBrightness(Int(newValue))
            }
        )
    }

    private func previewLightEffect(for state: IDEState) {
        previewLightEffect(currentModeDraft.lightBar.effect(for: state))
    }

    private func previewLightEffect(_ effect: LightEffectStyle) {
        guard bleManager.isConnected && bleManager.commandCharReady else {
            syncStatusMessage = "Virtual lighting preview updated; connect the keyboard to preview on the device."
            return
        }
        guard bleManager.supportsConfigurableLighting != false else {
            syncStatusMessage = "The current firmware uses the old protocol: 0x91 returns a fake success without changing the lights. Please update the firmware first."
            return
        }
        bleManager.previewLightEffect(effect.firmwareIndex)
        syncStatusMessage = "Previewing lighting effect: \(effect.title)."
    }

    private func previewBrightness(_ value: Int) {
        guard bleManager.isConnected && bleManager.commandCharReady else {
            syncStatusMessage = "Brightness updated to \(value)%; connect the keyboard to preview on the device."
            return
        }
        guard bleManager.supportsConfigurableLighting != false else {
            syncStatusMessage = "The current firmware uses the old protocol; brightness will not be written. Please update the firmware first."
            return
        }
        bleManager.setBrightness(UInt8(max(1, min(100, value))))
        syncStatusMessage = "Previewing brightness: \(value)%."
    }

    private func infoPill(title: String, subtitle: String, accent: Color, width: CGFloat = 86) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                Text(subtitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func manualCallout(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.callout)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func openNativeSpeechPrivacySettings() {
        openNativeSpeechPrivacySettingsURL()
    }

    private var nativeSpeechPermissionsReady: Bool {
        nativeSpeech.microphoneGranted &&
            nativeSpeech.speechRecognitionGranted &&
            nativeSpeech.siriEnabled &&
            nativeSpeech.dictationEnabled
    }

    private var startupPermissionsReady: Bool {
        bleManager.bluetoothPermissionGranted &&
            bleManager.bluetoothPoweredOn &&
            voiceRelay.inputMonitoringGranted &&
            voiceRelay.accessibilityGranted &&
            nativeSpeech.microphoneGranted &&
            nativeSpeech.speechRecognitionGranted &&
            nativeSpeech.siriEnabled &&
            nativeSpeech.dictationEnabled
    }

    private func scheduleStartupPermissionOnboarding() {
        voiceRelay.showsPermissionOnboarding = false
        bleManager.refreshBluetoothAuthorization()
        voiceRelay.refreshPermissions(deferredTCCRequery: true)
        nativeSpeech.refreshPermissions(deferredTCCRequery: true)
    }

    private func refreshStartupPermissionOnboarding() {
        voiceRelay.showsPermissionOnboarding = false
    }
}

private struct VoicePermissionOnboardingSheet: View {
    @ObservedObject var bleManager: AhaKeyBLEManager
    @ObservedObject var voiceRelay: VoiceRelayService
    @ObservedObject var nativeSpeech: NativeSpeechTranscriptionService
    @Environment(\.dismiss) private var dismiss

    @State private var fixInProgress = false
    @State private var fixAlertTitle = ""
    @State private var fixAlertMessage = ""
    @State private var fixAlertIsSuccess = false
    @State private var showFixAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("First-Run Permission Setup")
                .font(.system(size: 24, weight: .semibold))

            Text("AhaKey Studio needs several system permissions on first use: Bluetooth to connect to the keyboard, Input Monitoring and Accessibility to take over the voice key in the background, and Microphone, Speech Recognition, Siri, and Dictation for native macOS voice.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                permissionRow(title: "Bluetooth", granted: bleManager.bluetoothPermissionGranted && bleManager.bluetoothPoweredOn, detail: bleManager.bluetoothPermissionGranted ? "Turn on system Bluetooth to discover, connect, and sync the AhaKey keyboard." : "Allow AhaKey Studio to use Bluetooth in \"Privacy & Security > Bluetooth\".")
                permissionRow(title: "Microphone", granted: nativeSpeech.microphoneGranted, detail: "Allow AhaKey Studio to use Apple's native voice capture.")
                permissionRow(title: "Speech Recognition", granted: nativeSpeech.speechRecognitionGranted, detail: "Allow AhaKey Studio to use Apple's native speech recognition.")
                permissionRow(title: "Siri", granted: nativeSpeech.siriEnabled, detail: "Enable Siri in \"System Settings > Siri & Spotlight\" for macOS native voice features.")
                permissionRow(title: "Dictation", granted: nativeSpeech.dictationEnabled, detail: "Enable Dictation in \"System Settings > Keyboard > Dictation\" to keep the system speech components fully available.")
                permissionRow(title: "Accessibility", granted: voiceRelay.accessibilityGranted, detail: "Allow AhaKey Studio to convert the voice key into Apple native transcription or Fn/Globe.")
                permissionRow(title: "Input Monitoring", granted: voiceRelay.inputMonitoringGranted, detail: "Allow AhaKey Studio to listen for the physical voice key in the background; you usually need to quit and reopen the app after granting it.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Setup Steps")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("1. Click \"Request Permissions Now\" and allow Bluetooth, Microphone, and Speech Recognition in the system prompts.")
                Text("2. Once System Settings opens automatically, enable Siri, Dictation, and Accessibility in turn.")
                Text("3. Finally enable Input Monitoring; when the system prompts to restart, quit and reopen the app.")
                Text("4. Come back here and click \"I'm Done, Recheck\" to continue.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("If a permission is already allowed in the system but this app still shows it as off: fully quit AhaKey Studio and relaunch it. Input Monitoring, Accessibility, and similar permissions often apply per process — clicking \"Recheck\" or switching back from the background may still read the old state; after a restart it matches System Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Distribution / DMG / Xcode: the release build appears as \"AhaKey Studio\" in \"Privacy & Security\"; running this project from Xcode in Debug appears as \"AhaKey Studio (Debug)\" — grant each by name. A different path or signature is treated by the system as a separate app.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Bluetooth \(bleManager.bluetoothPermissionGranted ? (bleManager.bluetoothPoweredOn ? "On" : "Authorized but Bluetooth is off") : "Not Authorized")")
                Text(voiceRelay.lastPermissionCheckSummary)
                Text(nativeSpeech.lastPermissionCheckSummary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Request Permissions Now") {
                    requestPermissionsThenOpenPrivacySettingsIfNeeded(
                        bleManager: bleManager,
                        voiceRelay: voiceRelay,
                        nativeSpeech: nativeSpeech
                    )
                }
                .buttonStyle(.borderedProminent)

                Button("I'm Done, Recheck") {
                    bleManager.refreshBluetoothAuthorization()
                    voiceRelay.refreshPermissions(deferredTCCRequery: true)
                    nativeSpeech.refreshPermissions(deferredTCCRequery: true)
                }
                .buttonStyle(.bordered)

                RestartToApplyPermissionsButton(title: "Quit and Reopen")

                if !allPermissionsReady {
                    Button("Open System Settings") {
                        openCombinedVoicePrivacySettingsURL()
                    }
                    .buttonStyle(.bordered)
                }

                if DebugSigningFixer.isAvailable {
                    Button(fixInProgress ? "Resetting…" : "⚙️ Reset Dev Environment Signing (Usually Not Needed)") {
                        runDebugSigningFix()
                    }
                    .buttonStyle(.bordered)
                    .tint(.purple)
                    .disabled(fixInProgress)
                    .help("Use only in exceptional cases: expired certificate / new Mac / Team ID change / keychain corruption causing permission failure. One click re-signs the app and resets TCC authorization. Release builds (no source directory) do not show this button.")
                }

                Spacer()

                Button("Maybe Later") {
                    voiceRelay.dismissPermissionOnboarding()
                    dismiss()
                }
                .buttonStyle(.borderless)
            }

            if allPermissionsReady {
                Text("All first-run permissions are granted. After closing this panel, AhaKey Studio can connect to the keyboard, listen for the voice key in the background, and use native macOS voice normally.")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("Some permissions are still off. Handle each item above until all turn green, then close this panel.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onChange(of: voiceRelay.inputMonitoringGranted) { _ in
            closeIfReady()
        }
        .onChange(of: voiceRelay.accessibilityGranted) { _ in
            closeIfReady()
        }
        .onChange(of: bleManager.bluetoothPermissionGranted) { _ in
            closeIfReady()
        }
        .onChange(of: bleManager.bluetoothPoweredOn) { _ in
            closeIfReady()
        }
        .alert(fixAlertTitle, isPresented: $showFixAlert) {
            if fixAlertIsSuccess {
                Button("Quit App Now") { NSApp.terminate(nil) }
                Button("Quit Later", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(fixAlertMessage)
        }
    }

    private func runDebugSigningFix() {
        fixInProgress = true
        DebugSigningFixer.run { result in
            fixInProgress = false
            fixAlertIsSuccess = result.success
            fixAlertTitle = result.success ? "Fix Complete" : "Fix Failed"
            fixAlertMessage = result.output
            showFixAlert = true
        }
    }

    private func closeIfReady() {
        guard allPermissionsReady else { return }
        voiceRelay.dismissPermissionOnboarding()
        dismiss()
    }

    private var allPermissionsReady: Bool {
        bleManager.bluetoothPermissionGranted &&
            bleManager.bluetoothPoweredOn &&
            voiceRelay.inputMonitoringGranted &&
            voiceRelay.accessibilityGranted &&
            nativeSpeech.microphoneGranted &&
            nativeSpeech.speechRecognitionGranted &&
            nativeSpeech.siriEnabled &&
            nativeSpeech.dictationEnabled
    }

    private func permissionRow(title: String, granted: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    Text(granted ? "On" : "Off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct VoicePresetPicker: View {
    let selectedPreset: VoicePreset
    let onSelect: (VoicePreset) -> Void

    private let visiblePresets = VoicePreset.visibleCases
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(visiblePresets) { preset in
                Button {
                    if preset.availableInV1 {
                        onSelect(preset)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(preset.title)
                                .font(.callout.weight(.semibold))
                            Spacer()
                            if !preset.availableInV1 {
                                Text("In Development")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(preset.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(cardFill(for: preset))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(cardStroke(for: preset), lineWidth: preset == selectedPreset ? 1.5 : 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!preset.availableInV1)
            }
        }
    }

    private func cardFill(for preset: VoicePreset) -> Color {
        if preset == selectedPreset {
            return Color.accentColor.opacity(0.16)
        }
        if !preset.availableInV1 {
            return Color(nsColor: .controlBackgroundColor).opacity(0.65)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private func cardStroke(for preset: VoicePreset) -> Color {
        if preset == selectedPreset {
            return .accentColor
        }
        return Color.black.opacity(0.08)
    }
}

private struct ShortcutBindingEditor: View {
    @Binding var shortcut: ShortcutBinding
    @State private var isRecordingPrimaryKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Modifiers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(ShortcutModifier.allCases) { modifier in
                        Toggle(isOn: modifierBinding(modifier)) {
                            Text(modifier.symbol)
                                .font(.system(.headline, design: .rounded))
                        }
                        .toggleStyle(.button)
                        .help(modifier.title)
                    }
                    if !shortcut.modifiers.isEmpty {
                        Button("Clear Modifiers") {
                            var next = shortcut
                            next.modifiers = []
                            shortcut = next
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Primary Key")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                PrimaryKeyInputField(
                    shortcut: $shortcut,
                    isRecording: $isRecordingPrimaryKey
                )
            }

            if !shortcut.modifiers.isEmpty {
                Text("This is currently a combo (\(shortcut.displayLabel)). If you only want to send a single Enter, do not enable ⌘/⌃ etc., or click \"Clear Modifiers\" and then pick Enter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func modifierBinding(_ modifier: ShortcutModifier) -> Binding<Bool> {
        Binding(
            get: { shortcut.modifiers.contains(modifier) },
            set: { on in
                var next = shortcut
                next.setModifier(modifier, enabled: on)
                shortcut = next
            }
        )
    }

}

private struct PrimaryKeyInputField: View {
    @Binding var shortcut: ShortcutBinding
    @Binding var isRecording: Bool

    private var displayText: String {
        shortcut.keyCode == 0 ? "Press the keyboard shortcut directly" : HIDUsage.name(for: shortcut.keyCode)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isRecording ? Color.accentColor : Color.black.opacity(0.12), lineWidth: isRecording ? 1.5 : 1)
                )

            KeyCaptureOverlay(
                shortcut: $shortcut,
                isRecording: $isRecording,
                onActivate: {
                    isRecording = true
                }
            )
            .padding(.trailing, 38)

            HStack(spacing: 8) {
                Image(systemName: isRecording ? "keyboard.badge.ellipsis" : "keyboard")
                    .foregroundStyle(isRecording ? Color.accentColor : Color.secondary)
                Text(displayText)
                    .font(.callout)
                    .foregroundStyle(shortcut.keyCode == 0 && !isRecording ? Color.secondary : Color.primary)
                    .lineLimit(1)
                Spacer()

                Menu {
                    Button("Press the keyboard shortcut directly") {
                        shortcut = ShortcutBinding()
                        isRecording = false
                    }
                    Divider()
                    ForEach(HIDUsage.allOptions, id: \.code) { option in
                        Button(option.name) {
                            var next = shortcut
                            next.keyCode = option.code
                            shortcut = next
                            isRecording = false
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Expand the dropdown list")
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 36)
        .contentShape(Rectangle())
        .help("Press a key to set the primary key; click the arrow to expand the dropdown list.")
    }
}

private struct KeyCaptureOverlay: NSViewRepresentable {
    @Binding var shortcut: ShortcutBinding
    @Binding var isRecording: Bool
    let onActivate: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        configure(nsView)
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    private func configure(_ view: KeyCaptureNSView) {
        view.onBeginRecording = {
            onActivate()
            isRecording = true
        }
        view.onCapture = { event in
            guard let hidCode = HIDUsage.hidCode(forMacKeyCode: event.keyCode) else {
                NSSound.beep()
                isRecording = false
                return
            }
            shortcut = ShortcutBinding(
                modifiers: shortcutModifiers(from: event.modifierFlags),
                keyCode: hidCode
            )
            isRecording = false
        }
        view.onCaptureModifier = { keyCode in
            guard let hidCode = HIDUsage.hidCode(forMacKeyCode: keyCode) else {
                NSSound.beep()
                isRecording = false
                return
            }
            shortcut = ShortcutBinding(modifiers: [], keyCode: hidCode)
            isRecording = false
        }
    }

    final class KeyCaptureNSView: NSView {
        var onBeginRecording: (() -> Void)?
        var onCapture: ((NSEvent) -> Void)?
        var onCaptureModifier: ((UInt16) -> Void)?
        private var pendingModifierCapture: DispatchWorkItem?

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            onBeginRecording?()
        }

        override func keyDown(with event: NSEvent) {
            pendingModifierCapture?.cancel()
            pendingModifierCapture = nil
            onCapture?(event)
        }

        override func flagsChanged(with event: NSEvent) {
            onBeginRecording?()
            pendingModifierCapture?.cancel()
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.control)
                || flags.contains(.option)
                || flags.contains(.shift)
                || flags.contains(.command)
                || flags.contains(.capsLock)
                || flags.contains(.function)
            else {
                return
            }

            let workItem = DispatchWorkItem { [weak self] in
                self?.onCaptureModifier?(event.keyCode)
                self?.pendingModifierCapture = nil
            }
            pendingModifierCapture = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
        }
    }
}

private func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> [ShortcutModifier] {
    var modifiers: [ShortcutModifier] = []
    if flags.contains(.control) { modifiers.append(.control) }
    if flags.contains(.option) { modifiers.append(.option) }
    if flags.contains(.shift) { modifiers.append(.shift) }
    if flags.contains(.command) { modifiers.append(.command) }
    return modifiers
}

private struct CanvasKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.12, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

private struct AhaKeyKeyboardCanvasView: View {
    let modeDraft: AhaKeyModeDraft
    let selectedPart: AhaKeyStudioPart
    let lightBarPreview: IDEState
    let switchTitle: String
    let dirtyParts: Set<AhaKeyStudioPart>
    let onSelect: (AhaKeyStudioPart) -> Void
    let onModeSwitch: () -> Void
    var onSwitchToggle: (() -> Void)? = nil
    var liveLightMode: Int? = nil
    var liveIDEStateValue: Int? = nil
    var switchState: Int = 1   // 0=auto, 1=manual; firmware uses for color/effect overrides
    /// 0x83 查询出的当前 mode flash 帧数：nil=尚未查询/未连接；0=用户没上传；>0=已上传 N 帧
    var keyboardPictureFrameCount: Int? = nil

    @State private var modeSwitchPressed = false
    @State private var leverPressed = false

    private let baseWidth: CGFloat = 109
    private let baseHeight: CGFloat = 54

    var body: some View {
        GeometryReader { proxy in
            let drawingWidth = min(proxy.size.width, proxy.size.height * (baseWidth / baseHeight))
            let drawingHeight = drawingWidth * (baseHeight / baseWidth)

            ZStack {
                keyboardFrame(width: drawingWidth, height: drawingHeight)
            }
            .frame(width: drawingWidth, height: drawingHeight)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    @ViewBuilder
    private func keyboardFrame(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.95), Color(red: 0.92, green: 0.95, blue: 0.98)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(0.1), lineWidth: 1.2)
                )
                .shadow(color: .black.opacity(0.08), radius: 18, y: 14)

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
                .padding(12)

            VStack {
                Spacer()
            }

            // 螺丝挪到真正的"边角内侧" + 缩小直径 4.8 → 3.6：
            // 旧位置 (8,8)/(8,46) 会被按键灰底矩形和灯条/Key1 边线擦边或交叠。
            // 新位置每颗距离灯条/按键灰底/Key 边都留出 ≥ 3 个基线单位。
            ForEach(Array([CGPoint(x: 5.5, y: 5.5), CGPoint(x: 103.5, y: 5.5), CGPoint(x: 5.5, y: 48.5), CGPoint(x: 103.5, y: 48.5)].enumerated()), id: \.offset) { _, point in
                Circle()
                    .stroke(Color.black.opacity(0.14), lineWidth: 1.2)
                    .background(Circle().fill(Color.white.opacity(0.4)))
                    .frame(width: scaled(3.6, in: width), height: scaled(3.6, in: width))
                    .position(position(point.x, point.y, width: width, height: height))
            }

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
                .frame(width: scaled(4.2, in: width), height: scaled(12, in: width))
                .position(position(3.8, 28, width: width, height: height))

            // 按键灰底：略收一点尺寸，使它显著低于灯条选中态阴影的影响范围（≥ 5 个基线单位）
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.035))
                .frame(width: scaled(67, in: width), height: scaled(21, in: width))
                .position(position(43.8, 38.5, width: width, height: height))

            ledBarButton(width: width, height: height)
            oledButton(width: width, height: height)
            keyButton(for: .voice, width: width, height: height)
            keyButton(for: .approve, width: width, height: height)
            keyButton(for: .reject, width: width, height: height)
            keyButton(for: .submit, width: width, height: height)
            modeSwitchKey(width: width, height: height)
            switchButton(width: width, height: height)
        }
    }

    // 固件 ws2812_mode_e (psk_ws2812.h) → Swift 灯效样式
    private func lightModeToEffect(_ mode: Int) -> LightEffectStyle {
        switch mode {
        case 1: return .singleMove
        case 2: return .rainbowMove
        case 3: return .rainbowWave
        case 4: return .rainbowWaveSlow
        case 5: return .breathing
        case 6: return .middleLight
        default: return .off
        }
    }

    private static let firmwareRed = Color(red: 240 / 255, green: 32 / 255, blue: 41 / 255)
    private static let firmwareBlue = Color(red: 32 / 255, green: 80 / 255, blue: 255 / 255)

    private func firmwareLEDState(ideState: IDEState?, modeData: Int, switchState: Int) -> (LightEffectStyle, Color) {
        guard let s = ideState else {
            return (.off, Self.firmwareRed)
        }
        let effect = modeDraft.lightBar.effect(for: s)
        let color: Color = s == .preToolUse && switchState != 0 ? Self.firmwareBlue : Self.firmwareRed
        return (effect, color)
    }

    private func ledBarButton(width: CGFloat, height: CGFloat) -> some View {
        let part = AhaKeyStudioPart.lightBar
        // 略向上、宽度往里收：让选中态阴影（radius 10pt）跟键盘内描边、按键灰底、LCD 都有 ≥ 5 个基线单位的余量
        let rect = frame(13.0, 4.5, 53.5, 8.6, width: width, height: height)
        let modeData = modeDraft.mode.rawValue
        let effect: LightEffectStyle
        let baseColor: Color
        if let live = liveLightMode {
            // BLE 连接且 mode tab 与物理 workMode 一致：直接信任固件回报的 ws2812_mode + claude_state
            effect = lightModeToEffect(live)
            let liveIDE: IDEState? = liveIDEStateValue.flatMap { IDEState(rawValue: UInt8($0)) }
            // 颜色：仅 preToolUse + manual 是蓝，其他均红（与固件 ws2812_single_color 设定一致）
            if let s = liveIDE, s == .preToolUse, switchState != 0 {
                baseColor = Self.firmwareBlue
            } else {
                baseColor = Self.firmwareRed
            }
        } else {
            // 离线/查看非物理档位：按固件逻辑模拟 update_claude_ws2812()
            let previewIDE = lightBarPreview
            (effect, baseColor) = firmwareLEDState(ideState: previewIDE, modeData: modeData, switchState: switchState)
        }
        return Button {
            onSelect(part)
        } label: {
            VStack(spacing: rect.height * 0.12) {
                Text("Light Bar")
                    .font(.system(size: max(rect.height * 0.18, 10), weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .center)

                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let colors = ledColors(effect: effect, time: context.date.timeIntervalSince1970, count: 10, baseColor: baseColor)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.12))
                        HStack(spacing: rect.width * 0.026) {
                            ForEach(0..<10, id: \.self) { index in
                                Capsule()
                                    .fill(colors[index])
                                    .frame(width: rect.width * 0.072, height: rect.height * 0.26)
                                    .shadow(color: colors[index].opacity(0.65), radius: 2.5)
                            }
                        }
                        .padding(.horizontal, rect.width * 0.04)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: rect.height * 0.48)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .modifier(HotspotChrome(part: part, selectedPart: selectedPart, dirtyParts: dirtyParts))
        }
        .buttonStyle(.plain)
        .position(x: rect.midX, y: rect.midY)
    }

    private func oledButton(width: CGFloat, height: CGFloat) -> some View {
        let part = AhaKeyStudioPart.oledDisplay
        let rect = frame(71.2, 7.7, 24.2, 13.4, width: width, height: height)
        return Button {
            onSelect(part)
        } label: {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.92))
                    oledInnerContent(rect: rect)
                }
                // 右上角徽章：反映键盘 flash 真实状态
                pictureStateBadge(rect: rect)
            }
            .frame(width: rect.width, height: rect.height)
            .modifier(HotspotChrome(part: part, selectedPart: selectedPart, dirtyParts: dirtyParts))
        }
        .buttonStyle(.plain)
        .position(x: rect.midX, y: rect.midY)
    }

    @ViewBuilder
    private func pictureStateBadge(rect: CGRect) -> some View {
        if let count = keyboardPictureFrameCount {
            let isUploaded = count > 0
            let label = isUploaded ? "✓ Uploaded \(count) frames" : "Not Uploaded"
            Text(label)
                .font(.system(size: max(rect.height * 0.11, 8), weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, rect.width * 0.04)
                .padding(.vertical, rect.height * 0.02)
                .background(
                    Capsule()
                        .fill(isUploaded ? Color.green.opacity(0.85) : Color.gray.opacity(0.85))
                )
                .padding(rect.width * 0.025)
        }
    }

    /// 真实 LCD 是 160×80（2:1）。在 slot 中央用一个 2:1 的"屏幕区"渲染内容，
    /// 周围留键盘黑壳作为外框；图片 / 占位都在屏幕区内 .fit，不会撑出范围、不会被裁切。
    private func screenInnerSize(for rect: CGRect) -> CGSize {
        let screenAspect: CGFloat = 2.0
        if rect.width / rect.height >= screenAspect {
            let h = rect.height * 0.86
            return CGSize(width: h * screenAspect, height: h)
        } else {
            let w = rect.width * 0.86
            return CGSize(width: w, height: w / screenAspect)
        }
    }

    private func oledInnerContent(rect: CGRect) -> some View {
        let size = screenInnerSize(for: rect)
        return ZStack {
            Color.clear
            screenBody(screenWidth: size.width, screenHeight: size.height)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func screenBody(screenWidth: CGFloat, screenHeight: CGFloat) -> some View {
        if let gifPath = modeDraft.oled.localAssetPath {
            // .id(gifPath) 强制 SwiftUI 在路径切换时销毁并重建视图，
            // 否则旧路径的 @State frames/currentFrame/timer 会与新路径错位，
            // 导致 Mode 切换瞬间画布渲染上一档 GIF 的某一帧（claude / cursor 互窜）。
            AnimatedGIFView(path: gifPath, fps: modeDraft.oled.framesPerSecond)
                .id(gifPath)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color.black.opacity(0.6), Color.black.opacity(0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(alignment: .center, spacing: 2) {
                    if modeDraft.mode == .mode0 {
                        HStack(spacing: 4) {
                            Image(systemName: "cloud.fill")
                                .font(.system(size: screenHeight * 0.24, weight: .semibold))
                                .foregroundStyle(Color.orange.opacity(0.92))
                            Text(modeDraft.mode.title)
                                .font(.system(size: screenHeight * 0.20, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Text("Default Animation")
                            .font(.system(size: screenHeight * 0.18))
                            .foregroundStyle(.white.opacity(0.55))
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: {
                                if #available(macOS 13, *) { "sparkles.rectangle.stack" } else { "rectangle.stack" }
                            }())
                                .font(.system(size: screenHeight * 0.22, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.78))
                            Text("Not Uploaded")
                                .font(.system(size: screenHeight * 0.20, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Text("Waiting for Customization")
                            .font(.system(size: screenHeight * 0.18))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .padding(screenWidth * 0.04)
                .multilineTextAlignment(.center)
            }
        }
    }

    private func keyButton(for role: AhaKeyKeyRole, width: CGFloat, height: CGFloat) -> some View {
        let part = role.part
        let keyDraft = modeDraft.key(for: role)
        let specs: (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)
        switch role {
        case .voice:
            specs = (10.2, 29.2, 16.2, 16.8)
        case .approve:
            specs = (27.2, 29.2, 16.2, 16.8)
        case .reject:
            specs = (44.2, 29.2, 16.2, 16.8)
        case .submit:
            specs = (61.2, 29.2, 16.2, 16.8)
        }
        let rect = frame(specs.x, specs.y, specs.w, specs.h, width: width, height: height)
        return Button {
            onSelect(part)
        } label: {
            VStack(spacing: rect.height * 0.07) {
                ZStack {
                    RoundedRectangle(cornerRadius: rect.width * 0.18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white, Color(red: 0.95, green: 0.96, blue: 0.98)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

                    keyIcon(for: role, size: rect.height * 0.28)
                }
                .frame(width: rect.width * 0.8, height: rect.height * 0.76)

                Text(keyDraft.description.isEmpty ? keyDraft.displaySummary : keyDraft.description)
                    .font(.system(size: rect.height * 0.11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: rect.width, height: rect.height)
            .modifier(HotspotChrome(part: part, selectedPart: selectedPart, dirtyParts: dirtyParts))
        }
        .buttonStyle(CanvasKeyButtonStyle())
        .position(x: rect.midX, y: rect.midY)
    }

    @ViewBuilder
    private func keyIcon(for role: AhaKeyKeyRole, size: CGFloat) -> some View {
        Image(systemName: role.systemImage)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(Color.black.opacity(0.88))
    }

    private func modeSwitchKey(width: CGFloat, height: CGFloat) -> some View {
        let rect = frame(78.9, 40.9, 8.0, 10.2, width: width, height: height)
        return Button {
            onModeSwitch()
        } label: {
            VStack(spacing: rect.height * 0.08) {
                ZStack {
                    RoundedRectangle(cornerRadius: rect.width * 0.2, style: .continuous)
                        .fill(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: rect.width * 0.2, style: .continuous)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: rect.height * 0.18, weight: .semibold))
                        .foregroundStyle(Color.accentColor.opacity(0.72))
                }
                .frame(width: rect.width * 0.78, height: rect.height * 0.5)

                Text("Mode")
                    .font(.system(size: rect.height * 0.1, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: rect.width, height: rect.height)
        }
        .buttonStyle(CanvasKeyButtonStyle())
        .position(x: rect.midX, y: rect.midY)
        .help("Click to switch Mode (simulates the physical key)")
    }

    private func switchButton(width: CGFloat, height: CGFloat) -> some View {
        let part = AhaKeyStudioPart.toggleSwitch
        let rect = frame(87.8, 35.6, 6.8, 10.6, width: width, height: height)
        return Button {
            onSelect(part)
            // 物理拨杆损坏的用户靠这个：点击即翻转 auto/manual。
            // 最新固件 0x91 用于灯效预览，因此这里只改 hook 软件覆盖。
            onSwitchToggle?()
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: rect.width * 0.18, style: .continuous)
                        .fill(Color.black.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: rect.width * 0.18, style: .continuous)
                                .stroke(Color.black.opacity(0.12), lineWidth: 1)
                        )
                    Capsule()
                        .fill(Color.white)
                        .frame(width: rect.width * 0.36, height: rect.height * 0.65)
                        .overlay(Circle().fill(Color.gray.opacity(0.24)).frame(width: rect.width * 0.28, height: rect.width * 0.28))
                        .offset(y: switchTitle == "Auto-Approve" ? -rect.height * 0.08 : rect.height * 0.12)
                }
                .frame(width: rect.width * 0.58, height: rect.height * 0.78)

                Text(switchTitle)
                    .font(.system(size: rect.height * 0.12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: rect.width, height: rect.height)
            .modifier(HotspotChrome(part: part, selectedPart: selectedPart, dirtyParts: dirtyParts))
        }
        .buttonStyle(CanvasKeyButtonStyle())
        .position(x: rect.midX, y: rect.midY)
    }

    private func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: x / baseWidth * width,
            y: y / baseHeight * height,
            width: w / baseWidth * width,
            height: h / baseHeight * height
        )
    }

    private func position(_ x: CGFloat, _ y: CGFloat, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(x: x / baseWidth * width, y: y / baseHeight * height)
    }

    private func scaled(_ value: CGFloat, in width: CGFloat) -> CGFloat {
        value / baseWidth * width
    }

    private func ledColors(effect: LightEffectStyle, time: TimeInterval, count: Int,
                           baseColor: Color = Self.firmwareRed) -> [Color] {
        switch effect {
        case .off:
            return Array(repeating: Color.gray.opacity(0.15), count: count)
        case .middleLight:
            let center = Double(count - 1) / 2.0
            return (0..<count).map { i in
                let dist = abs(Double(i) - center) / center
                let pulse = (sin(time * 1.5) + 1.0) / 2.0 * 0.15
                return baseColor.opacity(0.2 + (1.0 - dist) * 0.65 + pulse)
            }
        case .singleMove:
            let period = 2.4
            let t = time.truncatingRemainder(dividingBy: period) / period
            let pos = t < 0.5 ? t * 2.0 * Double(count - 1) : (1.0 - (t - 0.5) * 2.0) * Double(count - 1)
            return (0..<count).map { i in
                let dist = abs(Double(i) - pos)
                let brightness = max(0.0, 1.0 - dist * 0.75)
                return baseColor.opacity(0.12 + brightness * 0.82)
            }
        case .breathing:
            let breath = (sin(time * Double.pi * 0.9) + 1.0) / 2.0
            return Array(repeating: baseColor.opacity(0.12 + breath * 0.78), count: count)
        case .rainbowMove:
            let period = 2.4
            let t = time.truncatingRemainder(dividingBy: period) / period
            let pos = t < 0.5 ? t * 2.0 * Double(count - 1) : (1.0 - (t - 0.5) * 2.0) * Double(count - 1)
            return (0..<count).map { i in
                let dist = abs(Double(i) - pos)
                let brightness = max(0.0, 1.0 - dist * 0.7)
                let hue = (Double(i) / Double(count) + time * 0.25).truncatingRemainder(dividingBy: 1.0)
                return Color(hue: hue, saturation: 1.0, brightness: 0.15 + brightness * 0.85)
            }
        case .rainbowWave:
            return (0..<count).map { i in
                let hue = (Double(i) / Double(count) + time * 0.4).truncatingRemainder(dividingBy: 1.0)
                return Color(hue: hue, saturation: 1.0, brightness: 0.9)
            }
        case .rainbowWaveSlow:
            return (0..<count).map { i in
                let hue = (Double(i) / Double(count) + time * 0.14).truncatingRemainder(dividingBy: 1.0)
                return Color(hue: hue, saturation: 1.0, brightness: 0.9)
            }
        case .typingRipple:
            let center = Double(count - 1) / 2.0
            let phase = time.truncatingRemainder(dividingBy: 1.6) / 1.6
            let rippleRadius = phase * center * 1.8
            return (0..<count).map { i in
                let dist = abs(Double(i) - center)
                let wave = max(0, 1.0 - abs(dist - rippleRadius) * 0.8)
                return baseColor.opacity(0.1 + wave * 0.85)
            }
        case .comet:
            let period = 1.8
            let t = time.truncatingRemainder(dividingBy: period) / period
            let pos = t * Double(count + 3) - 1.5
            return (0..<count).map { i in
                let dist = Double(i) - pos
                let tail = dist >= 0 ? 0.0 : max(0, 1.0 + dist * 0.25)
                let head = dist >= 0 && dist < 1.5 ? max(0, 1.0 - dist * 0.65) : 0.0
                return baseColor.opacity(0.08 + max(tail, head) * 0.88)
            }
        case .scanBar:
            let period = 2.0
            let t = time.truncatingRemainder(dividingBy: period) / period
            let pos = t < 0.5 ? t * 2.0 * Double(count - 1) : (1.0 - (t - 0.5) * 2.0) * Double(count - 1)
            return (0..<count).map { i in
                let dist = abs(Double(i) - pos)
                let brightness = dist < 1.5 ? 1.0 - dist * 0.3 : 0.0
                return baseColor.opacity(0.08 + max(0, brightness) * 0.88)
            }
        case .pulseCenter:
            let center = Double(count - 1) / 2.0
            let pulse = (sin(time * Double.pi * 2.5) + 1.0) / 2.0
            return (0..<count).map { i in
                let dist = abs(Double(i) - center) / center
                let intensity = pulse * max(0, 1.0 - dist * 0.8)
                return baseColor.opacity(0.08 + intensity * 0.88)
            }
        case .warningBlink:
            let blink = sin(time * Double.pi * 4.0) > 0 ? 0.9 : 0.1
            let orange = Color(red: 1.0, green: 0.6, blue: 0.0)
            return Array(repeating: orange.opacity(blink), count: count)
        case .successSweep:
            let green = Color(red: 0.1, green: 0.85, blue: 0.3)
            let progress = time.truncatingRemainder(dividingBy: 2.0) / 2.0
            let fillPos = progress * Double(count + 2) - 1
            return (0..<count).map { i in
                let lit = Double(i) <= fillPos ? 1.0 : 0.0
                return green.opacity(0.08 + lit * 0.88)
            }
        case .blueThinking:
            let blue = Color(red: 0.2, green: 0.5, blue: 1.0)
            return (0..<count).map { i in
                let wave = (sin(time * Double.pi * 0.8 + Double(i) * 0.6) + 1.0) / 2.0
                return blue.opacity(0.15 + wave * 0.75)
            }
        case .lowBattery:
            let red = Color(red: 1.0, green: 0.15, blue: 0.1)
            let pulse = (sin(time * Double.pi * 0.5) + 1.0) / 2.0
            return Array(repeating: red.opacity(0.1 + pulse * 0.6), count: count)
        case .chargingFlow:
            let green = Color(red: 0.1, green: 0.85, blue: 0.3)
            let period = 3.0
            let progress = time.truncatingRemainder(dividingBy: period) / period
            let fillPos = progress * Double(count)
            return (0..<count).map { i in
                let lit = Double(i) < fillPos ? 0.85 : 0.08
                return green.opacity(lit)
            }
        case .approvalWait:
            let amber = Color(red: 1.0, green: 0.75, blue: 0.2)
            let center = Double(count - 1) / 2.0
            let breath = (sin(time * Double.pi * 1.2) + 1.0) / 2.0
            let centerBlink = sin(time * Double.pi * 3.0) > 0 ? 1.0 : 0.4
            return (0..<count).map { i in
                let dist = abs(Double(i) - center) / center
                let isCenter = dist < 0.2
                let intensity = isCenter ? centerBlink : breath * (1.0 - dist * 0.5)
                return amber.opacity(0.1 + intensity * 0.8)
            }
        }
    }

    private func openNativeSpeechPrivacySettings() {
        openNativeSpeechPrivacySettingsURL()
    }
}

private struct AnimatedGIFView: View {
    let path: String
    let fps: Int

    @State private var frames: [NSImage] = []
    @State private var currentFrame = 0
    @State private var gifTimer: Timer? = nil

    var body: some View {
        Group {
            if !frames.isEmpty, currentFrame >= 0, currentFrame < frames.count {
                Image(nsImage: frames[currentFrame])
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.black
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear { loadFrames() }
        .onDisappear {
            gifTimer?.invalidate()
            gifTimer = nil
        }
    }

    private func loadFrames() {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return }
        var images: [NSImage] = []
        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            images.append(NSImage(cgImage: cgImage, size: .zero))
        }
        frames = images
        currentFrame = 0
        guard count > 1 else { return }
        let interval = 1.0 / Double(max(fps, 1))
        gifTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            currentFrame = (currentFrame + 1) % max(1, frames.count)
        }
    }
}

private func openNativeSpeechPrivacySettingsURL() {
    let candidates = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
        "x-apple.systempreferences:com.apple.Siri-Settings.extension",
        "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.security?Privacy"
    ]

    openFirstAvailableSystemSettingsURL(candidates)
}

/// 输入监控 / 辅助功能 / 麦克风和语音转写：系统在「已拒绝」或部分版本下不会再弹权限窗。主动申请后打开「隐私与安全性」相关页，保证有可操作反馈。
@MainActor
private func openCombinedVoicePrivacySettingsURL() {
    // 勿用未文档化的 `x-apple.systemsettings` + `.extension` 等组合；在部分系统上会被当成「文稿」，
    // 连续弹出「在 App Store 搜索… / 选取应用程序」而非进入设置。
    let candidates = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
        "x-apple.systempreferences:com.apple.Siri-Settings.extension",
        "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.security?Privacy",
    ]
    if openFirstAvailableSystemSettingsURL(candidates) { return }
    let appPaths = [
        "/System/Applications/System Settings.app",
        "/System/Library/CoreServices/Applications/System Settings.app",
        "/System/Applications/System Preferences.app",
    ]
    for path in appPaths where FileManager.default.fileExists(atPath: path) {
        if NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
            return
        }
    }
}

@discardableResult
private func openFirstAvailableSystemSettingsURL(_ candidates: [String]) -> Bool {
    for candidate in candidates {
        guard let url = URL(string: candidate) else { continue }
        if NSWorkspace.shared.open(url) {
            return true
        }
    }
    return false
}

@MainActor
private func openFirstMissingVoicePermissionSettings(
    bleManager: AhaKeyBLEManager,
    voiceRelay: VoiceRelayService,
    nativeSpeech: NativeSpeechTranscriptionService
) {
    if !bleManager.bluetoothPermissionGranted || !bleManager.bluetoothPoweredOn {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"]) { return }
    }
    if !nativeSpeech.microphoneGranted {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]) { return }
    }
    if !nativeSpeech.speechRecognitionGranted {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"]) { return }
    }
    if !nativeSpeech.siriEnabled {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.Siri-Settings.extension"]) { return }
    }
    if !nativeSpeech.dictationEnabled {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.Keyboard-Settings.extension"]) { return }
    }
    if !voiceRelay.accessibilityGranted {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]) { return }
    }
    if !voiceRelay.inputMonitoringGranted {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]) { return }
    }
    openCombinedVoicePrivacySettingsURL()
}

/// 先走系统 API 申请；随后在桌面端打开「隐私与安全性」相关页。输入监控 / 辅助功能在多数 macOS 版本上**不会**像 iOS 那样弹窗，麦克风和语音在「已选择过」后也不再弹窗，因此必须配合系统设置界面。
@MainActor
private func requestPermissionsThenOpenPrivacySettingsIfNeeded(
    bleManager: AhaKeyBLEManager,
    voiceRelay: VoiceRelayService,
    nativeSpeech: NativeSpeechTranscriptionService,
    delay: TimeInterval = 0.45
) {
    bleManager.refreshBluetoothAuthorization()
    voiceRelay.refreshPermissions(requestIfNeeded: true)
    nativeSpeech.refreshPermissions(requestIfNeeded: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        bleManager.refreshBluetoothAuthorization()
        openFirstMissingVoicePermissionSettings(bleManager: bleManager, voiceRelay: voiceRelay, nativeSpeech: nativeSpeech)
    }
}

/// 先启动一个延迟重开助手，再退出当前进程。不要在旧进程仍存活时 `open -n`：
/// AppDelegate 有单实例保护，新实例会发现旧实例还在并立即退出，造成"新程序闪退、旧程序不关"。
private func relaunchApplicationForPermissionRefresh() {
    let bundlePath = Bundle.main.bundleURL.path
    let script = "sleep 0.8; /usr/bin/open \(shellQuoted(bundlePath))"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    do {
        try process.run()
    } catch {
        // 即使自动重开助手启动失败，也要让当前进程正常退出；用户可手动再打开。
    }

    NSApp.windows.forEach { $0.close() }
    NSApp.terminate(nil)

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        if NSApp.isRunning {
            exit(0)
        }
    }
}

private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

@MainActor
private func activateAhaKeyWindowForTextInput() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.keyWindow?.makeKeyAndOrderFront(nil)
    NSApp.mainWindow?.makeKeyAndOrderFront(nil)
}

/// 在系统「隐私与安全性」中改完权限后，用确认框引导用户：退出后由 `open -n` 自动拉起同一份 .app。
private struct RestartToApplyPermissionsButton: View {
    var title: String = "Quit and Reopen…"
    @State private var showConfirm = false

    var body: some View {
        Button(title) { showConfirm = true }
            .buttonStyle(.bordered)
            .help("After changing permissions in System Settings, this app must be restarted for detection to match the system.")
            .alert("Restart Required to Refresh Permissions", isPresented: $showConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Restart Now") { relaunchApplicationForPermissionRefresh() }
            } message: {
                Text("The app will quit first, then reopen automatically. After reopening, \"Recheck Permissions\" reads the latest system state.")
            }
    }
}

private struct DeviceInfoSheetContainer: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var bleManager: AhaKeyBLEManager

    var body: some View {
        VStack(spacing: 0) {
            deviceInfoTitleChrome
            sheetScrollView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            activateAhaKeyWindowForTextInput()
        }
    }

    @ViewBuilder
    private var sheetScrollView: some View {
        if #available(macOS 13.0, *) {
            ScrollView {
                sheetFormContent
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                sheetFormContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var sheetFormContent: some View {
        DeviceInfoView(bleManager: bleManager)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .padding(.top, 6)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var deviceInfoTitleChrome: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text("Device Info · Agent")
                    .font(.headline)
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark.circle.fill")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Divider()
        }
        .layoutPriority(1)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 48)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct CloudAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var account = CloudAccountManager.shared
    @StateObject private var optimizer = AhaTypeTextOptimizer.shared
    @FocusState private var focusedLoginField: LoginField?

    private enum LoginField {
        case phone
        case password
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Cloud Account · AhaType")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if account.isLoggedIn {
                        profileSection
                    } else {
                        loginSection
                    }

                    Divider()

                    ahaTypeSection
                }
                .padding(18)
            }
        }
        .alert("Cloud Account", isPresented: Binding(
            get: { account.alertMessage != nil },
            set: { if !$0 { account.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { account.alertMessage = nil }
        } message: {
            Text(account.alertMessage ?? "")
        }
        .onAppear {
            activateAhaKeyWindowForTextInput()
            optimizer.refreshFromDisk()
            if account.isLoggedIn {
                account.refreshProfile()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    activateAhaKeyWindowForTextInput()
                    focusedLoginField = .phone
                }
            }
        }
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Log in to use AhaType cloud LLM cleanup.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Phone Number", text: $account.phone)
                .textFieldStyle(.roundedBorder)
                .focused($focusedLoginField, equals: .phone)
                .onTapGesture {
                    activateAhaKeyWindowForTextInput()
                    focusedLoginField = .phone
                }
                .onSubmit { focusedLoginField = .password }

            SecureField("Password", text: $account.password)
                .textFieldStyle(.roundedBorder)
                .focused($focusedLoginField, equals: .password)
                .onTapGesture {
                    activateAhaKeyWindowForTextInput()
                    focusedLoginField = .password
                }
                .onSubmit { account.login() }

            Toggle("Remember Password", isOn: $account.rememberPassword)

            HStack(spacing: 10) {
                Button("Log In") { account.login() }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.isBusy)
                Button("Sign Up") { account.register() }
                    .buttonStyle(.bordered)
                    .disabled(account.isBusy)
            }

            Text(account.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(account.profileSummary)
                .font(.callout)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 8) {
                quotaRow(title: "Daily", value: account.quotaText("daily"))
                quotaRow(title: "Weekly", value: account.quotaText("weekly"))
                quotaRow(title: "Monthly", value: account.quotaText("monthly"))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            HStack(spacing: 10) {
                Button("Refresh") { account.refreshProfile() }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.isBusy)
                Button("Switch Account") {
                    account.prepareForRelogin()
                    focusedLoginField = .phone
                }
                .buttonStyle(.bordered)
                .disabled(account.isBusy)
                Button("Log Out") { account.logout() }
                    .buttonStyle(.bordered)
                    .disabled(account.isBusy)
            }

            rechargeSection

            HStack(spacing: 10) {
                TextField("Free Coupon Code", text: $account.couponCode)
                    .textFieldStyle(.roundedBorder)
                Button("Redeem") { account.redeemCoupon() }
                    .buttonStyle(.bordered)
                    .disabled(account.isBusy)
            }

            Text(account.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var rechargeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recharge Subscription")
                .font(.callout.weight(.semibold))

            HStack(spacing: 8) {
                ForEach(CloudRechargePlan.allCases) { plan in
                    Button {
                        account.createWechatOrder(plan: plan)
                    } label: {
                        VStack(spacing: 3) {
                            Text(plan.title)
                                .font(.caption.weight(.semibold))
                            Text(account.priceText(for: plan))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(plan.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .disabled(account.isBusy)
                }
            }

            if let order = account.paymentOrder {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        if let image = makeQRCodeImage(from: order.paymentURL) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 132, height: 132)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(order.plan.title) · \(order.amountText)")
                                .font(.caption.weight(.semibold))
                            Text("Scan with WeChat to pay; the quota refreshes automatically after successful payment.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Order: \(order.outTradeNo)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                            Text("Status: \(order.status)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Copy Payment Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(order.paymentURL, forType: .string)
                        }
                        .buttonStyle(.bordered)

                        Button("Refresh Payment") {
                            account.refreshCurrentPaymentOrder()
                        }
                        .buttonStyle(.bordered)
                        .disabled(account.isBusy)

                        Button("Close Order") {
                            account.clearPaymentOrder()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }

    private var ahaTypeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { optimizer.isEnabled },
                set: { optimizer.setEnabled($0) }
            )) {
                Text("Enable AhaType Cloud Cleanup")
                    .font(.callout.weight(.semibold))
            }
            .toggleStyle(.switch)

            Text("When on, native macOS transcription is sent for cloud cleanup before the cleaned text is pasted. When logged out, expired, or on network failure, it automatically falls back to the raw transcription.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(optimizer.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(optimizer.lastQuotaSummary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func quotaRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func makeQRCodeImage(from text: String) -> NSImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

private struct HotspotChrome: ViewModifier {
    let part: AhaKeyStudioPart
    let selectedPart: AhaKeyStudioPart
    let dirtyParts: Set<AhaKeyStudioPart>

    func body(content: Content) -> some View {
        let isSelected = selectedPart == part
        content
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    // 非选中时几乎隐形，避免每个 hotspot 都画一圈灰线和邻近元件视觉打架
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.black.opacity(0.015),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .overlay(alignment: .topTrailing) {
                if dirtyParts.contains(part) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .padding(8)
                }
            }
            // 选中态阴影从 10 收到 6，减少向邻近元件溢出的发光半径
            .shadow(color: isSelected ? Color.accentColor.opacity(0.18) : .clear, radius: 6)
    }
}

private struct OLEDMotionPreviewSheet: View {
    let modeTitle: String
    let assetPath: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(modeTitle) Animation Preview")
                        .font(.system(size: 20, weight: .semibold))
                    Text("This shows the GIF animation file you just selected.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.92))

                if let assetPath {
                    DraggableAnimatedGIFPreview(path: assetPath)
                        .padding(12)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: {
                            if #available(macOS 14, *) { "film.stack" } else { "film" }
                        }())
                            .font(.system(size: 34, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text("No animation selected yet")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                        .frame(minWidth: 480, minHeight: 240)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 460)
            .clipped()
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 380)
    }
}

/// 支持鼠标按住拖拽（上下左右）查看大图，避免仅靠滚轮导致横向浏览困难。
private struct DraggableAnimatedGIFPreview: View {
    let path: String
    @State private var imageSize = CGSize(width: 480, height: 240)
    @State private var offset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let viewportSize = proxy.size
            AnimatedGIFPreview(path: path)
                .frame(width: imageSize.width, height: imageSize.height)
                .position(
                    x: viewportSize.width / 2 + offset.width,
                    y: viewportSize.height / 2 + offset.height
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let proposed = CGSize(
                                width: dragStartOffset.width + value.translation.width,
                                height: dragStartOffset.height + value.translation.height
                            )
                            offset = clampOffset(proposed, imageSize: imageSize, viewportSize: viewportSize)
                        }
                        .onEnded { _ in
                            dragStartOffset = offset
                        }
                )
                .onAppear {
                    reloadImageSizeAndResetOffset()
                }
                .onChange(of: path) { _ in
                    reloadImageSizeAndResetOffset()
                }
        }
    }

    private func reloadImageSizeAndResetOffset() {
        if let image = NSImage(contentsOfFile: path), image.size.width > 0, image.size.height > 0 {
            imageSize = image.size
        } else {
            imageSize = CGSize(width: 480, height: 240)
        }
        offset = .zero
        dragStartOffset = .zero
    }

    private func clampOffset(_ proposed: CGSize, imageSize: CGSize, viewportSize: CGSize) -> CGSize {
        let maxX = max(0, (imageSize.width - viewportSize.width) / 2)
        let maxY = max(0, (imageSize.height - viewportSize.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}

private struct AnimatedGIFPreview: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 12
        imageView.layer?.masksToBounds = true
        imageView.imageAlignment = .alignCenter
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = NSImage(contentsOfFile: path)
    }
}

// MARK: - 帮助中心（内嵌弹窗）

private enum HelpTopic: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case modes = "The Four Modes"
    case canvas = "Canvas & Keys"
    case toggleSwitch = "Virtual Switch"
    case oled = "LCD Screen"
    case lightBar = "Light Bar Colors"
    case voice = "Voice Input"
    case diagnostics = "Permission Diagnostics"
    case faq = "FAQ"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .overview: return "sparkles"
        case .modes: return "square.grid.3x1.below.line.grid.1x2"
        case .canvas: return "keyboard"
        case .toggleSwitch: return "switch.2"
        case .oled: return "play.tv"
        case .lightBar: return "rainbow"
        case .voice: return "mic.circle"
        case .diagnostics: return "stethoscope"
        case .faq: return "questionmark.bubble"
        }
    }
}

private struct HelpCenterSheet: View {
    let studioDraft: AhaKeyStudioDraft
    let selectedMode: AhaKeyModeSlot
    @ObservedObject var bleManager: AhaKeyBLEManager
    @Environment(\.dismiss) private var dismiss
    @State private var topic: HelpTopic = .overview

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "book.closed.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text("AhaKey Studio Help Center")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.thinMaterial)

            Divider()

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 188)
                    .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                ScrollView {
                    contentForTopic
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(topic)
            }
        }
        .frame(width: 880, height: 620)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(HelpTopic.allCases) { t in
                Button {
                    topic = t
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t.iconName)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 18)
                        Text(t.rawValue)
                            .font(.callout)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(t == topic ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .foregroundStyle(t == topic ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    @ViewBuilder
    private var contentForTopic: some View {
        switch topic {
        case .overview:      OverviewTopicView()
        case .modes:         ModesTopicView(selectedMode: selectedMode)
        case .canvas:        CanvasTopicView()
        case .toggleSwitch:  ToggleSwitchTopicView(bleManager: bleManager)
        case .oled:          OLEDTopicView(studioDraft: studioDraft, bleManager: bleManager)
        case .lightBar:      LightBarTopicView()
        case .voice:         VoiceTopicView()
        case .diagnostics:   DiagnosticsTopicView()
        case .faq:           FAQTopicView()
        }
    }
}

// MARK: 帮助中心 - 通用排版

private struct HelpTitle: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(title).font(.title2.weight(.semibold))
            }
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 12)
    }
}

private struct HelpSection: View {
    let title: String
    let text: String

    init(title: String, body text: String) {
        self.title = title
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 14)
    }
}

private struct HelpNote: View {
    let icon: String
    let tint: Color
    let text: String

    init(_ icon: String, tint: Color = .orange, body text: String) {
        self.icon = icon
        self.tint = tint
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .padding(.top, 2)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(tint.opacity(0.25), lineWidth: 1)
                )
        )
        .padding(.vertical, 6)
    }
}

private struct HelpSwatch: View {
    let color: Color
    let label: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color)
                .frame(width: 22, height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: 帮助中心 - 各章节

private struct OverviewTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "sparkles",
                title: "Overview",
                subtitle: "AhaKey Studio is the macOS configuration hub for the AhaKey keypad"
            )

            HelpSection(
                title: "How the Three Pieces Work Together",
                body: """
                • Main app (the one you are using) — view config, remap keys, upload LCD animations, check diagnostics
                • Agent daemon — runs in the background; listens to IDE hooks (Claude / Cursor / Codex / Kimi) and forwards the current AI state to the keyboard over BLE
                • Keyboard firmware — drives light bar colors, LCD display, and key mappings from the BLE state it receives
                """
            )

            HelpSection(
                title: "BLE Ownership Is One-Way",
                body: """
                Only one process can hold the keyboard's BLE connection at a time:
                • By default the Agent owns it → hook states reach the keyboard in real time and the auto-approve chain works
                • When you click \"Edit\" on the canvas → the main app temporarily takes over; it can upload LCD animations, remap keys, and read picture metadata
                • Click \"Back\" → the main app releases it and the Agent automatically takes over again
                """
            )

            HelpNote("info.circle.fill", tint: .blue, body: "On first connection, open \"Permission Diagnostics\" to go through the permission items; most hook issues come down to permissions.")
        }
    }
}

private struct ModesTopicView: View {
    let selectedMode: AhaKeyModeSlot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "square.grid.3x1.below.line.grid.1x2",
                title: "The Four Modes",
                subtitle: "Hardware key codes + software config switch in sync"
            )

            ForEach(AhaKeyModeSlot.allCases) { mode in
                modeCard(mode)
            }

            HelpNote("hand.tap.fill", tint: .accentColor, body: "How to switch: the Mode lever on the keyboard, the picker at the top of the main app, or the Mode button on the canvas. Changing any one syncs the other two.")
        }
    }

    @ViewBuilder
    private func modeCard(_ mode: AhaKeyModeSlot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(mode.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(modeChipColor(mode), in: Capsule())
                Text(mode.name).font(.headline)
                if mode == selectedMode {
                    Text("Current").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            Text(mode.subtitle).font(.callout).foregroundStyle(.secondary)
            Text(mode.guidance).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .padding(.bottom, 6)
    }

    private func modeChipColor(_ mode: AhaKeyModeSlot) -> Color {
        switch mode {
        case .mode0: return Color.orange
        case .mode1: return Color.purple
        case .mode2: return Color.green
        case .mode3: return Color.blue
        }
    }
}

private struct CanvasTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "keyboard",
                title: "Canvas & Keys",
                subtitle: "The keyboard-like drawing in the middle is a 1:1 mirror of your keypad — every element is clickable"
            )

            HelpSection(title: "Six Hotspots", body: "Light bar, LCD screen, Key1 (voice), Key2, Key3, Key4, and the switch. Click any of them to see its configuration in the Inspector on the right.")

            VStack(alignment: .leading, spacing: 10) {
                hotspotRow("rainbow", "Light Bar", "Lights up the 8 WS2812 LEDs on top of the keyboard; colors and effects follow IDE hook state.")
                hotspotRow("play.tv", "LCD Screen", "0.96\" IPS display; upload GIF animations (160×80, RGB565).")
                hotspotRow("mic", "Key 1 / Voice Key", "Native macOS voice defaults to F18; Typeless / WeChat Fn triggering uses F19.")
                hotspotRow("checkmark.circle", "Key 2 / Approve Key", "Mode-dependent defaults: Y / ↵ / ↵. Can be changed to a macro sequence.")
                hotspotRow("xmark.circle", "Key 3 / Reject Key", "Mode-dependent defaults: N / ⌫ / Esc. Can be changed to a macro sequence.")
                hotspotRow("delete.left", "Key 4 / Delete Key", "Defaults to Backspace; can be changed to any short-press / long-press.")
                hotspotRow("switch.2", "Switch", "Auto-approve vs manual approval; see the \"Virtual Switch\" chapter.")
            }

            HelpNote("hand.point.up.left", tint: .accentColor, body: """
                After clicking an element, the Inspector shows the \"Edit\" button. Clicking \"Edit\" takes over BLE and enters editing mode; when done, click \"Write to Keyboard\" to write the config, or \"Back\" to exit editing.
                """)
        }
    }

    private func hotspotRow(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(.tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(desc).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct ToggleSwitchTopicView: View {
    @ObservedObject var bleManager: AhaKeyBLEManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "switch.2",
                title: "Virtual Switch",
                subtitle: "Broken physical switch? Or want software control? Read on"
            )

            HelpSection(title: "What Each Position Does", body: """
                • Auto-Approve (switchState=0): hooks intercept each tool call / command request and allow it directly
                • Manual Approval (switchState=1): hooks hand the decision back to the terminal; you press Key2/Key3 to approve or reject
                """)

            VStack(alignment: .leading, spacing: 8) {
                Text("Clicking the canvas switch triggers three things (not all take effect):").font(.subheadline.weight(.medium))
                triggerRow(
                    num: "1",
                    title: "Optimistic canvas update",
                    desc: "Immediately flips the canvas switch position + top status bar; zero visual delay",
                    works: true
                )
                triggerRow(
                    num: "2",
                    title: "Notify the Agent to set userSwitchOverride",
                    desc: "The hook's auto-approve immediately switches to your selected position. Persisted to UserDefaults, still effective after an agent restart",
                    works: true
                )
                triggerRow(
                    num: "3",
                    title: "Software switch override",
                    desc: "In the latest firmware, 0x91 is used for lighting preview; the virtual switch only affects hook auto-approve and no longer writes the keyboard's sw_state.",
                    works: false,
                    requiresPatch: false
                )
            }

            HelpNote("exclamationmark.triangle.fill", tint: .orange, body: "The virtual switch no longer uses 0x91, avoiding conflicts with the latest firmware's lighting preview command.")

            VStack(alignment: .leading, spacing: 8) {
                Text("Current State").font(.subheadline.weight(.medium))
                stateRow("Current Effective Value", "\(bleManager.agentSwitchState ?? bleManager.switchState)")
                stateRow("Agent Override", bleManager.agentSwitchState != nil ? "\(bleManager.agentSwitchState!) (overriding)" : "Not set (using the keyboard's real value)")
                stateRow("Optimistic Display", bleManager.optimisticSwitchOverride != nil ? "Yes (waiting to align)" : "No")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    private func triggerRow(num: String, title: String, desc: String, works: Bool, requiresPatch: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(num)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(works ? Color.green : Color.orange))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.medium))
                    if requiresPatch {
                        Text("Requires Firmware").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                    }
                }
                Text(desc).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func stateRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospaced())
        }
    }
}

private struct OLEDTopicView: View {
    let studioDraft: AhaKeyStudioDraft
    @ObservedObject var bleManager: AhaKeyBLEManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "play.tv",
                title: "LCD Screen",
                subtitle: "0.96\" IPS · 160×80 · RGB565 · built-in 16 Mbit flash for frames"
            )

            HelpSection(title: "Default Animations (Auto-Synced on Connect)", body: """
                Mode 1 → claude_0.gif (built-in from factory)
                Mode 2 → cursor.gif
                Mode 3 → codex.gif
                Mode 4 → reserved/custom

                On first connection, if a Mode's flash slot is empty, the main app automatically pushes the corresponding bundled GIF to the keyboard.
                """)

            HelpSection(title: "Replace with Your Own GIF", body: """
                1. Click the LCD screen on the canvas → the Inspector shows \"Edit\"
                2. Click \"Edit\" to enter editing mode (takes over BLE)
                3. Choose your .gif (≤200 frames, ≤2 MB recommended); you can preview it on the virtual screen first
                4. When ready, click \"Write to Keyboard\" at the bottom to write it to the device
                """)

            HelpSection(title: "What the LCD Badge Means", body: """
                • Green \"✓ Uploaded N frames\": the keyboard flash really contains N frames (pushed by you or auto-sync)
                • Gray \"Not Uploaded\": the keyboard flash is empty, showing the firmware default or nothing
                • No badge: BLE has not been taken over to query yet (click \"Edit\" once and it appears)
                """)

            VStack(alignment: .leading, spacing: 6) {
                Text("Current keyboard flash state per Mode").font(.subheadline.weight(.medium))
                ForEach(AhaKeyModeSlot.allCases) { mode in
                    HStack {
                        Text(mode.title + " · " + mode.name).font(.callout)
                        Spacer()
                        if let s = bleManager.keyboardPictureStates[mode.rawValue] {
                            if s.frameCount > 0 {
                                Label("\(s.frameCount) frames", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.callout)
                            } else {
                                Label("Empty", systemImage: "tray").foregroundStyle(.secondary).font(.callout)
                            }
                        } else {
                            Text("Not Queried Yet").font(.callout).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))

            HelpNote("info.circle.fill", tint: .blue, body: "When switching Modes, the LCD briefly flashes the current key description text (a mechanical feel), then returns to that Mode's animation after about 1 second.")
        }
    }
}

private struct LightBarTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "rainbow",
                title: "Light Bar Colors",
                subtitle: "8 WS2812B LEDs; colors decided by the firmware's update_claude_ws2812(), mirrored 1:1 on the canvas"
            )

            HelpSection(title: "Color Reference", body: "Below is the firmware's actual behavior per IDE state in Mode 1 (Claude):")

            VStack(alignment: .leading, spacing: 8) {
                HelpSwatch(
                    color: Color(red: 240/255, green: 32/255, blue: 41/255),
                    label: "0xF02029 (Red)",
                    detail: "SessionStart / Stop / PostToolUse / PermissionRequest / UserPromptSubmit"
                )
                HelpSwatch(
                    color: Color(red: 32/255, green: 80/255, blue: 255/255),
                    label: "0x2050FF (Blue)",
                    detail: "PreToolUse — tool starts executing (manual position only)"
                )
                HelpSwatch(
                    color: Color.gray.opacity(0.3),
                    label: "OFF (dark)",
                    detail: "SessionEnd — Claude session ended"
                )
            }

            HelpSection(title: "Rainbow Override in Auto Position", body: """
                When the switch = auto (switchState=0), the firmware forces some states to rainbow effects:
                • PreToolUse / PermissionRequest → full rainbow wave
                • PostToolUse / UserPromptSubmit → single-point rainbow flow
                This is why \"the light bar turns rainbow when Cursor runs\" — it is a visual hint of the auto position, not Cursor-specific.
                """)

            HelpNote("exclamationmark.triangle.fill", tint: .orange, body: "In Mode 1 / Mode 2, the firmware's update_claude_ws2812() returns immediately — **the light bar no longer follows IDE state** and stays on the last set color. This is by firmware design, not a bug.")
        }
    }
}

private struct VoiceTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "mic.circle",
                title: "Voice Input",
                subtitle: "Native macOS voice uses F18; Fn / Globe triggering uses F19"
            )

            HelpSection(title: "Differences Between Presets", body: """
                • macOS native transcription: on-device language recognition, then ⌘V writes the result back at the cursor. Works in any text field
                • Fn/Globe: for Typeless, WeChat Voice, and Doubao IME — set the shortcut to Fn/Globe inside the corresponding app
                • Custom shortcut: only written to the keyboard; not taken over as a fixed voice preset
                • AhaType: recognize first, then optimize the text (login required)
                """)

            HelpSection(title: "Short Press vs Long Press", body: """
                • Short press (Toggle): first press starts, second press stops — good for long passages
                • Long press (Hold-to-speak): records while held, stops on release — good for WeChat, Doubao, and other input methods that need \"hold\"

                Switch between the two modes in the \"Trigger\" tab of the Key 1 Inspector.
                """)

            HelpNote("hand.raised.fill", tint: .red, body: "Microphone + Input Monitoring + Accessibility permissions are all required. Open \"Permission Diagnostics\" to jump to the corresponding System Settings page with one click.")
        }
    }
}

private struct DiagnosticsTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "stethoscope",
                title: "Permission Diagnostics",
                subtitle: "Opened via the \"Permission Diagnostics\" button in the bottom bar (not this page)"
            )

            HelpSection(title: "Permission Checklist", body: """
                • Bluetooth: required to connect to the keyboard
                • Microphone: needed by Apple native transcription, AhaType, hold-to-talk — all voice features
                • Input Monitoring: captures voice key press/release events
                • Accessibility: simulates keyboard keys (for ⌘V text write-back, Fn/Globe injection, etc.)
                • Speech Recognition: Apple native transcription
                • Siri & Dictation (macOS 13+): dependencies of native transcription
                """)

            HelpSection(title: "Agent Health Check", body: """
                Open \"Permission Diagnostics\" to see the Agent self-check results:
                • LaunchAgent registered: login item installed
                • Process running: launchd has launched ahakeyconfig-agent
                • Hooks configured: the .json / settings for Claude/Cursor/Codex/Kimi all reference ahakey-hook
                """)

            HelpSection(title: "Where Is the Transcription Test", body: "In the Permission Diagnostics panel. You can verify whether native macOS transcription works without connecting the keyboard. If transcription fails, it is usually the Microphone permission or a missing language model (System Settings → Siri & Dictation → Dictation languages).")
        }
    }
}

private struct FAQTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "questionmark.bubble",
                title: "FAQ",
                subtitle: "If your question is not listed below, open an issue on the GitHub repo"
            )

            faq(
                q: "Hooks don't intercept; the AI still stops and asks me",
                a: """
                Troubleshoot in this order:
                1. Is the Agent running? Check in \"Permission Diagnostics\"
                2. Does the Agent own Bluetooth? The top of the canvas should show Connected and not be in editing mode
                3. Is the switch in the auto position? Check the top status bar; if not, click the canvas switch to flip to auto
                4. Are the IDE hook files configured? \"Permission Diagnostics\" lists the hook install status for Claude/Cursor/Codex/Kimi
                5. Did you restart the IDE after installing? Kimi in particular must be fully quit and reopened after install/upgrade
                """
            )

            faq(
                q: "The light bar on the canvas doesn't change color",
                a: """
                • Check whether the top right shows \"Connected\"
                • Switch to the Mode you are currently using
                • Trigger a tool call so the hook actually sends 0x90 to the keyboard
                • If in manual approval position + Mode 1: preToolUse is blue, other states are red
                """
            )

            faq(
                q: "LCD auto-sync didn't trigger",
                a: """
                Auto-sync only queries picture metadata while the main app owns BLE. Flow:
                1. Click \"Edit\" at least once so the main app takes over BLE
                2. It triggers only after the 0x83 query for all four Modes completes
                3. It only applies to Modes whose flash is empty (picLength=0)
                4. If you have manually changed the \"upload GIF\" path in the Inspector, auto-sync skips that Mode (it won't override your choice)
                """
            )

            faq(
                q: "I clicked the switch, but the keyboard lighting didn't change",
                a: """
                In the latest firmware, 0x91 is used for lighting preview. The virtual switch is only a hook software override and no longer writes the keyboard's sw_state.
                """
            )

            faq(
                q: "Is OTA upgrade available?",
                a: """
                Planned for the next version. Currently all firmware upgrades require USB-ISP (open the case, short BOOT + wchisp). Details are in the repo docs.
                """
            )
        }
    }

    private func faq(q: String, a: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.tint)
                    .padding(.top, 1)
                Text(q).font(.callout.weight(.medium))
            }
            Text(a)
                .font(.callout)
                .foregroundStyle(.primary)
                .padding(.leading, 26)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.leading, 26).padding(.top, 4)
        }
        .padding(.vertical, 8)
    }
}
