import AppKit
import Common

// Fork addition. Workspace layout modes: tiling (grid), scrolling, floating

/// Modes explicitly chosen at runtime (layout-mode command, menu bar). They survive workspace garbage collection
@MainActor var workspaceLayoutModeOverrides: [String: WorkspaceLayoutMode] = [:]
/// Set by `layout-mode --all`. Takes priority over `default-layout-mode` config option until AeroSpace is restarted
@MainActor var runtimeDefaultLayoutMode: WorkspaceLayoutMode? = nil

@MainActor var effectiveDefaultLayoutMode: WorkspaceLayoutMode { runtimeDefaultLayoutMode ?? config.defaultLayoutMode }

/// Bring workspaces that don't have an explicit mode in sync with the default mode
@MainActor
func syncLayoutModesWithConfig() async {
    let defaultMode = effectiveDefaultLayoutMode
    for workspace in Workspace.all where workspaceLayoutModeOverrides[workspace.name] == nil {
        await workspace.setLayoutMode(defaultMode)
    }
}

/// Number of grid cells along the main axis for the given number of windows.
/// 1 -> 1, 2...4 -> 2, 5...9 -> 3, 10...16 -> 4
func gridColumnCount(forWindowCount count: Int) -> Int {
    var columns = 1
    while columns * columns < count { columns += 1 }
    return columns
}

let minScrollingColumnWidth: CGFloat = 100

@MainActor
func clampScrollingColumnWidth(_ width: CGFloat, _ strip: TilingContainer) -> CGFloat {
    let viewportWidth = strip.nodeWorkspace?.workspaceMonitorInfo.visibleRectPaddedByOuterGaps.width ?? width
    return width.coerce(in: minScrollingColumnWidth ... max(minScrollingColumnWidth, viewportWidth))
}

extension TilingContainer {
    /// The container is the root of a workspace in the scrolling layout mode. Its children are independent columns
    var isScrollingStrip: Bool { (parent as? Workspace)?.layoutMode == .scrolling }
}

extension Workspace {
    @MainActor
    var defaultScrollingColumnWidth: CGFloat {
        let viewportWidth = workspaceMonitorInfo.visibleRectPaddedByOuterGaps.width
        return max(minScrollingColumnWidth, viewportWidth * CGFloat(config.scrolling.columnWidthPercent) / 100)
    }

    /// Where a new (or re-tiled) window goes, according to the layout mode of the workspace.
    /// The window itself must not be a part of the workspace tiling tree at this point.
    ///
    /// `nil` means "use the upstream placement" (next to the most recently focused window)
    @MainActor
    func bindingDataForNewTilingWindowByLayoutMode() -> BindingData? {
        switch layoutMode {
            case .floating:
                BindingData(parent: floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST, floatedByLayoutMode: true)
            case .scrolling:
                scrollingBindingDataForNewWindow()
            case .tiling:
                switch config.newWindowPlacement {
                    case .grid: gridBindingDataForNewWindow()
                    case .afterFocused: nil
                }
        }
    }

    /// Scrolling mode: every new window is a new column right after the focused column
    @MainActor
    private func scrollingBindingDataForNewWindow() -> BindingData {
        let root = rootTilingContainer
        let index = (root.mostRecentInhabitedChild ?? root.mostRecentChild)?.ownIndex(in: .all).map { $0 + 1 } ?? INDEX_BIND_LAST
        return BindingData(parent: root, adaptiveWeight: defaultScrollingColumnWidth, index: index)
    }

