import SwiftUI

struct GeneralConnectionsView: View {
    @ObservedObject var connections = GeneralConnections.shared
    @State private var editing: LaunchConnection?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pinned Apps").font(.headline)
                InfoTip("""
                    Drop an app here or on the menu bar icon to pin it, then launch it here to apply your HUD and Mac Stats settings. Opening a game normally does not.
                    Pin an app to load Mac Stats every time it launches, from anywhere. A green dot means it's set up; a warning means it can't be (App Store app, or no room to patch) — launch it here instead.
                    """)
                Spacer()
                Button("Pin App…") { connections.choosePin() }
            }
            ForEach(connections.pins) { pin in
                let patch = connections.launchPatches[pin.id]
                HStack {
                    Text(pin.name).lineLimit(1).help(pin.path)
                    if patch == .patched {
                        Image(systemName: "circle.fill").foregroundStyle(.green).imageScale(.small)
                            .help("Loads Mac Stats on every launch.")
                    } else if patch == .unsupported {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.secondary)
                            .help("This app can't be set to load Mac Stats on its own — an App Store app, or no room to patch. Launch it here to show stats for that launch.")
                    }
                    Spacer()
                    Button("Launch") { connections.launch(pin) }
                        .disabled(connections.launching.contains(pin.id) || connections.signing.contains(pin.id))
                    Menu {
                        Button("Edit Name & Arguments…") { editing = pin }
                        if patch == .patchable { Button("Load Mac Stats on Launch…") { connections.loadOnLaunch(pin) } }
                        if patch == .patched { Button("Stop Loading Mac Stats") { connections.stopLoadingOnLaunch(pin) } }
                        Button("Remove Pin") { connections.remove(pin) }
                    } label: { Image(systemName: "ellipsis") }
                    .disabled(connections.signing.contains(pin.id))
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            if !connections.status.isEmpty {
                Text(connections.status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { connections.refreshSignatures() } // an app update can change a pin's signature
        .sheet(item: $editing) { pin in
            PinEditor(pin: pin) { connections.update($0) }
        }
    }
}

private struct PinEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var pin: LaunchConnection
    @State private var arguments: String
    let save: (LaunchConnection) -> Void

    init(pin: LaunchConnection, save: @escaping (LaunchConnection) -> Void) {
        _pin = State(initialValue: pin)
        _arguments = State(initialValue: pin.arguments.joined(separator: "\n"))
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Pin").font(.headline)
            TextField("Display name", text: $pin.name)
            Text("Arguments — one literal argument per line").font(.caption)
            TextEditor(text: $arguments).font(.system(.body, design: .monospaced))
                .frame(height: 100).border(.secondary.opacity(0.3))
            Text("No shell quoting. Blank lines are ignored.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    pin.arguments = LaunchConnection.arguments(from: arguments)
                    save(pin)
                    dismiss()
                }
                .disabled(pin.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }.padding().frame(width: 360)
    }
}
