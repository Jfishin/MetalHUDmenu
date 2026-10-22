import SwiftUI

struct MacStatsView: View {
    @ObservedObject var settings: HUDSettingsManager
    typealias Group = (name: String, stats: [StatsHelper.Stat])
    /// Catalog groups in order of first appearance.
    private let groups: [Group] = StatsHelper.catalog.reduce(into: []) { groups, stat in
        if let index = groups.firstIndex(where: { $0.name == stat.group }) { groups[index].stats.append(stat) }
        else { groups.append((stat.group, [stat])) }
    }
    /// Three columns fit the labels; later groups stack in the last one.
    private var columns: [[Group]] { groups.count <= 3 ? groups.map { [$0] } : groups.prefix(2).map { [$0] } + [Array(groups.dropFirst(2))] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle("Enable Mac Stats", isOn: $settings.systemStatsEnabled).toggleStyle(.switch)
                InfoTip("""
                    Changes reach running games within a second. Keep MetalHUDmenu open for sandboxed apps such as emulators: they can't read the sensors themselves, so this app reads them for them.
                    Colors: temperatures are green below 65 °C, yellow to 84 °C and red from 85 °C; memory and thermal pressure show their level. Other values stay white.
                    GPU usage is the share of time the GPU is busy at any speed (like mactop); the clock shows that speed, so 60% at 338 MHz means plenty of headroom. ANE usage is estimated from the Neural Engine's memory-bandwidth requests.
                    """)
                Spacer()
                if !settings.hudEnabled {
                    Text("Turn on the Metal HUD in the HUD tab to see stats.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(columns.indices, id: \.self) { column in
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(columns[column], id: \.name) { group in
                            Text(group.name).font(.subheadline.bold())
                                .padding(.top, group.name == columns[column].first?.name ? 0 : 8)
                            ForEach(group.stats) { stat in
                                Toggle(stat.label, isOn: Binding(
                                    get: { settings.systemStats.contains(stat.id) },
                                    set: { on in
                                        if on { settings.systemStats.insert(stat.id) }
                                        else { settings.systemStats.remove(stat.id) }
                                    }
                                )).toggleStyle(.checkbox)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(!settings.systemStatsEnabled)
            if groups.isEmpty {
                Text("The Mac Stats library is missing from this app. Reinstall MetalHUDmenu.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 {
                Text("Mac Stats on macOS 26 are experimental.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
