import SwiftUI

enum UnifiedOnboardingStorage {
    static let completedKey = "AhaKey.UnifiedOnboarding.v2.completed"
    static let micGrantedKey = "AhaKey.UnifiedOnboarding.v2.micPreGranted"
    static let pasteGrantedKey = "AhaKey.UnifiedOnboarding.v2.pastePreGranted"
    static let currentStepKey = "AhaKey.UnifiedOnboarding.v2.currentStep"
}

struct AhaKeyOnboardingPermissionState: Equatable {
    var bluetoothPermissionGranted: Bool
    var bluetoothPoweredOn: Bool
    var inputMonitoringGranted: Bool
    var accessibilityGranted: Bool
    var microphoneGranted: Bool
    var speechRecognitionGranted: Bool
    var siriEnabled: Bool
    var dictationEnabled: Bool
    var voiceSummary: String
    var speechSummary: String
    var isRecording: Bool
    var transcriptPreview: String
    var lastCommittedText: String
    var speechStatusMessage: String

    var bluetoothReady: Bool {
        bluetoothPermissionGranted && bluetoothPoweredOn
    }

    var backgroundPermissionsGranted: Bool {
        inputMonitoringGranted && accessibilityGranted
    }

    var nativeSpeechPermissionsGranted: Bool {
        microphoneGranted && speechRecognitionGranted && siriEnabled && dictationEnabled
    }

    var allPermissionsGranted: Bool {
        bluetoothReady && backgroundPermissionsGranted && nativeSpeechPermissionsGranted
    }

    var canTrySpeechInput: Bool {
        microphoneGranted && speechRecognitionGranted
    }
}

struct AhaKeyOnboardingActions {
    var requestPermissions: () -> Void
    var requestPermission: (AhaKeyOnboardingPermissionKind) -> Void
    var recheckPermissions: () -> Void
    var openSystemSettings: () -> Void
    var toggleTryExperience: () -> Void
}

enum AhaKeyOnboardingPermissionKind {
    case bluetooth
    case inputMonitoring
    case accessibility
    case microphone
    case speechRecognition
    case siri
    case dictation
}

struct UnifiedAhaKeyOnboardingView: View {
    var permissionState: AhaKeyOnboardingPermissionState
    var actions: AhaKeyOnboardingActions
    var onCompleted: (_ micGranted: Bool, _ pasteGranted: Bool) -> Void

