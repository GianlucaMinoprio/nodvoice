import Combine
import CoreMotion
import Foundation

enum DeviceEnvironment {
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
}

/// Detects nod-up, nod-down, and shake from AirPods IMU via CMHeadphoneMotionManager.
/// Simulator has no IMU: callers use `emitManual`.
@MainActor
final class HeadGestureService: NSObject, ObservableObject, CMHeadphoneMotionManagerDelegate {
    enum Gesture: String {
        case nodUp
        case nodDown
        case shake
    }

    @Published private(set) var isAvailable = false
    @Published private(set) var headphonesConnected = false
    @Published private(set) var isRunning = false
    @Published private(set) var lastPitch: Double = 0
    @Published private(set) var lastYaw: Double = 0
    @Published private(set) var lastRoll: Double = 0
    @Published private(set) var sampleCount: Int = 0
    @Published private(set) var liveLine = ""
    @Published private(set) var statusText = "AirPods motion: off"
    @Published var lastGesture: Gesture?

    let gestureSubject = PassthroughSubject<Gesture, Never>()

    private let manager = CMHeadphoneMotionManager()
    private let queue = OperationQueue()

    // ~9° nod, ~11° shake. Casual AirPods motion, not a full bow.
    private var nodPitchThreshold = 0.16
    private var shakeYawThreshold = 0.20
    private var gestureCooldown: TimeInterval = 0.55
    private var lastGestureAt: TimeInterval = 0
    private var yawHistory: [(t: TimeInterval, v: Double)] = []
    private let historyWindow: TimeInterval = 0.55

    private var pitchBaseline: Double?
    private var nodArmed = true

    override init() {
        super.init()
        queue.name = "nodvoice.headmotion"
        queue.maxConcurrentOperationCount = 1
        manager.delegate = self
        refreshConnection()
    }

    func refreshConnection() {
        if DeviceEnvironment.isSimulator {
            headphonesConnected = false
            isAvailable = false
            statusText = "Simulator: tap Nod up / Nod down / Shake"
            return
        }
        let connected = manager.isDeviceMotionAvailable
        headphonesConnected = connected
        isAvailable = connected
        if !connected {
            isRunning = false
            statusText = "Put AirPods in to use NodVoice"
        } else if isRunning {
            statusText = "AirPods motion: tracking"
        } else {
            statusText = "AirPods connected"
        }
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        refreshConnection()
        if headphonesConnected, !isRunning {
            start()
        }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        stop()
        refreshConnection()
    }

    func start() {
        refreshConnection()
        guard !DeviceEnvironment.isSimulator else { return }
        guard manager.isDeviceMotionAvailable else {
            isAvailable = false
            headphonesConnected = false
            isRunning = false
            statusText = "Put AirPods in to use NodVoice"
            return
        }
        guard !isRunning else { return }
        isAvailable = true
        headphonesConnected = true
        resetTracking()

        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in
                    self.manager.stopDeviceMotionUpdates()
                    self.isRunning = false
                    self.statusText = "Motion error: \(error.localizedDescription)"
                }
                return
            }
            guard let motion else { return }
            Task { @MainActor in
                guard self.isRunning else { return }
                self.ingest(motion)
            }
        }
        isRunning = true
        statusText = "AirPods motion: tracking"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if self.isRunning, self.sampleCount == 0 {
                self.statusText = "AirPods in, but no IMU yet. Reseat buds. Needs AirPods Pro / Max with head tracking."
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isRunning = false
        resetTracking()
        refreshConnection()
    }

    private func ingest(_ motion: CMDeviceMotion) {
        let pitch = motion.attitude.pitch
        let yaw = motion.attitude.yaw
        let roll = motion.attitude.roll
        lastPitch = pitch
        lastYaw = yaw
        lastRoll = roll
        sampleCount += 1
        if sampleCount == 1 {
            statusText = "IMU live. Nod to listen. Nod up/down to pick. Shake to speak."
        }
        if sampleCount % 8 == 0 {
            liveLine = String(
                format: "IMU  pitch %+.0f°  yaw %+.0f°  roll %+.0f°  n=%d",
                pitch * 180 / .pi,
                yaw * 180 / .pi,
                roll * 180 / .pi,
                sampleCount
            )
        }

        if pitchBaseline == nil { pitchBaseline = pitch }
        let pitchDelta = angleDifference(pitch, pitchBaseline ?? pitch)
        // Slow drift so resting pose updates without eating the nod.
        pitchBaseline = interpolateAngle(from: pitchBaseline ?? pitch, to: pitch, amount: 0.008)
        detectDirectionalNod(pitchDelta: pitchDelta)

        let now = ProcessInfo.processInfo.systemUptime
        yawHistory.append((now, yaw))
        yawHistory.removeAll { now - $0.t > historyWindow }
        detectWindowedShake()
    }

    /// Look down past threshold = nodDown. Look up = nodUp.
    /// Rearm only after the head comes back to center so one nod is one event.
    private func detectDirectionalNod(pitchDelta: Double) {
        if nodArmed {
            if pitchDelta >= nodPitchThreshold {
                nodArmed = false
                emit(.nodDown)
            } else if pitchDelta <= -nodPitchThreshold {
                nodArmed = false
                emit(.nodUp)
            }
        } else if abs(pitchDelta) < nodPitchThreshold * 0.35 {
            nodArmed = true
        }
    }

    private func detectWindowedShake() {
        guard yawHistory.count >= 6 else { return }
        let origin = yawHistory[0].v
        let deltas = yawHistory.map { angleDifference($0.v, origin) }
        guard let lo = deltas.min(), let hi = deltas.max() else { return }
        guard (hi - lo) >= shakeYawThreshold else { return }
        yawHistory.removeAll()
        emit(.shake)
    }

    private func emit(_ gesture: Gesture) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastGestureAt >= gestureCooldown else { return }
        lastGestureAt = now
        lastGesture = gesture
        switch gesture {
        case .nodDown: statusText = "Nod down"
        case .nodUp: statusText = "Nod up"
        case .shake: statusText = "Shake"
        }
        gestureSubject.send(gesture)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if self.lastGesture == gesture, self.isRunning {
                self.statusText = "AirPods motion: tracking"
            }
        }
    }

    func emitManual(_ gesture: Gesture) {
        lastGestureAt = 0
        emit(gesture)
    }

    private func resetTracking() {
        pitchBaseline = nil
        nodArmed = true
        yawHistory.removeAll()
        sampleCount = 0
        liveLine = ""
    }

    private func angleDifference(_ angle: Double, _ reference: Double) -> Double {
        atan2(sin(angle - reference), cos(angle - reference))
    }

    private func interpolateAngle(from: Double, to: Double, amount: Double) -> Double {
        from + angleDifference(to, from) * amount
    }
}
