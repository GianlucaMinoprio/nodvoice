import Combine
import CoreMotion
import Foundation

/// Detects nod (yes) and shake (no) from AirPods / headphone IMU via CMHeadphoneMotionManager.
/// This is the entire "brain sensing" stack. It's an IMU. That's the bit.
@MainActor
final class HeadGestureService: ObservableObject {
    enum Gesture: String {
        case nod
        case shake
    }

    @Published private(set) var isAvailable = false
    @Published private(set) var isRunning = false
    @Published private(set) var lastPitch: Double = 0
    @Published private(set) var lastYaw: Double = 0
    @Published private(set) var statusText = "AirPods motion: off"
    @Published var lastGesture: Gesture?

    /// Fired on main actor when a gesture is accepted (after cooldown).
    let gestureSubject = PassthroughSubject<Gesture, Never>()

    private let manager = CMHeadphoneMotionManager()
    private let queue = OperationQueue()

    // Tunables — start permissive, tighten on device.
    private var nodPitchThreshold = 0.28          // radians ~16°
    private var shakeYawThreshold = 0.35          // radians ~20°
    private var gestureCooldown: TimeInterval = 0.85
    private var lastGestureAt: TimeInterval = 0

    private var pitchBaseline: Double?
    private var yawBaseline: Double?
    private var pitchExtremum: Double = 0
    private var yawExtremum: Double = 0
    private var trackingPitchSwing = false
    private var trackingYawSwing = false

    init() {
        queue.name = "nodvoice.headmotion"
        queue.maxConcurrentOperationCount = 1
        isAvailable = manager.isDeviceMotionAvailable
        statusText = isAvailable
            ? "AirPods motion: ready (put buds in)"
            : "AirPods motion unavailable on this device"
    }

    func start() {
        guard manager.isDeviceMotionAvailable else {
            statusText = "No headphone motion API on this hardware"
            return
        }
        guard !isRunning else { return }

        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in
                    self.statusText = "Motion error: \(error.localizedDescription)"
                }
                return
            }
            guard let motion else { return }
            Task { @MainActor in
                self.ingest(motion)
            }
        }
        isRunning = true
        statusText = "AirPods motion: tracking"
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isRunning = false
        pitchBaseline = nil
        yawBaseline = nil
        trackingPitchSwing = false
        trackingYawSwing = false
        statusText = "AirPods motion: off"
    }

    private func ingest(_ motion: CMDeviceMotion) {
        // attitude: pitch = nod axis, yaw = shake axis (headphone frame)
        let pitch = motion.attitude.pitch
        let yaw = motion.attitude.yaw
        lastPitch = pitch
        lastYaw = yaw

        if pitchBaseline == nil { pitchBaseline = pitch }
        if yawBaseline == nil { yawBaseline = yaw }

        let pitchDelta = pitch - (pitchBaseline ?? pitch)
        let yawDelta = yaw - (yawBaseline ?? yaw)

        // Slow baseline drift so resting pose doesn't stick forever
        pitchBaseline = lerp(pitchBaseline ?? pitch, pitch, 0.02)
        yawBaseline = lerp(yawBaseline ?? yaw, yaw, 0.02)

        detectNod(pitchDelta: pitchDelta)
        detectShake(yawDelta: yawDelta)
    }

    private func detectNod(pitchDelta: Double) {
        // Looking for a down-then-up (or up-then-down) pitch excursion.
        if !trackingPitchSwing {
            if abs(pitchDelta) > nodPitchThreshold * 0.6 {
                trackingPitchSwing = true
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
        if !trackingYawSwing {
            if abs(yawDelta) > shakeYawThreshold * 0.6 {
                trackingYawSwing = true
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
                self.statusText = self.isRunning ? "AirPods motion: tracking" : "AirPods motion: off"
            }
        }
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }
}
