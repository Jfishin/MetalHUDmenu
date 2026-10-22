import AppKit

/// Compile with LaunchConnection.swift; pass the real helper and compiled probe paths.
/// Creates and launches only its own temporary app, never a user's game or saved pin.
@main struct GeneralLaunchTests {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "Usage: general-launch HELPER PROBE", code: 1)
        }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("mhud-general-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Owned Launch Probe.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Probe")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[2]), to: executable)
        let plist: [String: Any] = ["CFBundleExecutable": "Probe", "CFBundleIdentifier": "test.mhud.probe.\(UUID().uuidString)",
                                   "CFBundleName": "Owned Launch Probe", "CFBundlePackageType": "APPL", "LSUIElement": true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        try sign.run()
        sign.waitUntilExit()
        precondition(sign.terminationStatus == 0)
        let helper = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
        let args = ["literal space", "$(not-a-command)", "quote'\"literal"]
        let expected = ["loaded=1", "MTL_HUD_ENABLED=1", "MTL_HUD_ELEMENTS=device,fps", "MTL_HUD_SCALE=0.350",
                        "MTL_HUD_OPACITY=0.800", "MTL_HUD_ALIGNMENT=18", "STEAM_DYLD_INSERT_LIBRARIES=\(helper)"]
            + args.map { "arg=\($0)" }
        for route in ["process", "workspace"] {
            let report = directory.appendingPathComponent("\(route).txt")
            let environment = LaunchConnection.launchEnvironment(
                base: ["MHUD_PROBE_REPORT": report.path], library: helper, enabled: true,
                elements: ["fps", "device"], scale: 0.35, opacity: 0.8, alignment: "18")
            var launchFailure: Error?
            if route == "process" {
                let process = Process()
                process.executableURL = executable
                process.arguments = args
                process.environment = environment
                try process.run()
                process.waitUntilExit()
                precondition(process.terminationStatus == 0)
            } else {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.environment = environment
                configuration.arguments = args
                configuration.activates = false
                NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
                    launchFailure = error
                }
            }
            let deadline = Date().addingTimeInterval(15)
            while !fm.fileExists(atPath: report.path), launchFailure == nil, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            if let launchFailure { throw launchFailure }
            let output = try String(contentsOf: report, encoding: .utf8)
            for line in expected {
                guard output.components(separatedBy: .newlines).contains(line) else {
                    throw NSError(domain: "\(route) missing \(line); got \(output)", code: 1)
                }
            }
            print("\(route): real helper loaded, HUD environment and literal arguments verified")
        }
    }
}
