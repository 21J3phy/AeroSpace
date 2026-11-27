import AppKit
import Common

/// Fork addition
struct LayoutModeCommand: Command {
    let args: LayoutModeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let workspace = target.workspace
        let modes = args.cycleBetween.val
        let currentMode = workspace.layoutMode
        // Cycle: switch to the mode that follows the current one in the list
        let targetMode = modes.firstIndex(of: currentMode).map { modes[($0 + 1) % modes.count] } ?? modes.first.orDie()

        if args.all {
            runtimeDefaultLayoutMode = targetMode
            for workspace in Workspace.all {
                workspaceLayoutModeOverrides[workspace.name] = targetMode
                await workspace.setLayoutMode(targetMode)
            }
            return .succ
        }
        if targetMode == currentMode && targetMode == .tiling && !args.failIfNoop {
            // Asking for tiling when it's already tiling is a way to say "tidy the windows up into a grid again"
            if config.newWindowPlacement == .grid { workspace.rearrangeTilingWindowsIntoGrid() }
            return .succ
        }
        if targetMode == currentMode {
            return switch args.failIfNoop {
                case true: .fail
                case false:
                    .succ(io.err("Workspace '\(workspace.name)' is already in the \(targetMode.rawValue) layout mode. " +
                            "Tip: use --fail-if-noop to exit with non-zero exit code"))
            }
        }
        workspaceLayoutModeOverrides[workspace.name] = targetMode
        await workspace.setLayoutMode(targetMode)
        return .succ
    }
}
