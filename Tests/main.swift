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

for malformed in [Data(), Data(repeating: 0, count: 128)] {
    do { _ = try WineRuntimePatch.addingDependency(to: malformed); assertionFailure("invalid binary accepted") }
    catch { }
}
print("WineRuntimePatch: rejection checks passed")
