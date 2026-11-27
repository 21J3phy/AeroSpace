# What this fork changes

This is a fork of [AeroSpace](https://github.com/nikitabobko/AeroSpace) (branched from `167a0cf7`, 182 commits after
v0.21.3-Beta). Existing AeroSpace configs keep working without changes.

## 1. Trackpad swipes switch workspaces

Swipe left or right with three fingers to go to the next or previous workspace, the way macOS Spaces work.
One swipe moves one workspace. The swipe stops at the first and the last workspace.

The switch is animated: windows of the old workspace slide out and windows of the new one slide in.
The animation belongs to the `workspace` command (`workspace --animate next`), so key bindings can use it too,
for example `alt-2 = 'workspace --animate 2'`.

```toml
workspace-animation-duration-ms = 250   # 0 turns the animation off
```

Swipes are bound to ordinary AeroSpace commands, so they can be changed in the config:

```toml
[gestures]
    three-finger-swipe-left = 'workspace --animate next'    # built-in default
    three-finger-swipe-right = 'workspace --animate prev'   # built-in default
    four-finger-swipe-up = 'fullscreen'           # anything you like
    three-finger-swipe-left = ''                  # empty string unbinds
```

Keys are `(three|four|five)-finger-swipe-(left|right|up|down)`. The direction is the direction your fingers move.

macOS must not use the same swipe for itself, otherwise the desktop rubber-bands on every swipe.
`System Settings -> Trackpad -> More Gestures -> Swipe between full-screen applications` has to be set to four fingers.

Implementation: `Sources/AppBundle/gesture/`, `Sources/PrivateApi/multitouch.m`
(reads raw touches from the private MultitouchSupport framework, no extra permissions needed),
`Sources/AppBundle/layout/workspaceSlideAnimation.swift`.

## 2. Mission Control shows windows at a usable size

AeroSpace keeps windows of inactive workspaces in the corner of the screen, and Mission Control reacts to that by
shrinking every window to a tiny thumbnail. The fix is a macOS setting, not code:

```bash
defaults write com.apple.dock expose-group-apps -bool true && killall Dock
```

Together with `System Settings -> Trackpad -> More Gestures -> Mission Control -> Swipe Up with Three Fingers`
it gives the normal three finger swipe up.

## 3. New windows open in a grid

In upstream AeroSpace every new window is added next to the focused one, which turns a workspace into a row of
thin windows. The fork keeps the workspace looking like a grid:

| windows | arrangement |
|---------|-------------|
| 1       | full screen |
| 2       | side by side |
| 3 - 4   | 2 columns, up to 2 windows each |
| 5 - 9   | 3 columns, up to 3 windows each |
| 10 - 16 | 4 columns |

The grid is a regular AeroSpace tree, so `focus`, `move`, `resize`, `join-with` and dragging with the mouse work
as before.

```toml
new-window-placement = 'grid'            # default
new-window-placement = 'after-focused'   # upstream behavior
```

## 4. Tiling, scrolling or floating

Every workspace has a layout mode:

- `tiling`. The grid above
- `scrolling`. Every window is a column in a horizontal strip (like niri or PaperWM). The strip scrolls to keep the
  focused column on the screen. `focus left|right` walks along the strip, `resize` changes the width of one column
  without squeezing the others
- `floating`. Windows are not arranged. They get their own size back

Switch the mode:

- Menu bar icon -> `Layout mode of workspace ...`
- `aerospace layout-mode tiling|scrolling|floating`
- Bind a key that cycles through the modes: `alt-shift-space = 'layout-mode tiling scrolling floating'`
- `aerospace layout-mode --all scrolling` changes all workspaces at once

```toml
default-layout-mode = 'tiling'           # tiling|scrolling|floating
scrolling.column-width-percent = 50      # width of a new column
```

Implementation: `Sources/AppBundle/tree/layoutMode.swift`, `Sources/AppBundle/layout/layoutRecursive.swift`
(`layoutScrolling`), `Sources/AppBundle/command/impl/LayoutModeCommand.swift`.

## Building without Xcode

```bash
./build-fork.sh      # -> .fork-release/AeroSpace.app, .fork-release/aerospace
./install-fork.sh    # replaces the Homebrew AeroSpace
```

The app is signed ad hoc. macOS asks for the Accessibility permission again after every rebuild.

Tests:

```bash
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

## Known limits

- The slide animation moves every window through the Accessibility API on every frame, because macOS has no public
  way to move windows of other apps together. Apps that react slowly (some Electron apps, browsers under load) can
  stutter. The wallpaper doesn't move, and the animation doesn't follow your fingers: it starts once the swipe is
  recognized
- The slide animation is skipped when several monitors are connected
- In the scrolling mode with several monitors, columns that are only partially on the screen are hidden instead of
  sticking out onto the neighbour monitor
- `SecureInputView` and `VolumeView` spell out `@State` storage by hand, because the macro behind `@State` in the
  macOS 27 SDK only ships with full Xcode
