import AppKit
import Network
import WebKit

/// A loopback TCP listener the fixture points every imported tab address at. Any page
/// load or favicon fetch for an imported tab, in this process or a relaunched child,
/// would connect here; each connection gets an empty 404 and is counted.
final class NetworkTripwire: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var lines: [String] = []
    private var listener: NWListener?
    private var resumed = false
    var connections: Int { lock.lock(); defer { lock.unlock() }; return count }
    var requestLines: [String] { lock.lock(); defer { lock.unlock() }; return lines }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.lock(); self.count += 1; self.lock.unlock()
            connection.start(queue: .global(qos: .utility))
            self.readRequestLine(connection, buffer: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.lock.lock(); let first = !self.resumed
                switch state {
                case .ready, .failed: self.resumed = true
                default: break
                }
                self.lock.unlock()
                guard first else { return }
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { continuation.resume(returning: port) }
                    else { continuation.resume(throwing: ArcImportSmokeTest.Failure.assertion("Tripwire has no port")) }
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global(qos: .utility))
        }
    }
    /// Accumulates until the request line's CRLF (TCP may split it), at most 4 KiB, then answers 404.
    private func readRequestLine(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            let lineEnd = buffer.range(of: Data("\r\n".utf8))
            if lineEnd == nil, !complete, error == nil, buffer.count < 4096 {
                self?.readRequestLine(connection, buffer: buffer); return
            }
            let line = String(decoding: buffer[..<(lineEnd?.lowerBound ?? buffer.endIndex)], as: UTF8.self)
            if !line.isEmpty { self?.lock.lock(); self?.lines.append(String(line.prefix(160))); self?.lock.unlock() }
            let reply = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    func stop() { listener?.cancel(); listener = nil }
}

/// A child's stdout, collected as it arrives, bounded to 1 MiB.
final class ChildOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var ended = false
    func append(_ chunk: Data) { lock.lock(); if data.count < 1_048_576 { data.append(chunk.prefix(1_048_576 - data.count)) }; lock.unlock() }
    func end() { lock.lock(); ended = true; lock.unlock() }
    var isEnded: Bool { lock.lock(); defer { lock.unlock() }; return ended }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// File > Import from Arc… end to end in the app under test (`--arc-import-test`).
/// Drives the real ArcImportController sheet and the asynchronous
/// BrowserController.commitArcImport against the repository's original synthetic
/// Tests/Fixtures/arc/StorableSidebar.json, served by the runtime loopback
/// server. It never reads the user's Arc layout and prints no fixture content.
/// Website data stays in non-persistent stores; a real SessionWriter targets a
/// temporary file, so the commit's verified save and undo paths are real.
@MainActor final class ArcImportSmokeTest {
    private var controller: BrowserController!
    private var window: NSWindow!
    private var importer: ArcImportController?
    private var checks = 0
    private var watchdog: Timer?
    private var finished = false
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("bam-arc-import-\(UUID().uuidString)", isDirectory: true)
    private var sessionFile: URL { directory.appendingPathComponent("session.json") }
    private static let gammaSourceAddress = "https://board.example.com/g"
    /// The Gamma address after the tripwire rewrite (set once the listener has a port).
    private var gammaAddress = ArcImportSmokeTest.gammaSourceAddress
    private let tripwire = NetworkTripwire()
    private var childPIDs: [Int32] = []
    /// The relaunched child this fixture owns while one runs; every exit path stops it first.
    private var activeChild: Process?
    /// Overall deadline on the main run loop, then a background hard deadline that still works
    /// if the main thread stalls (it only exits; it never signals a stored PID).
    static let parentDeadline: TimeInterval = 420
    static let parentHardDeadline: TimeInterval = 480

    /// Bounded stop of the owned child: SIGTERM, up to 5 s, then SIGKILL for that PID only,
    /// up to 3 s more. Returns whether the child is confirmed to have exited.
    private func stopChild(_ child: Process) async -> Bool {
        if child.isRunning { child.terminate() }
        for _ in 0..<50 where child.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if child.isRunning {
            kill(child.processIdentifier, SIGKILL)
            for _ in 0..<30 where child.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        }
        let exited = !child.isRunning
        if exited, activeChild === child { activeChild = nil }
        return exited
    }
    private var tripwirePort: UInt16 = 0
    /// Points an HTTP(S) address at the tripwire, keeping its host as the first path segment:
    /// equal addresses stay equal, and every rewritten tab shares one loopback origin.
    private func tripwireAddress(_ raw: String) -> String {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host else { return raw }
        return "http://127.0.0.1:\(tripwirePort)/\(host)\(url.path.isEmpty ? "/" : url.path)"
    }
    /// The layout copy with every tab's HTTP(S) address on the tripwire. Counts, titles,
    /// structure and the non-web (file:) address are unchanged.
    private func pointedAtTripwire(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var sidebar = root["sidebar"] as? [String: Any], var containers = sidebar["containers"] as? [Any],
              containers.count > 1, var main = containers[1] as? [String: Any], var items = main["items"] as? [Any] else {
            throw Failure.assertion("Fixture layout has the local item list")
        }
        for index in items.indices {
            guard var object = items[index] as? [String: Any], var payload = object["data"] as? [String: Any],
                  var tab = payload["tab"] as? [String: Any], let raw = tab["savedURL"] as? String else { continue }
            tab["savedURL"] = tripwireAddress(raw)
            payload["tab"] = tab; object["data"] = payload; items[index] = object
        }
        main["items"] = items; containers[1] = main; sidebar["containers"] = containers; root["sidebar"] = sidebar
        return try JSONSerialization.data(withJSONObject: root)
    }
    enum Failure: Error { case assertion(String) }
    struct WriteRefused: Error {}
    /// commitArcImport's two failure outcomes: the undo was saved, or it wasn't.
    static let confirmedUndo = "Bam couldn’t save the imported layout, so the import was undone and nothing was added. Check free disk space and try again."
    static let unconfirmedUndo = "Bam couldn’t save to disk. The import was undone in this window, but Bam can’t confirm your tabs are saved — free up disk space before quitting."
    /// Ordered outcomes of an injected writer, recorded on its serial queue.
    final class WriteLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func record(_ event: String) { lock.lock(); entries.append(event); lock.unlock() }
        var events: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    // MARK: Space theme (original synthetic values in Arc's real windowTheme schema)

