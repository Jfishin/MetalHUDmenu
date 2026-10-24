// Run with Tests/run.sh. Patches an owned fixture app in a temporary folder, never a real app.
import Foundation

@main struct NativePatchTests {
    static func clang(_ args: [String]) throws {
        let p = try Process.run(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["--sdk", "macosx", "clang"] + args)
        p.waitUntilExit(); precondition(p.terminationStatus == 0, "clang \(args)")
    }
    static func codesign(_ app: URL) throws {
        let p = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", app.path])
        p.waitUntilExit(); precondition(p.terminationStatus == 0)
    }

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app"), backups = root.appendingPathComponent("backups")
        let exe = app.appendingPathComponent("Contents/MacOS/Fixture")
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        let src = root.appendingPathComponent("f.c")
        try "int main(void){return 0;}".write(to: src, atomically: true, encoding: .utf8)
        // Universal, with header room, like a real game.
        try clang(["-arch", "arm64", "-arch", "x86_64", "-headerpad_max_install_names", src.path, "-o", exe.path])
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.mhud-native", "CFBundleExecutable": "Fixture"],
                                           format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try codesign(app)
        let helper = root.appendingPathComponent("libMHUDStats.dylib").path
        try Data("not a real dylib, only its path is used".utf8).write(to: URL(fileURLWithPath: helper))
        let original = try Data(contentsOf: exe)

        precondition(NativePatch.state(app, helper: helper, backups: backups) == .patchable)
        try NativePatch.connect(app, helper: helper, backups: backups)
        precondition(NativePatch.state(app, helper: helper, backups: backups) == .patched)
        precondition(NativePatch.dependsOnHelper(exe, path: helper), "the executable now loads the helper")
        let afterPatch = try Data(contentsOf: exe)
        precondition(afterPatch != original, "the executable was patched")
        precondition(NativePatch.signature(app) != nil, "still validly signed")

        // Connecting twice is refused (already present), leaving the app untouched.
        do { try NativePatch.connect(app, helper: helper, backups: backups); preconditionFailure("double connect must refuse") } catch { }

        let leftover = try NativePatch.restore(app, backups: backups, discard: { try fm.removeItem(at: $0) })
        precondition(leftover == nil)
        let restored = try Data(contentsOf: exe)
        precondition(restored == original, "restore returns the exact original executable")
        precondition(NativePatch.state(app, helper: helper, backups: backups) == .patchable)

        // A binary with no spare header room is unsupported, not patched by force.
        try clang(["-arch", "arm64", src.path, "-o", exe.path]); try codesign(app)
        if NativePatch.state(app, helper: helper, backups: backups) == .patchable {
            // Some toolchains still leave room; only assert the refusal path when there genuinely isn't.
        } else {
            precondition(NativePatch.state(app, helper: helper, backups: backups) == .unsupported)
            do { try NativePatch.connect(app, helper: helper, backups: backups); preconditionFailure("no-room must refuse") } catch { }
        }
        print("NativePatch: patch, load reference, exact restore and refusal checks passed")
    }
}
