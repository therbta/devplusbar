#!/bin/sh
# Installs the latest Dev+ Bar into /Applications and opens it.
#
#   curl -fsSL https://devplusbar.pages.dev/install.sh | sh
#
# Everything runs inside main(), so a download cut short runs nothing.
set -eu

ZIP_URL="https://github.com/therbta/devplusbar/releases/latest/download/DevPlusBar-macos.zip"
TEAM_ID="6U58AKY6F8"

say() { printf '%s\n' "$*"; }
fail() { printf 'Dev+ Bar: %s\n' "$*" >&2; exit 1; }

main() {
    [ "$(uname -s)" = Darwin ] || fail "Dev+ Bar runs on macOS only."
    version=$(sw_vers -productVersion)
    [ "${version%%.*}" -ge 14 ] || fail "Dev+ Bar needs macOS 14 or newer; this Mac has $version."

    dest=/Applications
    [ -w "$dest" ] || dest="$HOME/Applications"
    mkdir -p "$dest"

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    say "Downloading Dev+ Bar..."
    curl -fsSL "$ZIP_URL" -o "$tmp/DevPlusBar.zip" || fail "could not download $ZIP_URL"
    ditto -x -k "$tmp/DevPlusBar.zip" "$tmp"
    app="$tmp/DevPlusBar.app"
    [ -d "$app" ] || fail "the download does not contain DevPlusBar.app."

    # Only install the app signed by Dev+ Bar's developer and notarized by Apple.
    codesign --verify --deep --strict "$app" 2>/dev/null || fail "DevPlusBar.app's signature is not valid."
    codesign -dv "$app" 2>&1 | grep -q "TeamIdentifier=$TEAM_ID" || fail "DevPlusBar.app is not signed by its developer."
    spctl --assess --type execute "$app" 2>/dev/null || fail "macOS does not accept DevPlusBar.app (not notarized)."

    pkill -x DevPlusBar 2>/dev/null || true
    rm -rf "$dest/DevPlusBar.app" 2>/dev/null || fail "could not replace $dest/DevPlusBar.app; remove it and run this again."
    ditto "$app" "$dest/DevPlusBar.app"

    say "Installed $dest/DevPlusBar.app"
    open "$dest/DevPlusBar.app"
    say "Dev+ Bar is in the menu bar. Sign in with GitHub in the window that opened."
}

main "$@"
