import AppKit

public final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    public init(title: String, handler: @escaping () -> Void, keyEquivalent: String = "") {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: keyEquivalent)
        self.target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler()
    }
}
