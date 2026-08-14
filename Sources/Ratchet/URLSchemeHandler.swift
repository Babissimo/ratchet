// Sources/Ratchet/URLSchemeHandler.swift
import AppKit
import FreeAgentKit

/// Registers for the ratchet:// custom URL scheme via the classic
/// NSAppleEventManager mechanism (the reliable way to receive a
/// custom-scheme open on macOS, independent of full app-lifecycle timing)
/// and exposes an async "wait for the next callback URL" API.
///
/// `@MainActor`-isolated because `pending` below is shared mutable state touched from two
/// directions: `waitForCallback` (previously a nonisolated `async` method, so it ran on the
/// generic executor and wrote the property *off* the main thread) and `handleGetURLEvent` (the
/// AppleEvent handler, always main-thread). A callback landing in that window could resume the
/// continuation twice — a crash — or drop it, hanging the login forever behind
/// `StatusItemController`'s `isLoggingIn` guard and permanently disabling the Log In item.
@MainActor
public final class URLSchemeHandler {
    /// The in-flight `waitForCallback`, if any: the continuation to resume, plus the timeout
    /// that must be cancelled the moment it is.
    private struct PendingCallback {
        let continuation: CheckedContinuation<URL, Error>
        let timeout: DispatchWorkItem
    }

    private var pending: PendingCallback?

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
        // A second wait while one is already in flight would strand the first continuation,
        // which never resumes. Callers are already serialized by `isLoggingIn`, so this is
        // belt-and-braces — but silently leaking a continuation is not an acceptable failure.
        if let existing = pending {
            existing.timeout.cancel()
            pending = nil
            existing.continuation.resume(throwing: FreeAgentError.authCancelled)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.resumePending(with: .failure(FreeAgentError.authTimedOut))
            }
            pending = PendingCallback(continuation: continuation, timeout: work)
            // Cancelled as soon as the callback arrives. Left armed (as it used to be) it would
            // fire long after this login finished and resume whatever continuation happened to
            // be pending *then* — killing a later, still-active login attempt with a spurious
            // "timed out".
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        // Only OAuth callbacks consume the pending login. Any other ratchet:// URL delivered
        // mid-login used to claim the continuation and abort the attempt, since it carries no
        // `code` — so a stray deep link (or another local app opening one) cancelled the login.
        guard Self.isOAuthCallback(url) else { return }
        resumePending(with: .success(url))
    }

    // Parsed once from `FreeAgentAuthenticator.redirectURI` rather than re-parsed per event —
    // it's the OAuth `redirect_uri` sent to FreeAgent and never changes at runtime, so this is
    // the single source of truth `isOAuthCallback` compares against instead of duplicating the
    // scheme/host as separate literals.
    private static let expectedCallback = URL(string: FreeAgentAuthenticator.redirectURI)

    /// Derived from `FreeAgentAuthenticator.redirectURI` at runtime, so the two can't drift apart.
    /// The `state` nonce is still checked downstream by the authenticator; this is only about
    /// which URLs are allowed to end the wait.
    private static func isOAuthCallback(_ url: URL) -> Bool {
        guard let expected = expectedCallback else { return false }
        guard url.scheme?.lowercased() == expected.scheme?.lowercased() else { return false }
        // "ratchet://callback" parses with "callback" as the host and an empty path, but tolerate
        // the path spelling too rather than depending on that parse.
        let host = url.host?.lowercased()
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let expectedHost = expected.host?.lowercased()
        let expectedPath = expected.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return host == expectedHost || (host?.isEmpty ?? true) && path == expectedPath
    }

    /// Resumes the pending continuation exactly once and disarms its timeout.
    private func resumePending(with result: Result<URL, Error>) {
        guard let current = pending else { return }
        pending = nil
        current.timeout.cancel()
        current.continuation.resume(with: result)
    }
}
