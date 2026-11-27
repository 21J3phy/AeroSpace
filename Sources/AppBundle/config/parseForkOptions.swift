import Common

// Fork additions to the config: gestures, layout modes, grid placement of new windows

enum NewWindowPlacement: String, CaseIterable, Sendable {
    /// Keep the workspace looking like a grid: add a column while there are fewer columns than rows, otherwise stack
    /// the window into the column that has the fewest windows
    case grid
    /// Upstream AeroSpace behavior. The new window is placed next to the focused window in its container
    case afterFocused = "after-focused"
}

struct ScrollingConfig: Withable, Equatable, Sendable {
    /// Default width of a new column in percents of the monitor width
    var columnWidthPercent: Int = 50
}

private let scrollingParser: [String: any ParserProtocol<ScrollingConfig>] = [
    "column-width-percent": Parser(\.columnWidthPercent, parseColumnWidthPercent),
]

private func parseColumnWidthPercent(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Int> {
    parseInt(raw, backtrace)
        .filter(.init(backtrace, "column-width-percent must be in [10, 100] range")) { (10 ... 100).contains($0) }
}

func parseWorkspaceAnimationDurationMs(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Int> {
    parseInt(raw, backtrace)
        .filter(.init(backtrace, "workspace-animation-duration-ms must be in [0, 2000] range")) { (0 ... 2000).contains($0) }
}

func parseScrollingConfig(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> ScrollingConfig {
    parseNonEmptyTable(raw, ScrollingConfig(), scrollingParser, backtrace, &c)
}

func parseWorkspaceLayoutMode(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<WorkspaceLayoutMode> {
    parseString(raw, backtrace).flatMap {
        WorkspaceLayoutMode(rawValue: $0).toResult(.init(
            backtrace,
            "Can't parse layout mode '\($0)'. Possible values: \(WorkspaceLayoutMode.allCases.map(\.rawValue).joined(separator: ", "))",
        ))
    }
}

func parseNewWindowPlacement(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<NewWindowPlacement> {
    parseString(raw, backtrace).flatMap {
        NewWindowPlacement(rawValue: $0).toResult(.init(
            backtrace,
            "Can't parse '\($0)'. Possible values: \(NewWindowPlacement.allCases.map(\.rawValue).joined(separator: ", "))",
        ))
    }
}

/// Gestures that work even when the config doesn't mention [gestures] at all
private let defaultGestureBindings: [String: String] = [
    "three-finger-swipe-left": "workspace --animate next",
    "three-finger-swipe-right": "workspace --animate prev",
]

/// [gestures] table. Keys look like 'three-finger-swipe-left', values are commands (the same as key bindings).
/// The table is merged on top of the default bindings. Empty string or empty array unbinds the gesture
func parseGestures(_ raw: OrderedJson?, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [TrackpadGesture: Shell<any Command>] {
    var result: [TrackpadGesture: Shell<any Command>] = [:]
    for (key, command) in defaultGestureBindings {
        if let gesture = TrackpadGesture.parse(key), let shell = try? parseCommand(command, allowExecAndForget: true, allowEval: false).toResult().get() {
            result[gesture] = shell
        }
    }
    guard let raw else { return result }
    guard let rawTable = raw.asDictOrNil else {
        c.errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return result
    }
    for (key, rawCommand): (String, OrderedJson) in rawTable {
        let backtrace = backtrace + .key(key)
        guard let gesture = TrackpadGesture.parse(key) else {
            c.errors += [.init(backtrace, "Unknown gesture '\(key)'. Possible values: \(TrackpadGesture.allKeys.joined(separator: ", "))")]
            continue
        }
        let isUnbind = rawCommand.asStringOrNil?.trim().isEmpty == true || rawCommand.asArrayOrNil?.isEmpty == true
        if isUnbind {
            result.removeValue(forKey: gesture)
        } else {
            result[gesture] = parseShellOfCommandsForConfig(rawCommand, backtrace, &c)
        }
    }
    return result
}
