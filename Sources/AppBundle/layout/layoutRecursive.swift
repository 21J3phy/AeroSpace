import AppKit
import Common

extension Workspace {
    @MainActor
    func layoutWorkspace() async throws { // todo revisit API
        if isEffectivelyEmpty { return }
        let rect = workspaceMonitorInfo.visibleRectPaddedByOuterGaps
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        // Fork addition: while the workspace slides in, it's laid out next to its final place
        let slideOffset = activeWorkspaceSlide.flatMap { $0.incomingWorkspace == self ? $0.incomingOffset : nil } ?? 0
        let context = LayoutContext(self, slideOffset: slideOffset)
        try await layoutRecursive(rect.topLeftCorner.addingXOffset(slideOffset), width: rect.width, height: rect.height - 1, virtual: rect, context)
    }
}

extension TreeNode {
    @MainActor
    fileprivate func layoutRecursive(_ point: Point, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch nodeCases {
            case .monitor(let it):
                try await it.getWorkspacesContainerOrCreate().getVisibleWorkspaceOrCreate(parent: it)
                    .layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            case .workspacesContainer: die()
            case .workspace(let workspace):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                switch workspace.layoutMode {
                    case .scrolling: // Fork addition
                        try await workspace.rootTilingContainer.layoutScrolling(point, width: width, height: height, virtual: virtual, context)
                    case .tiling, .floating:
                        try await workspace.rootTilingContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
                }
                try await workspace.floatingWindowsContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            case .floatingWindowsContainer(let container):
                let windows = container.children.filterIsInstance(of: Window.self)
                // todo make it parallel among different workspaces. Get rid of 'try await'
                let cm = CancellationMode.cancellable
                let rects = try await windows.mapConcurrentlyOnMain(cm) { try await $0.getAxRect(cm) } // Probably not idempotent
                for (window, windowRect) in zip(windows, rects) {
                    window.lastAppliedLayoutPhysicalRect = nil
                    window.lastAppliedLayoutVirtualRect = nil
                    window.layoutFloatingWindow(context, windowRect)
                }
            case .window(let window):
                if window.windowId != currentlyManipulatedWithMouseWindowId {
                    lastAppliedLayoutVirtualRect = virtual
                    if window.isFullscreen && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                        lastAppliedLayoutPhysicalRect = nil
                        window.layoutFullscreen(context)
                    } else {
                        lastAppliedLayoutPhysicalRect = physicalRect
                        window.isFullscreen = false
                        window.setAxFrame(point, CGSize(width: width, height: height))
                    }
                }
            case .tilingContainer(let container):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                switch container.layout {
                    case .tiles:
                        try await container.layoutTiles(point, width: width, height: height, virtual: virtual, context)
                    case .accordion:
                        try await container.layoutAccordion(point, width: width, height: height, virtual: virtual, context)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                return // Nothing to do for weirdos
        }
    }
}

extension TreeNode {
    /// Fork addition. See ``TilingContainer/layoutScrolling(_:width:height:virtual:_:)``
    @MainActor
    fileprivate func parkOutsideOfVisibleAreaRecursive(_ context: LayoutContext, windowWidth: CGFloat) {
        lastAppliedLayoutPhysicalRect = nil
        lastAppliedLayoutVirtualRect = nil
        if let window = self as? Window {
            if window.windowId == currentlyManipulatedWithMouseWindowId { return }
            let monitorRect = context.workspace.workspaceMonitorInfo.visibleRect
            // The same trick that is used for windows of inactive workspaces: keep one pixel of the window on the screen
            let parkingPoint = switch context.hideCorner {
                case .bottomLeftCorner: monitorRect.bottomLeftCorner + Point(x: 1 - windowWidth, y: -1)
                case .bottomRightCorner: monitorRect.bottomRightCorner - Point(x: 1, y: 1)
            }
            window.setAxFrame(parkingPoint, nil)
        } else {
            for child in children {
                child.parkOutsideOfVisibleAreaRecursive(context, windowWidth: windowWidth)
            }
        }
    }
}

