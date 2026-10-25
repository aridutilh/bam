import AppKit

/// Register before acquiring: a second launch can request focus while the first
/// is still constructing its window. Delivery waits for the main run loop.
@MainActor final class ProfileInstance: NSObject {
    private static let activation = Notification.Name("com.ari.orbitprototype.activateProfile")
    private let lock = ProfileLock()
    private var identity: String?
    var onActivation: (() -> Void)?

    static func activate(window: NSWindow?) {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func start(in directory: URL, ephemeral: Bool) throws -> Bool {
        guard !ephemeral else { return true }
        let identity = ProfileLock.identity(for: directory).path
        self.identity = identity
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(activateOwner),
            name: Self.activation, object: identity, suspensionBehavior: .deliverImmediately)
        switch try lock.acquire(in: directory) {
        case .acquired: return true
        case .occupied:
            DistributedNotificationCenter.default().postNotificationName(Self.activation,
                object: identity, userInfo: nil, deliverImmediately: true)
            return false
        }
    }

    @objc private func activateOwner(_ notification: Notification) {
        guard lock.isHeld, notification.object as? String == identity else { return }
        onActivation?()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        // Hold through AppKit/WebKit shutdown; the kernel also closes the
        // descriptor on normal exit or process death, including SIGKILL.
    }
}
