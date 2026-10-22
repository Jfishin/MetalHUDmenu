import AppKit
import Combine

final class GeneralConnections: ObservableObject {
    static let shared = GeneralConnections()
    private static let storageKey = "generalConnections"
    @Published private(set) var pins: [LaunchConnection] = []
    @Published var status = ""
    @Published private(set) var launching: Set<UUID> = []
    /// Whether each pin's code signature lets the helper load at launch.
    @Published private(set) var signatures: [UUID: AppSignature.State] = [:]
    @Published private(set) var signing: Set<UUID> = []
    private var processes: [UUID: Process] = [:]
    private var canSave = true

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        do {
            pins = try JSONDecoder().decode([LaunchConnection].self, from: data)
            refreshSignatures()
        } catch {
            canSave = false
            status = "Saved pins couldn't be read. They have been preserved; adding or editing pins is disabled."
        }
    }

    func choosePin() {
        let panel = NSOpenPanel()
        panel.title = "Pin an application or executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addPin(url: url)
    }

    func addPin(url: URL, name: String? = nil, arguments: [String] = []) {
        guard canSave else { return }
        guard validTarget(url) else { return }
        let path = url.standardizedFileURL.path
        guard !pins.contains(where: { $0.path == path }) else {
            status = "This application is already pinned."
            return
        }
        let pin = LaunchConnection(name: name ?? url.deletingPathExtension().lastPathComponent,
                                   path: path, arguments: arguments)
        save(pins + [pin])
    }

    func update(_ pin: LaunchConnection) {
        guard canSave, let index = pins.firstIndex(where: { $0.id == pin.id }) else { return }
        guard !pin.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Enter a display name."
            return
        }
        var updated = pins
        updated[index] = pin
        save(updated)
    }

    func remove(_ pin: LaunchConnection) { save(pins.filter { $0.id != pin.id }) }

    private func save(_ updated: [LaunchConnection]) {
        guard canSave else { return }
        do {
            let data = try JSONEncoder().encode(updated)
            UserDefaults.standard.set(data, forKey: Self.storageKey)
            pins = updated
            status = ""
            refreshSignatures()
        } catch { status = "Couldn't save pins: \(error.localizedDescription)" }
    }

    func refreshSignatures() {
        signatures = Dictionary(uniqueKeysWithValues: pins.map { ($0.id, AppSignature.state($0.url)) })
    }

    /// Re-signs a pinned app whose signature strips the helper, after the person confirms.
    func allowMacStats(_ pin: LaunchConnection) {
        guard !isRunning(pin) else { status = "Quit \(pin.name) first, then allow Mac Stats."; return }
        let alert = NSAlert()
        alert.messageText = "Allow Mac Stats in \(pin.name)?"
        alert.informativeText = """
            \(pin.name)'s signature blocks libraries added at launch, so Mac Stats can't load. MetalHUDmenu can \
            re-sign it on this Mac with that permission (and permission to load other developers' libraries) \
            added, after keeping a backup copy.

            The app will no longer carry its developer's signature. macOS may ask you to approve it once in \
            Privacy & Security, and an app update undoes the change. Restore Original Signature puts the backup back.
            """
        alert.addButton(withTitle: "Re-sign App")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        changeSignature(pin, working: "Re-signing \(pin.name)…") {
            try AppSignature.allow($0)
            return "\(pin.name) can load Mac Stats now. Launch it here."
        }
    }

    func restoreSignature(_ pin: LaunchConnection) {
        guard !isRunning(pin) else { status = "Quit \(pin.name) first, then restore its signature."; return }
        changeSignature(pin, working: "Restoring \(pin.name)…") {
            guard let leftover = try AppSignature.restore($0) else {
                return "\(pin.name)'s original signature is back. The re-signed copy is in the Trash."
            }
            return "\(pin.name)'s original signature is back. Delete the re-signed copy yourself: \(leftover.path)"
        }
    }

    /// codesign hashes the whole bundle, so it runs off the main thread. `change` returns the finished message.
    private func changeSignature(_ pin: LaunchConnection, working: String, _ change: @escaping (URL) throws -> String) {
        signing.insert(pin.id)
        status = working
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try change(pin.url) }
            DispatchQueue.main.async {
                self.signing.remove(pin.id)
                switch result {
                case .success(let message): self.status = message
                case .failure(let error): self.status = error.localizedDescription
                }
                self.refreshSignatures()
            }
        }
    }

    private func launchedMessage(_ pin: LaunchConnection) -> String {
        switch signatures[pin.id] {
        case .blocked: return "Launched \(pin.name) without Mac Stats: its signature blocks them. Choose Allow Mac Stats… in its menu."
        case .restricted: return "Launched \(pin.name) without Mac Stats: its App Store signature blocks them and can't be changed."
        default: return "Launched \(pin.name). Check the game HUD for stats."
        }
    }

    private func isRunning(_ pin: LaunchConnection) -> Bool {
        guard pin.isApplication else { return false }
        let resolved = pin.url.resolvingSymlinksInPath().standardizedFileURL
        let bundleID = Bundle(url: pin.url)?.bundleIdentifier
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == resolved ||
                (bundleID != nil && $0.bundleIdentifier == bundleID)
        }
    }

    private func validTarget(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            status = "The pinned application could not be found."
            return false
        }
        if url.pathExtension.lowercased() == "app", Bundle(url: url)?.executableURL != nil { return true }
        guard !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else {
            status = "Choose a macOS application or executable file."
            return false
        }
        return true
    }

    func launch(_ pin: LaunchConnection) {
        guard validTarget(pin.url), !launching.contains(pin.id), !signing.contains(pin.id) else { return }
        if isRunning(pin) {
            status = "Quit \(pin.name) first, then launch it here to apply stats."
            return
        }
        guard StatsHelper.shared.installFiles() else {
            status = "Couldn't install the Mac Stats helper."
            return
        }
        let settings = HUDSettingsManager.shared
        let environment = LaunchConnection.launchEnvironment(
            base: ProcessInfo.processInfo.environment, library: StatsHelper.library.path,
            enabled: settings.hudEnabled, elements: settings.selectedElements,
            scale: settings.scale, opacity: settings.opacity,
            alignment: settings.alignmentValue(for: settings.alignment))
        launching.insert(pin.id)
        status = "Launching \(pin.name)…"
        if pin.isApplication {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.environment = environment
            configuration.arguments = pin.arguments
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: pin.url, configuration: configuration) { _, error in
                Task { @MainActor in
                    self.launching.remove(pin.id)
                    self.status = error.map { "Couldn't launch \(pin.name): \($0.localizedDescription)" }
                        ?? self.launchedMessage(pin)
                }
            }
        } else {
            let process = Process()
            process.executableURL = pin.url
            process.arguments = pin.arguments
            process.environment = environment
            process.currentDirectoryURL = pin.url.deletingLastPathComponent()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let code = finished.terminationStatus
                Task { @MainActor in
                    self.processes.removeValue(forKey: pin.id)
                    self.launching.remove(pin.id)
                    if code != 0 { self.status = "\(pin.name) exited with status \(code)." }
                }
            }
            processes[pin.id] = process
            do {
                try process.run()
                status = launchedMessage(pin)
            } catch {
                processes.removeValue(forKey: pin.id)
                launching.remove(pin.id)
                status = "Couldn't launch \(pin.name): \(error.localizedDescription)"
            }
        }
    }
}
