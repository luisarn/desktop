# Voice Backends

## 概览

语音链路分两段，均可在 Studio 的语音键设置里切换后端：

1. **识别引擎（ASR）**：苹果原生 Speech 框架，或任意 OpenAI 兼容 `/audio/transcriptions` 端点
   （如自建 LiteLLM 代理的 Whisper / SenseVoice）。
2. **文字整理（AhaType）**：Typeless 云端服务，或任意 OpenAI 兼容 `/chat/completions` 端点
   （可编辑 system 提示词）。

两段都保持 fail-open：任何失败路径都直接粘贴原始转写，不丢字。

## 识别引擎

### 苹果原生

- 需要麦克风、语音识别、Siri、听写四项权限。
- 流式 partial 结果 + 前缀/重叠合并，停止后提交。
- 识别语言在「识别语言」多选列表里选（按目录顺序回退尝试）；为空时跟随 App 语言。
  注意苹果**没有 `yue-HK`**：粤语标识是 `zh-HK`（支持纯端侧）与 `yue-CN`；
  旧配置里的 `yue-HK` 会在加载时自动迁移为 `zh-HK`。
- 单 locale 识别，不支持中英混说自动切换。

### 自定义接口（OpenAI 兼容）

- 录音缓冲累积 PCM，停止后转 16 kHz 单声道 16-bit WAV，multipart 上传
  `{base}/audio/transcriptions`（`model` + `file`），解析返回的 `text`。
- 语言自动检测，天然支持中英/粤英混说。
- 无流式预览：录音中只显示状态，停止上传后一次性出结果。
- 配置项：API 地址（含 `/v1`）、模型名、API 密钥（Keychain，可留空）。
- 实现见 `Sources/Utilities/OpenAIAudioTranscription.swift`。

## 文字整理（AhaType）

- 云端 Typeless：沿用原有登录/配额体系（`~/Library/Application Support/VibeKeyboard/typeless_config.json` + Keychain）。
- 自定义接口：`{base}/chat/completions`，system 提示词可在设置里编辑
  （默认提示词要求保留原语言与原意、指令类内容整理成清晰提示词、只输出结果）。
  开启自定义后端时不需要 Typeless 登录，也不占云端配额。
- 密钥存 Keychain：`lab.jawa.ahakeyconfig.ahatype-custom`（整理）与
  `lab.jawa.ahakeyconfig.asr-custom`（识别）。

## Talkback（机器级，不在仓库内）

`~/.qoder/hooks/tts-stop.sh` 是 Qoder 的 Stop hook：回合结束时取最后一段回复文本，
按语言选声音调用 LiteLLM `/audio/speech`（model `moss`；中文→`fable-yue`，英文→`fable`）
并 `afplay` 播放。密钥优先取环境变量 `LITELLM_API_KEY`，回退到 Keychain 的 ASR 条目。
跨机器同步该脚本时注意 macOS 的 `mktemp` 不支持模板后缀（Linux 可以）。

## 诊断

- 识别/上传日志：`~/Library/Application Support/AhaKeyConfig/diagnostics/native-speech.log`
  （含 `using selected speech locale=`、`custom asr result=`、`custom asr error=` 等行）。
