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

/// Detects nod (yes) and shake (no) from AirPods / headphone IMU via CMHeadphoneMotionManager.
/// Simulator has no IMU: callers use `emitManual`.
@MainActor
final class HeadGestureService: NSObject, ObservableObject, CMHeadphoneMotionManagerDelegate {
    enum Gesture: String {
        case nod
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

    /// Fired on main actor when a gesture is accepted (after cooldown).
    let gestureSubject = PassthroughSubject<Gesture, Never>()

    private let manager = CMHeadphoneMotionManager()
    private let queue = OperationQueue()

    // Tunables — loose enough for a casual AirPods nod.
    private var nodPitchThreshold = 0.16          // radians ~9°
    private var shakeYawThreshold = 0.20          // radians ~11°
    private var gestureCooldown: TimeInterval = 0.7
    private var lastGestureAt: TimeInterval = 0
    private var pitchHistory: [(t: TimeInterval, v: Double)] = []
    private var yawHistory: [(t: TimeInterval, v: Double)] = []
    private var rollHistory: [(t: TimeInterval, v: Double)] = []
    private let historyWindow: TimeInterval = 0.55

    private var pitchBaseline: Double?
    private var yawBaseline: Double?
    private var pitchExtremum: Double = 0
    private var yawExtremum: Double = 0
    private var trackingPitchSwing = false
    private var trackingYawSwing = false
    private var pitchSwingStartedAt: TimeInterval = 0
    private var yawSwingStartedAt: TimeInterval = 0
    private let swingTimeout: TimeInterval = 1.25

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
            statusText = "Simulator: tap Nod / Shake (no AirPods IMU)"
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
        // Headphone frame: pitch/roll = nod, yaw = shake
        let pitch = motion.attitude.pitch
        let yaw = motion.attitude.yaw
        let roll = motion.attitude.roll
        lastPitch = pitch
        lastYaw = yaw
        lastRoll = roll
        sampleCount += 1
        if sampleCount == 1 {
            statusText = "IMU live — nod to pick, shake to cycle"
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

        let now = ProcessInfo.processInfo.systemUptime
        pitchHistory.append((now, pitch))
        yawHistory.append((now, yaw))
        rollHistory.append((now, roll))
        pitchHistory.removeAll { now - $0.t > historyWindow }
        yawHistory.removeAll { now - $0.t > historyWindow }
        rollHistory.removeAll { now - $0.t > historyWindow }

        detectWindowedNod()
        detectWindowedShake()
    }

    private func detectWindowedNod() {
        let pitchRange = windowRange(pitchHistory)
        let rollRange = windowRange(rollHistory)
        guard pitchRange >= nodPitchThreshold || rollRange >= nodPitchThreshold else { return }
        pitchHistory.removeAll()
        rollHistory.removeAll()
        emit(.nod)
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

    private func windowRange(_ samples: [(t: TimeInterval, v: Double)]) -> Double {
        guard samples.count >= 6 else { return 0 }
        let origin = samples[0].v
        let deltas = samples.map { angleDifference($0.v, origin) }
        guard let lo = deltas.min(), let hi = deltas.max() else { return 0 }
        return hi - lo
    }

    private func detectNod(pitchDelta: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        if trackingPitchSwing, now - pitchSwingStartedAt > swingTimeout {
            trackingPitchSwing = false
            pitchExtremum = 0
        }
        // Looking for a down-then-up (or up-then-down) pitch excursion.
        if !trackingPitchSwing {
            if abs(pitchDelta) > nodPitchThreshold * 0.6 {
                trackingPitchSwing = true
                pitchSwingStartedAt = now
                pitchExtremum = pitchDelta
            }
            return
        }

        if abs(pitchDelta) > abs(pitchExtremum) {
            pitchExtremum = pitchDelta
        }

        // Return toward center after a solid peak → count as nod
        let peaked = abs(pitchExtremum) >= nodPitchThreshold
        let returned = abs(pitchDelta) < nodPitchThreshold * 0.35
        if peaked && returned {
            trackingPitchSwing = false
            pitchExtremum = 0
            emit(.nod)
        }

        // Abandon stale swings
        if abs(pitchDelta) < 0.05 && abs(pitchExtremum) < nodPitchThreshold {
            trackingPitchSwing = false
            pitchExtremum = 0
        }
    }

    private func detectShake(yawDelta: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        if trackingYawSwing, now - yawSwingStartedAt > swingTimeout {
            trackingYawSwing = false
            yawExtremum = 0
        }
        if !trackingYawSwing {
            if abs(yawDelta) > shakeYawThreshold * 0.6 {
                trackingYawSwing = true
                yawSwingStartedAt = now
                yawExtremum = yawDelta
            }
            return
        }

        if abs(yawDelta) > abs(yawExtremum) {
            yawExtremum = yawDelta
        }

        // Opposite-side excursion = classic shake
        let peaked = abs(yawExtremum) >= shakeYawThreshold
        let crossedOpposite = (yawExtremum > 0 && yawDelta < -shakeYawThreshold * 0.45)
            || (yawExtremum < 0 && yawDelta > shakeYawThreshold * 0.45)

        if peaked && crossedOpposite {
            trackingYawSwing = false
            yawExtremum = 0
            emit(.shake)
            return
        }

        let returned = abs(yawDelta) < shakeYawThreshold * 0.3
        if peaked && returned {
            // Single side flick still counts as cycle
            trackingYawSwing = false
            yawExtremum = 0
            emit(.shake)
        }
    }

    private func emit(_ gesture: Gesture) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastGestureAt >= gestureCooldown else { return }
        lastGestureAt = now
        lastGesture = gesture
        statusText = gesture == .nod ? "Nod detected" : "Shake detected"
        gestureSubject.send(gesture)

        // Clear label shortly after
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if self.lastGesture == gesture {
                self.refreshConnection()
                if self.isRunning {
                    self.statusText = "AirPods motion: tracking"
                }
            }
        }
    }

    /// Simulator / UI stand-in for a real nod or shake.
    func emitManual(_ gesture: Gesture) {
        lastGestureAt = 0
        emit(gesture)
    }

    private func resetTracking() {
        pitchBaseline = nil
        yawBaseline = nil
        pitchExtremum = 0
        yawExtremum = 0
        trackingPitchSwing = false
        trackingYawSwing = false
        pitchHistory.removeAll()
        yawHistory.removeAll()
        rollHistory.removeAll()
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
