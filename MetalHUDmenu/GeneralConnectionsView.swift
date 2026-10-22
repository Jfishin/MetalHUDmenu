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
                    A warning means the app's signature blocks Mac Stats. Allow Mac Stats… in its menu re-signs it with a backup; App Store apps can't be changed.
                    """)
                Spacer()
                Button("Pin App…") { connections.choosePin() }
            }
            ForEach(connections.pins) { pin in
                let signature = connections.signatures[pin.id]
                HStack {
                    Text(pin.name).lineLimit(1).help(pin.path)
                    if signature == .blocked {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .help("This app's signature blocks Mac Stats. Choose Allow Mac Stats… in its menu.")
                    } else if signature == .restricted {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.secondary)
                            .help("This App Store app's signature blocks Mac Stats. It can't be re-signed: macOS would refuse to open it, and its iCloud and Game Center permissions only work with Apple's signature.")
                    }
                    Spacer()
                    Button("Launch") { connections.launch(pin) }
                        .disabled(connections.launching.contains(pin.id) || connections.signing.contains(pin.id))
                    Menu {
                        Button("Edit Name & Arguments…") { editing = pin }
                        if signature == .blocked { Button("Allow Mac Stats…") { connections.allowMacStats(pin) } }
                        if signature == .restricted { Button("Mac Stats unavailable (App Store app)") {}.disabled(true) }
                        if signature == .allowed { Button("Restore Original Signature") { connections.restoreSignature(pin) } }
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
