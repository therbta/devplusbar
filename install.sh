#!/bin/sh
# Installs the latest Dev+ Bar into /Applications and opens it.
#
#   curl -fsSL https://devplusbar.pages.dev/install.sh | sh
#
# Everything runs inside main(), so a download cut short runs nothing.
set -eu

ZIP_URL="https://github.com/therbta/devplusbar/releases/latest/download/Dev+ Bar-macos.zip"
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
    curl -fsSL "$ZIP_URL" -o "$tmp/Dev+ Bar.zip" || fail "could not download $ZIP_URL"
    ditto -x -k "$tmp/Dev+ Bar.zip" "$tmp"
    app="$tmp/Dev+ Bar.app"
    [ -d "$app" ] || fail "the download does not contain Dev+ Bar.app."

    # Only install the app signed by Dev+ Bar's developer and notarized by Apple.
    codesign --verify --deep --strict "$app" 2>/dev/null || fail "Dev+ Bar.app's signature is not valid."
    codesign -dv "$app" 2>&1 | grep -q "TeamIdentifier=$TEAM_ID" || fail "Dev+ Bar.app is not signed by its developer."
    spctl --assess --type execute "$app" 2>/dev/null || fail "macOS does not accept Dev+ Bar.app (not notarized)."

    pkill -x Dev+ Bar 2>/dev/null || true
    rm -rf "$dest/Dev+ Bar.app" 2>/dev/null || fail "could not replace $dest/Dev+ Bar.app; remove it and run this again."
    ditto "$app" "$dest/Dev+ Bar.app"

    say "Installed $dest/Dev+ Bar.app"
    open "$dest/Dev+ Bar.app"
    say "Dev+ Bar is in the menu bar. Sign in with GitHub in the window that opened."
}

main "$@"
