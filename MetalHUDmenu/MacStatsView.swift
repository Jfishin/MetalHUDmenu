//
//  MacStatsView.swift
//  MetalHUDMenu
//

import SwiftUI

struct MacStatsView: View {
    @ObservedObject var settings: HUDSettingsManager
    @ObservedObject var helper: StatsHelper

    private let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mac stats in Apple's HUD")
                .font(.headline)
            Text("Pick once. Games that are already running update within a second.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(HUDSettingsManager.systemStatCatalog, id: \.key) { stat in
                    Toggle(stat.label, isOn: Binding(
                        get: { settings.systemStats.contains(stat.key) },
                        set: { on in
                            if on { settings.systemStats.insert(stat.key) } else { settings.systemStats.remove(stat.key) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }

            if !settings.hudEnabled {
                Text("Stats appear inside the HUD. Turn it on in the HUD tab.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider().padding(.vertical, 4)

            // MARK: - Steam
            HStack {
                Text("Steam").font(.headline)
                Spacer()
                Button(settings.steamConnected ? "Disconnect" : "Connect") {
                    helper.setSteamConnected(!settings.steamConnected)
                }
                .disabled(helper.busy)
            }
            Text(helper.steamStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Ask when Steam opens", isOn: Binding(
                get: { !settings.steamNeverAsk },
                set: { settings.steamNeverAsk = !$0 }
            ))
            .toggleStyle(.checkbox)
            .disabled(settings.steamConnected)
            Text("Connecting adds MetalHUDmenu to each game's launch options and keeps your own. If Steam is open, it restarts once.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 {
                Text("Mac stats on macOS 26 are experimental.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}
