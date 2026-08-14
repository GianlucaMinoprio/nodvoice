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
        options = []
        selectedIndex = 0
        transcript = ""
        debugLine = ""

        Task {
            let ok = await capture.requestPermission()
            guard ok else {
                phase = .error("Microphone permission denied")
                return
            }
            do {
                try capture.start()
                phase = .listening
                head.start()
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }

    func stopAndProcess() {
        guard phase == .listening else { return }
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
        capture.stop()
        player.stop()
        options = []
        selectedIndex = 0
        phase = .idle
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
            phase = .error(error.localizedDescription)
            debugLine = ""
        }
    }

    private func speak(option: ReplyOption) async {
        do {
            phase = .speaking
            debugLine = "TTS \(settings.voiceID)…"
            let audio = try await client.synthesize(
                text: option.text,
                apiKey: settings.apiKey,
                voiceID: settings.voiceID,
                language: settings.language
            )
            try Task.checkCancellation()

            let turn = ConversationTurn(heard: transcript, spoken: option.text)
            history.insert(turn, at: 0)
            if history.count > 20 { history = Array(history.prefix(20)) }

            try await player.play(data: audio)
            phase = .idle
            debugLine = "Done"
            options = []
        } catch is CancellationError {
            // ignore
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}