    @State private var step: AhaKeyOnboardingStep = .restoredProgress
    @State private var didRunTryExperience = false
    @State private var tryInputFieldText = ""
    @FocusState private var tryInputFieldFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 980
            let contentMinHeight = max(420, geometry.size.height - 116)
            VStack(spacing: 0) {
                topBar
                Divider().opacity(0.45)
                if compact {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            mainPanel
                            guidePanel
                        }
                        .padding(24)
                        .padding(.bottom, 12)
                    }
                } else {
                    ScrollView {
                        HStack(alignment: .top, spacing: 0) {
                            mainPanel
                                .frame(width: max(500, geometry.size.width * 0.48), alignment: .topLeading)
                                .padding(.horizontal, 48)
                                .padding(.vertical, 34)
                                .background(Color(nsColor: .textBackgroundColor))

                            Divider().opacity(0.45)

                            guidePanel
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(.horizontal, 46)
                                .padding(.vertical, 34)
                                .background(Color(nsColor: .windowBackgroundColor))
                        }
                        .frame(maxWidth: .infinity, minHeight: contentMinHeight, alignment: .topLeading)
                    }
                }
                Divider().opacity(0.45)
                bottomNavigationBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .onAppear {
            resumeProgressIfReady()
        }
        .onChange(of: step) { newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: UnifiedOnboardingStorage.currentStepKey)
        }
        .onChange(of: permissionState) { _ in
            resumeProgressIfReady()
        }
        .onChange(of: permissionState.transcriptPreview) { newValue in
            if !newValue.isEmpty {
                didRunTryExperience = true
            }
        }
        .onChange(of: permissionState.lastCommittedText) { newValue in
            if !newValue.isEmpty {
                didRunTryExperience = true
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 18) {
            Spacer(minLength: 0)
            stepper
            Spacer(minLength: 0)
            Button("Skip") {
                finish()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.trailing, 22)
        }
        .padding(.vertical, 12)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // 顶部步骤导航，所有步骤均可点击跳转
    private var stepper: some View {
        HStack(spacing: 12) {
            ForEach(AhaKeyOnboardingStep.allCases) { item in
                HStack(spacing: 12) {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            moveToStep(item)
                        }
                    } label: {
                        Text(item.title)
                            .font(.system(size: 15, weight: step == item ? .semibold : .medium))
                            .foregroundStyle(step == item ? Color.primary : Color.secondary)
                            .frame(width: 78, height: 34)
                            .contentShape(Rectangle())
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(step == item ? Color.primary : Color.clear)
                                    .frame(height: 2)
                            }
                    }
                    .buttonStyle(.plain)

                    if item != AhaKeyOnboardingStep.allCases.last {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Main Panel

    @ViewBuilder
    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch step {
            case .welcome:
                welcomePanel
            case .dialogPermissions:
                dialogPermissionsPanel
            case .settingsPermissions:
                settingsPermissionsPanel
            case .tryInput:
                tryInputPanel
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var welcomePanel: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Set Up AhaKey on This Mac")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Connect the keyboard, take over the voice key in the background, enable macOS native speech, and try a real input experience.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 14) {
                onboardingCard(systemImage: "keyboard", title: "Connect & Control", detail: "Once Bluetooth is on, AhaKey Studio takes over the factory voice key and syncs the current Mode.")
                onboardingCard(systemImage: "lock.shield", title: "Step-by-Step Authorization", detail: "First complete the dialog permissions for Bluetooth, Microphone, and Speech Recognition, then turn on Siri, Dictation, and Accessibility in order, and finally handle Input Monitoring and restart.")
                onboardingCard(systemImage: "mic", title: "Try Input", detail: "Finally, dictate a sentence to confirm that recognition and text insertion are ready.")
            }
        }
    }

    private var dialogPermissionsPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(
                title: "Step 1: Dialog Permissions",
                detail: "For each permission below, click \"Request\" and a system dialog will appear — just click Allow."
            )

            VStack(spacing: 12) {
                PermissionStatusRow(
                    title: "Bluetooth",
                    detail: bluetoothDetail,
                    granted: permissionState.bluetoothReady,
                    actionTitle: permissionState.bluetoothReady ? nil : "Request",
                    action: { actions.requestPermission(.bluetooth) }
                )
                PermissionStatusRow(
                    title: "Microphone",
                    detail: "Allow AhaKey Studio to use Apple's native audio capture.",
                    granted: permissionState.microphoneGranted,
                    actionTitle: permissionState.microphoneGranted ? nil : "Request",
                    action: { actions.requestPermission(.microphone) }
                )
                PermissionStatusRow(
                    title: "Speech Recognition",
                    detail: "Allow AhaKey Studio to use Apple's native speech recognition.",
                    granted: permissionState.speechRecognitionGranted,
                    actionTitle: permissionState.speechRecognitionGranted ? nil : "Request",
                    action: { actions.requestPermission(.speechRecognition) }
                )
            }

            HStack(spacing: 10) {
                Button("Recheck") {
                    actions.recheckPermissions()
                }
                .buttonStyle(OnboardingSecondaryButtonStyle())
            }

        }
    }

    private var settingsPermissionsPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(
                title: "Step 2: System Settings Permissions",
                detail: "These permissions must be turned on manually in System Settings. Click \"Open Settings\" and enable them there."
            )

            VStack(spacing: 12) {
                PermissionStatusRow(
                    title: "Siri",
                    detail: "Turn on Siri in System Settings > Siri & Spotlight.",
                    granted: permissionState.siriEnabled,
                    actionTitle: permissionState.siriEnabled ? nil : "Open Settings",
                    action: { actions.requestPermission(.siri) }
                )
                PermissionStatusRow(
                    title: "Dictation",
                    detail: "Turn on Dictation in System Settings > Keyboard > Dictation.",
                    granted: permissionState.dictationEnabled,
                    actionTitle: permissionState.dictationEnabled ? nil : "Open Settings",
                    action: { actions.requestPermission(.dictation) }
                )
                PermissionStatusRow(
                    title: "Accessibility",
                    detail: "Allow AhaKey Studio to convert the voice key into macOS native transcription or Fn/Globe.",
                    granted: permissionState.accessibilityGranted,
                    actionTitle: permissionState.accessibilityGranted ? nil : "Open Settings",
                    action: { actions.requestPermission(.accessibility) }
                )
                PermissionStatusRow(
                    title: "Input Monitoring",
                    detail: "Allow AhaKey Studio to listen for the physical voice key in the background; you usually need to quit and reopen the app after enabling this.",
                    granted: permissionState.inputMonitoringGranted,
                    actionTitle: permissionState.inputMonitoringGranted ? nil : "Open Settings",
                    action: {
                        UserDefaults.standard.set(AhaKeyOnboardingStep.tryInput.rawValue, forKey: UnifiedOnboardingStorage.currentStepKey)
                        actions.requestPermission(.inputMonitoring)
                    }
                )
            }

            HStack(spacing: 10) {
                Button("Recheck") {
                    actions.recheckPermissions()
                }
                .buttonStyle(OnboardingSecondaryButtonStyle())
            }

        }
    }

    private var tryInputPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(
                title: "Step 3: Try Input",
                detail: "Connect the keypad via Bluetooth, place the cursor here, and press the microphone key to start speaking."
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(permissionState.isRecording ? Color.red : (permissionState.canTrySpeechInput ? Color.green : Color.orange))
                        .frame(width: 10, height: 10)
                    Text(permissionState.isRecording ? "Recording" : (permissionState.canTrySpeechInput ? "Speech Ready" : "Speech Permissions Missing"))
                        .font(.system(size: 15, weight: .semibold))
                }

                ZStack(alignment: .topLeading) {
                    if tryInputFieldText.isEmpty {
                        Text("Connect the keypad via Bluetooth, place the cursor here, and press the microphone key to start speaking")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                    }
                    TextEditor(text: $tryInputFieldText)
                        .font(.system(size: 18, weight: .medium))
                        .focused($tryInputFieldFocused)
                        .modifier(HideScrollContentBackgroundModifier())
                }
                .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .onAppear { tryInputFieldFocused = true }

                Text(permissionState.speechStatusMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(permissionState.isRecording ? "Stop & Insert" : "Start Speaking") {
                    didRunTryExperience = true
                    actions.toggleTryExperience()
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(!permissionState.canTrySpeechInput)

                Button("Recheck") {
                    actions.recheckPermissions()
                }
                .buttonStyle(OnboardingSecondaryButtonStyle())
            }

        }
    }

    // MARK: - Guide Panel（右侧，分组高亮）

    private var guidePanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(step.guideTitle)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.primary)
            Text(step.guideDetail)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                PermissionGroupSection(
                    groupLabel: "Dialog Permissions",
                    isHighlighted: step == .dialogPermissions,
                    items: [
                        ("Bluetooth", permissionState.bluetoothReady),
                        ("Microphone", permissionState.microphoneGranted),
                        ("Speech Recognition", permissionState.speechRecognitionGranted),
                    ]
                )

                PermissionGroupSection(
                    groupLabel: "System Settings Permissions",
                    isHighlighted: step == .settingsPermissions || step == .tryInput,
                    items: [
                        ("Siri", permissionState.siriEnabled),
                        ("Dictation", permissionState.dictationEnabled),
                        ("Accessibility", permissionState.accessibilityGranted),
                        ("Input Monitoring", permissionState.inputMonitoringGranted),
                    ]
                )
            }

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 8) {
                Text("Current Status")
                    .font(.system(size: 15, weight: .semibold))
                Text(permissionState.voiceSummary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(permissionState.speechSummary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Bottom Navigation（文字次级按钮）

    private var bottomNavigationBar: some View {
        HStack(spacing: 0) {
            Spacer()

            if step != .welcome {
                Button("Back") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        moveToStep(step.previous)
                    }
                }
                .buttonStyle(OnboardingTextButtonStyle())
            }

            Button(bottomNextTitle) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    goForward()
                }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .padding(.leading, step == .welcome ? 0 : 8)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var bottomNextTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .tryInput: return "Enter Workspace"
        default: return "Next"
        }
    }

    // MARK: - Helpers

    private var bluetoothDetail: String {
        if !permissionState.bluetoothPermissionGranted {
            return "Allow AhaKey Studio to scan for and connect to the AhaKey keyboard."
        }
        if !permissionState.bluetoothPoweredOn {
            return "Authorized, but Bluetooth is currently off. Turn it on in Control Center or System Settings."
        }
        return "Bluetooth is available and can scan for and connect to the keyboard."
    }

    private var manualSettingsPermissionsGranted: Bool {
        permissionState.siriEnabled &&
            permissionState.dictationEnabled &&
            permissionState.accessibilityGranted &&
            permissionState.inputMonitoringGranted
    }

    private var tryPreviewText: String {
        if !permissionState.transcriptPreview.isEmpty {
            return permissionState.transcriptPreview
        }
        if !permissionState.lastCommittedText.isEmpty {
            return permissionState.lastCommittedText
        }
        return "Real-time recognition or the most recently inserted text will appear here."
    }

    private func sectionHeader(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func onboardingCard(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func moveToStep(_ next: AhaKeyOnboardingStep) {
        step = next
        UserDefaults.standard.set(next.rawValue, forKey: UnifiedOnboardingStorage.currentStepKey)
    }

    private func resumeProgressIfReady() {
        guard step == .settingsPermissions, manualSettingsPermissionsGranted else { return }
        moveToStep(.tryInput)
    }

    private func goForward() {
        if step == .tryInput {
            finish()
            return
        }
        moveToStep(AhaKeyOnboardingStep(rawValue: min(AhaKeyOnboardingStep.tryInput.rawValue, step.rawValue + 1)) ?? .tryInput)
    }

    private func finish() {
        UserDefaults.standard.set(permissionState.microphoneGranted, forKey: UnifiedOnboardingStorage.micGrantedKey)
        UserDefaults.standard.set(permissionState.backgroundPermissionsGranted, forKey: UnifiedOnboardingStorage.pasteGrantedKey)
        UserDefaults.standard.removeObject(forKey: UnifiedOnboardingStorage.currentStepKey)
        onCompleted(permissionState.microphoneGranted, permissionState.backgroundPermissionsGranted)
    }
}

// MARK: - Permission Group Section（右侧分组视窗）

private struct PermissionGroupSection: View {
    var groupLabel: String
    var isHighlighted: Bool
    var items: [(String, Bool)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(groupLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHighlighted ? Color.accentColor : Color.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.0) { title, granted in
                    summaryRow(title: title, granted: granted)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHighlighted ? Color.accentColor.opacity(0.06) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isHighlighted ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1.5)
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isHighlighted)
    }

    private func summaryRow(title: String, granted: Bool) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
            Text(title)
                .font(.system(size: 14, weight: .medium))
            Spacer()
            Text(granted ? "Enabled" : "Not Enabled")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(granted ? Color.green : Color.orange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Permission Status Row

private struct PermissionStatusRow: View {
    var title: String
    var detail: String
    var granted: Bool
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                    Text(granted ? "Enabled" : "Not Enabled")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(granted ? Color.green : Color.orange)
                }
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                if granted {
                    Button(actionTitle) {
                        action()
                    }
                    .buttonStyle(OnboardingSecondaryButtonStyle())
                    .disabled(true)
                    .padding(.top, 1)
                } else {
                    Button(actionTitle) {
                        action()
                    }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .padding(.top, 1)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Onboarding Steps

private enum AhaKeyOnboardingStep: Int, CaseIterable, Identifiable {
    static var restoredProgress: AhaKeyOnboardingStep {
        let rawValue = UserDefaults.standard.integer(forKey: UnifiedOnboardingStorage.currentStepKey)
        return AhaKeyOnboardingStep(rawValue: rawValue) ?? .welcome
    }

    case welcome
    case dialogPermissions
    case settingsPermissions
    case tryInput

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .dialogPermissions: return "Dialogs"
        case .settingsPermissions: return "Settings"
        case .tryInput: return "Try It"
        }
    }

    var previous: AhaKeyOnboardingStep {
        AhaKeyOnboardingStep(rawValue: max(0, rawValue - 1)) ?? .welcome
    }

    var guideTitle: String {
        switch self {
        case .welcome: return "Setup Roadmap"
        case .dialogPermissions: return "First, complete the dialog-confirmed permissions"
        case .settingsPermissions: return "Then turn on the rest in System Settings"
        case .tryInput: return "Finally, try a real input"
        }
    }

    var guideDetail: String {
        switch self {
        case .welcome:
            return "The guide authorizes in two stages: first complete the permissions confirmed via system dialogs, then turn on the rest in System Settings, and finally try input."
        case .dialogPermissions:
            return "Bluetooth, Microphone, and Speech Recognition can be confirmed directly in a dialog — click \"Request\" and allow it in the popup."
        case .settingsPermissions:
            return "Turn on Siri, Dictation, and Accessibility in order, then Input Monitoring last. After enabling Input Monitoring you usually need to quit and reopen the app; this guide remembers your progress."
        case .tryInput:
            return "This tests the same speech pipeline used in the app — it's no longer just showing permission status."
        }
    }
}

// MARK: - Button Styles

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 34)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.82 : 1.0), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(Color(nsColor: .controlBackgroundColor).opacity(configuration.isPressed ? 0.7 : 1.0), in: RoundedRectangle(cornerRadius: 7))
    }
}

// 次级文字按钮（底部导航"上一步"使用）
private struct OnboardingTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(configuration.isPressed ? Color.secondary : Color.primary)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .contentShape(Rectangle())
    }
}

private struct HideScrollContentBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}
