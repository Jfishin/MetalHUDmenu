import Foundation

@main struct GeneralConnectionTests {
    static func main() throws {
        let args = LaunchConnection.arguments(from: "space here\n--flag\n$(not-a-command)\n\n")
        precondition(args == ["space here", "--flag", "$(not-a-command)"])
        let pin = LaunchConnection(name: "Game", path: "/Games/A Game.app", arguments: args)
        let restored = try JSONDecoder().decode(LaunchConnection.self, from: JSONEncoder().encode(pin))
        precondition(restored == pin)
        precondition(pin.isApplication)
        let env = LaunchConnection.launchEnvironment(
            base: ["DYLD_INSERT_LIBRARIES": "/overlay:/stats", "STEAM_DYLD_INSERT_LIBRARIES": "/steam", "KEEP": "value"],
            library: "/stats", enabled: false, elements: ["fps", "device"], scale: 0.2, opacity: 1, alignment: "12")
        precondition(env["DYLD_INSERT_LIBRARIES"] == "/overlay:/stats")
        precondition(env["STEAM_DYLD_INSERT_LIBRARIES"] == "/steam:/stats")
        precondition(env["MTL_HUD_ENABLED"] == "0")
        precondition(env["MTL_HUD_ELEMENTS"] == "device,fps")
        precondition(env["MTL_HUD_SCALE"] == "0.200" && env["MTL_HUD_OPACITY"] == "1.000")
        precondition(env["MTL_HUD_ALIGNMENT"] == "12" && env["KEEP"] == "value")
        print("General Connections model/environment tests passed")
    }
}
