import Foundation

struct AppSettings: Equatable {
    var apiKey: String
    var chatModel: String
    var voiceID: String
    var language: String
    var optionCount: Int

    static let apiKeyAccount = "xai_api_key"
    static let modelAccount = "chat_model"
    static let voiceAccount = "voice_id"
    static let languageAccount = "language"
    static let optionCountAccount = "option_count"

    /// Default chat model for multi-reply. Fast alternatives: grok-4-1-fast-non-reasoning
    static let defaultChatModel = "grok-4.5"
    static let defaultVoice = "eve"
    static let defaultLanguage = "en"
    static let defaultOptionCount = 3

    static func load() -> AppSettings {
        let countRaw = KeychainStore.get(account: optionCountAccount).flatMap(Int.init)
        return AppSettings(
            apiKey: KeychainStore.get(account: apiKeyAccount) ?? "",
            chatModel: KeychainStore.get(account: modelAccount) ?? defaultChatModel,
            voiceID: KeychainStore.get(account: voiceAccount) ?? defaultVoice,
            language: KeychainStore.get(account: languageAccount) ?? defaultLanguage,
            optionCount: max(2, min(5, countRaw ?? defaultOptionCount))
        )
    }

    func save() {
        if apiKey.isEmpty {
            KeychainStore.delete(account: Self.apiKeyAccount)
        } else {
            KeychainStore.set(apiKey, account: Self.apiKeyAccount)
        }
        KeychainStore.set(chatModel, account: Self.modelAccount)
        KeychainStore.set(voiceID, account: Self.voiceAccount)
        KeychainStore.set(language, account: Self.languageAccount)
        KeychainStore.set(String(optionCount), account: Self.optionCountAccount)
    }
}

enum XAIClientError: LocalizedError {
    case missingAPIKey
    case badStatus(Int, String)
    case decodeFailed(String)
    case emptyTranscript
    case emptyOptions

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your xAI API key in Settings."
        case .badStatus(let code, let body):
            return "xAI HTTP \(code): \(body.prefix(280))"
        case .decodeFailed(let detail):
            return "Could not parse xAI response: \(detail)"
        case .emptyTranscript:
            return "STT returned empty text. Try again closer to the mic."
        case .emptyOptions:
            return "Model returned no reply options."
        }
    }
}

actor XAIClient {
    private let session: URLSession
    private let baseURL = URL(string: "https://api.x.ai/v1")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - STT

    func transcribe(fileURL: URL, apiKey: String, language: String) async throws -> String {
        guard !apiKey.isEmpty else { throw XAIClientError.missingAPIKey }

        var request = URLRequest(url: baseURL.appendingPathComponent("stt"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        let mime = mimeType(for: fileURL)

        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        // Options must precede file per xAI STT docs
        appendField(name: "format", value: "true")
        appendField(name: "language", value: language)
        appendField(name: "keyterm", value: "NodVoice")
        appendField(name: "keyterm", value: "AirPods")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try throwIfNeeded(data: data, response: response)

        let decoded = try JSONDecoder().decode(STTResponse.self, from: data)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw XAIClientError.emptyTranscript }
        return text
    }

    // MARK: - Chat (multi-reply)

    func generateReplyOptions(
        transcript: String,
        prior: [ConversationTurn],
        settings: AppSettings
    ) async throws -> [ReplyOption] {
        guard !settings.apiKey.isEmpty else { throw XAIClientError.missingAPIKey }

        let system = """
        You are NodVoice, a silent copilot in the user's ear.
        Given overheard conversation transcript, propose \(settings.optionCount) short spoken replies the USER could say next.
        Rules:
        - Each option is something the user would speak out loud (1 sentence, max ~25 words)
        - Vary tone: e.g. direct, warm, witty, clarifying
        - No markdown, no quotes around the whole option
        - Prefer natural conversational English unless the transcript is clearly another language
        - Return ONLY valid JSON: {"options":[{"text":"...","tone":"direct"}, ...]}
        """

        var messages: [[String: String]] = [
            ["role": "system", "content": system]
        ]

        if !prior.isEmpty {
            let history = prior.suffix(4).map { turn in
                var block = "HEARD: \(turn.heard)"
                if let spoken = turn.spoken { block += "\nUSER SAID: \(spoken)" }
                return block
            }.joined(separator: "\n---\n")
            messages.append([
                "role": "user",
                "content": "Recent context:\n\(history)"
            ])
        }

        messages.append([
            "role": "user",
            "content": "Latest transcript to answer:\n\(transcript)"
        ])

        let payload: [String: Any] = [
            "model": settings.chatModel,
            "temperature": 0.7,
            "max_tokens": 400,
            "response_format": ["type": "json_object"],
            "messages": messages
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        try throwIfNeeded(data: data, response: response)

        let chat = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = chat.choices.first?.message.content else {
            throw XAIClientError.decodeFailed("missing choices")
        }

        let options = try parseOptions(from: content)
        guard !options.isEmpty else { throw XAIClientError.emptyOptions }
        return options
    }

    // MARK: - TTS

    func synthesize(text: String, apiKey: String, voiceID: String, language: String) async throws -> Data {
        guard !apiKey.isEmpty else { throw XAIClientError.missingAPIKey }

        let payload: [String: Any] = [
            "text": text,
            "voice_id": voiceID,
            "language": language,
            "output_format": [
                "codec": "mp3",
                "sample_rate": 24_000,
                "bit_rate": 128_000
            ]
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("tts"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        try throwIfNeeded(data: data, response: response, expectJSONErrorOnly: true)

        guard !data.isEmpty else {
            throw XAIClientError.decodeFailed("empty TTS audio")
        }
        return data
    }

    // MARK: - Helpers

    private func parseOptions(from content: String) throws -> [ReplyOption] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonData: Data
        if let data = trimmed.data(using: .utf8), trimmed.first == "{" {
            jsonData = data
        } else if let start = trimmed.firstIndex(of: "{"),
                  let end = trimmed.lastIndex(of: "}"),
                  start < end {
            jsonData = Data(trimmed[start...end].utf8)
        } else {
            throw XAIClientError.decodeFailed("no JSON object in model output")
        }

        do {
            let payload = try JSONDecoder().decode(ReplyOptionsPayload.self, from: jsonData)
            return payload.options
                .map { ReplyOption(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), tone: $0.tone ?? "neutral") }
                .filter { !$0.text.isEmpty }
        } catch {
            throw XAIClientError.decodeFailed(error.localizedDescription)
        }
    }

    private func throwIfNeeded(data: Data, response: URLResponse, expectJSONErrorOnly: Bool = false) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
            throw XAIClientError.badStatus(http.statusCode, body)
        }
        if expectJSONErrorOnly {
            // TTS returns raw audio; if server sent JSON error with 200 (unlikely), ignore
            return
        }
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a": return "audio/m4a"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "caf": return "audio/x-caf"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - DTOs

private struct STTResponse: Decodable {
    let text: String
    let duration: Double?
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}
