import SwiftUI
import UIKit

/// Main screen — intentionally boring iOS: List + Sections + system controls.
struct RootView: View {
    @EnvironmentObject private var session: SessionController
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                transcriptSection
                repliesSection
                historySection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("NodVoice")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    if session.showsReset {
                        Button("Reset", role: .destructive) {
                            session.resetToIdle()
                        }
                    }

                    if session.phase == .choosing {
                        Spacer()
                        if session.allowsManualGestures {
                            Button {
                                session.simulateNodUp()
                            } label: {
                                Label("Up", systemImage: "arrow.up")
                            }
                            Button {
                                session.simulateNodDown()
                            } label: {
                                Label("Down", systemImage: "arrow.down")
                            }
                            Button {
                                session.simulateShake()
                            } label: {
                                Label("Speak", systemImage: "checkmark.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button {
                                session.cycleOption(forward: false)
                            } label: {
                                Label("Up", systemImage: "arrow.up")
                            }
                            Button {
                                session.cycleOption(forward: true)
                            } label: {
                                Label("Down", systemImage: "arrow.down")
                            }
                            Button {
                                session.confirmSelection()
                            } label: {
                                Label("Speak", systemImage: "speaker.wave.2.fill")
                            }
                        }
                    } else {
                        Spacer()
                        Button {
                            session.toggleListen()
                        } label: {
                            if session.isBusy {
                                ProgressView()
                            } else {
                                Label(
                                    session.phase == .listening ? "Stop" : "Listen",
                                    systemImage: session.phase == .listening ? "stop.circle.fill" : "mic.circle.fill"
                                )
                            }
                        }
                        .disabled(session.isBusy || !session.canUseApp)
                        .tint(session.phase == .listening ? .red : .accentColor)
                    }
                }
            }
            .overlay {
                if case .error(let message) = session.phase {
                    // keep list visible; error also shown in status section
                    Color.clear
                        .accessibilityLabel(message)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(session)
                    .presentationDetents([.medium, .large])
            }
            .onAppear { session.onAppear() }
            .background {
                if session.allowsManualGestures {
                    ShakeCatcher {
                        session.simulateShake()
                    }
                    .frame(width: 0, height: 0)
                }
            }
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            LabeledContent {
                Text(session.phase.shortLabel)
                    .foregroundStyle(session.phase.tint)
                    .fontWeight(.semibold)
            } label: {
                Label("Status", systemImage: session.phase.symbolName)
            }

            if let errorMessage = session.phase.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            LabeledContent("AirPods") {
                Text(airPodsLabel)
                    .foregroundStyle(session.canUseApp ? Color.secondary : Color.orange)
            }

            if !session.canUseApp {
                Label("Connect AirPods to use this app on iPhone", systemImage: "airpodspro")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            // Always show IMU. Hiding it lets SwiftUI drop the subscription
            // and the AirPods stream goes stale. When this line is on screen, nods work.
            Text(session.head.liveLine.isEmpty ? "IMU starting…" : session.head.liveLine)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            if !session.motionStatus.isEmpty {
                Text(session.motionStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !session.debugLine.isEmpty {
                Text(session.debugLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if !SuperGrokSession.isSignedIn {
                Label("Demo mode. Sign in with SuperGrok in Settings.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Session")
        } footer: {
            Text(session.phase == .choosing
                 ? "Stay on a reply. The circle fills, then it speaks."
                 : "Shake to start. Pause to draft. Shake to stop.")
        }
    }

    private var isGestureFlash: Bool {
        ["Nod down", "Nod up", "Shake"].contains(session.motionStatus)
    }

    private var airPodsLabel: String {
        if session.isSimulator { return "Simulator" }
        if session.head.headphonesConnected {
            return session.head.isRunning ? "Tracking" : "Connected"
        }
        return "Not connected"
    }

    private var transcriptSection: some View {
        Section {
            if session.transcript.isEmpty {
                ContentUnavailableView(
                    "Nothing heard yet",
                    systemImage: "ear",
                    description: Text("Shake to listen. It stops on silence, or shake again to end.")
                )
                .listRowBackground(Color.clear)
            } else {
                Text(session.transcript)
                    .font(.body)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Heard")
        }
    }

    @ViewBuilder
    private var repliesSection: some View {
        if !session.options.isEmpty {
            Section {
                ForEach(Array(session.options.enumerated()), id: \.element.id) { index, option in
                    Button {
                        session.selectedIndex = index
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            DwellRing(
                                progress: index == session.selectedIndex ? session.dwellProgress : 0,
                                selected: index == session.selectedIndex
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.text)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Text(option.tone.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        index == session.selectedIndex
                            ? Color.accentColor.opacity(0.12)
                            : nil
                    )
                    .accessibilityLabel("Reply \(index + 1), \(option.tone): \(option.text)")
                    .accessibilityAddTraits(index == session.selectedIndex ? .isSelected : [])
                }
            } header: {
                Text("Replies")
            } footer: {
                Text("Stay on a reply. The circle fills, then it speaks.")
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !session.history.isEmpty {
            Section("Recent") {
                ForEach(session.history.prefix(5)) { turn in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(turn.heard)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        if let spoken = turn.spoken {
                            Label(spoken, systemImage: "waveform")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

}

#Preview {
    RootView()
        .environmentObject(SessionController())
}

private struct DwellRing: View {
    var progress: Double
    var selected: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.05), value: progress)
            Image(systemName: selected ? "checkmark" : "")
                .font(.caption.weight(.bold))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}

/// Simulator Hardware → Shake (or shake a device) cycles replies.
private struct ShakeCatcher: UIViewControllerRepresentable {
    var onShake: () -> Void

    func makeUIViewController(context: Context) -> ShakeViewController {
        let controller = ShakeViewController()
        controller.onShake = onShake
        return controller
    }

    func updateUIViewController(_ controller: ShakeViewController, context: Context) {
        controller.onShake = onShake
    }
}

private final class ShakeViewController: UIViewController {
    var onShake: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { true }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            onShake?()
        }
    }
}
