import SwiftUI

/// 单个键的映射配置
struct KeyConfig: Codable {
    var hidCode: UInt8 = 0
    var description: String = ""

    var displayName: String {
        hidCode == 0 ? "Not Set" : HIDUsage.name(for: hidCode)
    }
}

/// 键位配置持久化
enum KeyConfigStore {
    private static let key = "keyMappingConfig"

    static func save(_ keys: [KeyConfig]) {
        if let data = try? JSONEncoder().encode(keys) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> [KeyConfig]? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let configs = try? JSONDecoder().decode([KeyConfig].self, from: data),
              configs.count == 4 else { return nil }
        return configs
    }
}

struct KeyMappingView: View {
    @ObservedObject var bleManager: AhaKeyBLEManager

    @State private var selectedKey = 0
    @State private var keys: [KeyConfig] = KeyConfigStore.load() ?? [
        KeyConfig(hidCode: HIDUsage.capsLock, description: "Record"),
        KeyConfig(hidCode: HIDUsage.enter, description: "Enter"),
        KeyConfig(hidCode: HIDUsage.escape, description: "Cancel"),
        KeyConfig(hidCode: HIDUsage.backspace, description: "Backspace"),
    ]
    @State private var showWriteSuccess = false

    private let keyLabels = ["Key 1\n🎤", "Key 2\n✓", "Key 3\n✗", "Key 4\n⌫"]

    var body: some View {
        Form {
            // MARK: - 按键选择
            Section("Key Mapping") {
                HStack(spacing: 12) {
                    ForEach(0..<4) { index in
                        Button {
                            selectedKey = index
                        } label: {
                            VStack(spacing: 4) {
                                Text(keyLabels[index])
                                    .font(.system(.body, design: .rounded))
                                    .multilineTextAlignment(.center)
                                Text(keys[index].displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedKey == index
                                          ? Color.accentColor.opacity(0.15)
                                          : Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(selectedKey == index
                                                  ? Color.accentColor
                                                  : Color.primary.opacity(0.1), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // MARK: - 编辑选中键
            Section("Key \(selectedKey + 1) Settings") {
                Picker("Key Code", selection: $keys[selectedKey].hidCode) {
                    Text("Not Set").tag(UInt8(0))
                    ForEach(HIDUsage.allOptions, id: \.code) { option in
                        Text("\(option.name)  (\(String(format: "0x%02X", option.code)))")
                            .tag(option.code)
                    }
                }

                CompatLabeledContent("Description") {
                    TextField("Shown on the keyboard LCD", text: $keys[selectedKey].description)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }

            // MARK: - 预设方案
            Section {
                HStack {
                    Button("EchoWrite Recommended") {
                        applyEchoWritePreset()
                    }
                    .buttonStyle(.bordered)
                    .help("Key1=F18(EchoWrite) Key2=Enter Key3=Escape Key4=Enter")

                    Button("Restore Defaults") {
                        applyDefaultPreset()
                    }
                    .buttonStyle(.bordered)
                    .help("Restore factory default key mapping")
                }
            } header: {
                Text("Presets")
            } footer: {
                Text("EchoWrite Recommended: Key1 sends F18 to trigger EchoWrite recording, Key2/4 confirm, Key3 cancels.")
                    .font(.caption)
            }

            // MARK: - 写入设备
            if bleManager.isConnected {
                Section {
                    HStack {
                        Button("Apply All Keys to Device") {
                            writeAllKeys()
                        }
                        .buttonStyle(.borderedProminent)

                        if showWriteSuccess {
                            Label("Sent", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }
                }
            } else {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Please connect an AhaKey device first")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }

    }

    // MARK: - Actions

    private func applyEchoWritePreset() {
        keys = [
            KeyConfig(hidCode: HIDUsage.f18, description: "EchoWrite"),
            KeyConfig(hidCode: HIDUsage.enter, description: "Enter"),
            KeyConfig(hidCode: HIDUsage.escape, description: "Cancel"),
            KeyConfig(hidCode: HIDUsage.enter, description: "Enter"),
        ]
        KeyConfigStore.save(keys)
    }

    private func applyDefaultPreset() {
        keys = [
            KeyConfig(hidCode: HIDUsage.capsLock, description: "CapsLock"),
            KeyConfig(hidCode: HIDUsage.enter, description: "Enter"),
            KeyConfig(hidCode: HIDUsage.escape, description: "Escape"),
            KeyConfig(hidCode: HIDUsage.enter, description: "Enter"),
        ]
        KeyConfigStore.save(keys)
    }

    private func writeAllKeys() {
        for (index, key) in keys.enumerated() {
            guard key.hidCode != 0 else { continue }
            let keyIndex = UInt8(index)
            bleManager.setKeyMapping(keyIndex: keyIndex, hidCodes: [key.hidCode])
            if !key.description.isEmpty {
                bleManager.setKeyDescription(keyIndex: keyIndex, text: key.description)
            }
        }
        // 写入完毕后保存到 Flash + 本地持久化
        bleManager.saveConfig()
        KeyConfigStore.save(keys)
        showWriteSuccess = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Double(3) * 1_000_000_000))
            showWriteSuccess = false
        }
    }
}
