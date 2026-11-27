#!/bin/bash
# Fork addition. Replaces the Homebrew AeroSpace with the build from .fork-release (see build-fork.sh).
#
# To go back to the upstream AeroSpace:
#   rm -rf /Applications/AeroSpace.app "$(brew --prefix)/bin/aerospace"
#   brew install --cask nikitabobko/tap/aerospace
set -euo pipefail
cd "$(dirname "$0")"

app=".fork-release/AeroSpace.app"
cli=".fork-release/aerospace"
if ! test -d "$app" || ! test -f "$cli"; then
    echo "Run ./build-fork.sh first" > /dev/stderr
    exit 1
fi

# Quit the running AeroSpace. It puts hidden windows back on the screen on exit
pkill -x AeroSpace 2> /dev/null && sleep 1 || true

# brew upgrade would silently replace the fork with the upstream build. Unregister the cask
if command -v brew > /dev/null && brew list --cask aerospace > /dev/null 2>&1; then
    HOMEBREW_NO_AUTOREMOVE=1 brew uninstall --cask aerospace # Without the variable brew also removes unrelated orphaned packages
fi

bin_dir="$(command -v brew > /dev/null && echo "$(brew --prefix)/bin" || echo /usr/local/bin)"
rm -rf /Applications/AeroSpace.app
cp -R "$app" /Applications/AeroSpace.app
rm -f "$bin_dir/aerospace"
cp "$cli" "$bin_dir/aerospace"

# The Accessibility permission of the upstream build is tied to its code signature and doesn't apply to the fork.
# Remove the stale entry, so that macOS shows a fresh permission prompt instead of a checkbox that does nothing
tccutil reset Accessibility bobko.aerospace > /dev/null 2>&1 || true

echo "Installed /Applications/AeroSpace.app and $bin_dir/aerospace"
echo "Start it with: open -a AeroSpace"
echo "macOS will ask for the Accessibility permission again, because the fork is signed differently"
