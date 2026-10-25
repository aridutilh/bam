import AppKit
import CryptoKit
import ImageIO

/// Profile-scoped icons fetched directly from a page's declared URLs or origin.
/// Bounded asynchronous loading keeps icon work separate from page navigation.
/// SVG drawing runs in a separate WebKit process and returns a 64-pixel raster.
@MainActor final class WebsiteFaviconStore {
    struct Policy: Sendable {
        var maximumBytes = 512 * 1024
        var maximumDimension = 4096
        var maximumMemoryEntries = 256
        var maximumQueued = 128
        var maximumConcurrent = 4
        var maximumDiskEntries = 512
        var maximumDiskBytes = 16 * 1024 * 1024
        var cacheTTL: TimeInterval = 7 * 24 * 3600
        var missTTL: TimeInterval = 5 * 60
    }
    var onChange: ((UUID, String) -> Void)?
    private struct Key: Hashable, Sendable { let profile: UUID; let origin: String }
    private final class Entry {
        var image: NSImage?
        var expires = Date.distantPast
        var candidates: [URL] = []
        var generation = UUID()
        var diskChecked = false
        var wantsFetch = false
        var queued = false
        var lastUse = 0
    }
    private struct Job { let generation: UUID; let task: Task<Void, Never> }
    private struct Result: @unchecked Sendable {
        var image: CGImage?
        var record: FaviconDiskCache.Record?
        var write = false
    }
    private let policy: Policy
    private let now: () -> Date
    private let disk: FaviconDiskCache
    private let network: FaviconNetwork
    private var entries: [Key: Entry] = [:]
    private var queue: [Key] = []
    private var jobs: [Key: Job] = [:]
    private var tick = 0
    private var stopped = false
    private var pendingWrite: Task<Void, Never>?

    init(directory: URL?, configuration: URLSessionConfiguration? = nil,
         policy: Policy = Policy(), now: @escaping () -> Date = Date.init) {
        self.policy = policy; self.now = now
        disk = FaviconDiskCache(directory: directory, maximumEntries: policy.maximumDiskEntries, maximumBytes: policy.maximumDiskBytes)
        network = FaviconNetwork(configuration: configuration, maximumBytes: policy.maximumBytes)
    }

    nonisolated static func originKey(for url: URL) -> String? {
        guard let valid = FaviconNetwork.validURL(url), let host = valid.host?.lowercased() else { return nil }
        var parts = URLComponents()
        parts.scheme = valid.scheme!.lowercased(); parts.host = host
        if let port = valid.port, !(parts.scheme == "https" && port == 443 || parts.scheme == "http" && port == 80) { parts.port = port }
        return parts.string
    }

    func image(for pageURL: URL, profileID: UUID, allowFetch: Bool = true) -> NSImage? {
        guard !stopped, let origin = Self.originKey(for: pageURL), let entry = entry(for: Key(profile: profileID, origin: origin)) else { return nil }
        let key = Key(profile: profileID, origin: origin)
        entry.wantsFetch = entry.wantsFetch || allowFetch
        if entry.expires <= now(), allowFetch || !entry.diskChecked { enqueue(key) }
        return entry.image
    }

    func updateCandidates(_ candidates: [URL], for pageURL: URL, profileID: UUID) {
        guard !stopped, let origin = Self.originKey(for: pageURL) else { return }
        let key = Key(profile: profileID, origin: origin)
        guard let entry = entry(for: key) else { return }
        var seen = Set<String>()
        let secure = pageURL.scheme?.lowercased() == "https"
        var updated: [URL] = []
        for candidate in candidates.prefix(24) {
            let accepted: URL?
            if candidate.scheme?.lowercased() == "data" {
                accepted = Self.acceptsDataIcon(candidate, maximumBytes: policy.maximumBytes) ? candidate : nil
            } else { accepted = FaviconNetwork.validURL(candidate, requiresHTTPS: secure) }
            if let accepted, seen.insert(accepted.absoluteString).inserted { updated.append(accepted) }
            if updated.count == 6 { break }
        }
        guard updated != entry.candidates else { return }
        entry.candidates = updated; entry.generation = UUID(); entry.expires = .distantPast
        entry.diskChecked = true; entry.wantsFetch = true
        jobs[key]?.task.cancel()
        enqueue(key)
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true; onChange = nil
        jobs.values.forEach { $0.task.cancel() }; jobs.removeAll()
        queue.removeAll(); entries.removeAll(); network.shutdown()
    }

