import CryptoKit
import Foundation
import Security

/// Adds a weak dependency on the installed Mac Stats helper to a native app's own
/// executable, so the app loads it on every launch however it is started — no pin,
/// no launch option, no attach. The reference goes into existing Mach-O header
/// padding, so nothing in the binary moves; the app is then re-signed. A weak
/// dependency means a missing helper never stops the app from launching.
///
/// This is the same technique WineRuntimePatch uses on winemac.so, pointed at the
/// game's main executable instead.
enum NativePatch {
    struct Failure: LocalizedError { let detail: String; var errorDescription: String? { detail } }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(detail: message) } }

    /// Insert LC_LOAD_WEAK_DYLIB for `path` into every 64-bit slice of a Mach-O, using
    /// header padding only. Refuses when a slice has no room or already depends on it.
    /// Slice sizes never change, so a fat header needs no adjustment.
    static func addingDependency(to original: Data, path: String) throws -> Data {
        let name = Array(path.utf8) + [UInt8(0)]
        try require(path.hasPrefix("/") && !path.contains("\0") == true, "The helper path must be absolute.")
        let commandSize = (24 + name.count + 7) & ~7

        func u32(_ data: Data, _ offset: Int, bigEndian: Bool = false) throws -> UInt32 {
            try require(offset >= 0 && offset <= data.count - 4, "Truncated Mach-O.")
            let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            return bigEndian ? raw.bigEndian : raw.littleEndian
        }

        // Slice file offsets: the whole file for a thin 64-bit binary, or each arch of a fat one.
        var slices: [Int] = [0]
        let magic = try u32(original, 0) // little-endian: 0xfeedfacf thin-64, 0xbebafeca fat, 0xcefaedfe thin-32
        if magic == 0xbebafeca {
            let count = Int(try u32(original, 4, bigEndian: true))
            try require(count > 0 && count < 64, "Unexpected universal binary.")
            slices = try (0..<count).map { Int(try u32(original, 8 + $0 * 20 + 8, bigEndian: true)) }
        } else {
            try require(magic == 0xfeedfacf, "Only 64-bit executables are supported.")
        }

        var result = original
        func put(_ offset: Int, _ value: UInt32) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { result.replaceSubrange(offset..<(offset + 4), with: $0) }
        }

        for base in slices {
            try require(try u32(original, base) == 0xfeedfacf, "Only 64-bit executables are supported.")
            let count = Int(try u32(original, base + 16)), size = Int(try u32(original, base + 20))
            let end = base + 32 + size
            try require(count > 0 && count < 8192 && end <= original.count, "Invalid Mach-O command table.")
            var cursor = base + 32, firstSection = original.count
            for _ in 0..<count {
                let command = try u32(original, cursor), length = Int(try u32(original, cursor + 4))
                try require(length >= 8 && length % 8 == 0 && cursor + length <= end, "Invalid load command.")
                if command == 0x19 { // LC_SEGMENT_64
                    try require(length >= 72, "Truncated segment.")
                    let sections = Int(try u32(original, cursor + 64))
                    try require(sections <= (length - 72) / 80, "Invalid section table.")
                    for i in 0..<sections {
                        let section = cursor + 72 + i * 80
                        let offset = Int(try u32(original, section + 48)), flags = try u32(original, section + 64) & 0xff
                        if offset > base && ![UInt32(1), 0x0c, 0x12].contains(flags) { firstSection = min(firstSection, offset) }
                    }
                }
                if [UInt32(0xc), 0x80000018, 0x8000001f, 0x80000023].contains(command) {
                    let offset = Int(try u32(original, cursor + 8))
                    try require(offset >= 24 && offset <= length, "Invalid dependency name.")
                    let existing = String(decoding: original[(cursor + offset)..<(cursor + length)].prefix { $0 != 0 }, as: UTF8.self)
                    try require(existing != path, "This app already loads the Mac Stats helper.")
                }
                cursor += length
            }
            try require(cursor == end, "Inconsistent Mach-O command sizes.")
            try require(end + commandSize <= firstSection, "No room in this app's header for Mac Stats.")
            try require(original[end..<(end + commandSize)].allSatisfy { $0 == 0 }, "Header padding is not empty.")
            put(end, 0x80000018) // LC_LOAD_WEAK_DYLIB
            put(end + 4, UInt32(commandSize)); put(end + 8, 24)
            result.replaceSubrange((end + 24)..<(end + 24 + name.count), with: name)
            put(base + 16, UInt32(count + 1)); put(base + 20, UInt32(size + commandSize))
        }
        return result
    }

    static func dependsOnHelper(_ executable: URL, path: String) -> Bool {
        guard let data = try? Data(contentsOf: executable) else { return false }
        // addingDependency throws "already loads" exactly when the dependency is present.
        do { _ = try addingDependency(to: data, path: path); return false }
        catch let failure as Failure { return failure.detail.contains("already loads") }
        catch { return false }
    }

    static let backups = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MetalHUDmenu/LaunchPatches", isDirectory: true)

    enum State { case unsupported, patchable, patched }
    struct Signature { let hardened: Bool; let entitlements: [String: Any]; let cdhash: Data? }

    static func signature(_ url: URL) -> Signature? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return Signature(hardened: flags & SecCodeSignatureFlags.runtime.rawValue != 0,
                         entitlements: info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:],
                         cdhash: info[kSecCodeInfoUnique as String] as? Data)
    }

    /// Entitlements outside com.apple.security.* (App Store identity, iCloud, Game Center, keychain groups...)
    /// need Apple's signature and a profile: AMFI refuses an ad hoc app that keeps them (error -424), and
    /// dropping them cuts those services and can cut the app off from its sandbox data. Never re-sign these.
    static func restrictedEntitlements(_ signature: Signature) -> [String] {
        signature.entitlements.keys.filter { !$0.hasPrefix("com.apple.security.") }.sorted()
    }

    private static func folder(_ app: URL, _ backups: URL) -> URL {
        let digest = SHA256.hash(data: Data(app.standardizedFileURL.path.utf8))
        return backups.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined(), isDirectory: true)
    }
    private static func executable(_ app: URL) -> URL? { Bundle(url: app)?.executableURL }

    static func state(_ app: URL, helper: String, backups: URL = backups) -> State {
        guard app.pathExtension.lowercased() == "app", let exe = executable(app),
              let signature = signature(app) else { return .unsupported }
        if dependsOnHelper(exe, path: helper) { return .patched }
        // App Store apps can't be re-signed, and a binary with no header room can't take the reference.
        guard restrictedEntitlements(signature).isEmpty,
              let data = try? Data(contentsOf: exe), (try? addingDependency(to: data, path: helper)) != nil
        else { return .unsupported }
        return .patchable
    }

    /// Patches the app's executable to load the helper every launch, keeping a backup and re-signing.
    static func connect(_ app: URL, helper: String, backups: URL = backups) throws {
        guard let exe = executable(app), let signature = signature(app) else {
            throw Failure(detail: "This app could not be read.")
        }
        try require(restrictedEntitlements(signature).isEmpty,
                    "This App Store app can't be changed; macOS would refuse to open it re-signed.")
        try require(FileManager.default.isReadableFile(atPath: helper), "The Mac Stats helper is missing. Reopen MetalHUDmenu first.")
        let patched = try addingDependency(to: Data(contentsOf: exe), path: helper)

        let fm = FileManager.default
        let folder = folder(app, backups), backup = folder.appendingPathComponent(app.lastPathComponent)
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.copyItem(at: app, to: backup) // APFS clone of the original
        try patched.write(to: exe)
        // Hardened apps must accept an outside library; this static route needs no DYLD entitlement.
        var entitlements = signature.entitlements
        if signature.hardened { entitlements["com.apple.security.cs.disable-library-validation"] = true }
        let plist = folder.appendingPathComponent("entitlements.plist")
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: plist)
        var arguments = ["--force", "--sign", "-"]
        if signature.hardened { arguments += ["--options", "runtime"] }
        arguments += ["--entitlements", plist.path, app.path]
        try codesign(arguments)
        guard dependsOnHelper(exe, path: helper), let hash = Self.signature(app)?.cdhash else {
            throw Failure(detail: "The change didn't take effect. The original is kept at \(backup.path).")
        }
        try hash.write(to: folder.appendingPathComponent("patched.cdhash"))
    }

    /// Puts the original executable back by swapping the whole bundle, and trashes the patched copy.
    @discardableResult
    static func restore(_ app: URL, backups: URL = backups,
                        discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws -> URL? {
        let fm = FileManager.default
        let folder = folder(app, backups), backup = folder.appendingPathComponent(app.lastPathComponent)
        try require(fm.fileExists(atPath: backup.path), "No backup of this app was found.")
        let recorded = try? Data(contentsOf: folder.appendingPathComponent("patched.cdhash"))
        try require(signature(app)?.cdhash == recorded,
                    "The app changed after Mac Stats was added, probably an update. Nothing was replaced; the backup is at \(backup.path).")
        let suffix = app.pathExtension.isEmpty ? "" : "." + app.pathExtension
        let aside = app.deletingLastPathComponent().appendingPathComponent(app.deletingPathExtension().lastPathComponent + " (Mac Stats copy)" + suffix)
        try fm.moveItem(at: app, to: aside)
        do { try fm.moveItem(at: backup, to: app) } catch { try? fm.moveItem(at: aside, to: app); throw error }
        try? fm.removeItem(at: folder)
        do { try discard(aside); return nil } catch { return aside }
    }

    private static func codesign(_ arguments: [String]) throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }
        throw Failure(detail: output.contains("Operation not permitted")
            ? "macOS blocked the change. Allow MetalHUDmenu under System Settings → Privacy & Security → App Management, then try again."
            : "codesign failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}
