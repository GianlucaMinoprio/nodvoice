import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: SessionController
    @Environment(\.dismiss) private var dismiss

    @State private var voiceID: String = AppSettings.defaultVoice
    @State private var language: String = AppSettings.defaultLanguage
    @State private var optionCount: Int = AppSettings.defaultOptionCount
    @State private var speakerVolume: Double = AppSettings.defaultSpeakerVolume
    @State private var dwellSeconds: Double = AppSettings.defaultDwellSeconds
    @State private var accountHint = SuperGrokSession.load()?.accountHint
    @State private var previewingVoice: String?
    @State private var previewError: String?

    private let voiceChoices = ["eve", "ara", "rex", "sal", "leo", "ursa"]
    private let previewLine = "Hey, it's me. Does this voice feel right for a quick reply?"
    private let client = XAIClient()

    private let languageChoices: [(code: String, name: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("it", "Italian"),
        ("de", "German"),
        ("pt", "Portuguese"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("ar", "Arabic"),
        ("hi", "Hindi")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if session.grokSignedIn {
                        LabeledContent("Status") {
                            Text("Signed in")
                                .foregroundStyle(.green)
                                .fontWeight(.semibold)
                        }
                        if let accountHint {
                            LabeledContent("Account") {
                                Text(accountHint)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Button("Sign out", role: .destructive) {
                            Task {
                                await SuperGrokAuth.shared.signOut()
                                refreshAuth()
                            }
                        }
                    } else {
                        Button {
                            session.connectGrok()
                        } label: {
                            if session.grokConnecting {
                                Label("Opening SuperGrok…", systemImage: "safari")
                            } else {
                                Label("Sign in with SuperGrok", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                    }
                } header: {
                    Text("SuperGrok")
                } footer: {
                    Text("Uses your grok.com or X Premium+ subscription. Tokens stay in the Keychain on this phone.")
                }

                Section {
                    ForEach(voiceChoices, id: \.self) { voice in
                        HStack {
                            Button {
                                voiceID = voice
                            } label: {
                                Label(voice.capitalized, systemImage: voiceID == voice ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(voiceID == voice ? Color.accentColor : Color.primary)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button {
                                preview(voice)
                            } label: {
                                if previewingVoice == voice {
                                    ProgressView()
                                } else {
                                    Image(systemName: "play.circle.fill")
                                        .font(.title3)
                                }
                            }
                            .disabled(!session.grokSignedIn || previewingVoice != nil)
                            .accessibilityLabel("Preview \(voice)")
                        }
                    }
                    if let previewError {
                        Text(previewError)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text(session.grokSignedIn
                         ? "Tap play to hear a sample on the phone speaker."
                         : "Sign in with SuperGrok to preview voices.")
                }

                Section {
                    Picker("Language", selection: $language) {
                        ForEach(languageChoices, id: \.code) { item in
                            Text(item.name).tag(item.code)
                        }
                    }

                    Stepper(value: $optionCount, in: 2...5) {
                        Text("Reply options: \(optionCount)")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Speaker \(Int(speakerVolume * 100))%")
                        Slider(value: $speakerVolume, in: 0.2...1, step: 0.05)
                    }
                } header: {
                    Text("Speech")
                } footer: {
                    Text("Language for listening and speaking. Replies use Grok 4.1.")
                }

                Section {
                    LabeledContent("Nod down") {
                        Text("Next reply")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Nod up") {
                        Text("Previous reply")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Shake") {
                        Text("Start or stop session")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Stay on a reply \(dwellLabel)")
                        Slider(value: $dwellSeconds, in: 1.5...4, step: 0.5)
                    }
                } header: {
                    Text("Gestures")
                } footer: {
                    Text("Shake to start. After a pause, replies appear. Hold a reply to speak from the phone speaker. Shake stops the session.")
                }

                Section {
                    LabeledContent("App") {
                        Text("NodVoice 1.0")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear(perform: load)
            .onDisappear { session.player.stop() }
        }
    }

    private var dwellLabel: String {
        if dwellSeconds == dwellSeconds.rounded() {
            return "\(Int(dwellSeconds))s"
        }
        return String(format: "%.1fs", dwellSeconds)
    }

    private func load() {
        voiceID = session.settings.voiceID
        language = session.settings.language
        optionCount = session.settings.optionCount
        speakerVolume = session.settings.speakerVolume
        dwellSeconds = session.settings.dwellSeconds
        refreshAuth()
    }

    private func refreshAuth() {
        accountHint = SuperGrokSession.load()?.accountHint
        session.refreshGrokAuth()
    }

    private func save() {
        session.settings.chatModel = AppSettings.defaultChatModel
        session.settings.voiceID = nonempty(voiceID, default: AppSettings.defaultVoice)
        session.settings.language = nonempty(language, default: AppSettings.defaultLanguage)
        session.settings.optionCount = optionCount
        session.settings.speakerVolume = speakerVolume
        session.settings.dwellSeconds = dwellSeconds
        session.saveSettings()
        dismiss()
    }

    private func preview(_ voice: String) {
        previewError = nil
        voiceID = voice
        previewingVoice = voice
        Task {
            defer { previewingVoice = nil }
            do {
                let bearer = try await SuperGrokAuth.shared.validAccessToken(fallbackAPIKey: "")
                let audio = try await client.synthesize(
                    text: previewLine,
                    apiKey: bearer,
                    voiceID: voice,
                    language: nonempty(language, default: AppSettings.defaultLanguage)
                )
                try await session.player.play(data: audio, volume: Float(speakerVolume))
            } catch {
                previewError = error.localizedDescription
            }
        }
    }

    private func nonempty(_ value: String, default defaultValue: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultValue : trimmed
    }
}

#Preview {
    SettingsView()
        .environmentObject(SessionController())
}
