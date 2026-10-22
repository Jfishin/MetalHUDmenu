// Run with Tests/run.sh. Checks the Steam launch-option cleanup that touches users' Steam config.
import Foundation

let w = "/Users/me/Library/Application Support/MetalHUDmenu/mhud-run"
let q = "\"\(w)\""
let notProton = "DXMT_ENABLE_NVEXT=1 CX_GRAPHICS_BACKEND=dxmt WINEMSYNC=1 MTL_HUD_ENABLED=1 %command%"

// Older versions added the wrapper; removal must restore exactly what was there before.
assert(SteamLaunchOptions.removing(wrapper: w, from: "DXMT_ENABLE_NVEXT=1 CX_GRAPHICS_BACKEND=dxmt WINEMSYNC=1 MTL_HUD_ENABLED=1 \(q) %command%") == notProton)
assert(SteamLaunchOptions.removing(wrapper: w, from: "\(q) %command%") == "")
assert(SteamLaunchOptions.removing(wrapper: w, from: "\(q) %command% -console") == "%command% -console")
assert(SteamLaunchOptions.removing(wrapper: w, from: notProton) == notProton, "options without the wrapper are unchanged")

// localconfig.vdf editing, in Steam's own layout, as an older version left it
let wrapped = "\\\"\(w)\\\""
let vdf = """
"UserLocalConfigStore"
{
\t"Software"
\t{
\t\t"Valve"
\t\t{
\t\t\t"Steam"
\t\t\t{
\t\t\t\t"apps"
\t\t\t\t{
\t\t\t\t\t"550"
\t\t\t\t\t{
\t\t\t\t\t\t"LastPlayed"\t\t"1790000000"
\t\t\t\t\t\t"LaunchOptions"\t\t"/usr/bin/env \\"A=b c\\" \(wrapped) %command% -console"
\t\t\t\t\t\t"cloud"
\t\t\t\t\t\t{
\t\t\t\t\t\t\t"LaunchOptions"\t\t"not a real one"
\t\t\t\t\t\t}
\t\t\t\t\t}
\t\t\t\t\t"367520"
\t\t\t\t\t{
\t\t\t\t\t\t"LastPlayed"\t\t"1790000001"
\t\t\t\t\t\t"LaunchOptions"\t\t"\(wrapped) %command%"
\t\t\t\t\t}
\t\t\t\t}
\t\t\t}
\t\t}
\t}
\t"friends"\t\t"x"
}

"""
let remove = { (s: String) in SteamLaunchOptions.removing(wrapper: w, from: s) }
let undone = SteamLaunchOptions.edit(localConfig: vdf, remove)!
assert(undone.contains("\"LaunchOptions\"\t\t\"/usr/bin/env \\\"A=b c\\\" %command% -console\""), "existing options keep their quotes")
assert(!undone.contains("mhud-run"), "every wrapper is removed")
assert(!undone.contains("\"LaunchOptions\"\t\t\"\""), "no empty LaunchOptions lines are left")
assert(undone.contains("\t\t\t\t\t\t\"LastPlayed\"\t\t\"1790000001\"\n\t\t\t\t\t}"), "an app that only had the wrapper loses the line")
assert(undone.contains("\"not a real one\""), "nested blocks are left alone")
assert(undone.hasSuffix("\t\"friends\"\t\t\"x\"\n}\n"), "rest of the file is untouched")
assert(SteamLaunchOptions.edit(localConfig: undone, remove) == undone, "re-running changes nothing")
assert(SteamLaunchOptions.edit(localConfig: "\"a\" { b }", remove) == nil, "unquoted tokens are refused")

print("SteamLaunchOptions: all checks passed")

let stable = WineRuntimePatch.verifiedBuilds["CrossOver 26.3.0.39832"]!
let preview = WineRuntimePatch.verifiedBuilds["CrossOver Preview 27.0.0.41073"]!
assert(WineRuntimePatch.verifiedBuild(stable) != nil && stable.count == 1)
assert(WineRuntimePatch.verifiedBuild(preview) != nil && preview.count == 2)
var mixed = preview
mixed["x86_64-unix"] = stable["x86_64-unix"]
assert(WineRuntimePatch.verifiedBuild(mixed) == nil, "mixed runtime versions must be rejected")
assert(WineRuntimePatch.verifiedBuild([:]) == nil)
assert(WineRuntimePatch.verifiedBuild(["x86_64-unix": "unknown"]) == nil)
assert(WineRuntimePatch.verifiedBuild(["aarch64-unix": preview["aarch64-unix"]!]) == nil,
       "missing architecture must not silently produce a partial connection")
for malformed in [Data(), Data(repeating: 0, count: 128)] {
    do { _ = try WineRuntimePatch.addingDependency(to: malformed); assertionFailure("invalid binary accepted") }
    catch { }
}
print("WineRuntimePatch: profile and rejection checks passed")
