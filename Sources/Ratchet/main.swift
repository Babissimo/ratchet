// Sources/Ratchet/main.swift
import AppKit

// Top-level code genuinely runs on the main thread, but the compiler types it as nonisolated,
// so constructing the main-actor-isolated AppDelegate needs that fact stated explicitly.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    // NSApplication references its delegate weakly. `delegate` is kept alive by staying in
    // scope across the run() call below, which never returns.
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
