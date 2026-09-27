import SwiftUI

/// 苹果原生转写的识别语言选择（多选，按目录顺序回退尝试）。
struct SpeechLanguagePickerView: View {
    @ObservedObject var service: NativeSpeechTranscriptionService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(NSLocalizedString("识别语言", comment: ""), systemImage: "globe")
                .font(.callout.weight(.semibold))
            if service.selectedSpeechLocales.isEmpty {
                Text(NSLocalizedString("未选择时跟随 macOS 系统语言。", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(NativeSpeechTranscriptionService.speechLocaleCatalog, id: \.id) { entry in
                Toggle(isOn: selectionBinding(for: entry.id)) {
                    HStack {
                        Text(entry.label)
                            .font(.callout)
                        Spacer()
                        Text(entry.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }

    private func selectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { service.selectedSpeechLocales.contains(id) },
            set: { isEnabled in
                if isEnabled {
                    service.selectedSpeechLocales.append(id)
                } else {
                    service.selectedSpeechLocales.removeAll { $0 == id }
                }
            }
        )
    }
}
