import AppKit
import Common
import os
import PrivateApi

// Fork addition. Trackpad swipes bound to AeroSpace commands. See [gestures] config section

private let recognizer = OSAllocatedUnfairLock(initialState: SwipeRecognizer())

/// Called on a MultitouchSupport thread
private let onTouchFrame: AeroTouchFrameCallback = { touches, count, timestamp in
    let points: [TouchPoint] = unsafe UnsafeBufferPointer(start: touches, count: Int(count)).map { TouchPoint(x: $0.x, y: $0.y) }
    guard let gesture = recognizer.withLock({ $0.feed(points, timestamp: timestamp) }) else { return }
    Task.startUnstructured { @MainActor in
        await runTrackpadGesture(gesture)
    }
}

@MainActor
private func runTrackpadGesture(_ gesture: TrackpadGesture) async {
    guard let token: RunSessionGuard = .isServerEnabled else { return }
    guard let commands = config.gestures[gesture] else { return }
    _ = try? await runLightSession(.trackpadGesture(gesture.description), token) {
        _ = await commands.run(.defaultEnv, .emptyStdin)
    }
}

@MainActor private var startedDeviceCount: Int32 = 0
@MainActor private var deviceWatcher: Timer? = nil
@MainActor private var wakeObserver: (any NSObjectProtocol)? = nil

/// Start or stop listening to the trackpad depending on whether the config contains gesture bindings
@MainActor
func syncTrackpadGestures() {
    if isUnitTest { return }
    if config.gestures.isEmpty {
        stopTrackpadGestures()
        return
    }
    if deviceWatcher != nil { return } // Already running
    restartTrackpadDevices()
    // Trackpads can be connected and disconnected (bluetooth, sleep). There is no public notification for that
    deviceWatcher = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
        Task.startUnstructured { @MainActor in
            if aeroMultitouchDeviceCount() != startedDeviceCount { restartTrackpadDevices() }
        }
    }
    wakeObserver = NSWorkspace.shared.notificationCenter
        .addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task.startUnstructured { @MainActor in restartTrackpadDevices() }
        }
}

@MainActor
private func restartTrackpadDevices() {
    recognizer.withLock { $0 = SwipeRecognizer() }
    startedDeviceCount = unsafe aeroMultitouchStart(onTouchFrame)
}

@MainActor
private func stopTrackpadGestures() {
    deviceWatcher?.invalidate()
    deviceWatcher = nil
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    wakeObserver = nil
    aeroMultitouchStop()
    startedDeviceCount = 0
}
