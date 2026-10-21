#!/bin/zsh
# Compiles the Foundation-only sources with the checks in Tests/main.swift and runs them.
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
out=$(mktemp -d)/checks
xcrun swiftc -Onone MetalHUDmenu/SteamLaunchOptions.swift Tests/main.swift -o "$out"
"$out"
