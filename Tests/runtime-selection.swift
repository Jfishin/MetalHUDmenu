import Foundation

/// Owned fixtures only. Reads vendor libraries to exercise exact production profiles;
/// never writes an installed app or runner. Temporary external backups are removed.
@main struct RuntimeSelectionTests {
    static let fm = FileManager.default
    static func expectFailure(_ label: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch { print("PASS \(label)"); return }
        throw WineRuntimePatch.Failure(detail: "Unexpected success: \(label)")
    }
    static func app(at url: URL, identifier: String = "com.codeweavers.CrossOver") throws -> URL {
        let root = url.appendingPathComponent("Contents/SharedSupport/CrossOver")
        try fm.createDirectory(at: root.appendingPathComponent("lib/wine/x86_64-unix"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": identifier, "CFBundleName": "Fixture CrossOver",
                    "CFBundlePackageType": "APPL", "CFBundleVersion": "fixture"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data("unknown runtime".utf8).write(to: root.appendingPathComponent("lib/wine/x86_64-unix/winemac.so"))
        return root
    }
    static func main() throws {
        let scratch = fm.temporaryDirectory.appendingPathComponent("mhud-selection-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let chosenApp = scratch.appendingPathComponent("Renamed CrossOver.app")
        let root = try app(at: chosenApp)
        let selected = try WineRuntimePatch.runtimeRoot(forApplication: chosenApp)
        assert(selected.path == root.path, "Selected \(selected.path); expected \(root.path)")
        assert(WineRuntimePatch.isStandalone(selected))
        assert(WineRuntimePatch.displayName(selected).contains("Renamed CrossOver"))
        let discovered = WineRuntimePatch.availableRunners(selectedApplications: [chosenApp, chosenApp], notProtonEnabled: false)
        assert(discovered.filter { $0.path == root.path }.count == 1)
        assert(discovered.allSatisfy(WineRuntimePatch.isStandalone))
        print("PASS arbitrary app selection, canonical discovery, deduplication and disabled NotProton")

        let impostor = scratch.appendingPathComponent("Impostor.app")
        _ = try app(at: impostor, identifier: "example.impostor")
        try expectFailure("non-CrossOver app rejected") { _ = try WineRuntimePatch.runtimeRoot(forApplication: impostor) }
        let helper = scratch.appendingPathComponent("helper.dylib")
        try Data("fixture helper; never loaded".utf8).write(to: helper)
        try expectFailure("selected app still requires full verified build hashes") { try WineRuntimePatch.connect(root, helper: helper) }
        assert(!WineRuntimePatch.hasRecoveryRecord(root))

        // Use each installed stock build only as a read-only fixture source.
        for sourceApp in ["CrossOver.app", "CrossOver Preview.app"] {
            let sourceRoot = URL(fileURLWithPath: "/Applications/\(sourceApp)/Contents/SharedSupport/CrossOver")
            guard fm.fileExists(atPath: sourceRoot.path) else { print("SKIP missing \(sourceApp)"); continue }
            let fixtureApp = scratch.appendingPathComponent("Copy of \(sourceApp)")
            let fixtureRoot = try app(at: fixtureApp)
            let backup = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MetalHUDmenu/RuntimeBackups")
                .appendingPathComponent(WineRuntimePatch.hash(Data(fixtureRoot.path.utf8)))
            assert(!fm.fileExists(atPath: backup.path))
            defer { try? fm.removeItem(at: backup) }
            var originals: [String: Data] = [:]
            for arch in WineRuntimePatch.knownArchitectures {
                let relative = "lib/wine/\(arch)/winemac.so"
                let source = sourceRoot.appendingPathComponent(relative)
                guard fm.fileExists(atPath: source.path) else { continue }
                let original = try Data(contentsOf: source)
                originals[arch] = original
                let target = fixtureRoot.appendingPathComponent(relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try original.write(to: target)
            }
            let firstArch = originals.keys.sorted()[0]
            let target = fixtureRoot.appendingPathComponent("lib/wine/\(firstArch)/winemac.so")
            let link = target.deletingLastPathComponent().appendingPathComponent("MHUD.dylib")
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: helper.path)
            try expectFailure("unowned matching helper link preserved") { try WineRuntimePatch.connect(fixtureRoot, helper: helper) }
            let preservedLink = try fm.destinationOfSymbolicLink(atPath: link.path)
            assert(preservedLink == helper.path)
            try fm.removeItem(at: link)

            try WineRuntimePatch.connect(fixtureRoot, helper: helper)
            assert(WineRuntimePatch.isConnected(fixtureRoot))
            assert(fm.fileExists(atPath: backup.appendingPathComponent("manifest.json").path))
            assert(!fm.fileExists(atPath: fixtureRoot.appendingPathComponent(".metalhudmenu-backup").path))
            try WineRuntimePatch.connect(fixtureRoot, helper: helper)
            // Model an interrupted multi-file commit: one restored original and missing link.
            try originals[firstArch]!.write(to: target)
            try fm.removeItem(at: link)
            assert(!WineRuntimePatch.isConnected(fixtureRoot) && WineRuntimePatch.hasRecoveryRecord(fixtureRoot))
            try WineRuntimePatch.connect(fixtureRoot, helper: helper)
            assert(WineRuntimePatch.isConnected(fixtureRoot))
            let saved = backup.appendingPathComponent(firstArch + ".so")
            try Data("damaged backup".utf8).write(to: saved)
            try expectFailure("restore refuses damaged backup") { try WineRuntimePatch.disconnect(fixtureRoot) }
            try originals[firstArch]!.write(to: saved)
            let patched = try Data(contentsOf: target)
            try Data("vendor update".utf8).write(to: target)
            try expectFailure("restore refuses changed vendor library") { try WineRuntimePatch.disconnect(fixtureRoot) }
            let preservedUpdate = try Data(contentsOf: target)
            assert(preservedUpdate == Data("vendor update".utf8))
            try patched.write(to: target)

            // A directory symlink must not redirect an otherwise recognized file outside the selected runtime.
            let directory = target.deletingLastPathComponent()
            let movedDirectory = fixtureRoot.appendingPathComponent("saved-\(firstArch)")
            try fm.moveItem(at: directory, to: movedDirectory)
            try fm.createSymbolicLink(at: directory, withDestinationURL: movedDirectory)
            try expectFailure("restore refuses symlinked library directory") { try WineRuntimePatch.disconnect(fixtureRoot) }
            try fm.removeItem(at: directory)
            try fm.moveItem(at: movedDirectory, to: directory)

            try WineRuntimePatch.disconnect(fixtureRoot)
            assert(!WineRuntimePatch.isConnected(fixtureRoot))
            for (arch, original) in originals {
                let target = fixtureRoot.appendingPathComponent("lib/wine/\(arch)/winemac.so")
                let restored = try Data(contentsOf: target)
                assert(restored == original)
                assert((try? fm.destinationOfSymbolicLink(atPath: target.deletingLastPathComponent().appendingPathComponent("MHUD.dylib").path)) == nil)
            }
            try WineRuntimePatch.connect(fixtureRoot, helper: helper)
            try WineRuntimePatch.disconnect(fixtureRoot)
            print("PASS \(sourceApp): connect, reconnect, interrupted recovery, external backups, exact restore and reuse (\(originals.count) architectures)")
        }
    }
}