    /// Work keeps the repository fixture's mid-tone (0.2, 0.4, 0.9), so its nearest flat colour,
    /// and every count, is unchanged; the rest is a full theme as Arc stores it.
    private static let themeGradient: [[Double]] = [[0.86, 0.42, 0.30], [0.34, 0.27, 0.62]]
    private static let themeLight: [String: [Double]] = ["background": [0.97, 0.94, 0.92], "backgroundExtra": [0.99, 0.97, 0.96],
                                                         "title": [0.10, 0.08, 0.09], "subtitle": [0.38, 0.33, 0.35]]
    private static let themeDark: [String: [Double]] = ["background": [0.11, 0.09, 0.12], "backgroundExtra": [0.15, 0.12, 0.16],
                                                        "title": [0.96, 0.94, 0.95], "subtitle": [0.71, 0.66, 0.70]]
    private static let themeAccent: [String: [Double]] = ["midTone": [0.2, 0.4, 0.9], "tintedLight": [0.82, 0.87, 0.99], "shaded": [0.14, 0.27, 0.62]]
    private static func arcColor(_ c: [Double], alpha: Double = 1) -> [String: Any] {
        ["red": c[0], "green": c[1], "blue": c[2], "alpha": alpha, "colorSpace": "extendedSRGB"]
    }
    private static func arcWindowTheme() -> [String: Any] {
        func roles(_ p: [String: [Double]]) -> [String: Any] {
            let ink = p["title"]!, ground = p["background"]!
            return ["background": arcColor(ground), "backgroundExtra": arcColor(p["backgroundExtra"]!), "title": arcColor(ink),
                    "subtitle": arcColor(p["subtitle"]!), "focus": arcColor(themeAccent["midTone"]!, alpha: 0.8),
                    "hover": arcColor([0.5, 0.5, 0.5], alpha: 0.48), "foregroundPrimary": arcColor(ink),
                    "foregroundSecondary": arcColor([0.6, 0.6, 0.6]), "foregroundTertiary": arcColor([0.7, 0.7, 0.7]),
                    "cutoutColor": arcColor(ground), "maxContrastColor": arcColor(ink), "minContrastColor": arcColor(ground)]
        }
        let gradient: [String: Any] = ["baseColors": themeGradient.map { arcColor($0) }, "overlayColors": [Any](), "translucencyStyle": "light",
                                       "modifiers": ["intensityFactor": 0.0, "noiseFactor": 0.0, "overlay": "grain"], "wheel": ["complimentary": [String: Any]()]]
        return [
            "primaryColorPalette": ["midTone": arcColor(themeAccent["midTone"]!), "tintedLight": arcColor(themeAccent["tintedLight"]!),
                                    "shaded": arcColor(themeAccent["shaded"]!), "shadedDark": arcColor([0.08, 0.13, 0.30])],
            "semanticColorPalette": ["appearanceBased": ["light": roles(themeLight), "dark": roles(themeDark)]],
            "background": ["single": ["_0": ["style": ["color": ["_0": ["blendedGradient": ["_0": gradient]]]],
                                             "isVibrant": true, "contentOverBackgroundAppearance": "light"]]]
        ]
    }
    /// The SpaceTheme Bam must keep: Arc's semantic roles per appearance, its accent variants,
    /// and the gradient's two original base colours (not the contrast-eased canvas stops).
    private static var expectedTheme: SpaceTheme {
        func rgba(_ c: [Double]) -> SpaceTheme.RGBA { SpaceTheme.RGBA(red: c[0], green: c[1], blue: c[2])! }
        func roles(_ p: [String: [Double]]) -> SpaceTheme.Roles {
            SpaceTheme.Roles(background: rgba(p["background"]!), backgroundExtra: rgba(p["backgroundExtra"]!), title: rgba(p["title"]!), subtitle: rgba(p["subtitle"]!))
        }
        return SpaceTheme(gradient: themeGradient.map(rgba), light: roles(themeLight), dark: roles(themeDark), accent: rgba(themeAccent["midTone"]!),
                          accentLight: rgba(themeAccent["tintedLight"]!), accentDark: rgba(themeAccent["shaded"]!))!
    }
    /// The page/reference host: the topmost webHost subview other than the transient page
    /// feedback overlay (every import shows "Imported N tabs from Arc" above everything).
    private static func contentHost(of browser: BrowserController) -> NSView? {
        browser.webHost.subviews.last { $0 !== browser.pageFeedback.view }
    }
    private static func encodedTheme(_ theme: SpaceTheme?) -> String? {
        guard let theme else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(theme)).map { String(decoding: $0, as: UTF8.self) }
    }
    /// The layout copy with Work's windowTheme replaced by the full theme above.
    private func withWorkTheme(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var sidebar = root["sidebar"] as? [String: Any], var containers = sidebar["containers"] as? [Any],
              containers.count > 1, var main = containers[1] as? [String: Any], var spaces = main["spaces"] as? [Any],
              let index = spaces.firstIndex(where: { ($0 as? [String: Any])?["title"] as? String == "Work" }),
              var work = spaces[index] as? [String: Any] else { throw Failure.assertion("Fixture layout has a Work Space") }
        var custom = work["customInfo"] as? [String: Any] ?? [:]
        let previous = (((custom["windowTheme"] as? [String: Any])?["primaryColorPalette"] as? [String: Any])?["midTone"] as? [String: Any])
        guard previous?["red"] as? Double == 0.2, previous?["green"] as? Double == 0.4, previous?["blue"] as? Double == 0.9 else {
            throw Failure.assertion("Work keeps the repository fixture's mid-tone")
        }
        custom["windowTheme"] = Self.arcWindowTheme(); work["customInfo"] = custom; spaces[index] = work
        main["spaces"] = spaces; containers[1] = main; sidebar["containers"] = containers; root["sidebar"] = sidebar
        return try JSONSerialization.data(withJSONObject: root)
    }

    // MARK: Imported icons (original synthetic PNGs; nothing is fetched)

    /// A relaunch child of this same executable: `--arc-import-test --arc-icon-child <mode> <dir> <expected icons>`.
    static let childFlag = "--arc-icon-child"
    private enum IconFile { case valid(Int, Int, Int), oversized, garbage, symlink, missing }
    /// Fixture tabs (by Arc saved title) and the cache file each gets. Three tabs share
    /// board.example.com, so their icons must stay distinct per tab, not per origin.
    private static let iconPlan: [(title: String, file: IconFile, today: Bool)] = [
        ("Alpha Board", .valid(225, 40, 40), false), ("Beta Board", .valid(40, 190, 60), false),
        ("Alpha Board copy", .valid(40, 80, 225), false), ("Left Pane", .valid(225, 195, 30), false),
        ("Home Mail", .valid(205, 40, 200), false), ("Today One", .valid(30, 195, 210), true),
        ("Deep Page", .oversized, false), ("PR 1", .garbage, false), ("Right Pane", .symlink, false), ("Docs Home", .missing, false),
    ]
    private static let gammaItemID = "00000000-0000-4000-8000-999999999999"
    private static let gammaColor = (240, 140, 20)
    private struct ExpectedIcon { let itemID: String; let title: String; let color: (Int, Int, Int); let today: Bool }

    private static func png(_ red: Int, _ green: Int, _ blue: Int, size: Int = 32) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: max(2, size / 8), height: max(2, size / 8)))  // corner mark
        return context.makeImage().flatMap(ImportedIconDiskCache.pngData)
    }
    /// Writes `SidebarItemsFaviconCache` beside a layout copy in `folder`, named as Arc names
    /// them, and returns the valid icons expected for the base layout (Gamma's file is extra).
    private func writeIconCache(in folder: URL, source: ArcImport.Source) throws -> [ExpectedIcon] {
        let fm = FileManager.default
        let cache = folder.appendingPathComponent(ArcIconImport.cacheDirectoryName, isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        func itemID(_ title: String) throws -> String {
            let ids = source.nodes.values.compactMap { node -> String? in
                if case .tab(_, let saved) = node.kind, saved == title { return node.id }
                return nil
            }
            guard ids.count == 1 else { throw Failure.assertion("Fixture has exactly one tab saved as \(title)") }
            return ids[0]
        }
        var expected: [ExpectedIcon] = []
        for entry in Self.iconPlan {
            let id = try itemID(entry.title)
            let file = cache.appendingPathComponent(ArcIconImport.fileName(forItemID: id))
            switch entry.file {
            case .valid(let r, let g, let b):
                guard let data = Self.png(r, g, b) else { throw Failure.assertion("Synthetic PNG encodes") }
                try data.write(to: file)
                expected.append(ExpectedIcon(itemID: id, title: entry.title, color: (r, g, b), today: entry.today))
            case .oversized:
                guard let data = Self.png(120, 120, 120, size: 300) else { throw Failure.assertion("Oversized PNG encodes") }
                try data.write(to: file)
            case .garbage: try Data("not an image".utf8).write(to: file)
            case .symlink:
                let outside = folder.appendingPathComponent("outside-icon.png")
                guard let data = Self.png(250, 250, 250) else { throw Failure.assertion("Symlink target PNG encodes") }
                try data.write(to: outside)
                try fm.createSymbolicLink(at: file, withDestinationURL: outside)
            case .missing: break
            }
        }
        guard let gamma = Self.png(Self.gammaColor.0, Self.gammaColor.1, Self.gammaColor.2) else { throw Failure.assertion("Gamma PNG encodes") }
        try gamma.write(to: cache.appendingPathComponent(ArcIconImport.fileName(forItemID: Self.gammaItemID)))
        return expected
    }
    /// The centre pixel of an icon as drawn in sRGB.
    private static func centerColor(_ image: NSImage) -> (Int, Int, Int)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard drawn else { return nil }
        let i = ((height / 2) * width + width / 2) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }
    private static func matches(_ a: (Int, Int, Int)?, _ b: (Int, Int, Int)) -> Bool {
        guard let a else { return false }
        return abs(a.0 - b.0) <= 28 && abs(a.1 - b.1) <= 28 && abs(a.2 - b.2) <= 28
    }
    private func tabID(forItem itemID: String, in session: BrowserSession) -> UUID? {
        guard let link = session.importLinks?["arc:\(itemID)"], link.hasPrefix("tab:") else { return nil }
        return UUID(uuidString: String(link.dropFirst(4)))
    }
    /// What the sidebar would draw for an imported tab (`favicon(forTabID:)`).
    private func shownColor(_ itemID: String) -> (Int, Int, Int)? {
        guard let id = tabID(forItem: itemID, in: controller.session), let image = controller.favicon(forTabID: id) else { return nil }
        return Self.centerColor(image)
    }
    /// Every expected icon shows on its own tab, in its own colour.
    private func requireIcons(_ expected: [ExpectedIcon], _ label: String) throws {
        for icon in expected {
            try check(Self.matches(shownColor(icon.itemID), icon.color), "\(label): \(icon.title) shows its own imported icon (\(String(describing: shownColor(icon.itemID))))")
        }
    }
    private static func treeDigest(_ folder: URL) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        var parts: [String] = []
        for case let file as URL in enumerator where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let data = (try? Data(contentsOf: file)) ?? Data()
            parts.append(String(file.path.dropFirst(folder.path.count)) + ":" + ImportedIconDiskCache.sha256(data))
        }
        return parts.sorted().joined(separator: "\n")
    }

    /// Relaunches this same app executable in a child mode on `folder` and returns its summary.
    private func launchChild(_ mode: String, folder: URL, expected: Int) async throws -> [String: Any] {
        guard !finished, activeChild == nil else { throw Failure.assertion("No relaunch starts while the fixture is finishing or another child runs") }
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--arc-import-test", Self.childFlag, mode, folder.path, String(expected)]
        let output = Pipe(), collected = ChildOutput()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { collected.end(); handle.readabilityHandler = nil } else { collected.append(chunk) }
        }
        child.standardOutput = output
        try child.run()
        activeChild = child
        let deadline = Date().addingTimeInterval(90)
        while child.isRunning && Date() < deadline && !finished { try await Task.sleep(for: .milliseconds(100)) }
        // finish() owns the child once the fixture is finishing.
        guard !finished else { throw Failure.assertion("\(mode) relaunch interrupted by fixture shutdown") }
        if child.isRunning {
            let stopped = await stopChild(child)
            output.fileHandleForReading.readabilityHandler = nil
            throw Failure.assertion("\(mode) relaunch timed out after 90 s; \(stopped ? "stopped and confirmed exited" : "could not be confirmed stopped")")
        }
        activeChild = nil
        // Bounded drain: the pipe normally reaches EOF at exit; never wait more than 2 s for it.
        for _ in 0..<40 where !collected.isEnded { try await Task.sleep(for: .milliseconds(50)) }
        output.fileHandleForReading.readabilityHandler = nil
        let text = collected.text
        let lines = text.split(separator: "\n").map(String.init)
        let pid = child.processIdentifier
        guard let startIndex = lines.firstIndex(of: "ARC_ICON_CHILD_START mode=\(mode) pid=\(pid)"),
              let summaryIndex = lines.lastIndex(where: { $0.hasPrefix("ARC_ICON_CHILD ") }), startIndex < summaryIndex,
              let summary = try JSONSerialization.jsonObject(with: Data(lines[summaryIndex].dropFirst("ARC_ICON_CHILD ".count).utf8)) as? [String: Any] else {
            throw Failure.assertion("\(mode) relaunch printed no start marker then summary (exit \(child.terminationStatus))")
        }
        try check(!child.isRunning && child.terminationReason == .exit && child.terminationStatus == 0 && summary["ok"] as? Bool == true,
                  "\(mode) relaunch exited cleanly (exit \(child.terminationStatus), error: \(summary["error"] ?? "none"))")
        try check(summary["pid"] as? Int == Int(pid) && pid != getpid() && summary["mode"] as? String == mode,
                  "\(mode) summary comes from its own new process (pid \(pid))")
        childPIDs.append(pid)
        return summary
    }
    private func childColorsMatch(_ summary: [String: Any], _ expected: [ExpectedIcon]) -> Bool {
        guard let colors = summary["colors"] as? [String: [Int]], colors.count == expected.count else { return false }
        return expected.allSatisfy { icon in
            guard let c = colors[icon.itemID], c.count == 3 else { return false }
            return Self.matches((c[0], c[1], c[2]), icon.color)
        }
    }

    /// Child side. `import`: temp controller whose session and icon cache live in `folder`
    /// (website data and extension host stay private), commits the layout, waits for the
    /// icons and their disk records. `reload`: a new process loading that session before
    /// its view loads, so launch-time restore runs. `private`: a fully private controller
    /// on the same session must restore nothing. Prints one ARC_ICON_CHILD line and exits.
    private func runChild(mode: String, folder: URL, expected: Int) async {
        print("ARC_ICON_CHILD_START mode=\(mode) pid=\(getpid())"); fflush(stdout)
        var summary: [String: Any] = ["mode": mode, "pid": Int(getpid())]
        do {
            let sessionURL = folder.appendingPathComponent("session.json")
            let browser = BrowserController(sessionURL: sessionURL, ephemeral: true)
            controller = browser
            // Create the extension host while still private, so it never uses persistent storage.
            if #available(macOS 15.4, *) { _ = browser.browserExtensions }
            if mode == "import" {
                let start = BrowserTab(title: "Start", address: "orbit://newtab", space: 0)
                browser.session = BrowserSession(tabs: [start], activeID: start.id)
                browser.privateMode = false
                browser.sessionWriter = SessionWriter(url: sessionURL)
            } else {
                browser.session = SessionFile.load(sessionURL)
                if mode == "reload" { browser.privateMode = false }  // no writer: reload never saves
            }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Bam Arc icon relaunch (\(mode))"; window.isReleasedWhenClosed = false
            window.contentViewController = browser  // view load runs restoreImportedIcons
            window.setContentSize(NSSize(width: 900, height: 600)); window.orderFront(nil)
            switch mode {
            case "import":
                let source = try ArcImport.load(from: folder.appendingPathComponent(ArcImport.sourceFileName))
                let message = await commitDirectly(source)
                guard message == nil else { throw Failure.assertion("Child import failed: \(message!)") }
                try await wait("Child icons installed", timeout: 20) { browser.importedTabIcons.count == expected }
                let disk = browser.importedIconDisk
                summary["disk_records"] = browser.importedIconQueue.sync { disk?.recordCount ?? -1 }
            case "reload":
                try await wait("Relaunch restores icons", timeout: 20) { browser.importedTabIcons.count == expected }
            default:
                try await Task.sleep(for: .milliseconds(1500))
            }
            var colors: [String: [Int]] = [:]
            for (key, value) in browser.session.importLinks ?? [:] where key.hasPrefix("arc:") && value.hasPrefix("tab:") {
                guard let id = UUID(uuidString: String(value.dropFirst(4))), let image = browser.favicon(forTabID: id),
                      let c = Self.centerColor(image) else { continue }
                colors[String(key.dropFirst(4))] = [c.0, c.1, c.2]
            }
            summary["icons"] = browser.importedTabIcons.count
            summary["colors"] = colors
            // The Easel reference survives the relaunch in its place and is shown natively.
            if let work = browser.session.spaces.first(where: { $0.name == "Work" }) {
                summary["work_rows"] = rows(browser.session, work.id)
                summary["work_theme"] = Self.encodedTheme(work.theme) ?? "none"
            }
            let easels = browser.session.tabs.filter { $0.isArcEasel && importedTabIDs(browser.session).contains($0.id) }
            summary["easel_rows"] = easels.map(\.displayTitle)
            if mode != "private", easels.count == 1 {
                browser.select(easels[0].id)
                summary["easel_native"] = browser.browsers[easels[0].id] == nil && !browser.pendingLoads.contains(easels[0].id)
                    && (Self.contentHost(of: browser) as? EaselReferenceView)?.shownName == easels[0].displayTitle
            }
            summary["imported_pages"] = importedTabIDs(browser.session).intersection(browser.browsers.keys).count
            summary["ok"] = true
        } catch {
            summary["ok"] = false; summary["error"] = String(describing: error)
        }
        controller?.prepareToClose(); window?.orderOut(nil)
        let data = (try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])) ?? Data("{\"ok\":false}".utf8)
        print("ARC_ICON_CHILD " + (String(data: data, encoding: .utf8) ?? "{\"ok\":false}")); fflush(stdout)
        exit(summary["ok"] as? Bool == true ? 0 : 1)
    }

    func start() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: Self.childFlag), arguments.count > index + 3, let expected = Int(arguments[index + 3]) {
            // Off the main run loop, so a child whose main thread stalls still exits on its own.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 75) {
                print("ARC_ICON_CHILD {\"ok\":false,\"error\":\"child timeout\"}"); fflush(stdout); exit(1)
            }
            Task { @MainActor in await runChild(mode: arguments[index + 1], folder: URL(fileURLWithPath: arguments[index + 2], isDirectory: true), expected: expected) }
            return
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.parentDeadline, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(false, "Overall fixture timeout") }
        }
        // Last resort if the main thread stalls: exit without signalling anything. A raw PID
        // could already belong to another process by now; each relaunch child enforces its own
        // 75 s exit. The temporary folder is left in place rather than removed.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.parentHardDeadline) {
            print("FAIL: Arc import — hard deadline reached with the main thread unresponsive; temporary folder left in place")
            fflush(stdout); exit(1)
        }
        Task { @MainActor in
            do {
                try await run()
                finish(true, "\(checks) checks through the real Import from Arc sheet and callbacks: preview/cancel without mutation, options, locked controls while saving, verified success and dismissal, preview-equals-commit counts, one blank landing with and without Today, Spaces/emoji/profiles, nested folders, Splits, per-profile Favorites and overflow, dormancy, verified save and reload, repeat without duplication, unconfirmed and confirmed undo after failed saves, locked sheet during a slow write, incremental re-import; imported icons from original synthetic cache PNGs (per tab on a shared site, profile-scoped, invalid files fall back, none for previews/cancels/undone imports, no page or fetch) with persistence and isolation verified across relaunched processes; the Arc Easel kept as a named reference row in its place, shown natively without page or connection, before and after relaunch")
            } catch { finish(false, String(describing: error)) }
        }
    }

    // MARK: Helpers

    private func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.assertion(message) }
        checks += 1
    }
    private func wait(_ message: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw Failure.assertion("Timeout: \(message)") }
            try await Task.sleep(for: .milliseconds(30))
        }
        checks += 1
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    /// What an import may add or must leave alone: not selection, counters or
    /// per-tab runtime state such as sleep snapshots and live titles.
    private struct Layout: Encodable {
        struct Tab: Encodable { let id: UUID, address: String, space: Int, folderID: UUID?, saved: SavedTabState? }
        let tabs: [Tab], folders: [BrowserFolder], spaces: [BrowserSpace], profiles: [BrowserProfile]
        let splits: [BrowserSplit]?, importLinks: [String: String]?
        init(_ s: BrowserSession) {
            tabs = s.tabs.map { Tab(id: $0.id, address: $0.address, space: $0.space, folderID: $0.folderID, saved: $0.saved) }
            folders = s.folders; spaces = s.spaces; profiles = s.profiles; splits = s.splits; importLinks = s.importLinks
        }
    }
    /// One commit through the sheet: controls lock while saving, the sheet
    /// closes on verified success, and the window lands on exactly one new
    /// blank tab while every newly imported tab stays without a page.
    private func commitThroughSheet(_ sheet: ArcImportController, _ label: String) async throws -> (planned: ArcImport.Report, added: [BrowserTab]) {
        guard let planned = sheet.report else { throw Failure.assertion("\(label): preview exists") }
        let before = controller.session
        let linkedBefore = importedTabIDs(before)
        sheet.importButton.performClick(nil)
        try check(sheet.isCommitting && !sheet.importButton.isEnabled && !sheet.cancelButton.isEnabled,
                  "\(label): controls lock while the import saves")
        try await waitForDismissal(sheet, label)
        let after = controller.session
        let newlyImported = importedTabIDs(after).subtracting(linkedBefore)
        let added = after.tabs.filter { tab in !before.tabs.contains { $0.id == tab.id } }
        let landing = added.filter { !newlyImported.contains($0.id) }
        // Easel references are provenance-linked rows but not counted in importedTabs.
        let rowsPlanned = planned.importedTabs + planned.easelReferences
        try check(newlyImported.count == rowsPlanned && added.count == rowsPlanned + 1,
                  "\(label): adds exactly the previewed tabs and Easel references (\(newlyImported.count)/\(rowsPlanned)) plus one landing tab")
        try check(landing.count == 1 && landing[0].id == after.activeID && landing[0].isHome && !landing[0].isSaved
                  && landing[0].space == planned.firstSpaceID,
                  "\(label): lands on exactly one new blank tab in the first imported Space")
        try check(importedTabIDs(after).isDisjoint(with: controller.browsers.keys), "\(label): no imported tab has a page")
        try check(after.folders.count - before.folders.count == planned.importedFolders, "\(label): adds exactly the previewed folders")
        return (planned, added)
    }
    private func layout(_ session: BrowserSession) throws -> Data { try encoded(Layout(session)) }
    /// Tabs created by an import, by provenance rather than by novelty.
    private func importedTabIDs(_ session: BrowserSession) -> Set<UUID> {
        Set((session.importLinks ?? [:]).values.compactMap { $0.hasPrefix("tab:") ? UUID(uuidString: String($0.dropFirst(4))) : nil })
    }
    private func rows(_ session: BrowserSession, _ space: Int) -> [String] {
        session.keptLayout(in: space).map { entry in
            let name = entry.isFolder ? "[" + (session.folder(entry.id)?.name ?? "?") + "]"
                : session.tabs.first { $0.id == entry.id }.map(\.displayTitle) ?? "?"
            return String(repeating: "  ", count: entry.depth) + name
        }
    }

    /// The real File ▸ Import from Arc… sheet with its real preview, commit and
    /// dismiss callbacks. A nil initial source opens it empty, so no personal
    /// Arc layout is read; each step then loads the synthetic fixture.
    private func presentImporter() async throws -> ArcImportController {
        guard let sheet = controller.presentArcImport(initialSourceURL: nil) else {
            throw Failure.assertion("Import from Arc opens its sheet")
        }
        importer = sheet
        try check(controller.arcImporter === sheet && sheet.source == nil, "The sheet opens empty, reading no layout")
        try await wait("Import sheet attaches to the browser window") { window.attachedSheet === sheet.window }
        return sheet
    }
    /// The sheet's error line, once a commit has finished with a failure.
    private func sheetError(_ sheet: ArcImportController) -> String? {
        guard !sheet.isCommitting, !sheet.status.isHidden, sheet.status.textColor == .systemRed,
              !sheet.status.stringValue.isEmpty else { return nil }
        return sheet.status.stringValue
    }
    private func waitForDismissal(_ sheet: ArcImportController, _ label: String) async throws {
        let deadline = Date().addingTimeInterval(40)
        while controller.arcImporter != nil || window.attachedSheet != nil {
            guard Date() < deadline else {
                throw Failure.assertion("Timeout: \(label): sheet dismissed (committing: \(sheet.isCommitting), error: \(sheetError(sheet) ?? "none"))")
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        checks += 1
        importer = nil
    }
    private func commitDirectly(_ source: ArcImport.Source) async -> String? {
        await withCheckedContinuation { continuation in
            controller.commitArcImport(source, options: ArcImport.Options()) { continuation.resume(returning: $0) }
        }
    }
    /// The fixture plus one new kept tab after “Beta Board” in “Projects”.
    private func grownFixture(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var sidebar = root["sidebar"] as? [String: Any], var containers = sidebar["containers"] as? [Any],
              containers.count > 1, var main = containers[1] as? [String: Any], var items = main["items"] as? [Any],
              let index = items.firstIndex(where: { ($0 as? [String: Any])?["title"] as? String == "Projects" }),
              var projects = items[index] as? [String: Any], let projectsID = projects["id"] as? String,
              let children = projects["childrenIds"] as? [String] else { throw Failure.assertion("Fixture has a Projects folder") }
        let id = "00000000-0000-4000-8000-999999999999"
        projects["childrenIds"] = children + [id]; items[index] = projects
        let gamma: [String: Any] = ["id": id, "childrenIds": [String](), "parentID": projectsID, "title": NSNull(),
                                    "createdAt": 0.0, "isUnread": false, "originatingDevice": "fixture",
                                    "data": ["tab": ["savedURL": gammaAddress, "savedTitle": "Gamma Board", "timeLastActiveAt": 0.0]]]
        items += [id, gamma]
        main["items"] = items; containers[1] = main; sidebar["containers"] = containers; root["sidebar"] = sidebar
        return try JSONSerialization.data(withJSONObject: root)
    }

    // MARK: Run

    private func run() async throws {
        guard let raw = ProcessInfo.processInfo.environment["BAM_TEST_URL"], let page = URLInput.directURL(raw),
              let remote = URL(string: "arc/StorableSidebar.json", relativeTo: page)?.absoluteURL else {
            throw Failure.assertion("Set BAM_TEST_URL to the runtime loopback fixture")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (served, response) = try await URLSession.shared.data(from: remote)
        try check((response as? HTTPURLResponse)?.statusCode == 200, "Loopback server serves the repository Arc fixture")
        // Every imported address points at this listener, so "no page, no fetch" is observed, not assumed.
        tripwirePort = try await tripwire.start()
        gammaAddress = tripwireAddress(Self.gammaSourceAddress)
        // Work also gets a full Arc Space theme in the real windowTheme schema (original values).
        let data = try withWorkTheme(pointedAtTripwire(served))
        let fixture = directory.appendingPathComponent(ArcImport.sourceFileName)
        try data.write(to: fixture)
        let source = try ArcImport.load(from: fixture)
        try check(source.spaces.map(\.title) == ["Work", "Home", "Side"], "Repository fixture is the original synthetic layout")
        try check(source.nodes.values.contains { if case .tab(let url, _) = $0.kind { return url.hasPrefix("http://127.0.0.1:\(tripwirePort)/") }; return false }
                  && !source.nodes.values.contains { if case .tab(let url, _) = $0.kind { return url.hasPrefix("https://") }; return false },
                  "Every web address in the layout copy points at the tripwire")
        try check(source.spaces.first { $0.title == "Work" }?.theme == Self.expectedTheme && source.spaces.filter { $0.theme != nil }.count == 1,
                  "Work's Arc theme parses to exactly its semantic roles, accents and two original gradient colours")
        let icons = try writeIconCache(in: directory, source: source)
        let iconTitles = Set(icons.map(\.title))
        let rejectedIconItems = try Self.iconPlan.filter { !iconTitles.contains($0.title) }.map { entry -> (String, String) in
            guard let node = source.nodes.values.first(where: { if case .tab(_, let saved) = $0.kind { return saved == entry.title }; return false })
            else { throw Failure.assertion("Fixture has \(entry.title)") }
            return (entry.title, node.id)
        }

        // A browser with one existing loopback tab. Non-persistent stores; a
        // real writer on a temporary file, as TabResourceSmokeTest does.
        controller = BrowserController(sessionURL: sessionFile, ephemeral: true)
        let existing = BrowserTab(title: "Existing", address: page.absoluteString, space: 0)
        controller.session = BrowserSession(tabs: [existing], activeID: existing.id)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Bam Arc import fixture"; window.isReleasedWhenClosed = false
        window.contentViewController = controller; window.setContentSize(NSSize(width: 1100, height: 720))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait("Fixture browser window is key") { NSApp.isActive && window.isKeyWindow }
        try await wait("Existing tab loads") { controller.activeWebView.map { !$0.isLoading && $0.url != nil } ?? false }
        let writer = SessionWriter(url: sessionFile)
        controller.privateMode = false; controller.sessionWriter = writer
        controller.save()
        try check(await writer.flushAsync(timeout: 5), "Writer saves the pre-import session")
        let original = controller.session
        let originalLayout = try layout(original)

        // 1. Preview, options and Cancel change nothing.
        var sheet = try await presentImporter()
        try check(!sheet.importButton.isEnabled, "Import is disabled until a layout is chosen")
        sheet.load(fixture)
        guard let preview = sheet.report else { throw Failure.assertion("Choosing the fixture produces a preview") }
        try check(preview.refusal == nil && !preview.isEmpty && sheet.importButton.isEnabled, "Preview enables Import")
        try check(preview.spaces.map(\.title) == ["Work", "Home", "Side"] && preview.spaces.allSatisfy(\.isNew), "Preview lists three new Spaces")
        try check(preview.importedThemes == 1 && preview.spaces.map(\.theme) == [true, false, false], "Preview marks Work's Arc theme, and only Work's")
        try check(preview.easels == 0 && preview.easelReferences == 1 && preview.spaces.first?.easels == 1 && preview.liveFolders == 1 && preview.invalidAddresses == 1 && preview.oversizedSplits == 1
                  && preview.favoriteOverflow == 2 && preview.unattachedProfiles == 1 && preview.flattenedTodayFolders == 1,
                  "Preview reports every approximation the fixture contains")
        let todayInPreview = preview.spaces.reduce(0) { $0 + $1.todayTabs }
        try check(todayInPreview > 0, "Preview counts Today tabs")
        sheet.todayBox.performClick(nil)
        try check(sheet.report?.spaces.reduce(0, { $0 + $1.todayTabs }) == 0
                  && sheet.report?.importedTabs == preview.importedTabs - todayInPreview, "Excluding Today updates the preview")
        sheet.todayBox.performClick(nil)
        try check(sheet.report == preview, "Re-including Today restores the original preview")
        try check(try layout(controller.session) == originalLayout && controller.session.space == original.space,
                  "Previewing never mutates the browser session")
        sheet.cancelButton.performClick(nil)
        try await waitForDismissal(sheet, "Cancel")
        try check(try layout(controller.session) == originalLayout, "Cancelled import leaves the session unchanged")
        try check(SessionFile.load(sessionFile).importLinks == nil, "Cancelled import writes nothing imported")
        try await Task.sleep(for: .milliseconds(300))
        try check(controller.importedTabIcons.count == 0, "Previews and Cancel install no icons")

        // 2a. Commit through the sheet with Today excluded.
        sheet = try await presentImporter()
        sheet.load(fixture)
        sheet.todayBox.performClick(nil)
        let first = try await commitThroughSheet(sheet, "Import without Today")
        try check(first.planned.spaces.allSatisfy { $0.todayTabs == 0 } && first.planned.importedTabs == preview.importedTabs - todayInPreview,
                  "Import without Today previews no Today tabs")
        // The imported theme: exactly Arc's colours and original gradient, on the Space now shown,
        // and showing that themed Space wakes no imported page and connects nowhere.
        try check(first.planned.importedThemes == 1, "The kept import brings Work's theme")
        if let workSpace = controller.session.spaces.first(where: { $0.name == "Work" }) {
            try check(workSpace.theme == Self.expectedTheme && workSpace.theme?.gradient == Self.expectedTheme.gradient,
                      "Work keeps Arc's semantic colours, accents and original two-colour gradient")
            try check(controller.session.space == workSpace.id && importedTabIDs(controller.session).isDisjoint(with: controller.browsers.keys)
                      && tripwire.connections == 0, "Showing the themed Space wakes no imported page and makes no connection")
        } else { throw Failure.assertion("Work exists after the kept import") }
        guard let work = controller.session.spaces.first(where: { $0.name == "Work" }),
              let home = controller.session.spaces.first(where: { $0.name == "Home" }),
              let side = controller.session.spaces.first(where: { $0.name == "Side" }) else { throw Failure.assertion("Imported Spaces exist") }
        try check(controller.session.space == work.id && first.planned.firstSpaceID == work.id, "Commit shows the first imported Space")
        try check(!controller.session.tabs.contains { importedTabIDs(controller.session).contains($0.id) && !$0.isSaved },
                  "No Today tab is imported when Today is excluded")

        // Icons for exactly the tabs this import added, read from the synthetic cache after the save.
        let firstIcons = icons.filter { !$0.today }
        try await wait("Imported icons appear after the verified save") { controller.importedTabIcons.count == firstIcons.count }
        try requireIcons(firstIcons, "Import without Today")
        let sameSite = firstIcons.filter { ["Alpha Board", "Beta Board", "Alpha Board copy"].contains($0.title) }.compactMap { shownColor($0.itemID) }
        try check(sameSite.count == 3 && !Self.matches(sameSite[0], sameSite[1]) && !Self.matches(sameSite[0], sameSite[2]) && !Self.matches(sameSite[1], sameSite[2]),
                  "Three tabs on one site keep three distinct icons")
        for (title, itemID) in rejectedIconItems {
            try check(tabID(forItem: itemID, in: controller.session) != nil && shownColor(itemID) == nil,
                      "\(title): an oversized, non-image, symlinked or missing cache file leaves the normal fallback")
        }
        if let mail = icons.first(where: { $0.title == "Home Mail" }), let mailID = tabID(forItem: mail.itemID, in: controller.session),
           let mailTab = controller.session.tabs.first(where: { $0.id == mailID }) {
            let address = mailTab.saved?.address ?? mailTab.address
            try check(controller.importedTabIcons.image(for: mailID, address: address, profile: home.profileID) != nil
                      && controller.importedTabIcons.image(for: mailID, address: address, profile: BrowserProfile.defaultID) == nil,
                      "An imported icon belongs to the tab's login profile only")
        } else { throw Failure.assertion("Home Mail was imported") }
        try check(importedTabIDs(controller.session).isDisjoint(with: controller.browsers.keys), "Showing imported icons creates no page")
        try check(tripwire.connections == 0, "Import and icon display made no connection to any imported address (\(tripwire.requestLines))")
        try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ImportedIcons").path),
                  "A controller that loaded as private keeps imported icons in memory only")

        // 2b. Re-import with Today: only Today tabs are added, again landing on one blank tab.
        sheet = try await presentImporter()
        sheet.load(fixture)
        let second = try await commitThroughSheet(sheet, "Import Today afterwards")
        try check(second.planned.importedTabs == todayInPreview && second.planned.importedFolders == 0
                  && second.planned.spaces.allSatisfy { !$0.isNew }, "Second import adds only the Today tabs to existing Spaces")
        try check(second.planned.importedThemes == 0 && controller.session.spaceDefinition(work.id)?.theme == Self.expectedTheme,
                  "The re-import neither reapplies nor changes Work's theme")
        let session = controller.session
        let importedIDs = importedTabIDs(session)
        let imported = session.tabs.filter { importedIDs.contains($0.id) }
        try check(first.planned.easelReferences == 1 && second.planned.easelReferences == 0, "The Easel reference arrives with the kept import, once")
        try check(imported.count == preview.importedTabs + preview.easelReferences,
                  "Both imports together add exactly the full preview (\(imported.count)/\(preview.importedTabs + preview.easelReferences))")
        try check(original.tabs.allSatisfy { tab in session.tabs.contains { $0.id == tab.id && $0.address == tab.address && $0.space == tab.space && $0.saved == tab.saved } },
                  "Existing tabs survive unchanged")
        try check(work.emoji == "💼" && home.emoji == "🏠" && side.emoji == "🧪", "Space emoji preserved")
        try await wait("The Today re-import adds its own icons") { controller.importedTabIcons.count == icons.count }
        try requireIcons(icons, "After the Today import")

        // Profiles: default Arc profile -> Bam default; custom -> its own new profile.
        try check(work.profileID == BrowserProfile.defaultID && side.profileID == BrowserProfile.defaultID, "Default Arc profile maps to Bam's default")
        try check(home.profileID != BrowserProfile.defaultID && session.profiles.contains { $0.id == home.profileID }
                  && !original.profiles.contains { $0.id == home.profileID } && first.planned.newProfiles.count == 1,
                  "Custom Arc profile becomes one new Bam login profile")

        // Hierarchy: nested folders, empty folder, duplicate URL, Splits, overflow.
        let workRows = rows(session, work.id)
        let expected = ["[More Favorites]", "  Fav 13", "  Fav 14", "Team Docs", "[Projects]", "  Alpha Board", "  [Alpha]",
                        "    [Level 2]", "      [Level 3]", "        [Level 4]", "          Deep Page", "  Beta Board",
                        "[Empty]", "Alpha Board copy", "Sketch", "Left Pane", "[Pull Requests]", "  PR 1", "Wide 1", "Wide 3"]
        try check(workRows == expected, "Work kept hierarchy matches Arc order, the Easel in its place (\(workRows.count) rows)")
        try check(session.folders.map { session.folderDepth($0.id) }.max() == 4, "Five-level folder nesting is represented")
        guard let left = imported.first(where: { $0.title == "Left Pane" }), let right = imported.first(where: { $0.title == "Right Pane" }),
              let wide = imported.first(where: { $0.title == "Wide 1" }) else { throw Failure.assertion("Split panes imported") }
        try check(session.split(for: left.id) == BrowserSplit(primaryID: left.id, secondaryID: right.id), "Arc Split becomes a Bam Split")
        try check(imported.contains { $0.title == "Wide 2" } && session.split(for: wide.id) != nil, "Oversized Split keeps two panes and its extra pane")

        // Favorites stay per profile.
        try check(session.favorites(in: BrowserProfile.defaultID).count == 12, "Twelve default-profile Favorites")
        try check(session.favorites(in: home.profileID).map(\.title) == ["Home Mail"], "Custom profile keeps its own Favorite")
        try check(!session.tabs.contains { $0.title.hasPrefix("Other ") }, "Unattached profile Favorites are not imported by default")

        // Dormancy: no imported page exists until the user selects one.
        try check(imported.filter(\.isSaved).allSatisfy(\.isUnloaded), "Imported kept tabs and Favorites are dormant")
        try check(importedIDs.isDisjoint(with: controller.browsers.keys), "No imported tab has a page after import")
        try check(Set(imported.filter { !$0.isSaved }.map(\.title)).isSuperset(of: ["Today One", "Today Two", "Loose Today"]),
                  "Today tabs stay ordinary tabs; Today folders flatten")

        // 3. Persisted through the real writer and reloaded as at launch.
        try check(writer.isLatestSnapshotSaved, "Commit confirmed the import reached disk")
        let reloaded = SessionFile.load(sessionFile)
        try check(try layout(reloaded) == layout(session), "Reloaded session keeps imported tabs, folders, Spaces, profiles, Splits and provenance")
        try check(rows(reloaded, work.id) == expected, "Reloaded hierarchy is identical")
        try check(reloaded.tabs.filter { importedIDs.contains($0.id) && $0.isSaved }.allSatisfy(\.isUnloaded), "Reloaded imported tabs are still dormant")
        try check(reloaded.spaceDefinition(work.id)?.theme == Self.expectedTheme, "The saved session keeps Work's theme exactly")

        // The imported Easel: one named, dormant kept reference row in its place, without a web
        // address. Selecting it shows the native reference, with no page and no connection.
        let easels = imported.filter(\.isArcEasel)
        guard easels.count == 1, let sketch = easels.first else { throw Failure.assertion("The fixture Easel imports as exactly one reference row (\(easels.count))") }
        try check(sketch.displayTitle == "Sketch" && sketch.saved?.kind == .kept && sketch.isUnloaded && sketch.space == work.id
                  && sketch.folderID == nil && !sketch.address.lowercased().hasPrefix("http"),
                  "The Easel is a dormant kept row named Sketch at Work's top level, with no web address")
        try check(reloaded.tabs.contains { $0.id == sketch.id && $0.isArcEasel && $0.displayTitle == "Sketch" }, "The Easel reference row is saved")
        controller.select(sketch.id)
        try check(controller.session.activeID == sketch.id && controller.browsers[sketch.id] == nil
                  && (Self.contentHost(of: controller) as? EaselReferenceView)?.shownName == "Sketch",
                  "Selecting the imported Easel row shows its native reference view, with no page")
        try await Task.sleep(for: .milliseconds(300))
        try check(controller.browsers[sketch.id] == nil && !controller.pendingLoads.contains(sketch.id) && tripwire.connections == 0,
                  "The Easel reference creates no renderer, requests nothing and connects nowhere")

        // 4. Repeat import of the same layout adds nothing and cannot commit.
        let committedLayout = try layout(controller.session)
        sheet = try await presentImporter()
        sheet.load(fixture)
        guard let repeated = sheet.report else { throw Failure.assertion("Repeat preview") }
        try check(repeated.isEmpty && repeated.alreadyImported > 0 && !sheet.importButton.isEnabled, "Repeat preview finds everything already imported")
        try check(await commitDirectly(source) == repeated.emptyReason, "A forced repeat commit is refused with the preview's reason")
        try check(try layout(controller.session) == committedLayout, "Repeat import leaves the session unchanged")
        sheet.cancelButton.performClick(nil)
        try await waitForDismissal(sheet, "Repeat cancel")

        // 5. One new Arc item, imported three times in the same sheet:
        //    a) every write fails, so the undo can't be confirmed and says so;
        //    b) only the import's write fails, so the undo is written and confirmed;
        //    c) the write is slow but succeeds, so the sheet waits, then closes.
        let grown = directory.appendingPathComponent("Grown.json")
        try grownFixture(data).write(to: grown)
        let beforeFailureLayout = try layout(controller.session)
        let address = gammaAddress
        sheet = try await presentImporter()
        sheet.load(grown)
        try check(sheet.report?.importedTabs == 1 && sheet.report?.spaces.allSatisfy({ !$0.isNew }) == true,
                  "Preview finds exactly the one new Arc item in existing Spaces")

        // a) Disk refuses everything.
        let refusing = SessionWriter(url: sessionFile) { _, _ in throw WriteRefused() }
        controller.sessionWriter = refusing
        sheet.importButton.performClick(nil)
        try check(sheet.isCommitting, "Import starts saving")
        try await wait("Unconfirmed undo is reported", timeout: 75) { self.sheetError(sheet) != nil }
        try check(sheetError(sheet) == Self.unconfirmedUndo, "An unsaved undo says it can't confirm the tabs are saved")
        try check(window.attachedSheet === sheet.window && controller.arcImporter === sheet && sheet.cancelButton.isEnabled,
                  "Sheet stays open and usable after a failed save")
        try check(try layout(controller.session) == beforeFailureLayout && !refusing.isLatestSnapshotSaved,
                  "The import is undone in the window although the undo is not on disk")
        try check(!controller.session.tabs.contains { $0.address == address }
                  && controller.browsers.keys.allSatisfy { id in controller.session.tabs.contains { $0.id == id } },
                  "Undo leaves no imported tab or orphan page")

        // b) Only snapshots holding the new item fail. The file is removed
        //    first, so its reappearance proves the undo itself was written.
        let log = WriteLog()
        controller.sessionWriter = SessionWriter(url: sessionFile) { snapshot, url in
            if snapshot.tabs.contains(where: { $0.address == address }) { log.record("refused"); throw WriteRefused() }
            try SessionFile.save(snapshot, to: url); log.record("saved")
        }
        try FileManager.default.removeItem(at: sessionFile)
        try check(sheet.report?.importedTabs == 1 && sheet.importButton.isEnabled, "The same item can be imported again")
        sheet.importButton.performClick(nil)
        try await wait("Confirmed undo is reported", timeout: 75) { self.sheetError(sheet) != nil }
        try check(sheetError(sheet) == Self.confirmedUndo, "A saved undo says nothing was added")
        let events = log.events
        try check(events.first == "refused" && events.dropFirst().contains("saved"),
                  "The import's write failed, then the undo was written (\(events))")
        try check(FileManager.default.fileExists(atPath: sessionFile.path)
                  && (try layout(SessionFile.load(sessionFile))) == beforeFailureLayout, "The written undo matches the layout before the import")
        try check(try layout(controller.session) == beforeFailureLayout, "The window matches the saved undo")
        try check(controller.session.spaceDefinition(work.id)?.theme == Self.expectedTheme
                  && SessionFile.load(sessionFile).spaceDefinition(work.id)?.theme == Self.expectedTheme,
                  "Undoing a later failed import keeps the earlier imported theme, in the window and on disk")
        try await Task.sleep(for: .milliseconds(400))
        try check(controller.importedTabIcons.count == icons.count && tabID(forItem: Self.gammaItemID, in: controller.session) == nil,
                  "Undone imports install no icons")

        // c) A slow but successful write keeps the sheet waiting, locked.
        controller.sessionWriter = SessionWriter(url: sessionFile) { snapshot, url in
            Thread.sleep(forTimeInterval: 1.5); try SessionFile.save(snapshot, to: url)
        }
        try check(sheet.importButton.isEnabled, "Import is available after a confirmed undo")
        sheet.importButton.performClick(nil)
        try await Task.sleep(for: .milliseconds(800))
        try check(sheet.isCommitting && window.attachedSheet === sheet.window && !sheet.cancelButton.isEnabled && sheetError(sheet) == nil,
                  "The sheet stays open and locked while the write is in flight")
        try await waitForDismissal(sheet, "Slow successful import")
        controller.sessionWriter = writer
        let merged = rows(controller.session, work.id)
        try check(controller.session.tabs.filter { $0.address == address }.count == 1
                  && importedTabIDs(controller.session).count == importedIDs.count + 1, "Retry adds only the new item")
        try check(merged.firstIndex(of: "  Gamma Board") == merged.firstIndex(of: "  Beta Board").map { $0 + 1 }, "New item lands after its source sibling")
        try check(merged.filter { $0 != "  Gamma Board" } == expected, "Existing imported layout is untouched")
        try check(SessionFile.load(sessionFile).tabs.filter { $0.address == address }.count == 1, "Retry reaches disk")
        try check(importedTabIDs(controller.session).isDisjoint(with: controller.browsers.keys), "Re-imported item is dormant too")
        try await wait("The re-imported item gets its icon") { controller.importedTabIcons.count == icons.count + 1 }
        try check(Self.matches(shownColor(Self.gammaItemID), Self.gammaColor), "The re-imported item shows its own icon")
        try requireIcons(icons, "After the re-import")
        try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ImportedIcons").path),
                  "The private controller never wrote an icon cache")
        try check(tripwire.connections == 0, "Every import, undo and retry made no connection to any imported address (\(tripwire.requestLines))")

        // 6. Relaunch: fresh processes of this same app on an owned temporary session.
        let persist = directory.appendingPathComponent("relaunch", isDirectory: true)
        try FileManager.default.createDirectory(at: persist, withIntermediateDirectories: true)
        try data.write(to: persist.appendingPathComponent(ArcImport.sourceFileName))
        _ = try writeIconCache(in: persist, source: source)
        let importChild = try await launchChild("import", folder: persist, expected: icons.count)
        try check(importChild["icons"] as? Int == icons.count && importChild["disk_records"] as? Int == icons.count && childColorsMatch(importChild, icons)
                  && importChild["imported_pages"] as? Int == 0, "Import child shows and saves exactly the valid icons, creating no page")
        try check(importChild["work_rows"] as? [String] == expected && importChild["easel_rows"] as? [String] == ["Sketch"]
                  && importChild["easel_native"] as? Bool == true, "Import child keeps the Easel row in its place and shows it natively")
        let expectedThemeJSON = Self.encodedTheme(Self.expectedTheme)
        try check(expectedThemeJSON != nil && importChild["work_theme"] as? String == expectedThemeJSON,
                  "Import child gives Work exactly Arc's theme colours and original gradient")
        let cacheFolder = persist.appendingPathComponent("ImportedIcons", isDirectory: true)
        try check(FileManager.default.fileExists(atPath: cacheFolder.appendingPathComponent("index.json").path), "Icons persist in the session's own cache")
        let reloadChild = try await launchChild("reload", folder: persist, expected: icons.count)
        try check(reloadChild["icons"] as? Int == icons.count && childColorsMatch(reloadChild, icons) && reloadChild["imported_pages"] as? Int == 0,
                  "A relaunched process restores the same icons for the same tabs and profiles, creating no page")
        try check(reloadChild["work_rows"] as? [String] == expected && reloadChild["easel_rows"] as? [String] == ["Sketch"]
                  && reloadChild["easel_native"] as? Bool == true,
                  "After relaunch the Easel row is still in its place and selecting it shows the native reference without a page")
        try check(reloadChild["work_theme"] as? String == expectedThemeJSON,
                  "After relaunch Work keeps exactly the same theme colours and original gradient, with no page woken")
        let digest = Self.treeDigest(cacheFolder)
        let isolated = try await launchChild("private", folder: persist, expected: 0)
        try check(isolated["icons"] as? Int == 0 && (isolated["colors"] as? [String: [Int]])?.isEmpty == true,
                  "A private relaunch on the same session shows no saved icons")
        try check(isolated["easel_rows"] as? [String] == ["Sketch"], "A private relaunch still loads the Easel row from the session")
        try check(isolated["work_theme"] as? String == expectedThemeJSON, "A private relaunch reads the same theme from the session")
        try check(digest != nil && Self.treeDigest(cacheFolder) == digest, "A private relaunch leaves the icon cache unchanged")
        try check(Set(childPIDs).count == 3 && !childPIDs.contains(getpid()), "Three distinct relaunched processes, none of them this one")
        try check(tripwire.connections == 0, "No relaunched process connected to any imported address (\(tripwire.requestLines))")

        // The tripwire is live: a deliberate request is seen, so zero above means no traffic.
        let probe = URL(string: "http://127.0.0.1:\(tripwirePort)/tripwire-self-test")!
        let (_, probeResponse) = try await URLSession.shared.data(from: probe)
        try check((probeResponse as? HTTPURLResponse)?.statusCode == 404, "Tripwire answers a deliberate request")
        try await wait("Tripwire records the deliberate request") { tripwire.connections == 1 && tripwire.requestLines.contains { $0.contains("/tripwire-self-test") } }
    }

    private func finish(_ success: Bool, _ message: String) {
        guard !finished else { return }; finished = true
        watchdog?.invalidate(); watchdog = nil
        if let sheet = importer?.window, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        controller?.sessionWriter = nil; controller?.privateMode = true
        controller?.prepareToClose(); window?.orderOut(nil)
        tripwire.stop()
        // Any owned relaunch child is stopped and confirmed exited before its folder is removed.
        Task { @MainActor in
            var passed = success, detail = message, removeFolder = true
            if let child = activeChild {
                let pid = child.processIdentifier
                if await stopChild(child) {
                    detail += "; stopped owned relaunch child \(pid) and confirmed it exited before cleanup"
                } else {
                    passed = false; removeFolder = false
                    detail += "; owned relaunch child \(pid) could not be confirmed stopped, so its temporary folder was kept"
                }
            }
            if removeFolder { try? FileManager.default.removeItem(at: directory) }
            print("\(passed ? "PASS" : "FAIL"): Arc import — \(detail)"); fflush(stdout)
            exit(passed ? 0 : 1)
        }
    }
}
