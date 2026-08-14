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

/// AirPods IMU: nod up / nod down / a real left-right head shake.
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

    private var nodPitchThreshold = 0.14          // ~8°, relative to last half-second
    private var shakeYawThreshold = 0.24          // ~14°, still needs both sides
    private var gestureCooldown: TimeInterval = 0.5
    private var lastGestureAt: TimeInterval = 0
    private var lastNodAt: TimeInterval = 0

    private var pitchHistory: [(t: TimeInterval, v: Double)] = []
    private var yawBaseline: Double?
    private var shakeSign = 0
    private var shakeArmedAt: TimeInterval = 0
    private let nodWindow: TimeInterval = 0.5

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
            statusText = "Simulator: tap gestures"
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
        if headphonesConnected, !isRunning { start() }
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
        if sampleCount % 8 == 0 {
            liveLine = String(
                format: "IMU  pitch %+.0f°  yaw %+.0f°  roll %+.0f°  n=%d",
                pitch * 180 / .pi,
                yaw * 180 / .pi,
                roll * 180 / .pi,
                sampleCount
            )
        }

        if yawBaseline == nil { yawBaseline = yaw }

        let now = ProcessInfo.processInfo.systemUptime
        pitchHistory.append((now, pitch))
        pitchHistory.removeAll { now - $0.t > nodWindow }
        detectWindowedNod()

        let yawDelta = angleDifference(yaw, yawBaseline ?? yaw)
        yawBaseline = interpolateAngle(from: yawBaseline ?? yaw, to: yaw, amount: 0.012)
        detectRealShake(yawDelta: yawDelta)
    }

    /// Compare to the last half-second, not a slow baseline.
    /// Looking down at the phone is rest. A nod is extra motion from there.
    private func detectWindowedNod() {
        guard pitchHistory.count >= 5 else { return }
        let origin = pitchHistory[0].v
        let deltas = pitchHistory.map { angleDifference($0.v, origin) }
        guard let lo = deltas.min(), let hi = deltas.max() else { return }

        if lo <= -nodPitchThreshold, lo <= -hi {
            pitchHistory.removeAll()
            lastNodAt = ProcessInfo.processInfo.systemUptime
            shakeSign = 0
            emit(.nodDown)
            return
        }
        if hi >= nodPitchThreshold, hi >= -lo {
            pitchHistory.removeAll()
            lastNodAt = ProcessInfo.processInfo.systemUptime
            shakeSign = 0
            emit(.nodUp)
        }
    }

    /// A real shake is left then right (or right then left), not a glance.
    private func detectRealShake(yawDelta: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastNodAt < 0.7 {
            shakeSign = 0
            return
        }
        if shakeSign != 0, now - shakeArmedAt > 1.15 {
            shakeSign = 0
        }

        if shakeSign == 0 {
            if abs(yawDelta) >= shakeYawThreshold {
                shakeSign = yawDelta > 0 ? 1 : -1
                shakeArmedAt = now
            }
            return
        }

        // Return swing can be smaller than the first flick.
        let opposite = Double(shakeSign) * yawDelta <= -shakeYawThreshold * 0.55
        if opposite {
            shakeSign = 0
            yawBaseline = lastYaw
            emit(.shake)
        }
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
        yawBaseline = nil
        shakeSign = 0
        pitchHistory.removeAll()
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
