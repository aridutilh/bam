import AppKit
import ImageIO

private final class FaviconProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var data: Data; var delay: TimeInterval = 0; var headers: [String: String] = [:]; var redirect: URL? }
    private static let lock = NSLock()
    private static var replies: [String: [Reply]] = [:]
    private static var requests: [URLRequest] = []
    private static var active = 0, peak = 0
    private let stateLock = NSLock()
    private var ended = false
    static func reset() { lock.lock(); replies = [:]; requests = []; active = 0; peak = 0; lock.unlock() }
    static func route(_ url: URL, _ values: [Reply]) { lock.lock(); replies[url.absoluteString] = values; lock.unlock() }
    static var recorded: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    static var peakActive: Int { lock.lock(); defer { lock.unlock() }; return peak }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request); Self.active += 1; Self.peak = max(Self.peak, Self.active)
        var available = Self.replies[request.url!.absoluteString] ?? []
        let reply = available.isEmpty ? Reply(status: 404, data: Data()) : available.removeFirst()
        Self.replies[request.url!.absoluteString] = available
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            stateLock.lock(); let cancelled = ended; stateLock.unlock(); guard !cancelled else { return }
            if let redirect = reply.redirect {
                let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": redirect.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            } else {
                let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                for start in stride(from: 0, to: reply.data.count, by: 256) {
                    stateLock.lock(); let cancelled = ended; stateLock.unlock(); if cancelled { break }
                    client?.urlProtocol(self, didLoad: reply.data.subdata(in: start..<min(start + 256, reply.data.count)))
                }
                client?.urlProtocolDidFinishLoading(self)
            }
            finish()
        }
    }
    private func finish() {
        stateLock.lock(); let shouldFinish = !ended; ended = true; stateLock.unlock()
        if shouldFinish { Self.lock.lock(); Self.active -= 1; Self.lock.unlock() }
    }
    override func stopLoading() { finish() }
}

