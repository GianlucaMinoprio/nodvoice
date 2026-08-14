import Foundation
import SwiftUI

enum SessionPhase: Equatable {
    case idle
    case listening
    case transcribing
    case thinking
    case choosing
    case speaking
    case error(String)

    var label: String { shortLabel }

    var shortLabel: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .thinking: return "Drafting"
        case .choosing: return "Choose reply"
        case .speaking: return "Speaking"
        case .error: return "Error"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return "checkmark.circle"
        case .listening: return "mic.fill"
        case .transcribing: return "waveform"
        case .thinking: return "brain.head.profile"
        case .choosing: return "hand.point.up.left"
        case .speaking: return "speaker.wave.2.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .idle: return .secondary
        case .listening: return .red
        case .transcribing, .thinking: return .orange
        case .choosing: return .accentColor
        case .speaking: return .blue
        case .error: return .orange
        }
    }

    var errorMessage: String? {
        if case .error(let message) = self { return message }
        return nil
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
