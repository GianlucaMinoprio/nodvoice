import Foundation

enum SessionPhase: Equatable {
    case idle
    case listening
    case transcribing
    case thinking
    case choosing
    case speaking
    case error(String)

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .thinking: return "Drafting replies…"
        case .choosing: return "Nod to pick · shake to cycle"
        case .speaking: return "Speaking…"
        case .error(let message): return message
        }
    }
}

struct ReplyOption: Identifiable, Equatable, Hashable {
    let id: UUID
    let text: String
    let tone: String

    init(id: UUID = UUID(), text: String, tone: String = "neutral") {
        self.id = id
        self.text = text
        self.tone = tone
    }
}

struct ConversationTurn: Identifiable, Equatable {
    let id: UUID
    let heard: String
    let spoken: String?
    let createdAt: Date

    init(id: UUID = UUID(), heard: String, spoken: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.heard = heard
        self.spoken = spoken
        self.createdAt = createdAt
    }
}

struct ReplyOptionsPayload: Codable {
    let options: [OptionDTO]

    struct OptionDTO: Codable {
        let text: String
        let tone: String?
    }
}
