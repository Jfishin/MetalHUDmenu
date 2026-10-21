//
//  HUDSettingsManager.swift
//  MetalHUDMenu
//

import Combine
import Foundation
import ServiceManagement

class HUDSettingsManager: ObservableObject {
    static let shared = HUDSettingsManager()

    // MARK: - Persisted HUD settings

    @Published var hudEnabled: Bool {
        didSet { UserDefaults.standard.set(hudEnabled, forKey: "hudEnabled") }
    }

    @Published var selectedElements: Set<String> {
        didSet { UserDefaults.standard.set(Array(selectedElements), forKey: "selectedElements") }
    }

    @Published var scale: Double {
        didSet { UserDefaults.standard.set(scale, forKey: "scale") }
    }

    @Published var opacity: Double {
        didSet { UserDefaults.standard.set(opacity, forKey: "opacity") }
    }

    @Published var alignment: String {
        didSet { UserDefaults.standard.set(alignment, forKey: "alignment") }
    }

    @Published var enableHUDOnBoot: Bool {
        didSet { UserDefaults.standard.set(enableHUDOnBoot, forKey: "enableHUDOnBoot") }
    }

    // MARK: - Mac stats (read live by libMHUDStats inside games)

    /// Stat tokens and labels. Keep in sync with the names in NativeHUD/mhud_stats.mm.
    static let systemStatCatalog: [(key: String, label: String)] = [
        ("cpuusage", "CPU usage"), ("gpuusage", "GPU usage"),
        ("cputemp", "CPU temperature"), ("gputemp", "GPU temperature"),
        ("fans", "Fan speed"), ("systempower", "System power"),
        ("cpupower", "CPU power (est.)"), ("gpupower", "GPU power"),
        ("swap", "Swap used"), ("free", "Free RAM"),
        ("inactive", "Free + inactive RAM"), ("thermal", "Thermal pressure")
    ]

    @Published var systemStats: Set<String> {
        didSet { UserDefaults.standard.set(systemStats.sorted(), forKey: "systemStats") }
    }

    @Published var steamConnected: Bool {
        didSet { UserDefaults.standard.set(steamConnected, forKey: "steamConnected") }
    }

    @Published var steamNeverAsk: Bool {
        didSet { UserDefaults.standard.set(steamNeverAsk, forKey: "steamNeverAsk") }
    }

    // MARK: - Open at Login

    @Published var openAtLogin: Bool {
        didSet {
            if openAtLogin {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
                enableHUDOnBoot = false
            }
        }
    }

    // MARK: - Status message (not persisted)

    @Published var statusMessage: String = ""

    // MARK: - Alignment lookup table

    private let alignmentMap: [String: String] = [
        "topLeft": "10",
        "topCenter": "14",
        "topRight": "12",
        "center": "30",
        "leftCenter": "26",
        "centerRight": "28",
        "bottomRight": "20",
        "bottomCenter": "22",
        "bottomLeft": "18"
    ]

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard

        self.hudEnabled = defaults.object(forKey: "hudEnabled") as? Bool ?? false
        self.scale = defaults.object(forKey: "scale") as? Double ?? 0.20
        self.opacity = defaults.object(forKey: "opacity") as? Double ?? 1.00
        self.alignment = defaults.string(forKey: "alignment") ?? "topRight"
        self.enableHUDOnBoot = defaults.object(forKey: "enableHUDOnBoot") as? Bool ?? false
        self.openAtLogin = SMAppService.mainApp.status == .enabled
        self.systemStats = Set(defaults.stringArray(forKey: "systemStats") ?? [])
        self.steamConnected = defaults.bool(forKey: "steamConnected")
        self.steamNeverAsk = defaults.bool(forKey: "steamNeverAsk")

        if let saved = defaults.stringArray(forKey: "selectedElements") {
            self.selectedElements = Set(saved)
        } else {
            self.selectedElements = []
        }
    }

    // MARK: - Apply / Disable

    func applySettings() {
        if hudEnabled {
            runLaunchctl(["setenv", "MTL_HUD_ENABLED", "1"])
            runLaunchctl(["setenv", "MTL_HUD_ELEMENTS", selectedElements.joined(separator: ",")])
            runLaunchctl(["setenv", "MTL_HUD_OPACITY", String(format: "%.3f", opacity)])
            runLaunchctl(["setenv", "MTL_HUD_SCALE", String(format: "%.3f", scale)])
            runLaunchctl(["setenv", "MTL_HUD_ALIGNMENT", alignmentValue(for: alignment)])
            statusMessage = "✅ Applied Metal HUD settings."
        } else {
            disableHUD()
        }
    }

    func disableHUD() {
        runLaunchctl(["unsetenv", "MTL_HUD_ENABLED"])
        statusMessage = "🚫 Disabled Metal HUD."
    }

    func applyOnBootIfNeeded() {
        if enableHUDOnBoot && hudEnabled {
            applySettings()
        }
    }

    // MARK: - Helpers

    func alignmentValue(for key: String) -> String {
        alignmentMap[key] ?? "4"
    }

    private func runLaunchctl(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["asuser", "\(getuid())", "/bin/launchctl"] + args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("Error running launchctl: \(error)")
        }
    }
}
