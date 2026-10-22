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

    // MARK: - Mac stats (read live by libMHUDStats; the stat list is StatsHelper.catalog)

    @Published var systemStatsEnabled: Bool {
        didSet { UserDefaults.standard.set(systemStatsEnabled, forKey: "systemStatsEnabled") }
    }

    @Published var systemStats: Set<String> {
        didSet { UserDefaults.standard.set(systemStats.sorted(), forKey: "systemStats") }
    }

    /// True when an older version added the wrapper to every Steam game; cleared once it's removed.
    @Published var steamConnected: Bool {
        didSet { UserDefaults.standard.set(steamConnected, forKey: "steamConnected") }
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

    // MARK: - Alignments (MTL_HUD_ALIGNMENT values), in screen order

    static let alignments: [(key: String, name: String, value: String)] = [
        ("topLeft", "Top Left", "10"), ("topCenter", "Top Center", "14"), ("topRight", "Top Right", "12"),
        ("leftCenter", "Left Center", "26"), ("center", "Center", "30"), ("centerRight", "Center Right", "28"),
        ("bottomLeft", "Bottom Left", "18"), ("bottomCenter", "Bottom Center", "22"), ("bottomRight", "Bottom Right", "20")
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
        self.systemStatsEnabled = defaults.object(forKey: "systemStatsEnabled") as? Bool ?? true
        self.systemStats = Set(defaults.stringArray(forKey: "systemStats") ?? [])
        self.steamConnected = defaults.bool(forKey: "steamConnected")

        if let saved = defaults.stringArray(forKey: "selectedElements") {
            self.selectedElements = Set(saved)
        } else {
            self.selectedElements = []
        }
    }

    // MARK: - Apply / Disable

    func applySettings() {
        if hudEnabled {
            runLaunchctl(["setenv",
                          "MTL_HUD_ENABLED", "1",
                          "MTL_HUD_ELEMENTS", selectedElements.sorted().joined(separator: ","),
                          "MTL_HUD_OPACITY", String(format: "%.3f", opacity),
                          "MTL_HUD_SCALE", String(format: "%.3f", scale),
                          "MTL_HUD_ALIGNMENT", alignmentValue(for: alignment)])
        } else {
            disableHUD()
        }
    }

    func disableHUD() {
        runLaunchctl(["unsetenv", "MTL_HUD_ENABLED"])
    }

    func applyOnBootIfNeeded() {
        if enableHUDOnBoot && hudEnabled {
            applySettings()
        }
    }

    // MARK: - Helpers

    func alignmentValue(for key: String) -> String {
        Self.alignments.first { $0.key == key }?.value ?? "4"
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
