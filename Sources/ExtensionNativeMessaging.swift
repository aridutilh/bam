import Foundation
import CryptoKit
import Security
import Darwin

struct ExtensionNativeMessagingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The first supported external host is deliberately one vendor and one verified
/// Chrome extension. The caller must authenticate its loaded extension context
/// and a current, profile-specific grant before using this transport.
struct ExtensionNativeMessaging: Sendable {
    static let applicationIdentifier = "com.1password.1password"
    static let chromeExtensionIdentifier = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
    static let origin = "chrome-extension://\(chromeExtensionIdentifier)/"
    static let vendorTeamIdentifier = "2BUA8C4S2C"
    // 1Password's documented BrowserSupport helper role. A future layout change
    // needs a reviewed adapter change; a different signed helper is not enough.
    static let helperRelativePath = "Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password-BrowserSupport"
    static let maximumMessageBytes = 1_048_576

    struct SigningIdentity: Equatable, Sendable {
        let identifier: String
        let teamIdentifier: String
        let codeHash: String
    }

    /// Persist only this metadata/fingerprint, never messages or host stderr.
    struct Host: Codable, Equatable, Sendable {
        let manifestURL: URL
        let executableURL: URL
        let applicationURL: URL
        let manifestSHA256: String
        let applicationCodeHash: String
        let executableCodeHash: String
        let executableIdentifier: String
        let teamIdentifier: String

        var approvalFingerprint: String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(self)).map(ExtensionNativeMessaging.digest) ?? ""
        }
    }

    typealias SignatureValidator = @Sendable (URL) throws -> SigningIdentity
    private let directories: [URL]
    private let signatureValidator: SignatureValidator
    private let browserValidator: @Sendable () throws -> Void
    private static let metadataLimit = 65_536

    init(searchDirectories: [URL]? = nil,
         signatureValidator: @escaping SignatureValidator = { try Self.signingIdentity(at: $0) },
         browserValidator: @escaping @Sendable () throws -> Void = { _ = try Self.signingIdentity(at: Bundle.main.bundleURL) }) {
        directories = searchDirectories ?? [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true),
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts", isDirectory: true)
        ]
        self.signatureValidator = signatureValidator; self.browserValidator = browserValidator
    }

    /// Reads only the named registration and installed app metadata. No host runs.
    /// A present invalid user registration fails closed instead of falling back
    /// to a different system registration with a different executable.
    func discover() throws -> Host {
        for directory in directories {
            let url = directory.appendingPathComponent(Self.applicationIdentifier + ".json")
            if FileManager.default.fileExists(atPath: url.path) { return try inspect(url) }
        }
        throw Self.failure("Install the official 1Password desktop app and its browser integration before connecting it to Bam.")
    }

    func validate(_ host: Host) throws {
        guard try discover() == host else { throw Self.failure("The 1Password native host changed. Review its connection again before continuing.") }
    }

    func validateBrowser() throws { try browserValidator() }

    private func inspect(_ registration: URL) throws -> Host {
        let data = try Self.readMetadata(registration)
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["name"] as? String == Self.applicationIdentifier,
              manifest["type"] as? String == "stdio",
              let origins = manifest["allowed_origins"] as? [String], origins.contains(Self.origin),
              let path = manifest["path"] as? String, path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else {
            throw Self.failure("The 1Password registration does not authorize the official Chrome extension or has an invalid native-host definition.")
        }
        let executable = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
        guard values.isRegularFile == true, values.isExecutable == true else { throw Self.failure("The registered 1Password native host is not a regular executable.") }
        var ancestor = executable.deletingLastPathComponent()
        var app: URL?
        while ancestor.path != "/" {
            if ancestor.pathExtension == "app",
               let data = try? Self.readMetadata(ancestor.appendingPathComponent("Contents/Info.plist")),
               let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               info["CFBundleIdentifier"] as? String == Self.applicationIdentifier { app = ancestor; break }
            ancestor.deleteLastPathComponent()
        }
        guard let app else { throw Self.failure("The native host must belong to the installed 1Password app.") }
        guard executable == app.appendingPathComponent(Self.helperRelativePath).standardizedFileURL else {
            throw Self.failure("This 1Password registration uses an unrecognized native-helper layout. Bam only supports the verified BrowserSupport helper.")
        }
        let resolvedRegistration = registration.standardizedFileURL.resolvingSymlinksInPath()
        if registration.standardizedFileURL != resolvedRegistration {
            guard Self.isWithin(resolvedRegistration, app) else { throw Self.failure("The native-host registration links outside the signed 1Password app.") }
        }
        let appIdentity = try signatureValidator(app), executableIdentity = try signatureValidator(executable)
        guard appIdentity.identifier == Self.applicationIdentifier,
              appIdentity.teamIdentifier == Self.vendorTeamIdentifier,
              executableIdentity.teamIdentifier == Self.vendorTeamIdentifier,
              !appIdentity.codeHash.isEmpty, !executableIdentity.codeHash.isEmpty,
              !executableIdentity.identifier.isEmpty else {
            throw Self.failure("The native host and containing app must have valid official 1Password signatures.")
        }
        return Host(manifestURL: registration.standardizedFileURL, executableURL: executable, applicationURL: app,
                    manifestSHA256: Self.digest(data), applicationCodeHash: appIdentity.codeHash,
                    executableCodeHash: executableIdentity.codeHash, executableIdentifier: executableIdentity.identifier,
                    teamIdentifier: executableIdentity.teamIdentifier)
    }

    private static func readMetadata(_ url: URL) throws -> Data {
        let resolved = url.resolvingSymlinksInPath()
        let info = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, size <= metadataLimit else { throw failure("Native-host metadata must be a regular file no larger than 64 KiB.") }
        let handle = try FileHandle(forReadingFrom: resolved); defer { try? handle.close() }
        let data = try handle.read(upToCount: metadataLimit + 1) ?? Data()
        guard data.count <= metadataLimit else { throw failure("Native-host metadata exceeds 64 KiB.") }
        return data
    }

    private static func isWithin(_ child: URL, _ parent: URL) -> Bool { child.path.hasPrefix(parent.path + "/") }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func failure(_ text: String) -> ExtensionNativeMessagingError { .init(message: text) }

    /// Apple-anchored signatures are mandatory. Ad-hoc signing is insufficient
    /// for both vendor-host authentication and 1Password's browser trust flow.
    static func signingIdentity(at url: URL) throws -> SigningIdentity {
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
            throw failure("An intact Apple-issued code signature is required. Ad-hoc development builds cannot establish this native-app connection.")
        }
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any], let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
              let hash = info[kSecCodeInfoUnique as String] as? Data else { throw failure("The native app's signing identity is incomplete.") }
        return SigningIdentity(identifier: identifier, teamIdentifier: team, codeHash: hash.map { String(format: "%02x", $0) }.joined())
    }
}

