import SwiftUI

/// Where Mac Stats gets into games: launchers and Wine runtimes on the left, pinned apps on the right.
struct GamesView: View {
    @ObservedObject var settings: HUDSettingsManager
    @ObservedObject var helper: StatsHelper
    @State private var copied: String?
    private var notProton: [URL] { helper.wineRuntimes.filter { !WineRuntimePatch.isStandalone($0) } }
    private var crossOver: [URL] { helper.wineRuntimes.filter { WineRuntimePatch.isStandalone($0) } }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Launch Option").font(.headline)
                    InfoTip("""
                        Adds Mac Stats to a game started by any launcher. Paste it into that game's launch options.
                        Steam: right-click a game › Properties › Launch Options.
                        Non-Steam (Heroic and others): paste the path into the game's wrapper command.
                        The HUD itself follows the HUD tab.
                        """)
                }
                copyRow("Steam", "\"\(StatsHelper.wrapper.path)\" %command%")
                copyRow("Non-Steam", StatsHelper.wrapper.path)
                if settings.steamConnected {
                    HStack {
                        caption("An older version added this to every Steam game.")
                        Spacer()
                        Button("Remove") { helper.removeFromSteam() }.disabled(helper.busy)
                    }
                }
                if !helper.steamStatus.isEmpty { caption(helper.steamStatus) }

                if !notProton.isEmpty {
                    Divider()
                    HStack {
                        Text("NotProton").font(.headline)
                        InfoTip(notProton.map(WineRuntimePatch.architectureDescription).joined(separator: "\n"))
                    }
                    ForEach(notProton, id: \.path) { root in runtimeRow(root) }
                }

                Divider()
                HStack {
                    Text("CrossOver").font(.headline)
                    InfoTip("One connection covers all bottles using that app. Connect checks the app's exact build first and refuses unknown ones. Restore puts the original runtime files back.")
                    Spacer()
                    Button { helper.refreshRunners() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh runtimes")
                    Button("Add App…") { helper.addCrossOver() }
                }
                ForEach(crossOver, id: \.path) { root in runtimeRow(root) }
                if !helper.runtimeStatus.isEmpty { caption(helper.runtimeStatus) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            GeneralConnectionsView()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
        .onAppear { helper.refreshRunners() }
    }

    private func copyRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).frame(width: 72, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.head)
                .textSelection(.enabled).help(value)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = value
            } label: { Image(systemName: copied == value ? "checkmark" : "doc.on.doc") }
            .help("Copy")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func runtimeRow(_ root: URL) -> some View {
        HStack(alignment: .top) {
            Text(WineRuntimePatch.displayName(root)).lineLimit(2).help(root.path)
            Spacer()
            let connected = helper.connectedRunners.contains(root.path)
            Button(connected ? "Restore" : "Connect") { helper.setRunner(root, connected: !connected) }
                .contextMenu {
                    if WineRuntimePatch.hasRecoveryRecord(root) {
                        Button("Restore original runtime files") { helper.setRunner(root, connected: false) }
                    }
                }
        }
    }
}
