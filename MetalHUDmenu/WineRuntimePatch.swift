import Foundation
import CryptoKit
import AppKit

/// Verified CrossOver runtime patches: a weak dylib dependency in existing
/// header padding. No code, exports, section offsets, or loader entitlements change.
enum WineRuntimePatch {
    static let dependency = "@loader_path/MHUD.dylib"
    static let knownArchitectures = ["aarch64-unix", "x86_64-unix"]
    static let verifiedBuilds: [String: [String: String]] = [
      "NotProton 27.0.0.41073": [
        "aarch64-unix": "56f1ba0f2e3dc2fd6ce2c8097239841ce2da862b483a6254de528517ce7d7f16",
        "x86_64-unix": "6fecabeb0d684e8f3a9bb4dba9b21692ee603103773c58c08dd06d7d26eff40e"
      ],
      "CrossOver Preview 27.0.0.41073": [
        "aarch64-unix": "56f1ba0f2e3dc2fd6ce2c8097239841ce2da862b483a6254de528517ce7d7f16",
        "x86_64-unix": "ad1c19b3e61b47b2ee8b21ce7d46b1170233b96f7f1022057540e8b72350ff55"
      ],
      "CrossOver 26.3.0.39832": [
        "x86_64-unix": "a46e1c63a5096210626d64ef6c62ddea7632f95dbcf437b1a3bf006d43dcf532"
      ]
    ]
    static func verifiedBuild(_ hashes: [String: String]) -> String? {
        verifiedBuilds.first { $0.value == hashes }?.key
    }
    struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }
    struct Entry: Codable {
        let architecture: String
        let original: String
        let patched: String
    }
    struct Record: Codable {
        let helper: String
        let entries: [Entry]
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(detail: message) }
    }

    /// Thin, little-endian 64-bit Mach-O only. Refuse nonzero padding and any
    /// existing dependency. Caller pins production inputs to the verified hashes.
    static func addingDependency(to original: Data) throws -> Data {
        func word(_ offset: Int) throws -> UInt32 {
            try require(offset >= 0 && offset <= original.count - 4, "Truncated Mach-O header.")
            return original.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
        }
        try require(original.count >= 32, "Truncated Mach-O file.")
        try require(try word(0) == 0xfeedfacf && word(12) == 6, "Expected a thin 64-bit Mach-O dylib.")
        let cpu = try word(4)
        try require(cpu == 0x0100000c || cpu == 0x01000007, "Unsupported Wine architecture.")
        let count = Int(try word(16)), size = Int(try word(20)), end = 32 + size
        try require(count > 0 && count < 4096 && end <= original.count, "Invalid Mach-O command table.")
        var cursor = 32, firstSection = original.count
        for _ in 0..<count {
            let command = try word(cursor), length = Int(try word(cursor + 4))
            try require(length >= 8 && length % 8 == 0 && cursor + length <= end, "Invalid Mach-O load command.")
            if command == 0x19 { // LC_SEGMENT_64
                try require(length >= 72, "Truncated segment.")
                let sections = Int(try word(cursor + 64))
                try require(sections <= (length - 72) / 80, "Invalid section table.")
                for i in 0..<sections {
                    let section = cursor + 72 + i * 80
                    let offset = Int(try word(section + 48)), flags = try word(section + 64) & 0xff
                    if offset > 0 && ![UInt32(1), 0x0c, 0x12].contains(flags) { firstSection = min(firstSection, offset) }
                }
            }
            if [UInt32(0xc), 0x80000018, 0x8000001f, 0x80000023].contains(command) {
                try require(length >= 24, "Truncated dylib command.")
                let offset = Int(try word(cursor + 8))
                try require(offset >= 24 && offset < length, "Invalid dependency name.")
                let bytes = original[(cursor + offset)..<(cursor + length)]
                let name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                try require(name != dependency, "This library already has the Mac Stats dependency.")
            }
            cursor += length
        }
        try require(cursor == end, "Inconsistent Mach-O command sizes.")
        let name = Array(dependency.utf8) + [UInt8(0)]
        let commandSize = (24 + name.count + 7) & ~7
        try require(firstSection >= end + commandSize && end + commandSize <= original.count,
                    "No room for the dependency; code relocation is not supported.")
        try require(original[end..<(end + commandSize)].allSatisfy { $0 == 0 }, "Header padding is not empty.")
        var result = original
        func put(_ offset: Int, _ value: UInt32) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { result.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        put(end, 0x80000018) // LC_LOAD_WEAK_DYLIB
        put(end + 4, UInt32(commandSize)); put(end + 8, 24)
        result.replaceSubrange((end + 24)..<(end + 24 + name.count), with: name)
        put(16, UInt32(count + 1)); put(20, UInt32(size + commandSize))
        return result
    }

    static var runners: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/notproton/runners")
    }
    static let standaloneRoots = ["/Applications/CrossOver.app", "/Applications/CrossOver Preview.app"].map {
        URL(fileURLWithPath: $0).appendingPathComponent("Contents/SharedSupport/CrossOver")
    }
    private static func application(_ root: URL) -> URL {
        root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    /// Selection identifies the application; connect separately verifies every library hash.
    static func runtimeRoot(forApplication app: URL) throws -> URL {
        let app = app.resolvingSymlinksInPath().standardizedFileURL
        try require(app.pathExtension.lowercased() == "app"
                    && Bundle(url: app)?.bundleIdentifier == "com.codeweavers.CrossOver",
                    "Choose a CrossOver application (.app).")
        let root = app.appendingPathComponent("Contents/SharedSupport/CrossOver")
        try require(root.path == root.resolvingSymlinksInPath().path && !architectures(root).isEmpty,
                    "This CrossOver app has no supported Wine runtime, or its runtime is linked outside the app.")
        return root
    }
    static func isStandalone(_ root: URL) -> Bool {
        (try? runtimeRoot(forApplication: application(root)).path) == root.standardizedFileURL.path
    }
    static func displayName(_ root: URL) -> String {
        if isStandalone(root) {
            let app = application(root)
            let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            return app.deletingPathExtension().lastPathComponent + " " + version
        }
        return "NotProton: " + root.deletingLastPathComponent().lastPathComponent
    }
    private static func architectures(_ root: URL) -> [String] {
        knownArchitectures.filter { FileManager.default.fileExists(atPath: library(root, $0).path) }
    }
    static func architectureDescription(_ root: URL) -> String {
        let arches = architectures(root)
        if arches.count == 2 { return "ARM64 (FEX) and x86_64 (Rosetta) share this runtime folder." }
        return arches.contains("aarch64-unix") ? "ARM64 (FEX) runtime" : "x86_64 (Rosetta) runtime"
    }
    static var isNotProtonInstalled: Bool {
        let candidates = [NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.notproton.NotProton"),
                          URL(fileURLWithPath: "/Applications/NotProton.app"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/NotProton.app")]
        return candidates.compactMap { $0 }.contains {
            FileManager.default.fileExists(atPath: $0.path) && Bundle(url: $0)?.bundleIdentifier == "com.notproton.NotProton"
        }
    }
    static func availableRunners(selectedApplications: [URL] = [], notProtonEnabled: Bool = true) -> [URL] {
        let notProton = notProtonEnabled && isNotProtonInstalled
            ? ((try? FileManager.default.contentsOfDirectory(at: runners, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent("CrossOver") }
            : []
        let standalone = (standaloneRoots.map(application) + selectedApplications)
            .compactMap { try? runtimeRoot(forApplication: $0) }
        return Array(Set((notProton + standalone).map { $0.resolvingSymlinksInPath().standardizedFileURL }))
            .filter { !architectures($0).isEmpty && (try? validateRoot($0)) != nil }
            .sorted { $0.path < $1.path }
    }
    private static func backupDir(_ root: URL) -> URL {
        guard isStandalone(root) else { return root.appendingPathComponent(".metalhudmenu-backup") }
        // Do not leave recovery files inside the vendor's sealed app bundle.
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MetalHUDmenu/RuntimeBackups")
            .appendingPathComponent(hash(Data(root.standardizedFileURL.path.utf8)))
    }
    private static func library(_ root: URL, _ arch: String) -> URL { root.appendingPathComponent("lib/wine/\(arch)/winemac.so") }
    private static func record(_ root: URL) throws -> Record {
        let value = try JSONDecoder().decode(Record.self, from: Data(contentsOf: backupDir(root).appendingPathComponent("manifest.json")))
        let expected = architectures(root)
        try require(!expected.isEmpty && Set(value.entries.map(\.architecture)) == Set(expected) && value.entries.count == expected.count,
                    "Invalid runtime backup record.")
        try require(verifiedBuild(Dictionary(uniqueKeysWithValues: value.entries.map { ($0.architecture, $0.original) })) != nil,
                    "Unverified runtime backup identity.")
        return value
    }
    static func isConnected(_ root: URL) -> Bool {
        guard let value = try? record(root) else { return false }
        return value.entries.allSatisfy { entry in
            let target = library(root, entry.architecture)
            let link = target.deletingLastPathComponent().appendingPathComponent("MHUD.dylib")
            return (try? Data(contentsOf: target)).map(hash) == entry.patched
                && (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == value.helper
                && FileManager.default.isReadableFile(atPath: value.helper)
        }
    }
    /// Includes interrupted connections so the UI can offer recovery independently of connected state.
    static func hasRecoveryRecord(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: backupDir(root).appendingPathComponent("manifest.json").path)
    }
    private static func validateRoot(_ root: URL) throws {
        let base = runners.resolvingSymlinksInPath().path + "/"
        let standalone = isStandalone(root) && root.standardizedFileURL.path == root.resolvingSymlinksInPath().path
        try require(standalone || (root.resolvingSymlinksInPath().path.hasPrefix(base) && root.lastPathComponent == "CrossOver"),
                    "Choose a discovered NotProton or CrossOver runtime.")
    }
    private static func validateLibrary(_ target: URL, root: URL) throws {
        let attributes = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        try require(attributes.isRegularFile == true && attributes.isSymbolicLink != true
                    && target.standardizedFileURL.path == target.resolvingSymlinksInPath().path,
                    "Wine library and its parent folders must not be symbolic links.")
        try require(target.path.hasPrefix(root.standardizedFileURL.path + "/"), "Wine library is outside the selected runtime.")
    }
    private static func sign(_ file: URL) throws {
        for arguments in [["--force", "--sign", "-", "--timestamp=none", "--preserve-metadata=identifier", file.path],
                          ["--verify", "--strict", file.path]] {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = arguments
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try require(process.terminationStatus == 0, "Could not sign staged Wine library: " + String(decoding: output, as: UTF8.self))
        }
    }
    private static func replace(_ source: URL, _ target: URL) throws {
        guard rename(source.path, target.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    static func connect(_ root: URL, helper: URL) throws {
        try validateRoot(root)
        let fm = FileManager.default, backup = backupDir(root)
        try require(fm.isReadableFile(atPath: helper.path), "Install the Mac Stats helper first.")
        let manifest = backup.appendingPathComponent("manifest.json")
        let prior = fm.fileExists(atPath: manifest.path) ? try record(root) : nil
        if let prior { try require(prior.helper == helper.path, "The recorded helper location differs; disconnect first.") }
        let arches = architectures(root)
        var originals: [String: String] = [:]
        for arch in arches {
            let source = prior == nil ? library(root, arch) : backup.appendingPathComponent(arch + ".so")
            originals[arch] = try hash(Data(contentsOf: source))
        }
        try require(verifiedBuild(originals) != nil,
                    "Unverified runtime build. Only the verified 26.3 and 27 Preview builds are supported; no installed libraries were changed.")
        var staged: [(URL, URL)] = [], entries: [Entry] = []
        defer { for (temp, _) in staged { try? fm.removeItem(at: temp) } }
        // Validate and stage all present architectures before modifying installed libraries.
        for arch in arches {
            let target = library(root, arch), saved = backup.appendingPathComponent(arch + ".so")
            try validateLibrary(target, root: root)
            let current = try Data(contentsOf: target)
            let oldEntry = prior?.entries.first { $0.architecture == arch }
            if let oldEntry { try require([oldEntry.original, oldEntry.patched].contains(hash(current)), "The runtime updated \(arch). Its library was left unchanged.") }
            let original = oldEntry == nil ? current : try Data(contentsOf: saved)
            try require(hash(original) == originals[arch], "Runtime changed during validation; try again after its update finishes.")
            if let oldEntry { try require(hash(original) == oldEntry.original, "A runtime backup changed; recovery metadata was preserved.") }
            let link = target.deletingLastPathComponent().appendingPathComponent("MHUD.dylib")
            if let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                try require(prior != nil && destination == helper.path, "An unowned MHUD.dylib link already exists; it was preserved.")
            } else { try require(!fm.fileExists(atPath: link.path), "An unrelated MHUD.dylib file already exists.") }
            let temp = target.deletingLastPathComponent().appendingPathComponent(".mhud-\(UUID().uuidString).so")
            staged.append((temp, target))
            try addingDependency(to: original).write(to: temp, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
            try sign(temp)
            if let oldEntry {
                try require(try hash(Data(contentsOf: temp)) == oldEntry.patched,
                            "The staged signature changed; disconnect before reconnecting. Existing recovery metadata was preserved.")
            }
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            if fm.fileExists(atPath: saved.path) {
                try require(try hash(Data(contentsOf: saved)) == hash(original), "Existing runtime backup differs; it was preserved.")
            } else { try original.write(to: saved, options: .withoutOverwriting) }
            entries.append(Entry(architecture: arch, original: hash(original), patched: try hash(Data(contentsOf: temp))))
        }
        let value = Record(helper: helper.path, entries: entries)
        try JSONEncoder().encode(value).write(to: manifest, options: .atomic)
        for (index, pair) in staged.enumerated() {
            let (temp, target) = pair, entry = entries[index]
            try validateLibrary(target, root: root)
            let current = try hash(Data(contentsOf: target))
            let accepted = [entry.original, prior?.entries.first { $0.architecture == entry.architecture }?.patched].compactMap { $0 }
            try require(accepted.contains(current), "Wine changed during preparation; reconnect after its update finishes.")
            let link = target.deletingLastPathComponent().appendingPathComponent("MHUD.dylib")
            if let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                try require(destination == helper.path, "The helper link changed during preparation; it was preserved.")
            } else {
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: helper.path)
            }
            try replace(temp, target)
        }
    }

    static func disconnect(_ root: URL) throws {
        try validateRoot(root)
        let fm = FileManager.default, value = try record(root)
        // Check all originals and current identities before restoring any file.
        for entry in value.entries {
            try validateLibrary(library(root, entry.architecture), root: root)
            try require(try hash(Data(contentsOf: backupDir(root).appendingPathComponent(entry.architecture + ".so"))) == entry.original,
                        "A runtime backup changed; refusing to restore it.")
            let current = try hash(Data(contentsOf: library(root, entry.architecture)))
            try require([entry.original, entry.patched].contains(current), "The runtime updated \(entry.architecture); refusing to overwrite the newer library.")
        }
        for entry in value.entries {
            let target = library(root, entry.architecture)
            let temp = target.deletingLastPathComponent().appendingPathComponent(".mhud-restore-\(UUID().uuidString).so")
            defer { try? fm.removeItem(at: temp) }
            try fm.copyItem(at: backupDir(root).appendingPathComponent(entry.architecture + ".so"), to: temp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
            try require(try hash(Data(contentsOf: temp)) == entry.original,
                        "A runtime backup changed during restore; the installed library was left unchanged.")
            let current = try hash(Data(contentsOf: target))
            try validateLibrary(target, root: root)
            try require([entry.original, entry.patched].contains(current),
                        "Wine changed during restore; its newer library was left unchanged.")
            try replace(temp, target)
            let link = target.deletingLastPathComponent().appendingPathComponent("MHUD.dylib")
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == value.helper { try fm.removeItem(at: link) }
        }
        // Keep the original backups/manifest for recovery and safe reconnection.
    }
}
