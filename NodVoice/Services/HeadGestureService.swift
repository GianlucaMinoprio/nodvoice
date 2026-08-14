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
    @Published private(set) var hasSamples = false
    @Published var lastGesture: Gesture?

    let gestureSubject = PassthroughSubject<Gesture, Never>()

    private let manager = CMHeadphoneMotionManager()
    private let queue = OperationQueue()

    private var nodPitchThreshold = 0.18          // ~10°
    private var shakeYawThreshold = 0.24          // ~14°, still needs both sides
    private var gestureCooldown: TimeInterval = 0.55
    private var lastGestureAt: TimeInterval = 0
    private var lastNodAt: TimeInterval = 0

    private var pitchBaseline: Double?
    private var yawBaseline: Double?
    private var lastYaw: Double = 0
    private var nodArmed = true
    private var shakeSign = 0
    private var shakeArmedAt: TimeInterval = 0

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
            return
        }
        let connected = manager.isDeviceMotionAvailable
        headphonesConnected = connected
        isAvailable = connected
        if !connected {
            isRunning = false
            hasSamples = false
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
            hasSamples = false
            return
        }
        if isRunning { return }
        isAvailable = true
        headphonesConnected = true
        resetTracking()

        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self else { return }
            if error != nil {
                DispatchQueue.main.async {
                    self.manager.stopDeviceMotionUpdates()
                    self.isRunning = false
                    self.hasSamples = false
                }
                return
            }
            guard let motion else { return }
            DispatchQueue.main.async {
                guard self.isRunning else { return }
                self.ingest(motion)
            }
        }
        isRunning = true
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
        lastYaw = yaw
        if !hasSamples { hasSamples = true }

        if pitchBaseline == nil { pitchBaseline = pitch }
        if yawBaseline == nil { yawBaseline = yaw }

        let pitchDelta = angleDifference(pitch, pitchBaseline ?? pitch)
        let yawDelta = angleDifference(yaw, yawBaseline ?? yaw)
        pitchBaseline = interpolateAngle(from: pitchBaseline ?? pitch, to: pitch, amount: 0.008)
        yawBaseline = interpolateAngle(from: yawBaseline ?? yaw, to: yaw, amount: 0.012)

        detectDirectionalNod(pitchDelta: pitchDelta)
        detectRealShake(yawDelta: yawDelta)
    }

    /// Flipped vs the previous build: chin down = nodDown.
    private func detectDirectionalNod(pitchDelta: Double) {
        if nodArmed {
            if pitchDelta <= -nodPitchThreshold {
                nodArmed = false
                lastNodAt = ProcessInfo.processInfo.systemUptime
                shakeSign = 0
                emit(.nodDown)
            } else if pitchDelta >= nodPitchThreshold {
                nodArmed = false
                lastNodAt = ProcessInfo.processInfo.systemUptime
                shakeSign = 0
                emit(.nodUp)
            }
        } else if abs(pitchDelta) < nodPitchThreshold * 0.35 {
            nodArmed = true
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
        gestureSubject.send(gesture)
    }

    func emitManual(_ gesture: Gesture) {
        lastGestureAt = 0
        emit(gesture)
    }

    private func resetTracking() {
        pitchBaseline = nil
        yawBaseline = nil
        nodArmed = true
        shakeSign = 0
        hasSamples = false
    }

    private func angleDifference(_ angle: Double, _ reference: Double) -> Double {
        atan2(sin(angle - reference), cos(angle - reference))
    }

    private func interpolateAngle(from: Double, to: Double, amount: Double) -> Double {
        from + angleDifference(to, from) * amount
    }
}
