import Combine
import Foundation
import SwiftUI

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

    func onAppear() {
        head.start()
    }

    func onDisappear() {
        // keep motion running while app is active; stop only if needed
    }

    func saveSettings() {
        settings.save()
    }

    func toggleListen() {
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

        // No API key → local demo so UI + nod gestures still work offline
        if settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
        debugLine = "Demo mode (no API key)"
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
        debugLine = "Demo: nod = select, shake = next. TTS needs API key"
    }

    func stopAndProcess() {
        guard phase == .listening else { return }

        // Demo mode has no recorder
        if settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                debugLine = "Demo: nod = select, shake = next"
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
        guard phase == .choosing else { return }
        switch gesture {
        case .nod:
            confirmSelection()
        case .shake:
            cycleOption(forward: true)
        }
    }

    // MARK: - Pipeline

    private func runPipeline(fileURL: URL) async {
        defer { try? FileManager.default.removeItem(at: fileURL) }
        do {
            phase = .transcribing
            debugLine = "STT…"
            let text = try await client.transcribe(
                fileURL: fileURL,
                apiKey: settings.apiKey,
                language: settings.language
            )
            try Task.checkCancellation()
            transcript = text

            phase = .thinking
            debugLine = "Chat \(settings.chatModel)…"
            let replies = try await client.generateReplyOptions(
                transcript: text,
                prior: history,
                settings: settings
            )
            try Task.checkCancellation()

            options = replies
            selectedIndex = 0
            phase = .choosing
            debugLine = "Nod = speak · shake = next"
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
            if settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Demo: mark selection without TTS
                let turn = ConversationTurn(heard: transcript, spoken: option.text)
                history.insert(turn, at: 0)
                phase = .idle
                debugLine = "Demo selected: \(option.text)"
                options = []
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                return
            }

            phase = .speaking
            debugLine = "TTS \(settings.voiceID)…"
            let audio = try await client.synthesize(
                text: option.text,
                apiKey: settings.apiKey,
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
            debugLine = "Done"
            options = []
        } catch is CancellationError {
            // ignore
        } catch {
            guard !Task.isCancelled else { return }
            phase = .error(error.localizedDescription)
        }
    }
}