private struct LayoutContext {
    let workspace: Workspace
    let resolvedGaps: ResolvedGaps
    /// Fork addition
    @MainActor var hideCorner: OptimalHideCorner {
        optimalHideCorner(for: workspace.workspaceMonitorInfo, among: globalUnsortedMonitorInfos)
    }

    /// Fork addition. See ``WorkspaceSlide``
    let slideOffset: CGFloat

    @MainActor
    init(_ workspace: Workspace, slideOffset: CGFloat) {
        self.workspace = workspace
        self.slideOffset = slideOffset
        self.resolvedGaps = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitorInfo)
    }
}

extension Window {
    @MainActor
    fileprivate func layoutFloatingWindow(_ context: LayoutContext, _ windowRect: Rect?) {
        let workspace = context.workspace
        let currentMonitor = windowRect?.center.monitorApproximation
        if let currentMonitor, let windowRect, workspace != currentMonitor.visibleWorkspace {
            let windowTopLeftCorner = windowRect.topLeftCorner
            let xProportion = (windowTopLeftCorner.x - currentMonitor.visibleRect.topLeftX) / currentMonitor.visibleRect.width
            let yProportion = (windowTopLeftCorner.y - currentMonitor.visibleRect.topLeftY) / currentMonitor.visibleRect.height

            let workspaceRect = workspace.workspaceMonitorInfo.visibleRect
            var newX = workspaceRect.topLeftX + xProportion * workspaceRect.width
            var newY = workspaceRect.topLeftY + yProportion * workspaceRect.height

            let windowWidth = windowRect.width
            let windowHeight = windowRect.height
            newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
            newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

            setAxFrame(Point(x: newX, y: newY), nil)
        }
        if isFullscreen {
            layoutFullscreen(context)
            isFullscreen = false
        }
    }

    @MainActor
    fileprivate func layoutFullscreen(_ context: LayoutContext) {
        let monitorRect = noOuterGapsInFullscreen
            ? context.workspace.workspaceMonitorInfo.visibleRect
            : context.workspace.workspaceMonitorInfo.visibleRectPaddedByOuterGaps
        setAxFrame(monitorRect.topLeftCorner.addingXOffset(context.slideOffset), CGSize(width: monitorRect.width, height: monitorRect.height))
    }
}

extension TilingContainer {
    @MainActor
    fileprivate func layoutTiles(_ point: Point, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        var point = point
        var virtualPoint = virtual.topLeftCorner

        let inhabitedChildren = inhabitedChildren

        guard let delta = ((orientation == .h ? width : height) - CGFloat(inhabitedChildren.sumOfDouble { $0.getWeight(orientation) }))
            .div(inhabitedChildren.count) else { return }

        let lastIndex = inhabitedChildren.indices.last
        for (i, child) in inhabitedChildren.enumerated() {
            child.setWeight(orientation, child.getWeight(orientation) + delta)
            let rawGap = context.resolvedGaps.inner.get(orientation).toDouble()
            // Gaps. Consider 4 cases:
            // 1. Multiple children. Layout first child
            // 2. Multiple children. Layout last child
            // 3. Multiple children. Layout child in the middle
            // 4. Single child   let rawGap = gaps.inner.get(orientation).toDouble()
            let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
            try await child.layoutRecursive(
                i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
                width: orientation == .h ? child.hWeight - gap : width,
                height: orientation == .v ? child.vWeight - gap : height,
                virtual: Rect(
                    topLeftX: virtualPoint.x,
                    topLeftY: virtualPoint.y,
                    width: orientation == .h ? child.hWeight : width,
                    height: orientation == .v ? child.vWeight : height,
                ),
                context,
            )
            virtualPoint = orientation == .h ? virtualPoint.addingXOffset(child.hWeight) : virtualPoint.addingYOffset(child.vWeight)
            point = orientation == .h ? point.addingXOffset(child.hWeight) : point.addingYOffset(child.vWeight)
        }
    }

