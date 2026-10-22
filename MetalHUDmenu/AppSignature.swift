import CryptoKit
import Foundation
import Security

/// Hardened apps without the DYLD and library-validation exceptions strip the stats helper at launch.
/// "Allow Mac Stats" re-signs such an app on this Mac (ad hoc, its entitlements plus those two) after
/// keeping an APFS clone; Restore swaps the clone back while the app is still the one we signed.
enum AppSignature {
    static let exceptions = ["com.apple.security.cs.allow-dyld-environment-variables",
                             "com.apple.security.cs.disable-library-validation"]
    static let defaultBackups = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MetalHUDmenu/SignatureBackups", isDirectory: true)

    /// restricted: blocked, and only Apple's signing can carry its entitlements, so it can't be re-signed here.
    enum State { case compatible, blocked, restricted, allowed }
    struct Signature { let hardened: Bool; let entitlements: [String: Any]; let cdhash: Data? }
    struct Failure: LocalizedError { let errorDescription: String? }

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

    /// With the hardened runtime on, launch-time injection needs both exceptions.
    static func blocksHelper(_ signature: Signature) -> Bool {
        signature.hardened && !exceptions.allSatisfy { signature.entitlements[$0] as? Bool == true }
    }

    /// Entitlements outside com.apple.security.* (App Store identity, iCloud, Game Center, keychain groups...)
    /// need Apple's signature and a profile: AMFI refuses an ad hoc app that keeps them (error -424), and
    /// dropping them cuts those services and can cut the app off from its sandbox data. Never re-sign these.
    static func restrictedEntitlements(_ signature: Signature) -> [String] {
        signature.entitlements.keys.filter { !$0.hasPrefix("com.apple.security.") }.sorted()
    }

    static func state(_ url: URL, backups: URL = defaultBackups) -> State {
        guard let signature = signature(url) else { return .compatible }
        if blocksHelper(signature) { return restrictedEntitlements(signature).isEmpty ? .blocked : .restricted }
        return signature.cdhash != nil && signature.cdhash == recordedHash(url, backups) ? .allowed : .compatible
    }

    static func allow(_ url: URL, backups: URL = defaultBackups) throws {
        guard let signature = signature(url), blocksHelper(signature) else { return }
        guard restrictedEntitlements(signature).isEmpty else {
            throw Failure(errorDescription: "This app's signature carries App Store, iCloud or Game Center permissions that only Apple's signature can grant. macOS won't open it re-signed, so it was left unchanged.")
        }
        let fm = FileManager.default
        let folder = folder(url, backups), backup = folder.appendingPathComponent(url.lastPathComponent)
        // A folder left from before an app update holds an older version; the current app is the original now.
        // ponytail: also replaces a backup from a failed attempt, which codesign's per-file atomic writes make safe.
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.copyItem(at: url, to: backup) // APFS clone: instant and shares storage
        var entitlements = signature.entitlements
        for key in exceptions { entitlements[key] = true }
        let plist = folder.appendingPathComponent("entitlements.plist")
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: plist)
        try codesign(["--force", "--sign", "-", "--options", "runtime", "--entitlements", plist.path, url.path])
        guard let signed = self.signature(url), !blocksHelper(signed), let hash = signed.cdhash else {
            throw Failure(errorDescription: "Re-signing didn't take effect. The original is kept at \(backup.path).")
        }
        try hash.write(to: folder.appendingPathComponent("resigned.cdhash"))
    }

    /// Returns where the re-signed copy is when it couldn't be moved to the Trash.
    @discardableResult
    static func restore(_ url: URL, backups: URL = defaultBackups,
                        discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws -> URL? {
        let fm = FileManager.default
        let folder = folder(url, backups), backup = folder.appendingPathComponent(url.lastPathComponent)
        guard fm.fileExists(atPath: backup.path) else { throw Failure(errorDescription: "No backup of this app was found.") }
        guard let hash = signature(url)?.cdhash, hash == recordedHash(url, backups) else {
            throw Failure(errorDescription: "The app changed after Mac Stats was allowed, probably an update. Nothing was replaced; the older backup is at \(backup.path).")
        }
        // Swap whole bundles so the original bytes, signature and attributes come back exactly.
        let suffix = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (re-signed copy)" + suffix)
        try fm.moveItem(at: url, to: aside)
        do { try fm.moveItem(at: backup, to: url) } catch { try? fm.moveItem(at: aside, to: url); throw error }
        try? fm.removeItem(at: folder)
        // App Store bundles are root-owned: a plain delete fails where the Trash still works.
        do { try discard(aside); return nil } catch { return aside }
    }

    private static func folder(_ url: URL, _ backups: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        return backups.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined(), isDirectory: true)
    }

    private static func recordedHash(_ url: URL, _ backups: URL) -> Data? {
        try? Data(contentsOf: folder(url, backups).appendingPathComponent("resigned.cdhash"))
    }

    private static func codesign(_ arguments: [String]) throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }
        throw Failure(errorDescription: output.contains("Operation not permitted")
            ? "macOS blocked the change. Allow MetalHUDmenu under System Settings → Privacy & Security → App Management, then try again."
            : "codesign failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}
