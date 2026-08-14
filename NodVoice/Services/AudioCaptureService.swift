import AVFoundation
import Foundation

@MainActor
final class AudioCaptureService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var lastError: String?

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    func requestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                    cont.resume(returning: allowed)
                }
            }
        }
    }

    func start() throws {
        lastError = nil
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodvoice-\(UUID().uuidString).m4a")
        fileURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw CaptureError.failedToStart
            }
            self.recorder = recorder
            isRecording = true
        } catch {
            fileURL = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stop() -> URL? {
        guard recorder != nil else { return nil }
        recorder?.stop()
        recorder = nil
        isRecording = false
        defer { fileURL = nil }
        return fileURL
    }

    enum CaptureError: LocalizedError {
        case failedToStart
        var errorDescription: String? { "Could not start microphone capture." }
    }
}