    private func entry(for key: Key) -> Entry? {
        tick &+= 1
        if let entry = entries[key] { entry.lastUse = tick; return entry }
        if entries.count >= max(1, policy.maximumMemoryEntries) {
            guard let oldest = entries.filter({ !$0.value.queued && jobs[$0.key] == nil }).min(by: { $0.value.lastUse < $1.value.lastUse })?.key else { return nil }
            entries.removeValue(forKey: oldest)
        }
        let entry = Entry(); entry.lastUse = tick; entries[key] = entry
        return entry
    }
    private func enqueue(_ key: Key) {
        guard !stopped, let entry = entries[key], !entry.queued, jobs[key] == nil,
              queue.count < max(1, policy.maximumQueued) else { return }
        entry.queued = true; queue.append(key); pump()
    }
    private func pump() {
        while !stopped, jobs.count < min(4, max(1, policy.maximumConcurrent)), !queue.isEmpty {
            let key = queue.removeFirst()
            guard let entry = entries[key] else { continue }
            entry.queued = false
            let generation = entry.generation, candidates = entry.candidates
            let readDisk = !entry.diskChecked, fetch = entry.wantsFetch, date = now()
            entry.diskChecked = true
            let task = Task { [weak self, disk, network, policy] in
                let result = await Self.load(key: key, candidates: candidates, readDisk: readDisk, fetch: fetch, date: date, disk: disk, network: network, policy: policy)
                self?.finish(key, generation: generation, result: result)
            }
            jobs[key] = Job(generation: generation, task: task)
        }
    }
    private func finish(_ key: Key, generation: UUID, result: Result) {
        guard !stopped, jobs[key]?.generation == generation else { return }
        jobs.removeValue(forKey: key)
        if let entry = entries[key] {
            if entry.generation == generation {
                if let record = result.record {
                    entry.expires = record.expires
                    let retainingPrevious = result.image == nil && entry.image != nil
                    if !retainingPrevious {
                        entry.image = result.image.map { image in
                            let value = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                            value.isTemplate = false; return value
                        }
                    }
                    if result.write && !retainingPrevious {
                        let previous = pendingWrite
                        pendingWrite = Task { [disk] in
                            await previous?.value
                            await disk.write(record, profile: key.profile, origin: key.origin)
                        }
                    }
                    onChange?(key.profile, key.origin)
                } else if entry.wantsFetch { enqueue(key) }
            } else { enqueue(key) }
        }
        pump()
    }
    nonisolated private static func load(key: Key, candidates: [URL], readDisk: Bool, fetch: Bool, date: Date,
                                        disk: FaviconDiskCache, network: FaviconNetwork, policy: Policy) async -> Result {
        if readDisk, let record = await disk.read(profile: key.profile, origin: key.origin, now: date, maximumBytes: policy.maximumBytes) {
            if record.png == nil { return Result(record: record) }
            if let data = record.png, let image = await decode(data, policy: policy) { return Result(image: image, record: record) }
        }
        guard fetch, !Task.isCancelled else { return Result() }
        let fallback = URL(string: key.origin + "/favicon.ico")!
        var seen = Set<String>()
        for url in (candidates + [fallback]).filter({ seen.insert($0.absoluteString).inserted }) {
            guard !Task.isCancelled else { return Result() }
            let data: Data?
            if url.scheme?.lowercased() == "data" { data = dataIcon(url, maximumBytes: policy.maximumBytes) }
            else { data = await network.fetch(url) }
            guard !Task.isCancelled else { return Result() }
            if let data, let image = await decode(data, policy: policy), let png = await pngData(image) {
                return Result(image: image, record: .init(origin: key.origin, expires: date.addingTimeInterval(policy.cacheTTL), png: png), write: true)
            }
        }
        return Result(record: .init(origin: key.origin, expires: date.addingTimeInterval(policy.missTTL), png: nil), write: true)
    }
    nonisolated private static func acceptsDataIcon(_ url: URL, maximumBytes: Int) -> Bool {
        dataIcon(url, maximumBytes: maximumBytes) != nil
    }
    nonisolated private static func dataIcon(_ url: URL, maximumBytes: Int) -> Data? {
        // An actual URL fragment is not part of a data URL's image bytes.
        // Encoded %23 stays in the payload, and query characters are retained.
        let limit = min(maximumBytes, 64 * 1024), string = String(url.absoluteString.prefix { $0 != "#" })
        guard string.utf8.count <= limit * 3 + 128, let comma = string.firstIndex(of: ",") else { return nil }
        let fields = string[..<comma].lowercased().split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let type = fields.first else { return nil }
        let raster = ["data:image/png", "data:image/x-icon", "data:image/vnd.microsoft.icon", "data:image/jpeg", "data:image/gif", "data:image/webp"]
        let svg = type == "data:image/svg+xml"
        guard svg || raster.contains(type),
              fields.dropFirst().allSatisfy({ ["base64", "charset=utf-8", "utf8"].contains($0) }),
              svg || fields.contains("base64"),
              let payload = String(string[string.index(after: comma)...]).removingPercentEncoding else { return nil }
        let data = fields.contains("base64") ? Data(base64Encoded: payload) : payload.data(using: .utf8)
        guard let data, data.count <= limit else { return nil }
        return data
    }
    nonisolated private static func decode(_ data: Data, policy: Policy) async -> CGImage? {
        guard data.count <= policy.maximumBytes, !Task.isCancelled else { return nil }
        let raster: CGImage? = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let type = CGImageSourceGetType(source) as String?,
                  ["public.png", "com.microsoft.ico", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp", "public.tiff", "com.microsoft.bmp"].contains(type),
                  CGImageSourceGetCount(source) <= 32 else { return nil }
            var chosen: Int?, best = Int.max
            for index in 0..<CGImageSourceGetCount(source) {
                guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                      width > 0, height > 0, width <= policy.maximumDimension, height <= policy.maximumDimension else { continue }
                let score = max(width, height) >= 64 ? max(width, height) - 64 : 10000 - max(width, height)
                if score < best { chosen = index; best = score }
            }
            guard let chosen else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, chosen, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }.value
        if let raster { return raster }
        guard !Task.isCancelled,
              await Task.detached(priority: .utility, operation: { FaviconSVGRenderer.accepts(data) }).value else { return nil }
        return await FaviconSVGRenderer.render(data, maximumDimension: policy.maximumDimension)
    }
    nonisolated private static func pngData(_ image: CGImage) async -> Data? {
        await Task.detached(priority: .utility) {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }.value
    }
}

