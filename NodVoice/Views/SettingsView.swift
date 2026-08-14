import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: SessionController
    @Environment(\.dismiss) private var dismiss

    @State private var chatModel: String = AppSettings.defaultChatModel
    @State private var voiceID: String = AppSettings.defaultVoice
    @State private var language: String = AppSettings.defaultLanguage
    @State private var optionCount: Int = AppSettings.defaultOptionCount
    @State private var showSuperGrok = false
    @State private var signedIn = SuperGrokSession.isSignedIn
    @State private var accountHint = SuperGrokSession.load()?.accountHint

    private let modelChoices = [
        "grok-4.5",
        "grok-4.6",
        "grok-4-1-fast-non-reasoning"
    ]

    private let voiceChoices = ["eve", "ara", "rex", "sal", "leo", "ursa"]

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
                    if signedIn {
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
                            showSuperGrok = true
                        } label: {
                            Label("Sign in with SuperGrok", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                } header: {
                    Text("SuperGrok")
                } footer: {
                    Text("Uses your grok.com or X Premium+ subscription. Tokens stay in the Keychain on this phone.")
                }

                Section {
                    Picker("Chat", selection: $chatModel) {
                        ForEach(modelChoices, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    if !modelChoices.contains(chatModel) {
                        TextField("Custom model id", text: $chatModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    }

                    Picker("Voice", selection: $voiceID) {
                        ForEach(voiceChoices, id: \.self) { voice in
                            Text(voice).tag(voice)
                        }
                    }
                    if !voiceChoices.contains(voiceID) {
                        TextField("Custom voice id", text: $voiceID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    }

                    Picker("Language", selection: $language) {
                        ForEach(languageChoices, id: \.code) { item in
                            Text("\(item.name) (\(item.code))").tag(item.code)
                        }
                    }
                    TextField("Language code", text: $language)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())

                    Stepper(value: $optionCount, in: 2...5) {
                        Text("Reply options: \(optionCount)")
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Pick a language or type a code (en, es, fr…).")
                }

                Section {
                    LabeledContent("Nod") {
                        Text("Speak selected")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Shake") {
                        Text("Next reply")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Gestures")
                } footer: {
                    Text("Needs AirPods with head tracking, in-ear, on a physical iPhone.")
                }

                Section {
                    LabeledContent("App") {
                        Text("NodVoice 1.0")
                            .foregroundStyle(.secondary)
                    }
                    Link(destination: URL(string: "https://docs.x.ai/developers/model-capabilities/audio/voice")!) {
                        Label("xAI voice docs", systemImage: "link")
                    }
                    Link(destination: URL(string: "https://x.com/gminoprio/status/2088126653507739720")!) {
                        Label("Original tweet", systemImage: "link")
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
            .sheet(isPresented: $showSuperGrok, onDismiss: refreshAuth) {
                SuperGrokSignInView {
                    refreshAuth()
                }
            }
        }
    }

    private func load() {
        chatModel = session.settings.chatModel
        voiceID = session.settings.voiceID
        language = session.settings.language
        optionCount = session.settings.optionCount
        refreshAuth()
    }

    private func refreshAuth() {
        signedIn = SuperGrokSession.isSignedIn
        accountHint = SuperGrokSession.load()?.accountHint
    }

    private func save() {
        session.settings.chatModel = nonempty(chatModel, default: AppSettings.defaultChatModel)
        session.settings.voiceID = nonempty(voiceID, default: AppSettings.defaultVoice)
        session.settings.language = nonempty(language, default: AppSettings.defaultLanguage)
        session.settings.optionCount = optionCount
        session.saveSettings()
        dismiss()
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
