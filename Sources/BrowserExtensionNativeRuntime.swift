import Foundation
import WebKit

@available(macOS 15.4, *)
@MainActor extension BrowserExtensionRuntime {
    func approvedNativeHost(_ context: WKWebExtensionContext) -> ExtensionNativeMessaging.Host? {
        guard owns(context), context.isLoaded, let id = UUID(uuidString: context.uniqueIdentifier), contexts[id] === context,
              context.hasPermission(.init(rawValue: "nativeMessaging")),
              context.webExtension.requestedPermissions.contains(.init(rawValue: "nativeMessaging")),
              let record = owner?.records.first(where: { $0.id == id && $0.profileID == profileID }),
              record.enabled, BrowserExtensions.supportsNativeCompanion(record) else { return nil }
        return record.nativeHost
    }
    func disconnectNative(_ context: WKWebExtensionContext) {
        for session in Array(nativeSessions.values) where session.context === context { session.finish(error: BrowserExtensions.failure("The extension’s desktop connection was closed.")) }
    }
    func disconnectAllNative() {
        for session in Array(nativeSessions.values) { session.finish(error: BrowserExtensions.failure("Bam closed the desktop connection.")) }
    }
    private func makeNativeSession(_ context: WKWebExtensionContext) throws -> BrowserExtensionNativeSession {
        guard let host = approvedNativeHost(context), let owner else {
            throw BrowserExtensions.failure("Connect the verified Chrome 1Password extension to its desktop app from Bam’s extension manager first.")
        }
        guard nativeSessions.count < 16, nativeSessions.values.filter({ $0.context === context }).count < 4 else {
            throw BrowserExtensions.failure("This extension has reached its desktop connection limit.")
        }
        let session = BrowserExtensionNativeSession(runtime: self, context: context, host: host, policy: owner.nativeMessagingPolicy)
        nativeSessions[session.id] = session
        return session
    }
    func sendNative(_ message: Any, context: WKWebExtensionContext, reply: @escaping (Any?, Error?) -> Void) {
        do { try makeNativeSession(context).start(message: message, reply: reply) }
        catch { reply(nil, error) }
    }
    func connectNative(_ port: WKWebExtension.MessagePort, context: WKWebExtensionContext, completion: @escaping (Error?) -> Void) {
        do { try makeNativeSession(context).start(port: port, completion: completion) }
        catch { completion(error) }
    }
}

/// One port or one-shot request. The runtime owns it until close, including while
/// asynchronous signature checks are pending. Closing never depends on a popup.
@available(macOS 15.4, *)
@MainActor final class BrowserExtensionNativeSession {
    let id = UUID()
    weak var context: WKWebExtensionContext?
    private weak var runtime: BrowserExtensionRuntime?
    private let host: ExtensionNativeMessaging.Host
    private let policy: ExtensionNativeMessaging
    private var connection: ExtensionNativeMessagingConnection?
    private var port: WKWebExtension.MessagePort?
    private var reply: ((Any?, Error?) -> Void)?
    private var completion: ((Error?) -> Void)?
    private var connecting: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var closed = false
    private var ready = false
    private var startupMessages: [Any] = []
    private var startupBytes = 0
    private var startupClose: Error?

    init(runtime: BrowserExtensionRuntime, context: WKWebExtensionContext, host: ExtensionNativeMessaging.Host, policy: ExtensionNativeMessaging) {
        self.runtime = runtime; self.context = context; self.host = host; self.policy = policy
    }
    private var authorized: Bool {
        guard !closed, let context, let runtime else { return false }
        return runtime.approvedNativeHost(context) == host
    }
    func start(message: Any, reply: @escaping (Any?, Error?) -> Void) {
        self.reply = reply
        connect(initialMessage: message)
    }
    func start(port: WKWebExtension.MessagePort, completion: @escaping (Error?) -> Void) {
        self.port = port; self.completion = completion
        port.disconnectHandler = { [weak self] error in self?.finish(error: error) }
        port.messageHandler = { [weak self] message, error in
            guard let self, self.authorized, let connection = self.connection, error == nil, let message else {
                self?.finish(error: error ?? BrowserExtensions.failure("The desktop connection is unavailable.")); return
            }
            Task { @MainActor [weak self] in
                do { try await connection.send(message) }
                catch { self?.finish(error: error) }
            }
        }
        connect(initialMessage: nil)
    }
    private func connect(initialMessage: Any?) {
        // Bound both handshake and one-shot waits. An established port may remain
        // open while its extension is enabled; unload/revoke closes it promptly.
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            self?.finish(error: BrowserExtensions.failure("The desktop app did not respond in time."))
        }
        connecting = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let connection = try await ExtensionNativeMessagingConnection.connect(host: self.host, policy: self.policy,
                    authority: { [weak self] in self?.authorized == true },
                    onMessage: { [weak self] value in self?.receive(value) },
                    onClose: { [weak self] error in self?.hostClosed(error) })
                guard self.authorized else { connection.close(); self.finish(error: BrowserExtensions.failure("Desktop-app access was revoked.")); return }
                self.connection = connection
                if let initialMessage { try await connection.send(initialMessage) }
                else {
                    self.deadline?.cancel(); self.deadline = nil
                    let completion = self.completion; self.completion = nil; completion?(nil)
                }
                self.ready = true
                let pending = self.startupMessages; self.startupMessages.removeAll(); self.startupBytes = 0
                for value in pending where !self.closed { self.receive(value) }
                if let error = self.startupClose, !self.closed { self.finish(error: error) }
                self.startupClose = nil
            } catch { self.finish(error: error) }
            self.connecting = nil
        }
    }
    private func hostClosed(_ error: Error?) {
        let error = error ?? BrowserExtensions.failure("The desktop app closed the connection.")
        // EOF may reach this actor while the successful request write is still
        // resuming. Keep its final reply ahead of close, just as the pipe did.
        if !ready && !closed { startupClose = error }
        else { finish(error: error) }
    }
    private func receive(_ message: Any) {
        guard authorized else { finish(error: BrowserExtensions.failure("Desktop-app access was revoked.")); return }
        if !ready {
            guard let size = try? ExtensionNativeMessageDecoder.encode(message).count,
                  startupMessages.count < 64, size <= 4_194_304 - startupBytes else {
                finish(error: BrowserExtensions.failure("The desktop app exceeded the startup message limit.")); return
            }
            startupMessages.append(message); startupBytes += size; return
        }
        if reply != nil { finish(value: message); return }
        port?.sendMessage(message) { [weak self] error in if let error { self?.finish(error: error) } }
    }
    func finish(value: Any? = nil, error: Error? = nil) {
        guard !closed else { return }; closed = true
        startupMessages.removeAll(); startupBytes = 0; startupClose = nil
        connecting?.cancel(); connecting = nil; deadline?.cancel(); deadline = nil
        let port = self.port; self.port = nil; port?.messageHandler = nil; port?.disconnectHandler = nil
        let reply = self.reply; self.reply = nil
        let completion = self.completion; self.completion = nil
        connection?.close(error: error); connection = nil
        runtime?.nativeSessions.removeValue(forKey: id)
        port?.disconnect(throwing: error)
        completion?(error ?? BrowserExtensions.failure("The desktop connection closed before it was ready."))
        reply?(value, error)
    }
}
