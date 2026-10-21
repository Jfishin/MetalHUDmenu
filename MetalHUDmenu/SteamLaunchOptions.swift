//
//  SteamLaunchOptions.swift
//  MetalHUDMenu
//
//  Adds MetalHUDmenu's launch wrapper to Steam's per-game launch options
//  (the same idea as `mangohud %command%` on Linux).
//

import Foundation

enum SteamLaunchOptions {
    static let command = "%command%"

    /// Puts the quoted wrapper right before %command%, keeping whatever the user or another tool already set.
    static func adding(wrapper: String, to options: String) -> String {
        let token = "\"\(wrapper)\""
        if options.contains(token) { return options }
        let trimmed = options.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "\(token) \(command)" }
        if let range = trimmed.range(of: command) {
            return trimmed.replacingCharacters(in: range, with: "\(token) \(command)")
        }
        return "\(token) \(command) \(trimmed)" // options without %command% are extra game arguments
    }

    static func removing(wrapper: String, from options: String) -> String {
        let result = options.replacingOccurrences(of: "\"\(wrapper)\" ", with: "")
        return result.trimmingCharacters(in: .whitespaces) == command ? "" : result
    }

    /// Rewrites LaunchOptions in localconfig.vdf text. Only touched values change; the rest stays byte-for-byte.
    /// `appIDs` nil means only apps already listed. Returns nil when the text isn't the layout Steam writes.
    static func edit(localConfig text: String, appIDs: Set<String>?, _ transform: (String) -> String) -> String? {
        let bytes = Array(text.utf8)
        let appsPath = ["userlocalconfigstore", "software", "valve", "steam", "apps"]
        struct App { var close = 0; var value: Range<Int>? }
        var apps: [String: App] = [:]
        var appsClose: Int?
        var path: [String] = []
        var pendingKey: String?
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
                guard let key = pendingKey else { pendingKey = String(decoding: bytes[range], as: UTF8.self); continue }
                if inApp() && key.lowercased() == "launchoptions" { apps[path.last!]?.value = range }
                pendingKey = nil
            case UInt8(ascii: "{"):
                guard let key = pendingKey else { return nil }
                path.append(key.lowercased())
                if inApp() { apps[path.last!] = App() }
                pendingKey = nil
                i += 1
            case UInt8(ascii: "}"):
                guard !path.isEmpty, pendingKey == nil else { return nil }
                if path == appsPath { appsClose = i }
                if inApp() { apps[path.last!]?.close = i }
                path.removeLast()
                i += 1
            default:
                return nil // unquoted tokens or conditionals: not a file layout we should touch
            }
        }
        guard let appsClose, path.isEmpty else { return nil }

        let indent = { (depth: Int) in String(repeating: "\t", count: depth) }
        func optionLine(_ value: String) -> String {
            "\(indent(appsPath.count + 1))\"LaunchOptions\"\t\t\"\(escape(value))\"\n"
        }
        var edits: [(at: Int, remove: Int, insert: String)] = []
        for (id, app) in apps {
            if let range = app.value {
                let old = unescape(String(decoding: bytes[range], as: UTF8.self))
                let new = transform(old)
                if new != old { edits.append((range.lowerBound, range.count, escape(new))) }
            } else if appIDs?.contains(id) == true {
                let new = transform("")
                if !new.isEmpty { edits.append((lineStart(bytes, app.close), 0, optionLine(new))) }
            }
        }
        for id in (appIDs ?? []).subtracting(apps.keys).sorted() {
            let new = transform("")
            guard !new.isEmpty else { continue }
            let block = "\(indent(appsPath.count))\"\(id)\"\n\(indent(appsPath.count)){\n\(optionLine(new))\(indent(appsPath.count))}\n"
            edits.append((lineStart(bytes, appsClose), 0, block))
        }

        var result = bytes
        for edit in edits.sorted(by: { $0.at > $1.at }) {
            result.replaceSubrange(edit.at..<(edit.at + edit.remove), with: Array(edit.insert.utf8))
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// Start of the line holding a closing brace, so inserted lines keep Steam's indentation.
    private static func lineStart(_ bytes: [UInt8], _ brace: Int) -> Int {
        var i = brace
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

    /// App IDs with an appmanifest in any Steam library folder.
    static func installedAppIDs() -> Set<String> {
        var libraries = [root.path]
        if let text = try? String(contentsOf: root.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8),
           let regex = try? NSRegularExpression(pattern: #""path"\s+"((?:[^"\\]|\\.)*)""#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(match.range(at: 1), in: text) { libraries.append(SteamLaunchOptions.unescape(String(text[r]))) }
            }
        }
        var ids = Set<String>()
        for library in Set(libraries) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: library + "/steamapps")) ?? []
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                ids.insert(String(file.dropFirst("appmanifest_".count).dropLast(".acf".count)))
            }
        }
        return ids
    }

    /// Adds (or removes) the wrapper for installed games in every account. Only call while Steam is closed,
    /// because Steam rewrites localconfig.vdf when it quits. Keeps a one-time backup next to each file.
    static func sync(wrapper: String, connected: Bool) throws {
        let ids = connected ? installedAppIDs() : nil
        for url in localConfigs() {
            let text = try String(contentsOf: url, encoding: .utf8)
            let edited = SteamLaunchOptions.edit(localConfig: text, appIDs: ids) {
                connected ? SteamLaunchOptions.adding(wrapper: wrapper, to: $0)
                          : SteamLaunchOptions.removing(wrapper: wrapper, from: $0)
            }
            guard let edited, edited != text else { continue }
            let backup = url.appendingPathExtension("metalhudmenu-backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: url, to: backup)
            }
            try edited.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