private actor FaviconDiskCache {
    struct Record: Codable, Sendable { let origin: String; let expires: Date; let png: Data? }
    private let directory: URL?
    private let maximumEntries: Int
    private let maximumBytes: Int
    init(directory: URL?, maximumEntries: Int, maximumBytes: Int) {
        self.directory = directory; self.maximumEntries = maximumEntries; self.maximumBytes = maximumBytes
    }
    private func file(profile: UUID, origin: String) -> URL? {
        let hash = SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(profile.uuidString, isDirectory: true).appendingPathComponent(hash + ".json")
    }
    func read(profile: UUID, origin: String, now: Date, maximumBytes: Int) -> Record? {
        guard let file = file(profile: profile, origin: origin),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumBytes * 2,
              let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(Record.self, from: data),
              record.origin == origin, record.expires > now else { return nil }
        return record
    }
    func write(_ record: Record, profile: UUID, origin: String) {
        guard let directory, let file = file(profile: profile, origin: origin), let data = try? JSONEncoder().encode(record) else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
            var records: [(URL, Int, Date)] = []
            for case let url as URL in files {
                guard url.pathExtension == "json", let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                records.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
            }
            records.sort { $0.2 < $1.2 }
            var bytes = records.reduce(0) { $0 + $1.1 }, count = records.count
            for item in records {
                guard bytes > maximumBytes || count > maximumEntries else { break }
                try? FileManager.default.removeItem(at: item.0); bytes -= item.1; count -= 1
            }
        } catch { /* A favicon cache failure must not affect browsing. */ }
    }
}