/// A streaming native-endian UInt32 + UTF-8 JSON codec. It rejects an oversized
/// length as soon as its four-byte header arrives, before allocating its body.
struct ExtensionNativeMessageDecoder {
    private var buffered = Data()
    private var expected: Int?
    var isEmpty: Bool { buffered.isEmpty && expected == nil }

    mutating func append(_ bytes: Data) throws -> [Data] {
        guard bytes.count <= 65_536 else { throw ExtensionNativeMessaging.failure("Native-host read exceeded its chunk limit.") }
        buffered.append(bytes)
        var messages: [Data] = []
        while true {
            if expected == nil {
                guard buffered.count >= 4 else { break }
                let size = buffered.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                guard size > 0, size <= ExtensionNativeMessaging.maximumMessageBytes else { throw ExtensionNativeMessaging.failure("The native host sent an invalid or oversized message.") }
                buffered.removeFirst(4); expected = Int(size)
            }
            guard let count = expected, buffered.count >= count else { break }
            messages.append(Data(buffered.prefix(count))); buffered.removeFirst(count); expected = nil
        }
        return messages
    }

    static func encode(_ message: Any) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        guard !data.isEmpty, data.count <= ExtensionNativeMessaging.maximumMessageBytes else { throw ExtensionNativeMessaging.failure("Native messages cannot exceed 1 MiB.") }
        var size = UInt32(data.count)
        var result = withUnsafeBytes(of: &size) { Data($0) }; result.append(data); return result
    }
}

