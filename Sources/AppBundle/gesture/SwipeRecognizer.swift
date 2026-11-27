import Common

/// Fork addition. A multi-finger swipe on the trackpad
struct TrackpadGesture: Hashable, Sendable, CustomStringConvertible {
    let fingers: Int
    /// Direction in which the fingers move
    let direction: CardinalDirection

    static let supportedFingerCounts = 3 ... 5
    private static let fingerNames = [3: "three", 4: "four", 5: "five"]

    /// Config key. For example: three-finger-swipe-left
    var description: String { "\(Self.fingerNames[fingers] ?? String(fingers))-finger-swipe-\(direction.rawValue)" }

    static func parse(_ raw: String) -> TrackpadGesture? {
        for (fingers, name) in fingerNames {
            let prefix = "\(name)-finger-swipe-"
            if raw.hasPrefix(prefix), let direction = CardinalDirection(rawValue: String(raw.dropFirst(prefix.count))) {
                return TrackpadGesture(fingers: fingers, direction: direction)
            }
        }
        return nil
    }

    static var allKeys: [String] {
        supportedFingerCounts.flatMap { fingers in
            CardinalDirection.allCases.map { TrackpadGesture(fingers: fingers, direction: $0).description }
        }
    }
}

struct TouchPoint: Equatable, Sendable {
    /// Normalized [0, 1]. Left to right
    var x: Float
    /// Normalized [0, 1]. Bottom to top
    var y: Float
}

/// Turns raw touch frames into discrete swipes. One swipe is reported per "fingers down ... fingers up" cycle,
/// the same way macOS switches one Space per swipe.
///
/// The recognizer is a pure state machine to keep it testable
struct SwipeRecognizer: Sendable {
    /// Trackpads are wider than they are tall. Normalized horizontal travel is scaled to be comparable with the vertical one
    static let aspectRatio: Float = 1.5
    /// Travel (in units of trackpad height) after which the swipe fires. Roughly 1 cm
    static let travelThreshold: Float = 0.12
    /// The main axis must be this much bigger than the other axis. Diagonal moves are ignored
    static let axisDominance: Float = 1.5
    /// All fingers must land within this time. Protects from a finger accidentally joining a two finger scroll
    static let maxLandingDuration: Double = 0.35
    /// The finger count must be stable for this long before the swipe can fire.
    /// Protects four finger swipes from being recognized as three finger ones while the last finger is still landing
    static let minStableDuration: Double = 0.03

    private enum Phase: Sendable {
        case idle
        case landing(firstTouchTime: Double)
        case tracking(fingers: Int, startX: Float, startY: Float, startTime: Double, firstTouchTime: Double)
        /// The swipe has fired, or the gesture is not a swipe. Wait until all fingers are lifted
        case spent
    }

    private var phase: Phase = .idle

    mutating func feed(_ touches: [TouchPoint], timestamp: Double) -> TrackpadGesture? {
        let count = touches.count
        if count == 0 {
            phase = .idle
            return nil
        }
        let centerX = touches.reduce(Float(0)) { $0 + $1.x } / Float(count)
        let centerY = touches.reduce(Float(0)) { $0 + $1.y } / Float(count)
        let supported = TrackpadGesture.supportedFingerCounts

        func startTracking(firstTouchTime: Double) -> Phase {
            if count > supported.upperBound || timestamp - firstTouchTime > Self.maxLandingDuration { return .spent }
            if !supported.contains(count) { return .landing(firstTouchTime: firstTouchTime) }
            return .tracking(fingers: count, startX: centerX, startY: centerY, startTime: timestamp, firstTouchTime: firstTouchTime)
        }

        switch phase {
            case .spent:
                return nil
            case .idle:
                phase = startTracking(firstTouchTime: timestamp)
                return nil
            case .landing(let firstTouchTime):
                phase = startTracking(firstTouchTime: firstTouchTime)
                return nil
            case .tracking(let fingers, let startX, let startY, let startTime, let firstTouchTime):
                if count > fingers { // One more finger has landed
                    phase = startTracking(firstTouchTime: firstTouchTime)
                    return nil
                }
                if count < fingers { // Fingers are being lifted
                    phase = .spent
                    return nil
                }
                if timestamp - startTime < Self.minStableDuration { return nil }
                let dx = (centerX - startX) * Self.aspectRatio
                let dy = centerY - startY
                if max(abs(dx), abs(dy)) < Self.travelThreshold { return nil }
                let direction: CardinalDirection
                if abs(dx) >= abs(dy) * Self.axisDominance {
                    direction = dx < 0 ? .left : .right
                } else if abs(dy) >= abs(dx) * Self.axisDominance {
                    direction = dy > 0 ? .up : .down
                } else {
                    phase = .spent
                    return nil
                }
                phase = .spent
                return TrackpadGesture(fingers: fingers, direction: direction)
        }
    }
}
