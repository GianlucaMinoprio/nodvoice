import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class SessionController: ObservableObject {
    @Published var phase: SessionPhase = .idle
    @Published var transcript: String = ""
    @Published var options: [ReplyOption] = []
    @Published var selectedIndex: Int = 0
    @Published var history: [ConversationTurn] = []
    @Published var settings: AppSettings
    @Published var motionStatus: String = ""
    @Published var debugLine: String = ""

    let capture = AudioCaptureService()
    let head = HeadGestureService()
    let player = SpeechPlayer()
    private let client = XAIClient()

    private var gestureBag: AnyCancellable?
    private var pipelineTask: Task<Void, Never>?

    init() {
        settings = AppSettings.load()
        gestureBag = head.gestureSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] gesture in
                self?.handle(gesture: gesture)
            }

        // Mirror motion status for UI
        head.$statusText
            .receive(on: RunLoop.main)
            .assign(to: &$motionStatus)

        head.$headphonesConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                self?.handleHeadphonesChange(connected)
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func handleHeadphonesChange(_ connected: Bool) {
        guard !isSimulator, !connected else { return }
        switch phase {
        case .idle:
            break
        default:
            pipelineTask?.cancel()
            _ = capture.stop()
            player.stop()
            phase = .error("AirPods disconnected")
            debugLine = "Reconnect AirPods to continue"
        }
    }

    var selectedOption: ReplyOption? {
        guard options.indices.contains(selectedIndex) else { return nil }
        return options[selectedIndex]
    }

    var isBusy: Bool {
        switch phase {
        case .transcribing, .thinking, .speaking:
            return true
        default:
            return false
        }
    }

    var showsReset: Bool {
        switch phase {
        case .idle, .listening:
            return false
        default:
            return true
        }
    }

    var isSimulator: Bool { DeviceEnvironment.isSimulator }

    /// Real iPhone: AirPods with head tracking must be in. Simulator: always allowed.
    var canUseApp: Bool {
        isSimulator || head.headphonesConnected
    }

    var allowsManualGestures: Bool { isSimulator }

    func onAppear() {
        head.refreshConnection()
        if canUseApp {
            head.start()
        }
    }

    func onDisappear() {
        // keep motion running while app is active; stop only if needed
    }

    func saveSettings() {
        settings.save()
    }

    func toggleListen() {
        guard canUseApp else {
            phase = .error("Put AirPods in to use NodVoice")
            return
        }
        switch phase {
        case .listening:
            stopAndProcess()
        case .idle, .error, .choosing:
            startListening()
        default:
            break
        }
    }

    func startListening() {
        pipelineTask?.cancel()
        player.stop()
        options = []
        selectedIndex = 0
        transcript = ""
        debugLine = ""

        guard canUseApp else {
            phase = .error("Put AirPods in to use NodVoice")
            return
        }
        // No live credential → local demo so UI + nod gestures still work offline
        if !settings.hasLiveCredential {
            pipelineTask = Task { await runDemoPipeline() }
            return
        }

        pipelineTask = Task {
            let ok = await capture.requestPermission()
            guard !Task.isCancelled else { return }
            guard ok else {
                phase = .error("Microphone permission denied")
                return
            }
            do {
                try capture.start()
                phase = .listening
                head.start()
            } catch {
                guard !Task.isCancelled else { return }
                phase = .error(error.localizedDescription)
            }
        }
    }

    /// Offline path: fake transcript + options so you can practice nod/shake.
    private func runDemoPipeline() async {
        phase = .listening
        debugLine = "Demo mode (sign in with SuperGrok)"
        head.start()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard !Task.isCancelled else { return }
        phase = .transcribing
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        transcript = "So what do you actually think about that idea?"
        phase = .thinking
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard !Task.isCancelled else { return }
        options = [
            ReplyOption(text: "I like it. Let's try a small version this week.", tone: "direct"),
            ReplyOption(text: "Interesting - what's the riskiest assumption?", tone: "curious"),
            ReplyOption(text: "Honestly? Feels like vibecoding with AirPods.", tone: "witty")
        ]
        selectedIndex = 0
        phase = .choosing
        debugLine = "Demo: nod down/up = pick, shake = speak. TTS needs SuperGrok"
    }

    func stopAndProcess() {
        guard phase == .listening else { return }

        // Demo mode has no recorder
        if !settings.hasLiveCredential {
            pipelineTask?.cancel()
            pipelineTask = Task {
                phase = .transcribing
                transcript = "So what do you actually think about that idea?"
                phase = .thinking
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                options = [
                    ReplyOption(text: "I like it. Let's try a small version this week.", tone: "direct"),
                    ReplyOption(text: "Interesting - what's the riskiest assumption?", tone: "curious"),
                    ReplyOption(text: "Honestly? Feels like vibecoding with AirPods.", tone: "witty")
                ]
                selectedIndex = 0
                phase = .choosing
                debugLine = "Demo: nod down/up = pick, shake = speak"
            }
            return
        }

        guard let url = capture.stop() else {
            phase = .error("No recording captured")
            return
        }

        pipelineTask?.cancel()
        pipelineTask = Task {
            await runPipeline(fileURL: url)
        }
    }

    func cycleOption(forward: Bool = true) {
        guard !options.isEmpty else { return }
        if forward {
            selectedIndex = (selectedIndex + 1) % options.count
        } else {
            selectedIndex = (selectedIndex - 1 + options.count) % options.count
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func confirmSelection() {
        guard phase == .choosing, let option = selectedOption else { return }
        pipelineTask?.cancel()
        pipelineTask = Task {
            await speak(option: option)
        }
    }

    func simulateNodDown() {
        head.emitManual(.nodDown)
    }

    func simulateNodUp() {
        head.emitManual(.nodUp)
    }

    func simulateShake() {
        head.emitManual(.shake)
    }

    /// Simulator / `simctl openurl` hooks: nodvoice://listen|stop|nod|nod-up|nod-down|shake|reset
    func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == "nodvoice" else { return }
        let action = (url.host ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        switch action {
        case "listen":
            if phase == .listening {
                stopAndProcess()
            } else {
                startListening()
            }
        case "stop":
            if phase == .listening { stopAndProcess() }
        case "nod", "nod-down", "noddown":
            simulateNodDown()
        case "nod-up", "nodup":
            simulateNodUp()
        case "shake":
            simulateShake()
        case "reset":
            resetToIdle()
        default:
            debugLine = "Unknown URL \(url.absoluteString)"
        }
    }

    func resetToIdle() {
        pipelineTask?.cancel()
        _ = capture.stop()
        player.stop()
        options = []
        selectedIndex = 0
        phase = .idle
        debugLine = ""
    }

    // MARK: - Gestures

    private func handle(gesture: HeadGestureService.Gesture) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch phase {
        case .idle, .error:
            startListening()
            debugLine = "Hands-free listen"
        case .listening:
            stopAndProcess()
        case .choosing:
            switch gesture {
            case .nodDown:
                cycleOption(forward: true)
                announceSelection()
            case .nodUp:
                cycleOption(forward: false)
                announceSelection()
            case .shake:
                confirmSelection()
            }
        case .speaking:
            player.stop()
            phase = .idle
            debugLine = "Stopped voice. Nod to listen again."
        case .transcribing, .thinking:
            debugLine = "Got \(label(for: gesture)), wait for replies"
        }
    }

    private func announceSelection() {
        guard let option = selectedOption else { return }
        debugLine = "Reply \(selectedIndex + 1) of \(options.count)"
        UIAccessibility.post(
            notification: .announcement,
            argument: "Reply \(selectedIndex + 1). \(option.text)"
        )
    }

    private func label(for gesture: HeadGestureService.Gesture) -> String {
        switch gesture {
        case .nodDown: return "nod down"
        case .nodUp: return "nod up"
        case .shake: return "shake"
        }
    }

    // MARK: - Pipeline

    private func runPipeline(fileURL: URL) async {
        defer { try? FileManager.default.removeItem(at: fileURL) }
        do {
            let bearer = try await SuperGrokAuth.shared.validAccessToken(fallbackAPIKey: "")
            phase = .transcribing
            debugLine = "STT…"
            let text = try await client.transcribe(
                fileURL: fileURL,
                apiKey: bearer,
                language: settings.language
            )
            try Task.checkCancellation()
            transcript = text

            phase = .thinking
            debugLine = "Chat \(settings.chatModel)…"
            let replies = try await client.generateReplyOptions(
                transcript: text,
                prior: history,
                bearer: bearer,
                settings: settings
            )
            try Task.checkCancellation()

            options = replies
            selectedIndex = 0
            phase = .choosing
            debugLine = "Nod down/up = pick · shake = speak"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch is CancellationError {
            // ignore
        } catch {
            guard !Task.isCancelled else { return }
            phase = .error(error.localizedDescription)
            debugLine = ""
        }
    }

    private func speak(option: ReplyOption) async {
        do {
            if !settings.hasLiveCredential {
                // Demo: mark selection without TTS
                let turn = ConversationTurn(heard: transcript, spoken: option.text)
                history.insert(turn, at: 0)
                phase = .idle
                debugLine = "Demo selected: \(option.text)"
                options = []
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                return
            }

            let bearer = try await SuperGrokAuth.shared.validAccessToken(fallbackAPIKey: "")
            phase = .speaking
            debugLine = "TTS \(settings.voiceID)…"
            let audio = try await client.synthesize(
                text: option.text,
                apiKey: bearer,
                voiceID: settings.voiceID,
                language: settings.language
            )
            try Task.checkCancellation()

            try await player.play(data: audio)
            try Task.checkCancellation()

            let turn = ConversationTurn(heard: transcript, spoken: option.text)
            history.insert(turn, at: 0)
            if history.count > 20 { history = Array(history.prefix(20)) }
            phase = .idle
            debugLine = "Done. Nod to listen again."
            options = []
        } catch is CancellationError {
            // ignore
        } catch {
            guard !Task.isCancelled else { return }
            phase = .error(error.localizedDescription)
        }
    }
}