/// The authority closure must check the exact loaded context, controller,
/// profile, official package provenance, and currently reviewed host fingerprint.
/// It runs before launching, sending, and delivering every received message.
@MainActor final class ExtensionNativeMessagingConnection {
    private var process: NativeMessagingProcess?
    private let authority: () -> Bool
    private var onMessage: ((Any) -> Void)?
    private var onClose: ((Error?) -> Void)?
    private var closed = false
    var isClosed: Bool { closed }
    var processIdentifier: Int32? { process?.identifier }

    private init(authority: @escaping () -> Bool, onMessage: @escaping (Any) -> Void, onClose: @escaping (Error?) -> Void) {
        self.authority = authority; self.onMessage = onMessage; self.onClose = onClose
    }

    static func connect(host: ExtensionNativeMessaging.Host, policy: ExtensionNativeMessaging = .init(),
                        authority: @escaping () -> Bool, onMessage: @escaping (Any) -> Void,
                        onClose: @escaping (Error?) -> Void) async throws -> ExtensionNativeMessagingConnection {
        guard authority() else { throw ExtensionNativeMessaging.failure("Native-app access is no longer allowed for this extension and profile.") }
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) { try policy.validateBrowser(); try policy.validate(host) }.value
        try Task.checkCancellation()
        guard authority() else { throw ExtensionNativeMessaging.failure("Native-app access was revoked before connecting.") }
        let connection = ExtensionNativeMessagingConnection(authority: authority, onMessage: onMessage, onClose: onClose)
        connection.process = try NativeMessagingProcess(executable: host.executableURL, arguments: [ExtensionNativeMessaging.origin],
            onMessage: { [weak connection] data, acknowledge in
                Task { @MainActor [weak connection] in
                    defer { acknowledge() }
                    guard let connection, !connection.closed else { return }
                    guard connection.authority() else { connection.close(error: ExtensionNativeMessaging.failure("Native-app access was revoked.")); return }
                    do { connection.onMessage?(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) }
                    catch { connection.close(error: ExtensionNativeMessaging.failure("The native host sent invalid JSON.")) }
                }
            }, onClose: { [weak connection] error in Task { @MainActor in connection?.close(error: error) } })
        return connection
    }

    func send(_ message: Any) async throws {
        guard !closed, authority(), let process else {
            close(error: ExtensionNativeMessaging.failure("Native-app access is no longer allowed."))
            throw ExtensionNativeMessaging.failure("The native-app connection is closed or revoked.")
        }
        let frame = try ExtensionNativeMessageDecoder.encode(message)
        try await withTaskCancellationHandler(operation: { try Task.checkCancellation(); try await process.send(frame) },
            onCancel: { process.close(error: CancellationError()) })
    }

    func close(error: Error? = nil) {
        guard !closed else { return }; closed = true
        process?.close(error: error); process = nil
        let callback = onClose; onClose = nil; onMessage = nil
        callback?(error)
    }
    deinit { process?.close(error: nil) }
}

/// All pipe/process state lives on one serial queue. Nonblocking writes prevent
/// an unresponsive host from blocking the UI; both directions have fixed budgets.
private final class NativeMessagingProcess: @unchecked Sendable {
    let identifier: Int32
    private let child: Process
    private let queue = DispatchQueue(label: "com.ari.bam.native-messaging", qos: .utility)
    private let input: FileHandle
    private let output: FileHandle
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var writerActive = false
    private var decoder = ExtensionNativeMessageDecoder()
    private var closed = false
    private var pending: [(Data, Int, CheckedContinuation<Void, Error>)] = []
    private var pendingBytes = 0
    private var deliveries = 0, deliveryBytes = 0
    private var closeNotificationPending = false
    private var closeError: Error?
    private let onMessage: @Sendable (Data, @escaping @Sendable () -> Void) -> Void
    private let onClose: @Sendable (Error?) -> Void

