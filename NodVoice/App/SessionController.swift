import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class SessionController: ObservableObject {
    @Published var phase: SessionPhase = .idle
    @Published var transcript: String = ""
    @Published var options: [ReplyOption] = []
    @Published var selectedIndex: Int = 0 {
        didSet {
            if oldValue != selectedIndex, phase == .choosing {
                restartDwell()
            }
        }
    }
    @Published var history: [ConversationTurn] = []
    @Published var settings: AppSettings
    @Published var imuLive = false
    @Published var grokSignedIn = SuperGrokSession.isSignedIn
    @Published var dwellProgress: Double = 0

    let capture = AudioCaptureService()
    let head = HeadGestureService()
    let player = SpeechPlayer()
    private let client = XAIClient()

    private var gestureBag: AnyCancellable?
    private var pipelineTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?
    private var ignoreGesturesUntil: TimeInterval = 0
    private var dwellSeconds: TimeInterval { settings.dwellSeconds }

    init() {
        settings = AppSettings.load()
        gestureBag = head.gestureSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] gesture in
                self?.handle(gesture: gesture)
            }

        head.$hasSamples
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .assign(to: &$imuLive)

        head.$headphonesConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                self?.handleHeadphonesChange(connected)
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func handleHeadphonesChange(_ connected: Bool) {
        if !connected { imuLive = false }
        guard !isSimulator, !connected else { return }
        if phase != .idle {
            endSession()
        }
    }

    enum Gate: Equatable {
        case connectGrok
        case wearAirPods
        case ready
    }

    var gate: Gate {
        if isSimulator {
            return grokSignedIn ? .ready : .connectGrok
        }
        if !grokSignedIn { return .connectGrok }
        if !imuLive { return .wearAirPods }
        return .ready
    }

    var statusTitle: String {
        switch gate {
        case .connectGrok: return "Connect Grok"
        case .wearAirPods: return "Wear AirPods"
        case .ready:
            return phase == .idle ? "Ready" : phase.shortLabel
        }
    }

    var statusSymbol: String {
        switch gate {
        case .connectGrok: return "person.crop.circle.badge.plus"
        case .wearAirPods: return "airpodspro"
        case .ready: return phase.symbolName
        }
    }

    var statusTint: Color {
        switch gate {
        case .connectGrok: return .accentColor
        case .wearAirPods: return .orange
        case .ready: return phase == .idle ? .green : phase.tint
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

    /// Ready only when SuperGrok is signed in and IMU samples are flowing.
    var canUseApp: Bool {
        isSimulator || (grokSignedIn && imuLive)
    }

    var allowsManualGestures: Bool { isSimulator }

    func onAppear() {
        grokSignedIn = SuperGrokSession.isSignedIn
        head.refreshConnection()
        head.start()
    }

    func refreshGrokAuth() {
        grokSignedIn = SuperGrokSession.isSignedIn
    }

    func onDisappear() {
        // keep motion running while app is active; stop only if needed
    }

    func saveSettings() {
        settings.save()
    }

    func toggleListen() {
        guard canUseApp else { return }
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
        listenTask?.cancel()
        cancelDwell()
        player.stop()
        options = []
        selectedIndex = 0
        transcript = ""
        lockGestures(1.1)

        guard canUseApp else { return }
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
                startListenMonitor()
            } catch {
                guard !Task.isCancelled else { return }
                phase = .error(error.localizedDescription)
            }
        }
    }

    /// Offline path: fake transcript + options so you can practice nod/shake.
    private func runDemoPipeline() async {
        phase = .listening
        head.start()
        startListenMonitor()
    }

    func stopAndProcess() {
        guard phase == .listening else { return }
        listenTask?.cancel()

        if !settings.hasLiveCredential {
            pipelineTask?.cancel()
            pipelineTask = Task {
                phase = .transcribing
                if transcript.isEmpty {
                    transcript = "So what do you actually think about that idea?"
                }
                phase = .thinking
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                presentDemoOptions()
            }
            return
        }

        let url = capture.stop()
        pipelineTask?.cancel()
        pipelineTask = Task {
            await finishTurn(lastChunk: url)
        }
    }

    func endSession() {
        listenTask?.cancel()
        pipelineTask?.cancel()
        cancelDwell()
        _ = capture.stop()
        player.stop()
        options = []
        selectedIndex = 0
        dwellProgress = 0
        phase = .idle
        lockGestures(0.8)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
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
        cancelDwell()
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
            break
        }
    }

    func resetToIdle() {
        endSession()
    }

    // MARK: - Gestures

    private func handle(gesture: HeadGestureService.Gesture) {
        let now = ProcessInfo.processInfo.systemUptime
        if now < ignoreGesturesUntil {
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch gesture {
        case .shake:
            switch phase {
            case .idle, .error:
                startListening()
            default:
                endSession()
            }
        case .nodDown:
            guard phase == .choosing else { return }
            cycleOption(forward: true)
            announceSelection()
        case .nodUp:
            guard phase == .choosing else { return }
            cycleOption(forward: false)
            announceSelection()
        }
    }

    private func announceSelection() {
        guard let option = selectedOption else { return }
        UIAccessibility.post(
            notification: .announcement,
            argument: "Reply \(selectedIndex + 1). \(option.text)"
        )
    }

    private func lockGestures(_ seconds: TimeInterval) {
        ignoreGesturesUntil = ProcessInfo.processInfo.systemUptime + seconds
    }

    private func presentDemoOptions() {
        options = [
            ReplyOption(text: "Yeah, I'm in. Let's try a small version this week.", tone: "positive"),
            ReplyOption(text: "Not for me. Let's skip this one.", tone: "negative"),
            ReplyOption(text: "Maybe. I need a bit more before I decide.", tone: "neutral"),
            ReplyOption(text: "What if we do a lighter version first?", tone: "alternative")
        ]
        selectedIndex = 0
        phase = .choosing
        lockGestures(0.5)
        restartDwell()
    }

    private func restartDwell() {
        dwellTask?.cancel()
        dwellProgress = 0
        guard phase == .choosing else { return }
        dwellTask = Task { await runDwell() }
    }

    private func cancelDwell() {
        dwellTask?.cancel()
        dwellTask = nil
        dwellProgress = 0
    }

    private func runDwell() async {
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled, phase == .choosing else { return }
        let ticks = 40
        for i in 1...ticks {
            guard !Task.isCancelled, phase == .choosing else { return }
            dwellProgress = Double(i) / Double(ticks)
            try? await Task.sleep(nanoseconds: UInt64(dwellSeconds / Double(ticks) * 1_000_000_000))
        }
        guard !Task.isCancelled, phase == .choosing else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        confirmSelection()
    }

    private func startListenMonitor() {
        listenTask?.cancel()
        listenTask = Task { await monitorListening() }
    }

    private func monitorListening() async {
        var heardSpeech = false
        var silentFor: TimeInterval = 0
        var lastRotate = Date()
        let started = Date()
        while !Task.isCancelled, phase == .listening {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !settings.hasLiveCredential {
                if Date().timeIntervalSince(started) > 1.8 {
                    if transcript.isEmpty {
                        transcript = "So what do you actually think about that idea?"
                    }
                    stopAndProcess()
                    return
                }
                continue
            }

            capture.updateMeters()
            if capture.averagePower > -28 {
                heardSpeech = true
                silentFor = 0
            } else if heardSpeech {
                silentFor += 0.1
            }

            if Date().timeIntervalSince(lastRotate) >= 3.2, phase == .listening {
                lastRotate = Date()
                await liveTranscribeChunk()
            }

            let elapsed = Date().timeIntervalSince(started)
            if heardSpeech, silentFor >= 1.6, elapsed >= 2.0 {
                stopAndProcess()
                return
            }
        }
    }

    private func liveTranscribeChunk() async {
        guard settings.hasLiveCredential, phase == .listening else { return }
        do {
            guard let url = try capture.rotate() else { return }
            defer { try? FileManager.default.removeItem(at: url) }
            try Task.checkCancellation()
            let bearer = try await SuperGrokAuth.shared.validAccessToken(fallbackAPIKey: "")
            let piece = try await client.transcribe(
                fileURL: url,
                apiKey: bearer,
                language: settings.language
            )
            appendLive(piece)
        } catch {
            // Chunk STT can fail on silence. Keep listening.
        }
    }

    private func appendLive(_ piece: String) {
        let piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard piece.count > 2 else { return }
        if transcript.isEmpty {
            transcript = piece
            return
        }
        if transcript.localizedCaseInsensitiveContains(piece) { return }
        if piece.localizedCaseInsensitiveContains(transcript) {
            transcript = piece
            return
        }
        transcript = stitchTranscript(existing: transcript, incoming: piece)
    }

    private func stitchTranscript(existing: String, incoming: String) -> String {
        let existingWords = existing.split(separator: " ").map(String.init)
        let incomingWords = incoming.split(separator: " ").map(String.init)
        guard !existingWords.isEmpty, !incomingWords.isEmpty else {
            return (existing + " " + incoming).trimmingCharacters(in: .whitespaces)
        }
        let maxOverlap = min(6, existingWords.count, incomingWords.count)
        if maxOverlap > 0 {
            for n in stride(from: maxOverlap, through: 1, by: -1) {
                let tail = existingWords.suffix(n).map { $0.lowercased() }
                let head = incomingWords.prefix(n).map { $0.lowercased() }
                if tail == head {
                    return (existingWords + incomingWords.dropFirst(n)).joined(separator: " ")
                }
            }
        }
        return existing + " " + incoming
    }

    // MARK: - Pipeline

    private func finishTurn(lastChunk: URL?) async {
        defer {
            if let lastChunk {
                try? FileManager.default.removeItem(at: lastChunk)
            }
        }
        do {
            let bearer = try await SuperGrokAuth.shared.validAccessToken(fallbackAPIKey: "")
            if let lastChunk {
                phase = .transcribing
                if let piece = try? await client.transcribe(
                    fileURL: lastChunk,
                    apiKey: bearer,
                    language: settings.language
                ) {
                    appendLive(piece)
                }
            }
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                phase = .error("Nothing heard. Shake to listen again.")
                return
            }

            phase = .thinking
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
            lockGestures(0.6)
            restartDwell()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch is CancellationError {
            // ignore
        } catch {
            guard !Task.isCancelled else { return }
            phase = .error(error.localizedDescription)
        }
    }

    private func speak(option: ReplyOption) async {
        do {
            if !settings.hasLiveCredential {
                // Demo: mark selection without TTS
                let turn = ConversationTurn(heard: transcript, spoken: option.text)
                history.insert(turn, at: 0)
                options = []
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                lockGestures(1.1)
                startListening()
                return
            }

            let bearer = try await SuperGrokAuth.shared.validAccessToken(fallbackAPIKey: "")
            phase = .speaking
            let audio = try await client.synthesize(
                text: option.text,
                apiKey: bearer,
                voiceID: settings.voiceID,
                language: settings.language
            )
            try Task.checkCancellation()

            try await player.play(data: audio, volume: Float(settings.speakerVolume))
            try Task.checkCancellation()

            let turn = ConversationTurn(heard: transcript, spoken: option.text)
            history.insert(turn, at: 0)
            if history.count > 20 { history = Array(history.prefix(20)) }
            options = []
            lockGestures(1.2)
            startListening()
        } catch is CancellationError {
            // ignore
        } catch {
            guard !Task.isCancelled else { return }
            phase = .error(error.localizedDescription)
        }
    }
}
