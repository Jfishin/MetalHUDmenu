#!/bin/zsh
# Compiles the Foundation-only sources and the stats math with their checks and runs them.
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -module-cache-path "$scratch/modules" -Onone MetalHUDmenu/SteamLaunchOptions.swift MetalHUDmenu/WineRuntimePatch.swift Tests/main.swift -o "$scratch/core"
"$scratch/core"
xcrun swiftc -module-cache-path "$scratch/modules" -Onone MetalHUDmenu/LaunchConnection.swift Tests/general-connections.swift -o "$scratch/general"
"$scratch/general"
xcrun swiftc -module-cache-path "$scratch/modules" -Onone MetalHUDmenu/NativePatch.swift Tests/native-patch.swift -o "$scratch/nativepatch"
"$scratch/nativepatch"
xcrun clang++ -std=c++17 Tests/stats-math.cpp -o "$scratch/stats-math"
"$scratch/stats-math"
