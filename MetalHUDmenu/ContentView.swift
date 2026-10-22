//
//  ContentView.swift
//  MetalHUDMenu
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var settings: HUDSettingsManager
    @AppStorage("tab") private var tab = "HUD" // the menu bar drop target switches it to Games
    @State private var done: String?            // "Applied" or "Disabled" until a setting changes or the menu reopens

    // MARK: - All known HUD elements
    private let allElements: [(key: String, label: String)] = [
        ("fps", "FPS"), ("frameinterval", "Frame Interval"),
        ("frameintervalgraph", "Frame Interval Graph"), ("frameintervalhistogram", "Frame Interval Histogram"),
        ("fpsgraph", "FPS Graph"), ("framenumber", "Frame Number"),
        ("presentdelay", "Present Delay"), ("refreshrate", "Refresh Rate"),
        ("gputime", "GPU Time"), ("gputimeline", "GPU Timeline"),
        ("metalcpu", "Metal CPU"), ("shaders", "Shader Compilation"),
        ("memory", "Memory"), ("disk", "Disk Usage"),
        ("thermal", "Thermal State"), ("gamemode", "Game Mode"),
        ("device", "Device"), ("rosetta", "Rosetta Info"),
        ("layersize", "Layer Size & Composition"), ("layerscale", "Layer Scale"),
        ("client", "Client Process")
    ]

    private let presets: [(name: String, elements: [String])] = [
        ("FPS Only", ["fps"]),
        ("Rich", ["fps", "gputime", "memory", "thermal", "shaders"]),
        ("Default", ["device", "rosetta", "layersize", "memory", "gamemode", "fps", "gputime", "frameinterval", "frameintervalgraph"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("", selection: $tab) {
                    Text("HUD").tag("HUD")
                    Text("Mac Stats").tag("Mac Stats")
                    Text("Games").tag("Games")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }

            switch tab {
            case "Mac Stats": MacStatsView(settings: settings)
            case "Games": GamesView(settings: settings, helper: StatsHelper.shared)
            default: hudTab
            }
        }
        .padding(16)
        .frame(width: 640)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { GeneralConnections.shared.addPin(url: url); tab = "Games" }
                }
            }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { _ in done = nil }
        .onReceive(settings.objectWillChange) { _ in done = nil }
    }

    private var hudTab: some View {
        HStack(alignment: .top, spacing: 20) {
            // MARK: - Elements
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Elements").font(.headline)
                    Spacer()
                    ForEach(presets, id: \.name) { preset in
                        Button(preset.name) { settings.selectedElements = Set(preset.elements) }
                    }
                    Button("All") { settings.selectedElements = Set(allElements.map(\.key)) }
                }
                .controlSize(.small)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 5) {
                    ForEach(allElements, id: \.key) { element in
                        Toggle(element.label, isOn: Binding(
                            get: { settings.selectedElements.contains(element.key) },
                            set: { on in
                                if on { settings.selectedElements.insert(element.key) }
                                else { settings.selectedElements.remove(element.key) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(width: 370)

            Divider()

            // MARK: - Appearance, startup and actions
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable Metal HUD", isOn: $settings.hudEnabled)
                    .toggleStyle(.switch)
                Text("Scale \(String(format: "%.2f", settings.scale))").font(.caption)
                Slider(value: $settings.scale, in: 0.05...1.0, step: 0.01)
                Text("Opacity \(Int(settings.opacity * 100))%").font(.caption)
                Slider(value: $settings.opacity, in: 0.1...1.0, step: 0.01)
                Picker("Location", selection: $settings.alignment) {
                    ForEach(HUDSettingsManager.alignments, id: \.key) { Text($0.name).tag($0.key) }
                }
                .pickerStyle(.menu)

                Divider()

                Toggle("Open at Login", isOn: $settings.openAtLogin)
                Toggle("Enable HUD on Boot", isOn: $settings.enableHUDOnBoot)
                    .disabled(!settings.openAtLogin)

                Divider()

                HStack {
                    Button(done == "Applied" ? "Applied" : "Apply") { settings.applySettings(); done = "Applied" }
                        .buttonStyle(.borderedProminent)
                        .tint(done == "Applied" ? .gray : .accentColor)
                    Button(done == "Disabled" ? "Disabled" : "Disable HUD") { settings.disableHUD(); done = "Disabled" }
                    InfoTip("Apps launched afterwards use these settings; running apps keep the ones they started with.")
                }
            }
        }
    }
}

/// An (i) that shows longer help on hover, so the menu stays short.
struct InfoTip: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Image(systemName: "info.circle").foregroundStyle(.secondary).help(text) }
}
