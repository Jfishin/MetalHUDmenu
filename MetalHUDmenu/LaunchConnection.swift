import Foundation

/// A pin owns only this record, never the application's files.
struct LaunchConnection: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var arguments: [String] = []

    var url: URL { URL(fileURLWithPath: path) }
    var isApplication: Bool { url.pathExtension.lowercased() == "app" }

    /// One literal argument per line. No shell interpretation or quoting needed.
    static func arguments(from text: String) -> [String] {
        text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    static func launchEnvironment(base: [String: String], library: String,
                                  enabled: Bool, elements: Set<String>, scale: Double,
                                  opacity: Double, alignment: String) -> [String: String] {
        var environment = base
        for key in ["DYLD_INSERT_LIBRARIES", "STEAM_DYLD_INSERT_LIBRARIES"] {
            var libraries = (environment[key] ?? "").split(separator: ":").map(String.init)
            if !libraries.contains(library) { libraries.append(library) }
            environment[key] = libraries.joined(separator: ":")
        }
        environment["MTL_HUD_ENABLED"] = enabled ? "1" : "0"
        environment["MTL_HUD_ELEMENTS"] = elements.sorted().joined(separator: ",")
        environment["MTL_HUD_SCALE"] = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), scale)
        environment["MTL_HUD_OPACITY"] = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), opacity)
        environment["MTL_HUD_ALIGNMENT"] = alignment
        environment["MHUD_HUD_EXPLICIT"] = "1" // these live settings win over the helper's saved Apply
        return environment
    }
}
