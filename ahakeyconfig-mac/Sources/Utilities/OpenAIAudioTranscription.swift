import AVFoundation
import Foundation

/// OpenAI 兼容的语音转文字接口（/audio/transcriptions）：
/// 把录音 PCM 缓冲转成 16 kHz 单声道 16-bit WAV 后上传，供自定义 ASR（如 LiteLLM 代理的 Whisper）使用。
enum OpenAIAudioTranscription {
    enum TranscriptionError: LocalizedError {
        case conversionFailed
        case http(status: Int, body: String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .conversionFailed:
                return NSLocalizedString("录音格式转换失败。", comment: "")
            case .http(let status, let body):
                return "HTTP \(status) \(body)"
            case .badResponse:
                return NSLocalizedString("响应缺少 text 字段。", comment: "")
            }
        }
    }

    static func normalizeBase(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if !value.isEmpty, !value.contains("://") {
            value = "https://\(value)"
        }
        return value
    }

    static func wavData(from buffers: [AVAudioPCMBuffer]) throws -> Data {
        guard let first = buffers.first else { throw TranscriptionError.conversionFailed }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: first.format, to: outputFormat) else {
            throw TranscriptionError.conversionFailed
        }

        var pcm = Data()
        var index = 0
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8192) else {
                throw TranscriptionError.conversionFailed
            }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                if index < buffers.count {
                    outStatus.pointee = .haveData
                    let buffer = buffers[index]
                    index += 1
                    return buffer
                }
                outStatus.pointee = .endOfStream
                return nil
            }
            if out.frameLength > 0, let channel = out.int16ChannelData {
                let byteCount = Int(out.frameLength) * MemoryLayout<Int16>.size
                channel[0].withMemoryRebound(to: UInt8.self, capacity: byteCount) { pointer in
                    pcm.append(pointer, count: byteCount)
                }
            }
            if status == .endOfStream { break }
            if status == .error || error != nil { throw TranscriptionError.conversionFailed }
        }

        guard !pcm.isEmpty else { throw TranscriptionError.conversionFailed }
        return wavHeader(pcmCount: pcm.count) + pcm
    }

    static func transcribe(wavData: Data, apiBase: String, model: String, apiKey: String) async throws -> String {
        guard let url = URL(string: "\(normalizeBase(apiBase))/audio/transcriptions") else {
            throw TranscriptionError.badResponse
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }
        addField("model", model)
        addField("response_format", "json")
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wavData)
        body.append(Data("\r\n".utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.http(status: status, body: String(bodyText.prefix(200)))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw TranscriptionError.badResponse
        }
        return text
    }

    private static func wavHeader(pcmCount: Int) -> Data {
        var header = Data()
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)

        func appendString(_ value: String) { header.append(contentsOf: value.utf8) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }

        appendString("RIFF")
        append32(UInt32(36 + pcmCount))
        appendString("WAVE")
        appendString("fmt ")
        append32(16)
        append16(1) // PCM
        append16(channels)
        append32(sampleRate)
        append32(byteRate)
        append16(blockAlign)
        append16(bitsPerSample)
        appendString("data")
        append32(UInt32(pcmCount))
        return header
    }
}
