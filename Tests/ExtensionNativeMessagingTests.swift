import Foundation
import CryptoKit
import Darwin

@main enum ExtensionNativeMessagingTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static var checks = 0

    static func main() async {
        if CommandLine.arguments.dropFirst().first == ExtensionNativeMessaging.origin { runHost(); return }
        do {
            try await run()
            print("PASS: External native messaging — \(checks) checks")
        } catch {
            FileHandle.standardError.write(Data("FAIL: External native messaging — \(error)\n".utf8)); exit(1)
        }
    }
    @MainActor static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }; checks += 1
    }
    @MainActor static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        throw Failure(description: message)
    }
    @MainActor static func wait(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { checks += 1; return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(description: "Timed out: " + label)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bam-native-messaging-tests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let executable = app.appendingPathComponent(ExtensionNativeMessaging.helperRelativePath)
        let bin = executable.deletingLastPathComponent()
        let registrations = root.appendingPathComponent("registrations", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: registrations, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let info = app.appendingPathComponent("Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": ExtensionNativeMessaging.applicationIdentifier], format: .xml, options: 0).write(to: info)
        let manifest = registrations.appendingPathComponent(ExtensionNativeMessaging.applicationIdentifier + ".json")
        let modeFile = bin.appendingPathComponent("mode")
        let original: [String: Any] = ["name": ExtensionNativeMessaging.applicationIdentifier, "type": "stdio", "path": executable.path,
                                       "allowed_origins": [ExtensionNativeMessaging.origin, "chrome-extension://another-official-vendor-build/"]]
        func writeManifest(_ value: [String: Any]) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: manifest) }
        func mode(_ text: String) throws { try Data(text.utf8).write(to: modeFile) }
        try writeManifest(original)
        // Test-only identity injection accepts just this generated fixture tree;
        // no unsigned real app or real user's native host is ever executed.
        let policy = ExtensionNativeMessaging(searchDirectories: [registrations], signatureValidator: { url in
            guard [app, executable].contains(url) else { throw Failure(description: "Unexpected signature target") }
            return .init(identifier: url == app ? ExtensionNativeMessaging.applicationIdentifier : "fixture-host",
                         teamIdentifier: ExtensionNativeMessaging.vendorTeamIdentifier,
                         codeHash: hash(try Data(contentsOf: url == app ? info : executable)))
        }, browserValidator: {})
        let host = try policy.discover()
        try check(host.executableURL == executable && host.applicationURL == app && host.approvalFingerprint.count == 64,
                  "Discovery must bind executable, containing app and approval fingerprint")
        try policy.validate(host); checks += 1
        try rejects("Production signatures must reject the unsigned fixture") { _ = try ExtensionNativeMessaging.signingIdentity(at: app) }
        let anotherHelper = bin.appendingPathComponent("AnotherSignedHelper")
        try FileManager.default.copyItem(at: executable, to: anotherHelper)
        try writeManifest(original.merging(["path": anotherHelper.path]) { _, new in new })
        try rejects("A different executable in the vendor app must not impersonate BrowserSupport") { _ = try policy.discover() }
        try writeManifest(original)
        for patch: [String: Any] in [["name": "other.host"], ["type": "http"], ["path": "relative-host"],
                                    ["allowed_origins": ["chrome-extension://*/"]], ["path": "/usr/bin/true"]] {
            try writeManifest(original.merging(patch) { _, new in new })
            try rejects("Invalid native manifest must fail closed") { _ = try policy.discover() }
        }
        try writeManifest(original.merging(["description": "changed registration"]) { _, new in new })
        try rejects("Manifest replacement must invalidate approval") { try policy.validate(host) }
        try writeManifest(original)
        let wrongSigner = ExtensionNativeMessaging(searchDirectories: [registrations], signatureValidator: { _ in
            .init(identifier: ExtensionNativeMessaging.applicationIdentifier, teamIdentifier: "OTHERTEAM", codeHash: "123")
        }, browserValidator: {})
        try rejects("A different signing team must be rejected") { _ = try wrongSigner.discover() }
        let unknown = ExtensionNativeMessaging(searchDirectories: [root.appendingPathComponent("missing")])
        try rejects("Missing host must return a setup error") { _ = try unknown.discover() }
        try Data(repeating: 32, count: 65_537).write(to: manifest)
        try rejects("Oversized native manifests must be bounded") { _ = try policy.discover() }
        try writeManifest(original)

        try codec()

        try mode("echo")
        var allowed = true, messages: [[String: Any]] = [], closes = 0
        let connection = try await ExtensionNativeMessagingConnection.connect(host: host, policy: policy, authority: { allowed },
            onMessage: { if let message = $0 as? [String: Any] { messages.append(message) } }, onClose: { _ in closes += 1 })
        let pid = connection.processIdentifier!
        try await connection.send(["hello": "fixture 🪩"])
        try await wait("framed split response") { messages.count == 1 }
        try check((messages[0]["echo"] as? [String: String])?["hello"] == "fixture 🪩" && messages[0]["origin"] as? String == ExtensionNativeMessaging.origin,
                  "Native process must receive JSON and the exact official Chrome origin argument")
        allowed = false
        do { try await connection.send(["mustNotArrive": true]); throw Failure(description: "Revoked send succeeded") }
        catch is ExtensionNativeMessagingError { checks += 1 }
        try check(connection.isClosed && closes == 1, "Revocation must close and notify once")
        connection.close(); try check(closes == 1, "Repeated close must be idempotent")
        try await wait("revoked owned process reaped") { kill(pid, 0) == -1 && errno == ESRCH }

        try mode("exit-reply")
        var exitMessages = 0, exitClosed = false, closeSawReply = false
        let oneShot = try await ExtensionNativeMessagingConnection.connect(host: host, policy: policy, authority: { true },
            onMessage: { _ in exitMessages += 1 }, onClose: { _ in closeSawReply = exitMessages == 1; exitClosed = true })
        try await oneShot.send(["request": 1])
        try await wait("reply before clean EOF notification") { exitClosed }
        try check(exitMessages == 1 && closeSawReply, "A host that exits immediately must deliver its complete final reply before close")

        for value in ["oversize", "truncated", "invalid-json"] {
            try mode(value)
            var failure: Error?, received = 0
            let bad = try await ExtensionNativeMessagingConnection.connect(host: host, policy: policy, authority: { true },
                onMessage: { _ in received += 1 }, onClose: { failure = $0 })
            try await wait("\(value) disconnect") { bad.isClosed }
            try check(failure != nil && received == 0, "Bad host frames must close without delivering data")
        }

        try mode("unsolicited")
        var receiveAllowed = true, received = 0, receiveClosed = false
        let receiveRevoke = try await ExtensionNativeMessagingConnection.connect(host: host, policy: policy, authority: { receiveAllowed },
            onMessage: { _ in received += 1 }, onClose: { _ in receiveClosed = true })
        receiveAllowed = false
        try await wait("incoming authority recheck") { receiveClosed }
        try check(received == 0 && receiveRevoke.isClosed, "Incoming data must recheck current authorization")

        try mode("ignore-term")
        var ready = false
        let stubborn = try await ExtensionNativeMessagingConnection.connect(host: host, policy: policy, authority: { true },
            onMessage: { _ in ready = true }, onClose: { _ in })
        let stubbornPID = stubborn.processIdentifier!
        try await wait("stubborn synthetic host ready") { ready }
        stubborn.close()
        try await wait("TERM-resistant owned process killed") { kill(stubbornPID, 0) == -1 && errno == ESRCH }

        try mode("no-read")
        var noReadReady = false, canceledClosed = false
        let noRead = try await ExtensionNativeMessagingConnection.connect(host: host, policy: policy, authority: { true },
            onMessage: { _ in noReadReady = true }, onClose: { _ in canceledClosed = true })
        let noReadPID = noRead.processIdentifier!
        try await wait("nonreading host ready") { noReadReady }
        let sendTask = Task { try await noRead.send(String(repeating: "x", count: 1_000_000)) }
        try await Task.sleep(nanoseconds: 50_000_000); sendTask.cancel()
        do { try await sendTask.value; throw Failure(description: "Canceled blocked write succeeded") }
        catch is CancellationError { checks += 1 }
        catch is ExtensionNativeMessagingError { checks += 1 }
        try await wait("blocked send cancellation closes connection") { canceledClosed }
        try await wait("canceled process reaped") { kill(noReadPID, 0) == -1 && errno == ESRCH }

        var launched = false
        do {
            _ = try await ExtensionNativeMessagingConnection.connect(host: host, policy: policy, authority: { false },
                onMessage: { _ in launched = true }, onClose: { _ in })
            throw Failure(description: "Denied authority launched host")
        } catch is ExtensionNativeMessagingError { checks += 1 }
        try check(!launched, "Denied connection must never receive host messages")
    }

    @MainActor static func codec() throws {
        let first = try ExtensionNativeMessageDecoder.encode(["a": "🪩"])
        let second = try ExtensionNativeMessageDecoder.encode([1, 2, 3])
        var decoder = ExtensionNativeMessageDecoder(), received: [Data] = []
        for byte in first + second { received += try decoder.append(Data([byte])) }
        try check(received.count == 2 && decoder.isEmpty, "Arbitrarily split headers/bodies must reassemble in order")
        try check((try JSONSerialization.jsonObject(with: received[0]) as? [String: String])?["a"] == "🪩", "Framing must count UTF-8 bytes, not characters")
        var tooLarge = UInt32(ExtensionNativeMessaging.maximumMessageBytes + 1)
        let header = withUnsafeBytes(of: &tooLarge) { Data($0) }
        var bounded = ExtensionNativeMessageDecoder()
        try rejects("Oversized header must fail before body allocation") { _ = try bounded.append(header) }
        try rejects("Outgoing frames must be bounded") { _ = try ExtensionNativeMessageDecoder.encode(String(repeating: "x", count: 1_048_576)) }
        var zero = ExtensionNativeMessageDecoder()
        try rejects("Zero-length frame must fail") { _ = try zero.append(Data(repeating: 0, count: 4)) }
        var partial = ExtensionNativeMessageDecoder(); _ = try partial.append(first.dropLast())
        try check(!partial.isEmpty, "Partial EOF must remain detectable")
    }

    /// Original fixture host. Never looks outside its private test directory.
    static func runHost() {
        let mode = (try? String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("mode"))) ?? ""
        func write(_ bytes: Data, split: Bool = false) {
            if split { for byte in bytes { try? FileHandle.standardOutput.write(contentsOf: Data([byte])) } }
            else { try? FileHandle.standardOutput.write(contentsOf: bytes) }
        }
        func frame(_ value: Any, split: Bool = false) { if let data = try? ExtensionNativeMessageDecoder.encode(value) { write(data, split: split) } }
        func readExactly(_ count: Int) -> Data? {
            var result = Data()
            while result.count < count {
                guard let data = try? FileHandle.standardInput.read(upToCount: count - result.count), !data.isEmpty else { return nil }
                result.append(data)
            }
            return result
        }
        if mode == "oversize" { var n = UInt32(1_048_577); write(withUnsafeBytes(of: &n) { Data($0) }); sleep(3); return }
        if mode == "truncated" { var n = UInt32(10); write(withUnsafeBytes(of: &n) { Data($0) } + Data("ab".utf8)); return }
        if mode == "invalid-json" { var n = UInt32(1); write(withUnsafeBytes(of: &n) { Data($0) } + Data("{".utf8)); sleep(3); return }
        if mode == "unsolicited" { usleep(100_000); frame(["private": "synthetic-only"]); sleep(3); return }
        if mode == "ignore-term" { signal(SIGTERM, SIG_IGN); frame(["ready": true]); while true { pause() } }
        if mode == "no-read" { frame(["ready": true]); sleep(10); return }
        while let header = readExactly(4) {
            let count = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            guard count > 0, count <= 1_048_576, let data = readExactly(count),
                  let message = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
            frame(["echo": message, "origin": CommandLine.arguments[1]], split: true)
            if mode == "exit-reply" { return }
        }
    }
}
