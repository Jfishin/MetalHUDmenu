//
//  MetalHUDMenuApp.swift
//  MetalHUDMenu
//

import SwiftUI

@main
struct MetalHUDMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings {} // no default window
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSDraggingDestination {
    var statusItem: NSStatusItem!
    var popover = NSPopover()
    let settings = HUDSettingsManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "Metal HUD")
            button.action = #selector(togglePopover)
            // Drop an app on the icon to pin it. The window forwards drag events to its delegate.
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = self
        }

        // Setup popover; it takes each tab's own size
        let content = NSHostingController(rootView: ContentView(settings: settings))
        content.sizingOptions = .preferredContentSize
        popover.behavior = .transient
        popover.contentViewController = content

        // Auto-apply HUD settings on boot if enabled
        settings.applyOnBootIfNeeded()

        // Mac stats: install files, watch Steam
        StatsHelper.shared.start()
    }

    // Dragging over the icon opens the menu on Games, so the app can also be dropped there.
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        UserDefaults.standard.set("Games", forKey: "tab")
        if !popover.isShown { togglePopover() }
        return .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        urls.forEach { GeneralConnections.shared.addPin(url: $0) }
        return !urls.isEmpty
    }

    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }
}