    init(executable: URL, arguments: [String],
         onMessage: @escaping @Sendable (Data, @escaping @Sendable () -> Void) -> Void,
         onClose: @escaping @Sendable (Error?) -> Void) throws {
        self.onMessage = onMessage; self.onClose = onClose
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable; child.arguments = arguments
        child.currentDirectoryURL = executable.deletingLastPathComponent()
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        // No shell, browser debug environment, or inherited injected libraries.
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                             "TMPDIR": FileManager.default.temporaryDirectory.path, "LANG": "en_US.UTF-8"]
        try child.run()
        self.child = child; identifier = child.processIdentifier
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
        let inputFlags = fcntl(input.fileDescriptor, F_GETFL), outputFlags = fcntl(output.fileDescriptor, F_GETFL)
        _ = fcntl(input.fileDescriptor, F_SETFL, inputFlags | O_NONBLOCK)
        _ = fcntl(output.fileDescriptor, F_SETFL, outputFlags | O_NONBLOCK)
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        child.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async { [self] in
                self.readAvailable()
                if !self.closed { self.finish(child.terminationStatus == 0 ? nil : ExtensionNativeMessaging.failure("The native host exited unexpectedly.")) }
            }
        }
        queue.async { [self] in
            guard !closed else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: output.fileDescriptor, queue: queue)
            reader = source
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { [output] in try? output.close() }
            source.resume()
            let writeSource = DispatchSource.makeWriteSource(fileDescriptor: input.fileDescriptor, queue: queue)
            writer = writeSource
            writeSource.setEventHandler { [weak self] in self?.writeAvailable() }
            writeSource.setCancelHandler { [input] in try? input.close() }
        }
    }

    func send(_ frame: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !closed else { continuation.resume(throwing: ExtensionNativeMessaging.failure("The native-app connection is closed.")); return }
                guard pending.count < 64, frame.count <= 4_194_304 - pendingBytes else {
                    continuation.resume(throwing: ExtensionNativeMessaging.failure("The native host is not consuming messages."))
                    finish(ExtensionNativeMessaging.failure("The native host exceeded the outgoing queue limit.")); return
                }
                pending.append((frame, 0, continuation)); pendingBytes += frame.count
                writeAvailable()
            }
        }
    }
    func close(error: Error?) { queue.async { [self] in finish(error) } }

    private func writeAvailable() {
        guard !closed else { return }
        while !pending.isEmpty {
            let item = pending[0]
            let count = item.0.withUnsafeBytes { Darwin.write(input.fileDescriptor, $0.baseAddress!.advanced(by: item.1), item.0.count - item.1) }
            if count > 0 {
                pending[0].1 += count; pendingBytes -= count
                if pending[0].1 == item.0.count { pending.removeFirst().2.resume() }
            } else if count < 0 && errno == EINTR { continue }
            else if count < 0 && [EAGAIN, EWOULDBLOCK].contains(errno) {
                if !writerActive { writerActive = true; writer?.resume() }
                return
            } else { finish(ExtensionNativeMessaging.failure("The native host closed its input.")); return }
        }
        if writerActive { writerActive = false; writer?.suspend() }
    }

    private func readAvailable() {
        guard !closed else { return }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while !closed {
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                do {
                    for message in try decoder.append(Data(bytes.prefix(count))) {
                        guard deliveries < 64, message.count <= 4_194_304 - deliveryBytes else { throw ExtensionNativeMessaging.failure("The native host exceeded the incoming queue limit.") }
                        deliveries += 1; deliveryBytes += message.count
                        onMessage(message) { [weak self] in
                            guard let self else { return }
                            self.queue.async { [self] in
                                self.deliveries -= 1; self.deliveryBytes -= message.count
                                self.notifyClosedIfDrained()
                            }
                        }
                    }
                } catch { finish(error) }
            } else if count == 0 {
                finish(decoder.isEmpty ? nil : ExtensionNativeMessaging.failure("The native host ended partway through a message.")); return
            } else if errno == EINTR { continue }
            else if [EAGAIN, EWOULDBLOCK].contains(errno) { return }
            else { finish(ExtensionNativeMessaging.failure("Could not read the native host's response.")); return }
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }; closed = true
        if let reader { reader.cancel() } else { try? output.close() }
        reader = nil
        if let writer {
            if !writerActive { writer.resume() }
            writer.cancel()
        } else { try? input.close() }
        writer = nil; writerActive = false
        for item in pending { item.2.resume(throwing: error ?? ExtensionNativeMessaging.failure("The native-app connection closed.")) }
        pending.removeAll(); pendingBytes = 0
        if child.isRunning {
            child.terminate()
            let child = child
            queue.asyncAfter(deadline: .now() + 1) { if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) } }
        }
        child.terminationHandler = nil
        closeError = error; closeNotificationPending = true
        notifyClosedIfDrained()
    }
    private func notifyClosedIfDrained() {
        guard closeNotificationPending, deliveries == 0 else { return }
        closeNotificationPending = false; onClose(closeError)
    }
}
