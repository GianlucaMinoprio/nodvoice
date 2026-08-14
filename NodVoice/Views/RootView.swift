import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: SessionController
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                background
                VStack(spacing: 20) {
                    header
                    statusCard
                    transcriptCard
                    optionsCard
                    Spacer(minLength: 8)
                    listenButton
                    helperRow
                }
                .padding(20)
            }
            .navigationTitle("NodVoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(session)
            }
            .onAppear { session.onAppear() }
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.07, green: 0.08, blue: 0.12),
                Color(red: 0.02, green: 0.02, blue: 0.04)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AirPods IMU · Grok STT · nod select · Grok TTS")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Text("No brain sensors were harmed.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(phaseColor)
                    .frame(width: 10, height: 10)
                Text(session.phase.label)
                    .font(.headline)
                Spacer()
                if session.phase == .listening {
                    ListeningBars()
                }
            }
            Text(session.motionStatus)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if !session.debugLine.isEmpty {
                Text(session.debugLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HEARD")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(session.transcript.isEmpty ? "—" : session.transcript)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var optionsCard: some View {
        if !session.options.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("REPLIES")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("shake = next · nod = go")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                ForEach(Array(session.options.enumerated()), id: \.element.id) { index, option in
                    Button {
                        session.selectedIndex = index
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(index == session.selectedIndex ? .black : .secondary)
                                .frame(width: 22, height: 22)
                                .background(
                                    Circle().fill(index == session.selectedIndex ? Color.green : Color.white.opacity(0.08))
                                )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.text)
                                    .font(.body.weight(index == session.selectedIndex ? .semibold : .regular))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Text(option.tone.uppercased())
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(index == session.selectedIndex ? Color.green.opacity(0.15) : Color.white.opacity(0.03))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(
                                            index == session.selectedIndex ? Color.green.opacity(0.7) : Color.white.opacity(0.06),
                                            lineWidth: 1
                                        )
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 12) {
                    Button("Next") { session.cycleOption() }
                        .buttonStyle(SecondaryChipStyle())
                    Button("Speak") { session.confirmSelection() }
                        .buttonStyle(PrimaryChipStyle())
                        .disabled(session.phase != .choosing)
                }
                .padding(.top, 4)
            }
        } else if !session.history.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("LAST")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let last = session.history.first {
                    Text(last.heard)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let spoken = last.spoken {
                        Text("→ \(spoken)")
                            .font(.subheadline.weight(.medium))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var listenButton: some View {
        Button {
            session.toggleListen()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: session.phase == .listening ? "stop.fill" : "mic.fill")
                Text(session.phase == .listening ? "Stop & think" : "Listen")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(ListenButtonStyle(listening: session.phase == .listening))
        .disabled({
            switch session.phase {
            case .transcribing, .thinking, .speaking: return true
            default: return false
            }
        }())
    }

    private var helperRow: some View {
        HStack {
            if session.settings.apiKey.isEmpty {
                Label("Add API key in Settings", systemImage: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("Key on device", systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.phase != .idle && session.phase != .listening {
                Button("Reset") { session.resetToIdle() }
                    .font(.caption.weight(.semibold))
            }
        }
    }

    private var phaseColor: Color {
        switch session.phase {
        case .idle: return .gray
        case .listening: return .red
        case .transcribing, .thinking: return .yellow
        case .choosing: return .green
        case .speaking: return .cyan
        case .error: return .orange
        }
    }
}

struct ListeningBars: View {
    @State private var animate = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.red)
                    .frame(width: 3, height: animate ? CGFloat(8 + i * 3) : 6)
                    .animation(
                        .easeInOut(duration: 0.35)
                        .repeatForever()
                        .delay(Double(i) * 0.07),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

struct ListenButtonStyle: ButtonStyle {
    let listening: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(listening ? Color.red.opacity(0.9) : Color.blue.opacity(0.9))
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct PrimaryChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.green.opacity(configuration.isPressed ? 0.55 : 0.85)))
            .foregroundStyle(.black)
    }
}

struct SecondaryChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0.12)))
            .foregroundStyle(.primary)
    }
}
