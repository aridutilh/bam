import AppKit

/// Register before acquiring: a second launch can request focus while the first
/// is still constructing its window. Delivery waits for the main run loop.
@MainActor final class ProfileInstance: NSObject {
    private static let activation = Notification.Name("com.ari.orbitprototype.activateProfile")
    private static let acknowledgment = Notification.Name("com.ari.orbitprototype.profileLaunchAccepted")
    private let lock = ProfileLock()
    private var identity: String?
    var onActivation: (() -> Void)?
    var onOpenURLs: (([URL]) -> Void)?
    private struct Request {
        let urls: [String]
        let deadline: Date
    }
    private var requests: [UUID: Request] = [:]
    private var accepted: [UUID: Date] = [:]
    private var timer: Timer?
    private var settleAfter = Date.distantFuture
    private var completed: (() -> Void)?
    private var failed: (() -> Void)?

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
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(acknowledge),
            name: Self.acknowledgment, object: identity, suspensionBehavior: .deliverImmediately)
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
        guard let rawID = notification.userInfo?["request"] as? String,
              let requestID = UUID(uuidString: rawID) else { onActivation?(); return }
        guard let rawURLs = notification.userInfo?["urls"] as? [String] else { return }
        // Retries retain the same request ID, while two deliberate opens of
        // the same URL are separate requests and must both be delivered.
        accepted = accepted.filter { $0.value > Date() }
        if accepted[requestID] == nil {
            let urls = rawURLs.compactMap(URL.init(string:))
            guard urls.count == rawURLs.count, urls.isEmpty || onOpenURLs != nil else { return }
            accepted[requestID] = Date().addingTimeInterval(60)
            if !urls.isEmpty { onOpenURLs?(urls) }
            onActivation?()
        }
        DistributedNotificationCenter.default().postNotificationName(Self.acknowledgment,
            object: identity, userInfo: ["request": rawID], deliverImmediately: true)
    }

    /// Keep the duplicate's event loop alive for initial/late launch Apple
    /// events. Only terminate after all requests were accepted by the owner
    /// and the launch has been quiet for one second. No controller/store opens.
    func beginHandoff(completed: @escaping () -> Void, failed: @escaping () -> Void) {
        precondition(!lock.isHeld && identity != nil && timer == nil)
        self.completed = completed
        self.failed = failed
        forwardURLs([]) // Acknowledge focus-only launches too.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryHandoff() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func forwardURLs(_ urls: [URL]) {
        precondition(!lock.isHeld && completed != nil)
        let id = UUID()
        requests[id] = Request(urls: urls.map(\.absoluteString), deadline: Date().addingTimeInterval(5))
        settleAfter = Date().addingTimeInterval(1)
        send(id)
    }

    private func send(_ id: UUID) {
        guard let request = requests[id] else { return }
        DistributedNotificationCenter.default().postNotificationName(Self.activation,
            object: identity, userInfo: ["request": id.uuidString, "urls": request.urls], deliverImmediately: true)
    }

    @objc private func acknowledge(_ notification: Notification) {
        guard !lock.isHeld, notification.object as? String == identity,
              let id = notification.userInfo?["request"] as? String,
              let uuid = UUID(uuidString: id) else { return }
        requests.removeValue(forKey: uuid)
    }

    private func retryHandoff() {
        if requests.values.contains(where: { $0.deadline <= Date() }) {
            timer?.invalidate(); timer = nil
            failed?()
        } else if requests.isEmpty && Date() >= settleAfter {
            timer?.invalidate(); timer = nil
            completed?()
        } else {
            for id in Array(requests.keys) { send(id) }
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        // Hold through AppKit/WebKit shutdown; the kernel also closes the
        // descriptor on normal exit or process death, including SIGKILL.
    }
}
