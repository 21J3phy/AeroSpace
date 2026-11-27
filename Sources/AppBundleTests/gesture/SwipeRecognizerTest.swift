@testable import AppBundle
import Common
import Testing

struct SwipeRecognizerTest {
    /// Simulate fingers that land at the same time and move together. Returns everything the recognizer reported
    private func swipe(
        fingers: Int,
        dx: Float,
        dy: Float,
        steps: Int = 10,
        recognizer: inout SwipeRecognizer,
        startTime: Double = 0,
    ) -> [TrackpadGesture] {
        var result: [TrackpadGesture] = []
        for step in 0 ... steps {
            let progress = Float(step) / Float(steps)
            let touches = (0 ..< fingers).map {
                TouchPoint(x: 0.3 + Float($0) * 0.1 + dx * progress, y: 0.5 + dy * progress)
            }
            if let gesture = recognizer.feed(touches, timestamp: startTime + Double(step) * 0.01) {
                result.append(gesture)
            }
        }
        _ = recognizer.feed([], timestamp: startTime + Double(steps + 1) * 0.01) // Lift all fingers
        return result
    }

    @Test func testThreeFingerSwipesInAllDirections() {
        var recognizer = SwipeRecognizer()
        assertEquals(swipe(fingers: 3, dx: -0.3, dy: 0, recognizer: &recognizer), [TrackpadGesture(fingers: 3, direction: .left)])
        assertEquals(swipe(fingers: 3, dx: 0.3, dy: 0, recognizer: &recognizer, startTime: 1), [TrackpadGesture(fingers: 3, direction: .right)])
        assertEquals(swipe(fingers: 3, dx: 0, dy: 0.3, recognizer: &recognizer, startTime: 2), [TrackpadGesture(fingers: 3, direction: .up)])
        assertEquals(swipe(fingers: 3, dx: 0, dy: -0.3, recognizer: &recognizer, startTime: 3), [TrackpadGesture(fingers: 3, direction: .down)])
    }

    @Test func testOneSwipeIsReportedOnlyOnce() {
        var recognizer = SwipeRecognizer()
        assertEquals(swipe(fingers: 3, dx: -0.9, dy: 0, steps: 50, recognizer: &recognizer).count, 1)
    }

    @Test func testSmallMovesAndDiagonalMovesAreIgnored() {
        var recognizer = SwipeRecognizer()
        assertEquals(swipe(fingers: 3, dx: 0.02, dy: 0.01, recognizer: &recognizer), [])
        assertEquals(swipe(fingers: 3, dx: 0.2, dy: 0.3, recognizer: &recognizer, startTime: 1), [])
    }

    @Test func testTwoFingerScrollIsIgnored() {
        var recognizer = SwipeRecognizer()
        assertEquals(swipe(fingers: 2, dx: -0.5, dy: 0, recognizer: &recognizer), [])
        assertEquals(swipe(fingers: 1, dx: -0.5, dy: 0, recognizer: &recognizer, startTime: 1), [])
    }

    @Test func testFourFingerSwipeIsNotReportedAsThreeFingerSwipe() {
        var recognizer = SwipeRecognizer()
        // Three fingers land first. The fourth one joins 10 ms later, then all of them move left
        var gestures: [TrackpadGesture] = []
        let three = (0 ..< 3).map { TouchPoint(x: 0.3 + Float($0) * 0.1, y: 0.5) }
        gestures += [recognizer.feed(three, timestamp: 0)].filterNotNil()
        for step in 0 ... 20 {
            let shift = Float(step) * 0.02
            let four = (0 ..< 4).map { TouchPoint(x: 0.3 + Float($0) * 0.1 - shift, y: 0.5) }
            gestures += [recognizer.feed(four, timestamp: 0.01 + Double(step) * 0.01)].filterNotNil()
        }
        assertEquals(gestures, [TrackpadGesture(fingers: 4, direction: .left)])
        // Fingers are lifted one by one. It must not produce one more swipe
        let lifting = (0 ..< 3).map { TouchPoint(x: 0.9 + Float($0) * 0.1, y: 0.5) }
        assertNil(recognizer.feed(lifting, timestamp: 0.3))
    }

    @Test func testThirdFingerJoiningScrollIsIgnored() {
        var recognizer = SwipeRecognizer()
        let two = [TouchPoint(x: 0.3, y: 0.5), TouchPoint(x: 0.4, y: 0.5)]
        assertNil(recognizer.feed(two, timestamp: 0))
        // The third finger lands a second later. It is a resting finger, not a three finger swipe
        for step in 0 ... 20 {
            let shift = Float(step) * 0.02
            let three = (0 ..< 3).map { TouchPoint(x: 0.3 + Float($0) * 0.1 - shift, y: 0.5) }
            assertNil(recognizer.feed(three, timestamp: 1 + Double(step) * 0.01))
        }
    }

    @Test func testParseGestureConfigKey() {
        assertEquals(TrackpadGesture.parse("three-finger-swipe-left"), TrackpadGesture(fingers: 3, direction: .left))
        assertEquals(TrackpadGesture.parse("four-finger-swipe-up"), TrackpadGesture(fingers: 4, direction: .up))
        assertEquals(TrackpadGesture.parse("two-finger-swipe-up"), nil)
        assertEquals(TrackpadGesture.parse("three-finger-swipe-sideways"), nil)
        assertEquals(TrackpadGesture(fingers: 5, direction: .down).description, "five-finger-swipe-down")
    }
}
