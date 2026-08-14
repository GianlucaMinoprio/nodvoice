import AVFoundation
import Foundation

@MainActor
final class SpeechPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false

    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?

    /// Play Grok TTS on the iPhone speaker even if AirPods are connected.
    func play(data: Data) async throws {
        stop()
        try routeToPhoneSpeaker()

        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.volume = 1
        player.prepareToPlay()
        self.player = player
        isPlaying = true
        player.play()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        continuation?.resume()
        continuation = nil
    }

    /// Force built-in speaker. Bluetooth flags would send Grok into the buds.
    func routeToPhoneSpeaker() throws {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        try session.overrideOutputAudioPort(.speaker)
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.continuation?.resume()
            self.continuation = nil
        }
    }
}
