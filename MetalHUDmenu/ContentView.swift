//
//  ContentView.swift
//  MetalHUDMenu
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var settings: HUDSettingsManager

    @State private var selectedPreset: String? = nil

    // MARK: - All known HUD elements
    struct HUDElement: Identifiable {
        let id = UUID()
        let key: String
        let label: String
    }

    private let allElements: [HUDElement] = [
        .init(key: "device", label: "Device"),
        .init(key: "rosetta", label: "Rosetta Info"),
        .init(key: "layersize", label: "Layer Size & Composition"),
        .init(key: "memory", label: "Memory"),
        .init(key: "fps", label: "FPS"),
        .init(key: "frameinterval", label: "Frame Interval"),
        .init(key: "frameintervalhistogram", label: "Frame Interval Histogram"),
        .init(key: "metalcpu", label: "Metal CPU"),
        .init(key: "gputimeline", label: "GPU Timeline"),
        .init(key: "shaders", label: "Shader Compilation"),
        .init(key: "framenumber", label: "Frame Number"),
        .init(key: "disk", label: "Disk Usage"),
        .init(key: "frameintervalgraph", label: "Frame Interval Graph"),
        .init(key: "presentdelay", label: "Present Delay"),
        .init(key: "gputime", label: "GPU Time"),
        .init(key: "thermal", label: "Thermal State"),
        .init(key: "fpsgraph", label: "FPS Graph"),
        .init(key: "layerscale", label: "Layer Scale"),
        .init(key: "refreshrate", label: "Refresh Rate"),
        .init(key: "gamemode", label: "Game Mode"),
        .init(key: "client", label: "Client Process")
    ]

    // MARK: - Alignment options
    struct HUDAlignment: Identifiable {
        let id = UUID()
        let name: String
        let key: String
        let value: String
    }

    private let alignments: [HUDAlignment] = [
        .init(name: "Top Left", key: "topLeft", value: "10"),
        .init(name: "Top Center", key: "topCenter", value: "14"),
        .init(name: "Top Right", key: "topRight", value: "12"),
        .init(name: "Center", key: "center", value: "30"),
        .init(name: "Left Center", key: "leftCenter", value: "26"),
        .init(name: "Center Right", key: "centerRight", value: "28"),
        .init(name: "Bottom Right", key: "bottomRight", value: "20"),
        .init(name: "Bottom Center", key: "bottomCenter", value: "22"),
        .init(name: "Bottom Left", key: "bottomLeft", value: "18")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Enable Metal HUD", isOn: $settings.hudEnabled)
                .toggleStyle(.switch)
                .padding(.bottom, 8)

            Divider()

            // MARK: - Presets
            Text("Presets")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                presetButton("FPS Only", elements: ["fps"])
                presetButton("Full", elements: allElements.map { $0.key })
                presetButton("Rich", elements: ["fps", "gputime", "memory", "thermal", "shaders"])
                presetButton("Default", elements: [
                    "device",
                    "rosetta",
                    "layersize",
                    "memory",
                    "gamemode",
                    "fps",
                    "gputime",
                    "frameinterval",
                    "frameintervalgraph"
                ])
            }

            Divider().padding(.vertical, 4)

            // MARK: - Elements
            Text("Elements")
                .font(.headline)

            #if os(macOS)
            AlwaysVisibleScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(allElements) { element in
                        Toggle(element.label, isOn: Binding(
                            get: { settings.selectedElements.contains(element.key) },
                            set: { newValue in
                                if newValue { settings.selectedElements.insert(element.key) }
                                else { settings.selectedElements.remove(element.key) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
            }
            .frame(height: 180)
            #else
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(allElements) { element in
                        Toggle(element.label, isOn: Binding(
                            get: { settings.selectedElements.contains(element.key) },
                            set: { newValue in
                                if newValue { settings.selectedElements.insert(element.key) }
                                else { settings.selectedElements.remove(element.key) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(height: 180)
            #endif

            Divider().padding(.vertical, 4)

            // MARK: - Sliders and Alignment
            Group {
                HStack {
                    Text("Scale: \(String(format: "%.2f", settings.scale))")
                    Slider(value: $settings.scale, in: 0.05...1.0, step: 0.01)
                }
                HStack {
                    Text("Opacity: \(Int(settings.opacity * 100))%")
                    Slider(value: $settings.opacity, in: 0.1...1.0, step: 0.01)
                }

                Picker("Location", selection: $settings.alignment) {
                    ForEach(alignments) { a in
                        Text(a.name).tag(a.key)
                    }
                }
                .pickerStyle(.menu)
            }

            Divider().padding(.vertical, 4)

            // MARK: - Launch settings
            Toggle("Open at Login", isOn: $settings.openAtLogin)
                .toggleStyle(.switch)

            Toggle("Enable HUD on Boot", isOn: $settings.enableHUDOnBoot)
                .toggleStyle(.switch)
                .disabled(!settings.openAtLogin)
                .foregroundStyle(settings.openAtLogin ? .primary : .secondary)

            Divider().padding(.vertical, 4)

            // MARK: - Action buttons
            HStack {
                Button("Apply") { settings.applySettings() }
                    .buttonStyle(.borderedProminent)
                Button("Disable HUD") { settings.disableHUD() }
                Spacer()
                Button("Quit App") { NSApplication.shared.terminate(nil) }
            }

            if !settings.statusMessage.isEmpty {
                Text(settings.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            Spacer()
        }
        .padding(16)
        .frame(width: 310)
    }

    // MARK: - Preset Buttons
    private func presetButton(_ name: String, elements: [String]) -> some View {
        Button(name) {
            selectedPreset = name
            settings.selectedElements = Set(elements)
        }
        .buttonStyle(.borderless)
    }
}

#if os(macOS)
import AppKit

struct AlwaysVisibleScrollView<Content: View>: NSViewRepresentable {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = hosting

        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])

        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let hosting = nsView.documentView as? NSHostingView<Content> {
            hosting.rootView = content
        }
    }
}
#endif
