@testable import AppBundle
import AppKit
import Common
import Testing

/// Open a window the same way a newly detected macOS window is placed
@MainActor
@discardableResult
private func openWindow(_ id: OpaqueWindowId, in workspace: Workspace) -> TestWindow {
    let window = TestWindow.new(id: id, parent: macosPopupWindowsContainer)
    let data = workspace.bindingDataForNewTilingWindowByLayoutMode()
        ?? BindingData(parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    window.floatedByLayoutMode = data.floatedByLayoutMode
    return window
}

@MainActor
@Suite(.serializedGlobally)
struct LayoutModeTest {
    init() {
        setUpWorkspacesForTests()
        config.newWindowPlacement = .grid
    }

    // MARK: - Tiling: grid placement

    @Test func testNewWindowsFormGrid() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer

        openWindow(1, in: workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1)]))
        openWindow(2, in: workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
        openWindow(3, in: workspace)
        assertEquals(root.layoutDescription, .h_tiles([.v_tiles([.window(1), .window(3)]), .window(2)]))
        openWindow(4, in: workspace)
        assertEquals(root.layoutDescription, .h_tiles([.v_tiles([.window(1), .window(3)]), .v_tiles([.window(2), .window(4)])]))
        openWindow(5, in: workspace)
        openWindow(6, in: workspace)
        assertEquals(root.layoutDescription, .h_tiles([
            .v_tiles([.window(1), .window(3)]),
            .v_tiles([.window(2), .window(4)]),
            .v_tiles([.window(5), .window(6)]),
        ]))
        openWindow(7, in: workspace)
        openWindow(8, in: workspace)
        openWindow(9, in: workspace)
        assertEquals(root.layoutDescription, .h_tiles([
            .v_tiles([.window(1), .window(3), .window(7)]),
            .v_tiles([.window(2), .window(4), .window(8)]),
            .v_tiles([.window(5), .window(6), .window(9)]),
        ]))
        openWindow(10, in: workspace)
        assertEquals(root.children.count, 4)
    }

    @Test func testGridWindowsHaveEqualSizes() async throws {
        let workspace = Workspace.get(byName: name)
        let windows = (1 ... 4).map { openWindow(OpaqueWindowId(integerLiteral: UInt64($0)), in: workspace) }
        try await workspace.layoutWorkspace()
        for window in windows {
            assertEquals(window.rectForTest?.width, 960)
            assertEquals(window.rectForTest.map { ($0.height * 2).rounded() }, 1079)
        }
    }

    @Test func testAfterFocusedPlacementKeepsUpstreamBehavior() {
        config.newWindowPlacement = .afterFocused
        let workspace = Workspace.get(byName: name)
        assertNil(workspace.bindingDataForNewTilingWindowByLayoutMode())
    }

    @Test func testGridDoesNotTouchAccordion() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.layout = .accordion
        assertNil(workspace.bindingDataForNewTilingWindowByLayoutMode())
    }

    // MARK: - Scrolling

    @Test func testScrollingColumnsAndScrolling() async throws {
        let workspace = Workspace.get(byName: name)
        await workspace.setLayoutMode(.scrolling)
        let window1 = openWindow(1, in: workspace)
        let window2 = openWindow(2, in: workspace)
        let window3 = openWindow(3, in: workspace)
        // Every window is a column. Default column width is the half of the 1920 points wide monitor
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))

        _ = window3.focusWindow()
        try await workspace.layoutWorkspace()
        assertEquals(workspace.scrollOffset, 960)
        assertEquals(window2.rectForTest?.topLeftX, 0)
        assertEquals(window2.rectForTest?.width, 960)
        assertEquals(window3.rectForTest?.topLeftX, 960)
        assertEquals(window3.rectForTest?.width, 960)
        assertEquals(window1.rectForTest?.topLeftX, 1919) // Parked outside of the visible area

        _ = window1.focusWindow()
        try await workspace.layoutWorkspace()
        assertEquals(workspace.scrollOffset, 0)
        assertEquals(window1.rectForTest?.topLeftX, 0)
        assertEquals(window2.rectForTest?.topLeftX, 960)
        assertEquals(window3.rectForTest?.topLeftX, 1919)
    }

    @Test func testScrollingNewWindowOpensAfterFocusedColumn() async {
        let workspace = Workspace.get(byName: name)
        await workspace.setLayoutMode(.scrolling)
        let window1 = openWindow(1, in: workspace)
        openWindow(2, in: workspace)
        _ = window1.focusWindow()
        openWindow(3, in: workspace)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(3), .window(2)]))
    }

    @Test func testScrollingFillsMonitorWhenStripIsNarrow() async throws {
        let workspace = Workspace.get(byName: name)
        await workspace.setLayoutMode(.scrolling)
        let window1 = openWindow(1, in: workspace)
        try await workspace.layoutWorkspace()
        assertEquals(window1.rectForTest?.topLeftX, 0)
        assertEquals(window1.rectForTest?.width, 1920)
    }

    @Test func testScrollingResizeDoesNotSqueezeOtherColumns() async {
        let workspace = Workspace.get(byName: name)
        await workspace.setLayoutMode(.scrolling)
        let window1 = openWindow(1, in: workspace)
        let window2 = openWindow(2, in: workspace)
        _ = window1.focusWindow()
        await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window1.hWeight, 1060)
        assertEquals(window2.hWeight, 960)
    }

    // MARK: - Switching modes

    @Test func testSwitchBetweenTilingAndScrolling() async {
        let workspace = Workspace.get(byName: name)
        for id in 1 ... 4 { openWindow(OpaqueWindowId(integerLiteral: UInt64(id)), in: workspace) }
        assertEquals(workspace.focusWorkspace(), true)

        await parseCommand("layout-mode scrolling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(workspace.layoutMode, .scrolling)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(3), .window(2), .window(4)]))

        await parseCommand("layout-mode tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(workspace.layoutMode, .tiling)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .v_tiles([.window(1), .window(2)]),
            .v_tiles([.window(3), .window(4)]),
        ]))
    }

    @Test func testFloatingModeAndBack() async {
        let workspace = Workspace.get(byName: name)
        for id in 1 ... 3 { openWindow(OpaqueWindowId(integerLiteral: UInt64(id)), in: workspace) }
        let dialog = TestWindow.new(id: 100, parent: workspace.floatingWindowsContainer) // Was floating before. Must stay floating
        assertEquals(workspace.focusWorkspace(), true)

        await parseCommand("layout-mode floating").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.rootTilingContainer.allLeafWindowsRecursive.count, 0)
        assertEquals(workspace.floatingWindows.count, 4)
        // New windows float as well
        let window4 = openWindow(4, in: workspace)
        assertTrue(window4.isFloating)

        await parseCommand("layout-mode tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.rootTilingContainer.allLeafWindowsRecursive.count, 4)
        assertEquals(workspace.floatingWindows, [dialog])
        assertEquals(workspace.rootTilingContainer.children.count, 2) // 4 windows -> 2x2 grid
    }

    @Test func testScrollingToFloatingBringsParkedWindowsBack() async throws {
        let workspace = Workspace.get(byName: name)
        assertEquals(workspace.focusWorkspace(), true)
        await workspace.setLayoutMode(.scrolling)
        let windows = (1 ... 4).map { openWindow(OpaqueWindowId(integerLiteral: UInt64($0)), in: workspace) }
        _ = windows[0].focusWindow()
        try await workspace.layoutWorkspace()
        assertEquals(windows[3].rectForTest?.topLeftX, 1919) // Parked

        await parseCommand("layout-mode floating").cmdOrDie.run(.defaultEnv, .emptyStdin)
        for window in windows {
            let rect = window.rectForTest.orDie()
            assertTrue(rect.topLeftX >= 0 && rect.topLeftX + rect.width <= 1920)
            assertTrue(rect.topLeftY >= 0 && rect.topLeftY + rect.height <= 1080)
        }
    }

    @Test func testLayoutModeTilingRearrangesIntoGrid() async {
        let workspace = Workspace.get(byName: name)
        assertEquals(workspace.focusWorkspace(), true)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
            TestWindow.new(id: 4, parent: $0)
        }
        await parseCommand("layout-mode tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .v_tiles([.window(1), .window(3)]),
            .v_tiles([.window(2), .window(4)]),
        ]))
    }

    @Test func testLayoutModeCyclesThroughArguments() async {
        let workspace = Workspace.get(byName: name)
        assertEquals(workspace.focusWorkspace(), true)
        let cycle = parseCommand("layout-mode tiling scrolling floating").cmdOrDie
        await cycle.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.layoutMode, .scrolling)
        await cycle.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.layoutMode, .floating)
        await cycle.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.layoutMode, .tiling)
    }

    @Test func testLayoutModeAll() async {
        let workspaceA = Workspace.get(byName: name + "A")
        assertEquals(workspaceA.focusWorkspace(), true)
        await parseCommand("layout-mode --all scrolling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(workspaceA.layoutMode, .scrolling)
        // Workspaces that are created later use the same mode
        assertEquals(Workspace.get(byName: name + "B").layoutMode, .scrolling)
    }

    @Test func testParseLayoutModeCommand() {
        testParseCommandFail("layout-mode", msg: "ERROR: Argument '\(WorkspaceLayoutMode.unionLiteral)' is mandatory", exitCode: 2)
        testParseCommandFail(
            "layout-mode foo",
            msg: "ERROR: Can't parse 'foo'\n       Possible values: \(WorkspaceLayoutMode.unionLiteral)",
            exitCode: 2,
        )
    }

    // MARK: - Config

    @Test func testParseForkConfigOptions() {
        let result = parseConfig(
            """
            config-version = 2
            default-layout-mode = 'scrolling'
            new-window-placement = 'after-focused'
            scrolling.column-width-percent = 40

            [gestures]
            three-finger-swipe-left = ''
            four-finger-swipe-up = 'fullscreen'

            [mode.main.binding]
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.config.defaultLayoutMode, .scrolling)
        assertEquals(result.config.newWindowPlacement, .afterFocused)
        assertEquals(result.config.scrolling.columnWidthPercent, 40)
        // Unbound explicitly
        assertNil(result.config.gestures[TrackpadGesture(fingers: 3, direction: .left)])
        // Default binding
        assertTrue(result.config.gestures[TrackpadGesture(fingers: 3, direction: .right)] != nil)
        // Custom binding
        assertTrue(result.config.gestures[TrackpadGesture(fingers: 4, direction: .up)] != nil)
    }

    @Test func testGesturesAreBoundByDefault() {
        let result = parseConfig("")
        assertEquals(Set(result.config.gestures.keys.map(\.description)), ["three-finger-swipe-left", "three-finger-swipe-right"])
        assertEquals(result.config.defaultLayoutMode, .tiling)
        assertEquals(result.config.newWindowPlacement, .grid)
    }

    @Test func testForkConfigErrors() {
        let result = parseConfig(
            """
            config-version = 2
            default-layout-mode = 'foo'
            scrolling.column-width-percent = 500

            [gestures]
            two-finger-swipe-left = 'workspace next'

            [mode.main.binding]
            """,
        )
        assertEquals(result.strErrors, [
            "[ERROR] default-layout-mode: Can't parse layout mode 'foo'. Possible values: tiling, scrolling, floating",
            "[ERROR] scrolling.column-width-percent: column-width-percent must be in [10, 100] range",
            "[ERROR] gestures.two-finger-swipe-left: Unknown gesture 'two-finger-swipe-left'. Possible values: \(TrackpadGesture.allKeys.joined(separator: ", "))",
        ])
    }
}
