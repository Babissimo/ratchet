// Sources/Ratchet/AppDelegate.swift
import AppKit
import RatchetCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: PlaceholderStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = PlaceholderStatusItem()
    }
}
