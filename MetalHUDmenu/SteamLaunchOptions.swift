//
//  SteamLaunchOptions.swift
//  MetalHUDMenu
//
//  Older versions put MetalHUDmenu's launch wrapper in every installed Steam game's launch options.
//  Now people paste the launch option themselves; this only removes what those versions added.
//

import Foundation

enum SteamLaunchOptions {
    static let command = "%command%"

    static func removing(wrapper: String, from options: String) -> String {
        let result = options.replacingOccurrences(of: "\"\(wrapper)\" ", with: "")
        return result.trimmingCharacters(in: .whitespaces) == command ? "" : result
    }

    /// Rewrites LaunchOptions in localconfig.vdf text. Only touched values change; the rest stays byte-for-byte.
    /// Returns nil when the text isn't the layout Steam writes.
    static func edit(localConfig text: String, _ transform: (String) -> String) -> String? {
        let bytes = Array(text.utf8)
        let appsPath = ["userlocalconfigstore", "software", "valve", "steam", "apps"]
        struct Option { var value: Range<Int>; var keyQuote: Int }
        var options: [Option] = []
        var path: [String] = []
        var pendingKey: String?
        var pendingKeyQuote = 0
        var i = 0

        func inApp() -> Bool { path.count == appsPath.count + 1 && Array(path.prefix(appsPath.count)) == appsPath }

        while i < bytes.count {
            switch bytes[i] {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                i += 1
            case UInt8(ascii: "/") where i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "/"):
                while i < bytes.count && bytes[i] != UInt8(ascii: "\n") { i += 1 }
            case UInt8(ascii: "\""):
                i += 1
                let start = i
                while i < bytes.count && bytes[i] != UInt8(ascii: "\"") { i += bytes[i] == UInt8(ascii: "\\") ? 2 : 1 }
                guard i < bytes.count else { return nil }
                let range = start..<i
                i += 1
                guard let key = pendingKey else {
                    pendingKey = String(decoding: bytes[range], as: UTF8.self)
                    pendingKeyQuote = start - 1
                    continue
                }
                if inApp() && key.lowercased() == "launchoptions" { options.append(Option(value: range, keyQuote: pendingKeyQuote)) }
                pendingKey = nil
            case UInt8(ascii: "{"):
                guard let key = pendingKey else { return nil }
                path.append(key.lowercased())
                pendingKey = nil
                i += 1
            case UInt8(ascii: "}"):
                guard !path.isEmpty, pendingKey == nil else { return nil }
                path.removeLast()
                i += 1
            default:
                return nil // unquoted tokens or conditionals: not a file layout we should touch
            }
        }
        guard path.isEmpty else { return nil }

        var result = bytes
        for option in options.reversed() {
            let old = unescape(String(decoding: bytes[option.value], as: UTF8.self))
            let new = transform(old)
            if new == old { continue }
            if new.isEmpty {
                // Drop the whole line instead of leaving an empty LaunchOptions behind.
                let start = lineStart(bytes, option.keyQuote)
                var end = option.value.upperBound + 1
                while end < bytes.count && bytes[end] != UInt8(ascii: "\n") { end += 1 }
                result.replaceSubrange(start..<min(end + 1, bytes.count), with: [])
            } else {
                result.replaceSubrange(option.value, with: Array(escape(new).utf8))
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// Start of the line holding `position` (past its indentation tabs), so edits keep Steam's layout.
    private static func lineStart(_ bytes: [UInt8], _ position: Int) -> Int {
        var i = position
        while i > 0 && (bytes[i - 1] == UInt8(ascii: "\t") || bytes[i - 1] == UInt8(ascii: " ")) { i -= 1 }
        return i
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func unescape(_ s: String) -> String {
        var out = "", escaped = false
        for c in s {
            if escaped { out.append(c == "n" ? "\n" : c == "t" ? "\t" : c); escaped = false }
            else if c == "\\" { escaped = true }
            else { out.append(c) }
        }
        return out
    }
}

enum SteamFiles {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Steam")

    /// localconfig.vdf for every Steam account on this Mac.
    static func localConfigs() -> [URL] {
        let userdata = root.appendingPathComponent("userdata")
        let users = (try? FileManager.default.contentsOfDirectory(atPath: userdata.path)) ?? []
        return users.map { userdata.appendingPathComponent("\($0)/config/localconfig.vdf") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Removes the wrapper from every game in every account. Only call while Steam is closed,
    /// because Steam rewrites localconfig.vdf when it quits. Keeps a one-time backup next to each file.
    static func removeWrapper(_ wrapper: String) throws {
        for url in localConfigs() {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let edited = SteamLaunchOptions.edit(localConfig: text, { SteamLaunchOptions.removing(wrapper: wrapper, from: $0) }),
                  edited != text else { continue }
            let backup = url.appendingPathExtension("metalhudmenu-backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: url, to: backup)
            }
            try edited.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
