import AppKit
import Common

// Fork addition. `workspace --animate`: slide the old workspace out and the new one in, like macOS Spaces do.
//
// There is no way to move windows of other apps in one transaction on macOS without disabling SIP,
// so the animation moves every window with the Accessibility API on every frame. Slow apps drop frames

@MainActor
final class WorkspaceSlide {
    let outgoingWorkspace: Workspace
    let incomingWorkspace: Workspace
    /// Signed width of the monitor. Positive: the incoming workspace arrives from the right
    let distance: CGFloat
    /// Eased progress of the animation in [0, 1]
    var progress: CGFloat = 0
    var outgoing: [(window: Window, origin: Point)] = []
    var incoming: [(window: Window, origin: Point)] = []

    init(outgoingWorkspace: Workspace, incomingWorkspace: Workspace, distance: CGFloat) {
        self.outgoingWorkspace = outgoingWorkspace
        self.incomingWorkspace = incomingWorkspace
        self.distance = distance
    }

    var incomingOffset: CGFloat { distance * (1 - progress) }
    var outgoingOffset: CGFloat { -distance * progress }

    func applyFrame() {
        for (window, origin) in outgoing where window.isBound {
            window.setAxFrame(origin.addingXOffset(outgoingOffset), nil)
        }
        for (window, origin) in incoming where window.isBound {
            window.setAxFrame(origin.addingXOffset(incomingOffset), nil)
        }
    }
}

/// The slide that is being animated right now. Layout code consults it to not fight with the animation:
/// - the incoming workspace is laid out shifted by ``WorkspaceSlide/incomingOffset``
/// - windows of the outgoing workspace are not hidden until the animation ends
@MainActor private(set) var activeWorkspaceSlide: WorkspaceSlide? = nil
@MainActor private var slideGeneration = 0

/// Jump to the end of the running animation. Used when the next animation starts before the previous one ended
@MainActor
func finishWorkspaceSlideImmediately() {
    guard let slide = activeWorkspaceSlide else { return }
    slide.progress = 1
    slide.applyFrame()
    activeWorkspaceSlide = nil
    slideGeneration += 1
}

/// Must be called after the focus has been moved to `incomingWorkspace` in the model, but before the layout is applied.
/// The regular layout pass that follows puts everything to the final positions
@MainActor
func slideWorkspaces(from outgoingWorkspace: Workspace, to incomingWorkspace: Workspace, incomingFromRight: Bool) async {
    let duration = Double(config.workspaceAnimationDurationMs) / 1000
    if duration <= 0 || isUnitTest || outgoingWorkspace == incomingWorkspace { return }
    // With several monitors a sliding window would travel across the neighbour monitor
    if globalUnsortedMonitorInfos.count != 1 { return }
    let monitor = incomingWorkspace.workspaceMonitorInfo
    if outgoingWorkspace.workspaceMonitorInfo.rect.topLeftCorner != monitor.rect.topLeftCorner { return }

    finishWorkspaceSlideImmediately()
    slideGeneration += 1
    let generation = slideGeneration
    let slide = WorkspaceSlide(
        outgoingWorkspace: outgoingWorkspace,
        incomingWorkspace: incomingWorkspace,
        distance: (incomingFromRight ? 1 : -1) * monitor.rect.width,
    )
    activeWorkspaceSlide = slide
    defer {
        if generation == slideGeneration { activeWorkspaceSlide = nil }
    }

    // Outgoing windows: everything that is on the screen right now
    let outgoingWindows = outgoingWorkspace.rootTilingContainer.allLeafWindowsRecursive + outgoingWorkspace.floatingWindows
    let outgoingRects = (try? await outgoingWindows.mapConcurrentlyOnMain(.cancellable) { try await $0.getAxRect(.cancellable) })
        ?? Array(repeating: nil, count: outgoingWindows.count)
    if generation != slideGeneration { return }
    for (window, rect) in zip(outgoingWindows, outgoingRects) {
        guard let rect, window.isBound else { continue }
        // Skip windows that are parked outside of the visible area (hidden columns of the scrolling layout mode)
        let isOnScreen = rect.minX < monitor.rect.maxX - 2 && rect.maxX > monitor.rect.minX + 2 && rect.minY < monitor.rect.maxY - 2
        if !isOnScreen { continue }
        // The window is going to be hidden far away from its real place. Remember the real place now
        (window as? MacWindow)?.rememberPositionBeforeHiding(rect)
        slide.outgoing.append((window, rect.topLeftCorner))
    }

    // Incoming floating windows are hidden in the corner of the monitor. Find out where they belong
    for window in incomingWorkspace.floatingWindows {
        if let origin = (window as? MacWindow)?.takeUnhiddenFloatingPosition() {
            slide.incoming.append((window, origin))
        }
    }
    // Incoming tiling windows: the layout pass gives them the right size and puts them next to the monitor
    _ = try? await incomingWorkspace.layoutWorkspace()
    if generation != slideGeneration { return }
    for window in incomingWorkspace.rootTilingContainer.allLeafWindowsRecursive {
        if let rect = window.lastAppliedLayoutPhysicalRect {
            slide.incoming.append((window, rect.topLeftCorner.addingXOffset(-slide.incomingOffset)))
        } else if window.isFullscreen {
            let rect = window.noOuterGapsInFullscreen ? monitor.visibleRect : monitor.visibleRectPaddedByOuterGaps
            slide.incoming.append((window, rect.topLeftCorner))
        }
    }

    let clock = ContinuousClock()
    let start = clock.now
    while generation == slideGeneration {
        let elapsed = start.duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let t = min(1, seconds / duration)
        slide.progress = 1 - pow(1 - t, 3) // ease out
        slide.applyFrame()
        if t >= 1 { break }
        try? await Task.sleep(for: .milliseconds(8))
    }
}