private final class FaviconNetwork: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        let continuation: CheckedContinuation<Data?, Never>
        var data = Data(), accepted = false, redirects = 0, requiresHTTPS: Bool
        init(_ continuation: CheckedContinuation<Data?, Never>, url: URL) { self.continuation = continuation; requiresHTTPS = url.scheme?.lowercased() == "https" }
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?, cancelled = false
        func install(_ task: URLSessionTask) { lock.lock(); self.task = task; let cancel = cancelled; lock.unlock(); if cancel { task.cancel() } }
        func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!
    private let maximumBytes: Int
    init(configuration: URLSessionConfiguration?, maximumBytes: Int) {
        self.maximumBytes = maximumBytes
        super.init()
        let config = (configuration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false; config.httpAdditionalHeaders = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 4
        let callbacks = OperationQueue(); callbacks.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: callbacks)
    }
    static func validURL(_ url: URL, requiresHTTPS: Bool = false) -> URL? {
        guard url.absoluteString.utf8.count <= 8192, let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), !requiresHTTPS || scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.fragment = nil
        return parts.url
    }
    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        request.setValue("image/png,image/x-icon,image/*;q=0.8", forHTTPHeaderField: "Accept")
        return request
    }
    func fetch(_ url: URL) async -> Data? {
        guard let url = Self.validURL(url) else { return nil }
        let cancellation = Cancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let task = session.dataTask(with: Self.request(url))
                lock.lock(); pending[task.taskIdentifier] = Pending(continuation, url: url); lock.unlock()
                cancellation.install(task); task.resume()
            }
        }, onCancel: { cancellation.cancel() })
    }
    func shutdown() { session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let item = pending[dataTask.taskIdentifier]
        let accepted = item != nil && (response as? HTTPURLResponse)?.statusCode == 200 &&
            response.expectedContentLength <= maximumBytes && response.url.flatMap { Self.validURL($0, requiresHTTPS: item!.requiresHTTPS) } != nil
        item?.accepted = accepted
        lock.unlock(); completionHandler(accepted ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let item = pending[dataTask.taskIdentifier] else { lock.unlock(); return }
        let overflow = data.count > maximumBytes - item.data.count
        if overflow { item.accepted = false } else { item.data.append(data) }
        lock.unlock(); if overflow { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let item = pending.removeValue(forKey: task.taskIdentifier); lock.unlock()
        item?.continuation.resume(returning: error == nil && item?.accepted == true ? item?.data : nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        guard let item = pending[task.taskIdentifier], item.redirects < 4,
              let url = request.url.flatMap({ Self.validURL($0, requiresHTTPS: item.requiresHTTPS) }) else {
            pending[task.taskIdentifier]?.accepted = false; lock.unlock(); completionHandler(nil); task.cancel(); return
        }
        item.redirects += 1; item.requiresHTTPS = item.requiresHTTPS || url.scheme?.lowercased() == "https"
        lock.unlock(); completionHandler(Self.request(url))
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