    /// Fork addition. Scrolling layout mode (niri/PaperWM-like).
    ///
    /// Children of the root container are columns of a horizontal strip. Weight of a column is its width in points.
    /// The strip can be wider than the monitor. It's scrolled just enough to keep the most recent column fully visible.
    /// Columns that don't fit are parked outside of the visible area the same way windows of inactive workspaces are
    @MainActor
    fileprivate func layoutScrolling(_ point: Point, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        lastAppliedLayoutPhysicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        lastAppliedLayoutVirtualRect = virtual
        if layout != .tiles { layout = .tiles }
        changeOrientation(.h)

        let columns = inhabitedChildren
        if columns.isEmpty { return }
        var widths: [CGFloat] = []
        for column in columns {
            let columnWidth = column.getWeight(.h).coerce(in: minScrollingColumnWidth ... max(minScrollingColumnWidth, width))
            column.setWeight(.h, columnWidth)
            widths.append(columnWidth)
        }
        // Don't waste the monitor space when the strip is narrower than the monitor
        let stripWidth = widths.reduce(0, +)
        if stripWidth < width {
            widths = widths.map { $0 * width / stripWidth }
        }
        var offsets: [CGFloat] = [] // Left edge of every column relative to the left edge of the strip
        var nextOffset: CGFloat = 0
        for columnWidth in widths {
            offsets.append(nextOffset)
            nextOffset += columnWidth
        }

        let focusedIndex = mostRecentInhabitedChild.flatMap { columns.firstIndex(of: $0) } ?? 0
        var scrollOffset = context.workspace.scrollOffset
        if offsets[focusedIndex] < scrollOffset {
            scrollOffset = offsets[focusedIndex]
        }
        if offsets[focusedIndex] + widths[focusedIndex] > scrollOffset + width {
            scrollOffset = offsets[focusedIndex] + widths[focusedIndex] - width
        }
        scrollOffset = scrollOffset.coerce(in: 0 ... max(0, max(stripWidth, width) - width))
        context.workspace.scrollOffset = scrollOffset

        // A partially visible column sticks out of the monitor. That's fine unless there is another monitor to show it
        let canShowPartiallyVisibleColumns = globalUnsortedMonitorInfos.count == 1
        let rawGap = context.resolvedGaps.inner.horizontal.toDouble()
        let lastIndex = columns.indices.last
        for (i, column) in columns.enumerated() {
            let left = offsets[i] - scrollOffset
            let right = left + widths[i]
            let isFullyVisible = left >= -1 && right <= width + 1
            let isPartiallyVisible = right > 1 && left < width - 1
            if isFullyVisible || (isPartiallyVisible && canShowPartiallyVisibleColumns) {
                let leftGap = i == 0 ? 0 : rawGap / 2
                let rightGap = i == lastIndex ? 0 : rawGap / 2
                try await column.layoutRecursive(
                    Point(x: point.x + left + leftGap, y: point.y),
                    width: widths[i] - leftGap - rightGap,
                    height: height,
                    virtual: Rect(topLeftX: virtual.topLeftX + left, topLeftY: virtual.topLeftY, width: widths[i], height: height),
                    context,
                )
            } else {
                column.parkOutsideOfVisibleAreaRecursive(context, windowWidth: widths[i])
            }
        }
    }

    @MainActor
    fileprivate func layoutAccordion(_ point: Point, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let inhabitedChildren = inhabitedChildren

        guard let mruIndex: Int = mostRecentInhabitedChild?.ownIndex(in: .inhabitedOnly) else { return }
        for (index, child) in inhabitedChildren.enumerated() {
            let padding = CGFloat(config.accordionPadding)
            let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
                case 0 where inhabitedChildren.count == 1: (0, 0)
                case 0:                                    (0, padding)
                case inhabitedChildren.indices.last:       (padding, 0)
                case mruIndex - 1:                         (0, 2 * padding)
                case mruIndex + 1:                         (2 * padding, 0)
                default:                                   (padding, padding)
            }
            switch orientation {
                case .h:
                    try await child.layoutRecursive(
                        point + Point(x: lPadding, y: 0),
                        width: width - rPadding - lPadding,
                        height: height,
                        virtual: virtual,
                        context,
                    )
                case .v:
                    try await child.layoutRecursive(
                        point + Point(x: 0, y: lPadding),
                        width: width,
                        height: height - lPadding - rPadding,
                        virtual: virtual,
                        context,
                    )
            }
        }
    }
}
