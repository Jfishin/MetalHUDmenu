// Run with Tests/run.sh. Checks the Steam launch-option editing that touches users' Steam config.
import Foundation

let w = "/Users/me/Library/Application Support/MetalHUDmenu/mhud-run"
let q = "\"\(w)\""
let notProton = "DXMT_ENABLE_NVEXT=1 CX_GRAPHICS_BACKEND=dxmt WINEMSYNC=1 MTL_HUD_ENABLED=1 %command%"

// Launch option strings
assert(SteamLaunchOptions.adding(wrapper: w, to: "") == "\(q) %command%")
assert(SteamLaunchOptions.adding(wrapper: w, to: notProton) == "DXMT_ENABLE_NVEXT=1 CX_GRAPHICS_BACKEND=dxmt WINEMSYNC=1 MTL_HUD_ENABLED=1 \(q) %command%")
assert(SteamLaunchOptions.adding(wrapper: w, to: "-console") == "\(q) %command% -console")
let once = SteamLaunchOptions.adding(wrapper: w, to: notProton)
assert(SteamLaunchOptions.adding(wrapper: w, to: once) == once, "adding twice changes nothing")
assert(SteamLaunchOptions.removing(wrapper: w, from: once) == notProton)
assert(SteamLaunchOptions.removing(wrapper: w, from: "\(q) %command%") == "")

// localconfig.vdf editing, in Steam's own layout
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
\t\t\t\t\t\t"LaunchOptions"\t\t"/usr/bin/env \\"A=b c\\" %command% -console"
\t\t\t\t\t\t"cloud"
\t\t\t\t\t\t{
\t\t\t\t\t\t\t"LaunchOptions"\t\t"not a real one"
\t\t\t\t\t\t}
\t\t\t\t\t}
\t\t\t\t\t"367520"
\t\t\t\t\t{
\t\t\t\t\t\t"LastPlayed"\t\t"1790000001"
\t\t\t\t\t}
\t\t\t\t}
\t\t\t}
\t\t}
\t}
\t"friends"\t\t"x"
}

"""
let add = { (s: String) in SteamLaunchOptions.adding(wrapper: w, to: s) }
let remove = { (s: String) in SteamLaunchOptions.removing(wrapper: w, from: s) }
let edited = SteamLaunchOptions.edit(localConfig: vdf, appIDs: ["550", "367520", "1875580"], add)!
assert(edited.contains("\"LaunchOptions\"\t\t\"/usr/bin/env \\\"A=b c\\\" \\\"\(w)\\\" %command% -console\""), "existing options keep their quotes")
assert(edited.contains("\t\t\t\t\t\t\"LastPlayed\"\t\t\"1790000001\"\n\t\t\t\t\t\t\"LaunchOptions\"\t\t\"\\\"\(w)\\\" %command%\"\n\t\t\t\t\t}"), "app without options gets a line")
assert(edited.contains("\t\t\t\t\t\"1875580\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"LaunchOptions\""), "missing app gets a block")
assert(edited.contains("\"not a real one\""), "nested blocks are left alone")
assert(edited.hasSuffix("\t\"friends\"\t\t\"x\"\n}\n"), "rest of the file is untouched")
assert(SteamLaunchOptions.edit(localConfig: edited, appIDs: ["550", "367520", "1875580"], add) == edited, "re-running changes nothing")

let undone = SteamLaunchOptions.edit(localConfig: edited, appIDs: nil, remove)!
assert(undone.contains("\"LaunchOptions\"\t\t\"/usr/bin/env \\\"A=b c\\\" %command% -console\""), "undo restores the original options")
assert(!undone.contains("mhud-run"), "undo removes every wrapper")
assert(SteamLaunchOptions.edit(localConfig: "\"a\" { b }", appIDs: nil, add) == nil, "unquoted tokens are refused")

print("SteamLaunchOptions: all checks passed")
