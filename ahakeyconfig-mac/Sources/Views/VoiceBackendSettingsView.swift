import SwiftUI

/// 语音后端设置：识别引擎（苹果原生 / 自定义 OpenAI 兼容 ASR）与整理后端（Typeless 云端 / 自定义 LLM）。
struct VoiceBackendSettingsView: View {
    @ObservedObject var service: NativeSpeechTranscriptionService
    @ObservedObject var optimizer: AhaTypeTextOptimizer

    @State private var asrKeyDraft = ""
    @State private var optimizerKeyDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(NSLocalizedString("识别引擎", comment: ""), systemImage: "waveform")
                .font(.callout.weight(.semibold))
            Picker("", selection: $service.customASREnabled) {
                Text(NSLocalizedString("苹果原生识别", comment: "")).tag(false)
                Text(NSLocalizedString("自定义接口", comment: "")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if service.customASREnabled {
                customASRFields
            } else {
                SpeechLanguagePickerView(service: service)
            }

            Divider()

            Label(NSLocalizedString("文字整理", comment: ""), systemImage: "sparkles")
                .font(.callout.weight(.semibold))
            Picker("", selection: $optimizer.customBackendEnabled) {
                Text(NSLocalizedString("云端 Typeless", comment: "")).tag(false)
                Text(NSLocalizedString("自定义接口", comment: "")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if optimizer.customBackendEnabled {
                customOptimizerFields
            } else {
                Text(NSLocalizedString("使用 AhaType 云端服务，需要登录。", comment: ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var customASRFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(
                NSLocalizedString("API 地址（含 /v1）", comment: ""),
                text: $service.customASRAPIBase,
                prompt: Text(verbatim: "https://litellm.rneng.duckdns.org/v1")
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            TextField(
                NSLocalizedString("模型名", comment: ""),
                text: $service.customASRModel,
                prompt: Text(verbatim: "whisper-large-v3")
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            SecureField(
                NSLocalizedString("API 密钥（可留空）", comment: ""),
                text: Binding(
                    get: { asrKeyDraft },
                    set: { newValue in
                        asrKeyDraft = newValue
                        service.setCustomASRKey(newValue)
                    }
                ),
                prompt: Text(service.hasCustomASRKey ? NSLocalizedString("已保存密钥；输入新值可覆盖", comment: "") : "")
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            Text(NSLocalizedString("走 OpenAI 兼容 /audio/transcriptions，语言自动检测，支持中英混说。", comment: ""))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var customOptimizerFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(
                NSLocalizedString("API 地址（含 /v1）", comment: ""),
                text: $optimizer.customAPIBase,
                prompt: Text(verbatim: "https://litellm.rneng.duckdns.org/v1")
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            TextField(
                NSLocalizedString("模型名", comment: ""),
                text: $optimizer.customModel,
                prompt: Text(verbatim: "gpt-4o-mini")
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            SecureField(
                NSLocalizedString("API 密钥（可留空）", comment: ""),
                text: Binding(
                    get: { optimizerKeyDraft },
                    set: { newValue in
                        optimizerKeyDraft = newValue
                        optimizer.setCustomAPIKey(newValue)
                    }
                ),
                prompt: Text(optimizer.hasCustomAPIKey ? NSLocalizedString("已保存密钥；输入新值可覆盖", comment: "") : "")
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            Label(NSLocalizedString("整理提示词（system）", comment: ""), systemImage: "text.justify")
                .font(.caption.weight(.semibold))
            TextEditor(text: $optimizer.customSystemPrompt)
                .font(.caption)
                .frame(height: 64)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            Text(NSLocalizedString("走 OpenAI 兼容 /chat/completions，失败时直接粘贴原始转写。", comment: ""))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
