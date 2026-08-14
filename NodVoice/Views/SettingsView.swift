import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: SessionController
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey: String = ""
    @State private var chatModel: String = AppSettings.defaultChatModel
    @State private var voiceID: String = AppSettings.defaultVoice
    @State private var language: String = AppSettings.defaultLanguage
    @State private var optionCount: Int = AppSettings.defaultOptionCount
    @State private var showKey = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Group {
                            if showKey {
                                TextField("xai-…", text: $apiKey)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("xai-…", text: $apiKey)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }
                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                    }
                    Text("Stored in Keychain on this device. Demo only — use ephemeral tokens for production.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("xAI API key")
                }

                Section("Models") {
                    TextField("Chat model", text: $chatModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Default: grok-4.5. Faster/cheaper: grok-4-1-fast-non-reasoning. Flagship: grok-4.6")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("TTS voice_id", text: $voiceID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("eve, ara, rex, sal, leo, …")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Language", text: $language)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Stepper("Reply options: \(optionCount)", value: $optionCount, in: 2...5)
                }

                Section("Gestures") {
                    LabeledContent("Nod (pitch)") { Text("Select + speak") }
                    LabeledContent("Shake (yaw)") { Text("Next option") }
                    Text("Requires AirPods with head tracking. Put them in before listening.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    Text("NodVoice is a public clapback app: same product shape as “brain sensing” demos, implemented with CMHeadphoneMotionManager + Grok APIs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("xAI voice docs", destination: URL(string: "https://docs.x.ai/developers/model-capabilities/audio/voice")!)
                    Link("Original tweet", destination: URL(string: "https://x.com/gminoprio/status/2088126653507739720")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        session.settings.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        session.settings.chatModel = chatModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        session.settings.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
                        session.settings.language = language.trimmingCharacters(in: .whitespacesAndNewlines)
                        session.settings.optionCount = optionCount
                        session.saveSettings()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                apiKey = session.settings.apiKey
                chatModel = session.settings.chatModel
                voiceID = session.settings.voiceID
                language = session.settings.language
                optionCount = session.settings.optionCount
            }
        }
    }
}