@main @MainActor enum WebsiteFaviconStoreTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var checks = 0
    static let profile = UUID(), other = UUID()
    static let page = URL(string: "https://example.invalid/page?q=private")!
    static let fallback = URL(string: "https://example.invalid/favicon.ico")!
    static var red: Data { png(red: 1, blue: 0) }
    static var blue: Data { png(red: 0, blue: 1) }
    static func main() async {
        do {
            try await priorityAndFallback()
            try await isolationAndPersistence()
            try await retryAndSupersession()
            try await limitsAndShutdown()
            try await redirects()
            print("PASS: Website favicons — \(checks) checks")
        } catch { FileHandle.standardError.write(Data("FAIL: Website favicons — \(error)\n".utf8)); exit(1) }
    }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }; checks += 1
    }
    static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(description: "Timed out: " + message) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    static func config() -> URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [FaviconProtocol.self]
        value.httpAdditionalHeaders = ["Cookie": "secret=1", "Authorization": "secret", "Referer": "https://private.invalid/"]
        return value
    }
    static func png(red: CGFloat, blue: CGFloat, width: Int = 64) -> Data {
        let context = CGContext(data: nil, width: width, height: width, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: 0, blue: blue, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: width))
        let data = NSMutableData(), destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
    static func color(_ image: NSImage?) -> String? {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let rep = NSBitmapImageRep(cgImage: cg).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return nil }
        return rep.redComponent > rep.blueComponent ? "red" : "blue"
    }
    static func icon(_ store: WebsiteFaviconStore, _ url: URL? = nil, _ profile: UUID? = nil, fetch: Bool = true) -> NSImage? {
        store.image(for: url ?? page, profileID: profile ?? Self.profile, allowFetch: fetch)
    }
    static func cacheFiles(_ root: URL) -> [URL] {
        (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "json" }
    }
    static func priorityAndFallback() async throws {
        FaviconProtocol.reset()
        let store = WebsiteFaviconStore(directory: nil, configuration: config()); defer { store.shutdown() }
        let cdn = URL(string: "https://cdn.invalid/icon.png")!
        FaviconProtocol.route(cdn, [.init(data: blue)])
        store.updateCandidates([cdn], for: page, profileID: profile)
        try await wait("declared CDN icon") { color(icon(store)) == "blue" }
        try check(FaviconProtocol.recorded.map(\.url) == [cdn], "A valid declared CDN icon must beat the origin fallback")
        let image = icon(store)!
        try check(!image.isTemplate && image.size.width == 64, "Decoded favicon must retain color and retina-sized pixels")
        let request = FaviconProtocol.recorded[0]
        try check(!request.httpShouldHandleCookies && ["Cookie", "Authorization", "Referer"].allSatisfy { request.value(forHTTPHeaderField: $0) == nil }, "Icon fetch leaked credentials or referrer")
        for _ in 0..<100 { _ = icon(store) }
        try check(FaviconProtocol.recorded.count == 1, "Memory cache must deduplicate repeated icon requests")
        try check(WebsiteFaviconStore.originKey(for: URL(string: "https://EXAMPLE.invalid:443/elsewhere#fragment")!) == "https://example.invalid", "Origin key must normalize case/default ports and discard page details")
        try check(WebsiteFaviconStore.originKey(for: URL(string: "file:///private/data")!) == nil && WebsiteFaviconStore.originKey(for: URL(string: "https://name:secret@example.invalid/")!) == nil, "Non-web and credential-bearing pages must be rejected")
        let invalid = URL(string: "https://cdn.invalid/not-image")!
        FaviconProtocol.route(invalid, [.init(data: Data("<html>not an icon</html>".utf8))])
        FaviconProtocol.route(fallback, [.init(data: red)])
        store.updateCandidates([invalid], for: page, profileID: profile)
        try await wait("invalid declared icon falls back") { color(icon(store)) == "red" }
        try check(FaviconProtocol.recorded.suffix(2).map(\.url) == [invalid, fallback], "Invalid image must advance to the same-origin favicon fallback")
        let encoded = URL(string: "data:image/png;base64," + blue.base64EncodedString())!
        let count = FaviconProtocol.recorded.count
        store.updateCandidates([encoded], for: page, profileID: profile)
        try await wait("bounded embedded icon") { color(icon(store)) == "blue" }
        try check(FaviconProtocol.recorded.count == count, "A valid embedded icon must not require network access")
        var ico = Data([0, 0, 1, 0, 1, 0, 64, 64, 0, 0, 1, 0, 32, 0])
        for number in [UInt32(red.count), 22] {
            ico.append(contentsOf: (0..<4).map { UInt8((number >> ($0 * 8)) & 255) })
        }
        ico.append(red)
        let icoURL = URL(string: "https://cdn.invalid/real.ico")!
        FaviconProtocol.route(icoURL, [.init(data: ico)])
        store.updateCandidates([icoURL], for: page, profileID: profile)
        try await wait("ICO container decode") { color(icon(store)) == "red" }
        try check(FaviconProtocol.recorded.last?.url == icoURL, "An actual ICO container must decode to a full-color icon")
    }
    static func isolationAndPersistence() async throws {
        FaviconProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bam-favicon-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var changes: [(UUID, String)] = []
        let store = WebsiteFaviconStore(directory: root, configuration: config())
        store.onChange = { changes.append(($0, $1)) }
        FaviconProtocol.route(fallback, [.init(data: red), .init(data: blue)])
        try await wait("first profile") { color(icon(store)) == "red" }
        try check(icon(store, page, other, fetch: false) == nil, "A second profile must never reuse the first profile's memory icon")
        try await wait("second profile after disk-only lookup") { color(icon(store, page, other)) == "blue" }
        try check(color(icon(store)) == "red" && changes.contains { $0.0 == profile && $0.1 == "https://example.invalid" } && changes.contains { $0.0 == other }, "Profile-specific images and callback keys must stay separate")
        try await wait("profile-scoped disk records") { cacheFiles(root).count == 2 }
        store.shutdown()
        let count = FaviconProtocol.recorded.count
        let restored = WebsiteFaviconStore(directory: root, configuration: config()); defer { restored.shutdown() }
        try await wait("disk cache restoration") { color(icon(restored, page, profile, fetch: false)) == "red" && color(icon(restored, page, other, fetch: false)) == "blue" }
        try check(FaviconProtocol.recorded.count == count, "Fresh disk cache must restore both profiles without network")
        let memoryOnly = WebsiteFaviconStore(directory: nil, configuration: config()); defer { memoryOnly.shutdown() }
        _ = icon(memoryOnly, page, profile, fetch: false)
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(icon(memoryOnly, page, profile, fetch: false) == nil && FaviconProtocol.recorded.count == count, "Memory-only/disk-only lookup must not access another store or fetch")
    }
    static func retryAndSupersession() async throws {
        FaviconProtocol.reset()
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        var policy = WebsiteFaviconStore.Policy(); policy.missTTL = 1; policy.cacheTTL = 10
        let store = WebsiteFaviconStore(directory: nil, configuration: config(), policy: policy, now: { date }); defer { store.shutdown() }
        var notifications = 0; store.onChange = { _, _ in notifications += 1 }
        FaviconProtocol.route(fallback, [.init(status: 404, data: Data()), .init(data: red), .init(data: blue)])
        _ = icon(store); try await wait("negative cache") { notifications == 1 }
        for _ in 0..<10 { _ = icon(store) }
        try check(FaviconProtocol.recorded.count == 1, "A cached miss must not retry before its TTL")
        date.addTimeInterval(2)
        try await wait("miss retry") { color(icon(store)) == "red" }
        date.addTimeInterval(11)
        try await wait("positive cache expiry") { color(icon(store)) == "blue" }
        try check(FaviconProtocol.recorded.count == 3, "Positive and negative expiration must permit retry")
        let old = URL(string: "https://cdn.invalid/old.png")!, new = URL(string: "https://cdn.invalid/new.png")!
        FaviconProtocol.route(old, [.init(data: red, delay: 0.2)])
        FaviconProtocol.route(new, [.init(data: blue)])
        store.updateCandidates([old], for: page, profileID: profile)
        try await wait("old request started") { FaviconProtocol.recorded.contains { $0.url == old } }
        let before = notifications
        store.updateCandidates([new], for: page, profileID: profile)
        try await wait("replacement completed") { notifications > before }
        try await Task.sleep(nanoseconds: 250_000_000)
        try check(color(icon(store)) == "blue" && notifications == before + 1, "Cancelled stale requests must not replace or notify over a newer candidate")
        let missing = URL(string: "https://cdn.invalid/missing")!
        let prior = notifications
        store.updateCandidates([missing], for: page, profileID: profile)
        try await wait("failed refresh completes") { notifications > prior }
        let requests = FaviconProtocol.recorded.count
        try check(color(icon(store)) == "blue", "A temporary failed refresh must retain the known good origin icon")
        for _ in 0..<10 { _ = icon(store) }
        try check(FaviconProtocol.recorded.count == requests, "A retained icon must still honor failed-refresh retry TTL")
    }
    static func limitsAndShutdown() async throws {
        FaviconProtocol.reset()
        var policy = WebsiteFaviconStore.Policy(); policy.maximumBytes = 1024; policy.maximumDimension = 64
        policy.maximumConcurrent = 2; policy.maximumQueued = 3; policy.maximumMemoryEntries = 8
        let store = WebsiteFaviconStore(directory: nil, configuration: config(), policy: policy); defer { store.shutdown() }
        let large = URL(string: "https://cdn.invalid/large.png")!, dimension = URL(string: "https://cdn.invalid/dimension.png")!
        FaviconProtocol.route(large, [.init(data: Data(repeating: 1, count: 2048))])
        FaviconProtocol.route(dimension, [.init(data: png(red: 0, blue: 1, width: 128))])
        FaviconProtocol.route(fallback, [.init(data: red)])
        store.updateCandidates([large, dimension], for: page, profileID: profile)
        try await wait("size and dimension rejection") { color(icon(store)) == "red" }
        try check(FaviconProtocol.recorded.map(\.url) == [large, dimension, fallback], "Oversized body/dimensions must fall through to valid fallback")
        store.shutdown(); FaviconProtocol.reset()
        let bounded = WebsiteFaviconStore(directory: nil, configuration: config(), policy: policy)
        var changes = 0; bounded.onChange = { _, _ in changes += 1 }
        for number in 0..<20 {
            let page = URL(string: "https://site\(number).invalid/")!
            let url = URL(string: "https://site\(number).invalid/favicon.ico")!
            FaviconProtocol.route(url, [.init(data: red, delay: 0.08)])
            _ = icon(bounded, page)
        }
        try await wait("bounded queue drains") { changes == 5 }
        try check(FaviconProtocol.recorded.count == 5 && FaviconProtocol.peakActive <= 2, "Network concurrency and queued requests must stay bounded")
        let pendingPage = URL(string: "https://pending.invalid/")!, pendingIcon = URL(string: "https://pending.invalid/favicon.ico")!
        FaviconProtocol.route(pendingIcon, [.init(data: blue, delay: 0.2)])
        _ = icon(bounded, pendingPage)
        try await wait("shutdown request started") { FaviconProtocol.recorded.contains { $0.url == pendingIcon } }
        bounded.shutdown(); let before = changes
        try await Task.sleep(nanoseconds: 250_000_000)
        try check(changes == before && icon(bounded) == nil, "Shutdown must suppress stale callbacks and future fetches")
        FaviconProtocol.reset()
        var diskPolicy = WebsiteFaviconStore.Policy(); diskPolicy.maximumDiskEntries = 2; diskPolicy.maximumDiskBytes = 4096; diskPolicy.maximumMemoryEntries = 1
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bam-favicon-bounds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let diskStore = WebsiteFaviconStore(directory: root, configuration: config(), policy: diskPolicy); defer { diskStore.shutdown() }
        for index in 0..<3 {
            let page = URL(string: "https://disk\(index).invalid/")!, url = URL(string: "https://disk\(index).invalid/favicon.ico")!
            FaviconProtocol.route(url, [.init(data: red)])
            try await wait("bounded disk \(index)") { color(icon(diskStore, page)) == "red" }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let files = cacheFiles(root), bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        try check(files.count <= 2 && bytes <= 4096, "Persistent cache must enforce file and byte budgets")
        try check(icon(diskStore, URL(string: "https://disk0.invalid/")!, fetch: false) == nil, "Memory LRU must evict old icons when full")
    }
    static func redirects() async throws {
        FaviconProtocol.reset()
        let store = WebsiteFaviconStore(directory: nil, configuration: config()); defer { store.shutdown() }
        let cdn = URL(string: "https://cdn.invalid/redirected.png")!
        FaviconProtocol.route(fallback, [.init(data: Data(), redirect: cdn)])
        FaviconProtocol.route(cdn, [.init(data: blue)])
        try await wait("safe CDN redirect") { color(icon(store)) == "blue" }
        try check(FaviconProtocol.recorded.map(\.url) == [fallback, cdn], "Fallback must permit a bounded safe CDN redirect")
        let start = URL(string: "https://cdn.invalid/downgrade")!, insecure = URL(string: "http://cdn.invalid/insecure")!
        FaviconProtocol.route(start, [.init(data: Data(), redirect: insecure)])
        FaviconProtocol.route(fallback, [.init(data: red)])
        store.updateCandidates([start], for: page, profileID: profile)
        try await wait("downgrade rejected") { color(icon(store)) == "red" }
        try check(!FaviconProtocol.recorded.contains { $0.url == insecure }, "HTTPS redirect must never downgrade to HTTP")
        let credential = URL(string: "https://user:password@cdn.invalid/private.png")!
        let credentialStart = URL(string: "https://cdn.invalid/credential")!
        FaviconProtocol.route(credentialStart, [.init(data: Data(), redirect: credential)])
        FaviconProtocol.route(fallback, [.init(data: blue)])
        store.updateCandidates([credentialStart], for: page, profileID: profile)
        try await wait("credential redirect rejected") { color(icon(store)) == "blue" }
        try check(!FaviconProtocol.recorded.contains { $0.url?.user != nil }, "Redirects must never transmit URL credentials")
        let loop = (0..<7).map { URL(string: "https://cdn.invalid/loop\($0)")! }
        for index in 0..<6 { FaviconProtocol.route(loop[index], [.init(data: Data(), redirect: loop[index + 1])]) }
        FaviconProtocol.route(fallback, [.init(data: red)])
        store.updateCandidates([loop[0]], for: page, profileID: profile)
        try await wait("redirect budget") { color(icon(store)) == "red" }
        try check(FaviconProtocol.recorded.filter { $0.url?.path.hasPrefix("/loop") == true }.count == 5,
                  "A request must stop after four followed redirects and use its fallback")
    }
}
