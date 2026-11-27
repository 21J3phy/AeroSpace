public struct LayoutModeCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .layoutMode,
        help: layout_mode_help_generated,
        flags: [
            "--workspace": workspaceSubArgParser(),
            "--all": trueBoolFlag(\.all),
            "--fail-if-noop": trueBoolFlag(\.failIfNoop),
        ],
        posArgs: [newMandatoryPosArgParser(\.cycleBetween, parseCycleBetween, placeholder: WorkspaceLayoutMode.unionLiteral)],
        conflictingFlags: [
            ["--all", "--workspace"],
        ],
    )

    public var cycleBetween: Lateinit<[WorkspaceLayoutMode]> = .uninitialized
    public var all: Bool = false
    public var failIfNoop: Bool = false

    public init(rawArgs: [String], cycleBetween: [WorkspaceLayoutMode]) {
        self.commonState = .init(rawArgs.slice)
        self.cycleBetween = .initialized(cycleBetween)
    }
}

extension WorkspaceLayoutMode {
    public static var unionLiteral: String { "(" + allCases.map(\.rawValue).joined(separator: "|") + ")..." }
}

private func parseCycleBetween(input: PosArgParserInput) -> ParsedCliArgs<[WorkspaceLayoutMode]> {
    let args = input.nonFlagArgs()
    var result: [WorkspaceLayoutMode] = []
    for (i, arg) in args.enumerated() {
        guard let mode = WorkspaceLayoutMode(rawValue: arg) else {
            return .fail("Can't parse '\(arg)'\nPossible values: \(WorkspaceLayoutMode.unionLiteral)", advanceBy: i + 1)
        }
        result.append(mode)
    }
    return .succ(result, advanceBy: args.count)
}

func parseLayoutModeCmdArgs(_ args: StrArrSlice) -> ParsedCmd<LayoutModeCmdArgs> {
    parseSpecificCmdArgs(LayoutModeCmdArgs(rawArgs: args), args)
        .filter("--fail-if-noop allows only one <layout-mode> argument") { $0.failIfNoop.implies($0.cycleBetween.val.count == 1) }
}
