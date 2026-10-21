//
//  StatsHelper.swift
//  MetalHUDMenu
//
//  Keeps the Mac stats files installed and connects Steam games to them.
//  Runs while MetalHUDmenu is open (Open at Login keeps it set-and-forget).
//

import AppKit
import Combine
import UserNotifications

final class StatsHelper: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = StatsHelper()
    static let steamID = "com.valvesoftware.steam"
    /// Stable location for files games load, so games keep launching if the app moves.
    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MetalHUDmenu")
    static var wrapper: URL { supportDir.appendingPathComponent("mhud-run") }

    @Published var steamStatus = ""
    @Published var busy = false

    private let settings = HUDSettingsManager.shared
    private var relaunchSteam = false
    private var runningSteam: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.steamID).first
    }

    func start() {
        installFiles()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appLaunched), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appTerminated), name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: "steam",
            actions: [UNNotificationAction(identifier: "connect", title: "Connect"),
                      UNNotificationAction(identifier: "never", title: "Don't Ask Again")],
            intentIdentifiers: [])])

        if runningSteam == nil { syncSteam() } else { updateStatus() }
    }

    // MARK: - Files

    /// Copies the stats library and wrapper out of the app bundle when they changed.
    func installFiles() {
        guard let resources = Bundle.main.resourceURL else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        for name in ["libMHUDStats.dylib", "mhud-run"] {
            let source = resources.appendingPathComponent(name), target = Self.supportDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: source) else { continue }
            if (try? Data(contentsOf: target)) == data { continue }
            // Remove first so running games keep their mapped copy instead of seeing it rewritten.
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: source, to: target)
        }
    }

    // MARK: - Steam

    /// Connect or disconnect Steam games. Steam must be closed to edit its config, so a running Steam restarts once.
    func setSteamConnected(_ connected: Bool) {
        settings.steamConnected = connected
        installFiles()
        guard let steam = runningSteam else { syncSteam(); return }
        busy = true
        relaunchSteam = true
        steamStatus = "Restarting Steam…"
        steam.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.relaunchSteam, self.runningSteam != nil else { return }
            self.relaunchSteam = false
            self.busy = false
            self.steamStatus = "Steam didn't quit. Quit Steam and the change applies then."
        }
    }

    func syncSteam() {
        do {
            try SteamFiles.sync(wrapper: Self.wrapper.path, connected: settings.steamConnected)
            updateStatus()
        } catch {
            steamStatus = "Couldn't update Steam: \(error.localizedDescription)"
        }
    }

    private func updateStatus() {
        steamStatus = settings.steamConnected ? "Connected. Steam games start with your stats." : "Not connected."
    }

    private func isSteam(_ note: Notification) -> Bool {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.steamID
    }

    @objc private func appTerminated(_ note: Notification) {
        guard isSteam(note) else { return }
        // Steam writes its config on quit, so this is the safe moment. It also picks up newly installed games.
        syncSteam()
        if relaunchSteam, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.steamID) {
            relaunchSteam = false
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        busy = false
    }

    @objc private func appLaunched(_ note: Notification) {
        guard isSteam(note), !relaunchSteam, !settings.steamConnected, !settings.steamNeverAsk,
              !settings.systemStats.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Show Mac stats in Steam games?"
            content.body = "MetalHUDmenu can add your selected stats to the HUD in Steam games. Steam restarts once."
            content.categoryIdentifier = "steam"
            center.add(UNNotificationRequest(identifier: "steam-connect", content: content, trigger: nil))
        }
    }

    // MARK: - Notification actions

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        Task { @MainActor in
            switch action {
            case "connect": self.setSteamConnected(true)
            case "never": self.settings.steamNeverAsk = true
            default: break // dismissed or clicked: ask again next time Steam opens
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
