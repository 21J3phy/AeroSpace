/// Fork addition. How a whole workspace arranges its windows
public enum WorkspaceLayoutMode: String, CaseIterable, Equatable, Sendable {
    /// i3-like tiling tree. New windows are placed in a grid
    case tiling
    /// niri/PaperWM-like horizontal strip of columns. The strip scrolls to keep the focused column in view
    case scrolling
    /// AeroSpace doesn't arrange windows. Every window floats
    case floating
}
