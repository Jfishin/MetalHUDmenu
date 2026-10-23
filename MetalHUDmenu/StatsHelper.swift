//
//  StatsHelper.swift
//  MetalHUDMenu
//
//  Keeps the Mac stats files installed, publishes readings for sandboxed games, and patches Wine runtimes.
//  Runs while MetalHUDmenu is open (Open at Login keeps it set-and-forget).
//

import AppKit
import Combine
import UniformTypeIdentifiers

final class StatsHelper: NSObject, ObservableObject {
    static let shared = StatsHelper()
    static let steamID = "com.valvesoftware.steam"
    /// Stable location for files games load, so games keep launching if the app moves.
    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MetalHUDmenu")
    static var wrapper: URL { supportDir.appendingPathComponent("mhud-run") }
    static var library: URL { supportDir.appendingPathComponent("libMHUDStats.dylib") }

    struct Stat: Identifiable { let id: String, label: String, group: String }

    /// The bundled stats library, loaded into this app to list the stats and to publish readings.
    private static let bundledLibrary = Bundle.main.url(forResource: "libMHUDStats", withExtension: "dylib")
        .flatMap { dlopen($0.path, RTLD_NOW) }

    /// Every stat the library can show, in menu order. The library owns this list.
    static let catalog: [Stat] = {
        guard let symbol = bundledLibrary.flatMap({ dlsym($0, "mhud_catalog") }) else { return [] }
        let text = String(cString: unsafeBitCast(symbol, to: (@convention(c) () -> UnsafePointer<CChar>).self)())
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t").map(String.init)
            return fields.count == 3 ? Stat(id: fields[0], label: fields[1], group: fields[2]) : nil
        }
    }()

    @Published var steamStatus = ""
    @Published var busy = false
    @Published var wineRuntimes: [URL] = []
    @Published var connectedRunners: Set<String> = []
    @Published var runtimeStatus = ""

    private let settings = HUDSettingsManager.shared
    private var relaunchSteam = false
    private var runningSteam: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.steamID).first
    }

    func start() {
        // Sandboxed games can read neither the sensors nor our preferences. While any game's helper
        // pings, the library samples here and publishes readings those games can read.
        if let symbol = Self.bundledLibrary.flatMap({ dlsym($0, "mhud_publisher_start") }) {
            unsafeBitCast(symbol, to: (@convention(c) () -> Void).self)()
        }
        guard installFiles() else { return }
        refreshRunners()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appTerminated),
                                                          name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    // MARK: - Wine runtimes

    func refreshRunners() {
        let apps = (UserDefaults.standard.stringArray(forKey: "crossOverApplications") ?? []).map { URL(fileURLWithPath: $0) }
        wineRuntimes = WineRuntimePatch.availableRunners(selectedApplications: apps)
        connectedRunners = Set(wineRuntimes.filter { WineRuntimePatch.isConnected($0) }.map(\.path))
    }

    func setRunner(_ root: URL, connected: Bool) {
        if connected && WineRuntimePatch.isStandalone(root) {
            let alert = NSAlert()
            alert.messageText = "Modify this Wine runtime?"
            alert.informativeText = "This enables Mac Stats for every game using this runtime. It changes signed app contents, so macOS or the app may reject the modified app. Restore puts the original libraries back; backups stay outside the app. No loader entitlements are changed. Quit the app and its games before connecting or restoring."
            alert.addButton(withTitle: "Connect Runtime")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        guard !connected || installFiles() else { return }
        do {
            if connected { try WineRuntimePatch.connect(root, helper: Self.library) }
            else { try WineRuntimePatch.disconnect(root) }
            runtimeStatus = connected ? "Runtime patched. Restart its games to load Mac Stats; in-game loading must still be checked."
                : "Original Wine libraries restored. Restart games for this change."
        } catch { runtimeStatus = error.localizedDescription }
        refreshRunners()
    }

    func addRuntime() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Wine app, its Wine folder, or its winemac.so"
        panel.allowedContentTypes = [.applicationBundle, .folder, .data]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let root = try WineRuntimePatch.runtimeRoot(forApplication: url)
            let paths = Set((UserDefaults.standard.stringArray(forKey: "crossOverApplications") ?? []) + [root.path])
            UserDefaults.standard.set(paths.sorted(), forKey: "crossOverApplications")
            refreshRunners()
            runtimeStatus = "Added \(WineRuntimePatch.displayName(root)). Connect checks its library has room before changing it."
        } catch { runtimeStatus = error.localizedDescription }
    }

    // MARK: - Files

    /// Copies the stats library and wrapper out of the app bundle when they changed.
    @discardableResult func installFiles() -> Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
            for name in ["libMHUDStats.dylib", "mhud-run"] {
                let source = resources.appendingPathComponent(name), target = Self.supportDir.appendingPathComponent(name)
                let data = try Data(contentsOf: source)
                if (try? Data(contentsOf: target)) == data { continue }
                // Rename a completed sibling over the destination. Mapped games keep
                // their inode, and a failed copy never leaves the installed path absent.
                let staged = Self.supportDir.appendingPathComponent(".\(name).\(UUID().uuidString)")
                defer { try? fm.removeItem(at: staged) }
                try data.write(to: staged, options: .withoutOverwriting)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
                guard rename(staged.path, target.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
            return true
        } catch {
            let message = "Could not install Mac Stats: \(error.localizedDescription)"
            steamStatus = message
            runtimeStatus = message
            return false
        }
    }

    // MARK: - Steam (cleanup only)

    /// Older versions added the wrapper to every installed Steam game. Steam rewrites its config
    /// when it quits, so a running Steam restarts once.
    func removeFromSteam() {
        guard let steam = runningSteam else { finishSteamRemoval(); return }
        busy = true
        relaunchSteam = true
        steamStatus = "Restarting Steam…"
        steam.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.relaunchSteam, self.runningSteam != nil else { return }
            self.relaunchSteam = false
            self.busy = false
            self.steamStatus = "Steam didn't quit. Quit Steam, then press Remove again."
        }
    }

    private func finishSteamRemoval() {
        do {
            try SteamFiles.removeWrapper(Self.wrapper.path)
            settings.steamConnected = false
            steamStatus = "Removed from your Steam games. Paste the launch option into the games you want."
        } catch {
            steamStatus = "Couldn't update Steam: \(error.localizedDescription)"
        }
    }

    @objc private func appTerminated(_ note: Notification) {
        guard relaunchSteam,
              (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.steamID
        else { return }
        relaunchSteam = false
        finishSteamRemoval()
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.steamID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        busy = false
    }
}
