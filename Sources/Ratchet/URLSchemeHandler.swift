// Sources/Ratchet/URLSchemeHandler.swift
import AppKit
import FreeAgentKit

/// Registers for the ratchet:// custom URL scheme via the classic
/// NSAppleEventManager mechanism (the reliable way to receive a
/// custom-scheme open on macOS, independent of full app-lifecycle timing)
/// and exposes an async "wait for the next callback URL" API.
public final class URLSchemeHandler {
    private var continuation: CheckedContinuation<URL, Error>?

    public init() {}

    public func register() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    public func waitForCallback(timeout: TimeInterval) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let pending = self.continuation else { return }
                self.continuation = nil
                pending.resume(throwing: FreeAgentError.authTimedOut)
            }
        }
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        continuation?.resume(returning: url)
        continuation = nil
    }
}
