// Run with Tests/run.sh. Re-signs an owned fixture app in a temporary folder, never a real app.
import Foundation

@main struct AppSignatureTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app"), backups = root.appendingPathComponent("backups")
        let executable = app.appendingPathComponent("Contents/MacOS/Fixture")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.mhud-fixture", "CFBundleExecutable": "Fixture"],
                                           format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let jit = root.appendingPathComponent("jit.plist")
        try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.cs.allow-jit": true], format: .xml, options: 0).write(to: jit)
        func sign() throws {
            let process = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"),
                                          arguments: ["--force", "--sign", "-", "--options", "runtime", "--entitlements", jit.path, app.path])
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
        }

        // A hardened app like Dolphin: JIT allowed, DYLD variables not.
        try sign()
        let original = try Data(contentsOf: executable)
        precondition(AppSignature.state(app, backups: backups) == .blocked)

        try AppSignature.allow(app, backups: backups)
        precondition(AppSignature.state(app, backups: backups) == .allowed)
        let signed = AppSignature.signature(app)!
        precondition(signed.hardened, "keeps the hardened runtime")
        precondition(signed.entitlements["com.apple.security.cs.allow-jit"] as? Bool == true, "keeps the app's own entitlements")
        precondition(AppSignature.exceptions.allSatisfy { signed.entitlements[$0] as? Bool == true })

        let leftover = try AppSignature.restore(app, backups: backups, discard: { try fm.removeItem(at: $0) }) // not the real Trash
        let restored = try Data(contentsOf: executable)
        precondition(restored == original, "restore puts the original bytes back")
        precondition(AppSignature.state(app, backups: backups) == .blocked)
        precondition(leftover == nil && !fm.fileExists(atPath: root.appendingPathComponent("Fixture (re-signed copy).app").path))

        // An app replaced after allowing (an update) is never overwritten by the older backup.
        try AppSignature.allow(app, backups: backups)
        try sign()
        precondition(AppSignature.state(app, backups: backups) == .blocked)
        do { try AppSignature.restore(app, backups: backups); preconditionFailure("restore over a changed app must be refused") } catch { }
        try AppSignature.allow(app, backups: backups) // allowing again replaces the stale backup
        precondition(AppSignature.state(app, backups: backups) == .allowed)

        // An App Store app like DREDGE: AMFI refuses an ad hoc copy that keeps its restricted entitlements.
        try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.cs.allow-jit": true, "com.apple.security.app-sandbox": true,
                                                              "com.apple.developer.game-center": true], format: .xml, options: 0).write(to: jit)
        try sign()
        let store = try Data(contentsOf: executable)
        precondition(AppSignature.state(app, backups: backups) == .restricted)
        do { try AppSignature.allow(app, backups: backups); preconditionFailure("restricted apps must not be re-signed") } catch { }
        let untouched = try Data(contentsOf: executable)
        precondition(untouched == store, "a refused app is left unchanged")
        print("AppSignature: detect, allow, exact restore and update checks passed")
    }
}