    /// Tiling mode: keep the workspace looking like a grid instead of an ever-growing row of thin windows.
    ///
    /// The grid is still a regular AeroSpace tree (root container with nested containers of the opposite
    /// orientation), so focus, move, resize and join-with keep working as usual
    @MainActor
    private func gridBindingDataForNewWindow() -> BindingData? {
        let root = rootTilingContainer
        if root.layout != .tiles { return nil } // The user asked for accordion. Don't interfere
        let cells = root.inhabitedChildren
        let windowCount = root.allInhabitedLeafWindowsRecursive.count + 1
        if cells.count < gridColumnCount(forWindowCount: windowCount) {
            return BindingData(parent: root, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
        // Stack into the cell that has the fewest windows. `min` returns the first one among equals
        guard let target = cells.min(by: { $0.allInhabitedLeafWindowsRecursive.count < $1.allInhabitedLeafWindowsRecursive.count }) else {
            return nil
        }
        switch target.tilingTreeNodeCasesOrDie() {
            case .window(let window):
                let prevBinding = window.unbindFromParent()
                let cell = TilingContainer(
                    parent: root,
                    adaptiveWeight: prevBinding.adaptiveWeight,
                    root.orientation.opposite,
                    .tiles,
                    index: prevBinding.index,
                )
                window.bind(to: cell, adaptiveWeight: WEIGHT_AUTO, index: 0)
                return BindingData(parent: cell, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            case .tilingContainer(let cell):
                return switch cell.lifeStatus {
                    case .alive: BindingData(parent: cell, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                    case .mustBeFlattened, .deadOrInvisible: nil
                }
        }
    }

    /// Switch the layout mode and rearrange windows of the workspace accordingly
    @MainActor
    func setLayoutMode(_ newMode: WorkspaceLayoutMode) async {
        let oldMode = layoutMode
        if oldMode == newMode { return }
        layoutMode = newMode
        scrollOffset = 0
        switch (oldMode, newMode) {
            case (.floating, _): await tileWindowsFloatedByLayoutMode()
            case (_, .floating): floatAllTilingWindows()
            case (.tiling, .scrolling): turnEveryWindowIntoScrollingColumn()
            case (.scrolling, .tiling): rearrangeTilingWindowsIntoGrid()
            case (.tiling, .tiling), (.scrolling, .scrolling): break
        }
    }

    @MainActor
    private func floatAllTilingWindows() {
        let monitorRect = workspaceMonitorInfo.visibleRect
        let isVisible = isVisible
        var cascadeIndex = 0
        for window in rootTilingContainer.allLeafWindowsRecursive {
            let tiledRect = window.lastAppliedLayoutPhysicalRect
            window.bindAsFloatingWindow(to: self)
            window.floatedByLayoutMode = true
            window.isFullscreen = false
            let size = window.lastFloatingSize
            if !isVisible {
                // Windows of invisible workspaces are hidden. They are put back on the screen when the workspace is focused
                if let size { window.setAxFrame(nil, size) }
                continue
            }
            // Give the window its own size back, and keep it where it was
            let width = size?.width ?? tiledRect?.width ?? monitorRect.width / 2
            let height = size?.height ?? tiledRect?.height ?? monitorRect.height / 2
            var origin: Point
            if let tiledRect {
                origin = tiledRect.topLeftCorner
            } else {
                // Scrolling layout mode parks columns that don't fit outside of the visible area. Bring the window back
                let cascadeOffset = CGFloat(cascadeIndex % 8) * 32
                cascadeIndex += 1
                origin = Point(
                    x: monitorRect.minX + (monitorRect.width - width) / 2 + cascadeOffset,
                    y: monitorRect.minY + (monitorRect.height - height) / 2 + cascadeOffset,
                )
            }
            origin.x = origin.x.coerce(in: monitorRect.minX ... max(monitorRect.minX, monitorRect.maxX - width))
            origin.y = origin.y.coerce(in: monitorRect.minY ... max(monitorRect.minY, monitorRect.maxY - height))
            window.setAxFrame(origin, size)
        }
    }

    @MainActor
    private func tileWindowsFloatedByLayoutMode() async {
        for window in floatingWindows where window.floatedByLayoutMode {
            window.lastFloatingSize = (try? await window.getAxSize(.nonCancellable)) ?? window.lastFloatingSize
            if !window.isBound || window.nodeWorkspace != self { continue } // The window is gone during the suspension point
            window.floatedByLayoutMode = false
            window.unbindFromParent()
            let data = bindingDataForNewTilingWindowByLayoutMode()
                ?? BindingData(parent: rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
            window.floatedByLayoutMode = data.floatedByLayoutMode
        }
    }

    /// Flatten the tiling tree. Every window becomes its own column of the default width
    @MainActor
    private func turnEveryWindowIntoScrollingColumn() {
        let root = rootTilingContainer
        let mostRecentWindow = root.mostRecentWindowRecursive
        let width = defaultScrollingColumnWidth
        for window in root.allLeafWindowsRecursive {
            window.bind(to: root, adaptiveWeight: width, index: INDEX_BIND_LAST)
        }
        root.unbindWindowlessContainers()
        root.layout = .tiles
        root.changeOrientation(.h)
        mostRecentWindow?.markAsMostRecentChild()
    }

    /// Rebuild the tiling tree as a grid. Windows keep their order (left to right, then top to bottom)
    @MainActor
    func rearrangeTilingWindowsIntoGrid() {
        let root = rootTilingContainer
        let mostRecentWindow = root.mostRecentWindowRecursive
        for window in root.allLeafWindowsRecursive {
            window.bind(to: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        }
        root.unbindWindowlessContainers()
        root.layout = .tiles
        let windows = root.children.filterIsInstance(of: Window.self).filter { $0.lifeStatus.isInhabited }
        let columnCount = gridColumnCount(forWindowCount: windows.count)
        var cells: [[Window]] = Array(repeating: [], count: columnCount)
        for (index, window) in windows.enumerated() {
            cells[index % columnCount].append(window)
        }
        for cell in cells where cell.count > 1 {
            guard let index = cell.first?.ownIndex(in: .all) else { continue }
            let container = TilingContainer(parent: root, adaptiveWeight: 1, root.orientation.opposite, .tiles, index: index)
            for window in cell {
                window.bind(to: container, adaptiveWeight: 1, index: INDEX_BIND_LAST)
            }
        }
        mostRecentWindow?.markAsMostRecentChild()
    }
}

extension TilingContainer {
    @MainActor
    fileprivate func unbindWindowlessContainers() {
        for child in children {
            if let container = child as? TilingContainer, container.isEffectivelyEmpty {
                container.unbindFromParent()
            }
        }
    }
}
