import AppKit
import WebKit
import Darwin

/// Covers the real browser adapter, in addition to the isolated extension host.
@available(macOS 15.4, *)
@MainActor enum BrowserExtensionSmokeTest {
    private final class WeakReference<Value: AnyObject> {
        weak var value: Value?
        init(_ value: Value) { self.value = value }
    }
    /// Observations, not a leak threshold: WebKit/process caches can outlive views.
    private static func recordLifecycle(_ phase: String, retiredPopovers: Int, retiredWebViews: Int, retiredContexts: Int = 0) {
        var usage = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &usage) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V0, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        var report: [String: Any] = ["phase": phase, "pid": getpid(), "uptime": ProcessInfo.processInfo.systemUptime,
            "retiredPopoversStillAlive": retiredPopovers, "retiredWebViewsStillAlive": retiredWebViews,
            "retiredContextsStillAlive": retiredContexts]
        if result == 0 { report["appResidentBytes"] = usage.ri_resident_size; report["appPhysicalFootprintBytes"] = usage.ri_phys_footprint }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys) {
            print("BAM_EXTENSION_LIFECYCLE " + String(decoding: data, as: UTF8.self)); fflush(stdout)
        }
    }
    static func run(fixtureURL: URL, pageURL: URL) async throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw ExtensionSmokeTest.Failure(description: message) }; checks += 1
        }
        func wait(_ message: String, _ condition: @escaping @MainActor () async -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            while ProcessInfo.processInfo.systemUptime < deadline {
                if await condition() { checks += 1; return }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            throw ExtensionSmokeTest.Failure(description: message)
        }
        let controller = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-extension-session.json"), ephemeral: true)
        controller.session.tabs.removeAll(); controller.automaticallyShowsVideo = false
        let profile = controller.session.currentProfileID
        let other = controller.session.createProfile(name: "Other")!
        let otherSpace = controller.session.createSpace(name: "Other", symbol: "briefcase", colorIndex: 1, profileID: other)!
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        // Attaching a controller lets AppKit adopt its initially empty root size.
        // Match App.swift: size the content after attachment before testing chrome.
        window.setContentSize(NSSize(width: 920, height: 650))
        controller.view.frame = NSRect(x: 0, y: 0, width: 920, height: 650)
        window.makeKeyAndOrderFront(nil)
        controller.layoutBrowser(); controller.view.layoutSubtreeIfNeeded()
        defer { controller.prepareToClose(persistSession: false); window.orderOut(nil); window.close() }
        let host = controller.browserExtensions
        host.permissionPrompt = { _ in true }; host.onReloadNeeded = nil
        let config = WKWebViewConfiguration(); config.websiteDataStore = controller.profileStores.store(for: profile)
        host.configure(config, profileID: profile)
        let sourceFixture = FileManager.default.temporaryDirectory.appendingPathComponent("bam-browser-extension-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixtureURL, to: sourceFixture)
        defer { try? FileManager.default.removeItem(at: sourceFixture) }
        let sourceManifest = sourceFixture.appendingPathComponent("manifest.json")
        var sourceDefinition = try JSONSerialization.jsonObject(with: Data(contentsOf: sourceManifest)) as! [String: Any]
        sourceDefinition["optional_permissions"] = ["alarms", "cookies", "webNavigation"]
        sourceDefinition["optional_host_permissions"] = ["http://localhost/*", "https://optional.invalid/*", "https://removed.invalid/*"]
        // Original solid-color icons make vendor-driven action changes observable
        // in the actual sidebar pixels, without any vendor account or artwork.
        for (name, rgb) in [("blue", [UInt8(0), 0, 255]), ("orange", [UInt8(255), 102, 0])] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied, bytesPerRow: 0, bitsPerPixel: 0)!
            // setColor(sRGBColor) on a Device RGB bitmap can silently produce
            // transparent pixels on some AppKit versions. Fill explicit RGBA.
            for y in 0..<24 { for x in 0..<24 {
                let pixel = bitmap.bitmapData!.advanced(by: y * bitmap.bytesPerRow + x * 4)
                pixel[0] = rgb[0]; pixel[1] = rgb[1]; pixel[2] = rgb[2]; pixel[3] = 255
            } }
            let png = bitmap.representation(using: .png, properties: [:])!
            try check(NSBitmapImageRep(data: png)?.colorAt(x: 12, y: 12)?.alphaComponent == 1,
                      "Action fixture PNG did not contain opaque pixels")
            try png.write(to: sourceFixture.appendingPathComponent("action-\(name).png"))
        }
        var fixtureAction = sourceDefinition["action"] as! [String: Any]
        fixtureAction["default_icon"] = "action-blue.png"; sourceDefinition["action"] = fixtureAction
        try JSONSerialization.data(withJSONObject: sourceDefinition).write(to: sourceManifest)
        // A canceled install review, then Enable: the first approval must still review and grant every requested site
        // (not migrate the never-approved record's empty grants to withheld).
        var installReviews: [BrowserExtensionPermissionReview] = []
        host.permissionPrompt = { review in installReviews.append(review); return false }
        let extensionID = try await host.importPackage(at: sourceFixture, profileID: profile)
        let canceledInstall = host.records.first { $0.id == extensionID }
        try check(installReviews.map(\.websites) == [["http://127.0.0.1/*"]] && canceledInstall?.enabled == false &&
            canceledInstall?.awaitingFirstReview == true && canceledInstall?.siteAccess == nil && host.context(for: extensionID) == nil,
            "A canceled install review must leave the record waiting for its first approval: \(installReviews.map(\.websites))")
        host.permissionPrompt = { review in installReviews.append(review); return true }
        try await host.setEnabled(true, id: extensionID)
        let firstApproval = host.records.first { $0.id == extensionID }
        try check(installReviews.count == 2 && installReviews[1].websites == ["http://127.0.0.1/*"] && firstApproval?.awaitingFirstReview == nil &&
            host.siteAccess(id: extensionID)?.state.mode == .allRequested &&
            host.context(for: extensionID)?.permissionStatus(for: pageURL) == .grantedExplicitly,
            "Enable after a canceled install must review and grant every requested site: reviewed=\(installReviews.last?.websites ?? []), status=\(String(describing: host.context(for: extensionID)?.permissionStatus(for: pageURL)))")
        host.permissionPrompt = { _ in true }
        let url = pageURL.appending(queryItems: [URLQueryItem(name: "profile", value: "browser-adapter")])
        guard let id = controller.openProfileTab(url, profileID: profile, active: true), let web = controller.browsers[id] else { throw ExtensionSmokeTest.Failure(description: "Browser adapter did not create its page") }
        try await wait("Browser adapter did not inject extension on first navigation") {
            (try? await web.evaluateJavaScript("document.documentElement.dataset.bamExtensionResult || ''") as? String)?.contains("browser-adapter") == true
        }
        func checkLiveLookup(_ profileID: UUID) throws {
            for surface in controller.extensionSurfaces(profileID: profileID) {
                guard let direct = controller.extensionSurface(profileID: profileID, id: surface.id) else {
                    throw ExtensionSmokeTest.Failure(description: "Live single-tab resolver omitted a listed page")
                }
                try check(direct.id == surface.id && direct.title == surface.title && direct.url == surface.url &&
                          direct.webView === surface.webView && direct.window === surface.window &&
                          direct.isActive == surface.isActive && direct.isSelected == surface.isSelected && direct.isPinned == surface.isPinned &&
                          direct.isLoading == surface.isLoading,
                          "Single-tab resolver diverged from the browser's live surface list")
            }
        }
        try checkLiveLookup(profile)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func actionButton() -> NSButton? {
            descendants(controller.sidebar).first { $0.identifier?.rawValue == "extension-action-\(extensionID.uuidString)" } as? NSButton
        }
        try await wait("Enabled extension did not appear as a visible sidebar action") { actionButton()?.isHidden == false }
        guard let button = actionButton(), let actionContext = host.context(for: extensionID),
              let liveRuntime = config.webExtensionController?.delegate as? BrowserExtensionRuntime,
              let liveTab = liveRuntime.tabs[id], let tabAction = actionContext.action(for: liveTab) else {
            throw ExtensionSmokeTest.Failure(description: "Missing toolbar action fixture")
        }
        try check(button.accessibilityLabel() == actionContext.webExtension.displayName, "Extension button lost its vendor name")
        recordLifecycle("baseline", retiredPopovers: 0, retiredWebViews: 0)
        button.performClick(nil)
        try await wait("Clicking the sidebar action did not show WebKit's actual popup") { tabAction.popupPopover?.isShown == true }
        try check(tabAction.popupPopover?.behavior == .transient, "Extension popup cannot dismiss on outside click")
        try check(liveRuntime.popupAnchor == nil && liveRuntime.popupTabID == nil && liveRuntime.popupContextID == nil, "Presented popup retained a reusable invocation anchor")
        // Inspect the displayed popover's actual hierarchy. Reading popupWebView
        // alone can create a replacement and hide a discarded presentation.
        func presentedWeb(_ popover: NSPopover) -> WKWebView? {
            guard popover.isShown, let root = popover.contentViewController?.view, let popupWindow = root.window else { return nil }
            return descendants(root).compactMap { $0 as? WKWebView }.first { $0.window === popupWindow }
        }
        do {
            guard let firstPopover = tabAction.popupPopover else { throw ExtensionSmokeTest.Failure(description: "Initial action has no presented popover") }
            try await wait("Initial presented popup did not contain live extension HTML") {
                guard let web = presentedWeb(firstPopover) else { return false }
                return (try? await web.evaluateJavaScript("document.title")) as? String == "Bam fixture ready"
            }
            guard let popupWeb = presentedWeb(firstPopover) else { throw ExtensionSmokeTest.Failure(description: "Missing live popup for action updates") }
            func isColor(_ color: NSColor?, _ expected: String) -> Bool {
                guard let color = color?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else { return false }
                // AppKit color management and compositing soften saturated icon
                // channels in the sidebar. Require a bright, separated hue,
                // rather than assuming an untouched zero channel at the pixel.
                let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                switch expected {
                case "blue": return b > 0.65 && b - r > 0.4 && b - g > 0.35
                case "orange": return r > 0.7 && r - g > 0.3 && g - b > 0.2
                case "green": return g > 0.65 && g - r > 0.35 && g - b > 0.35
                default: return false
                }
            }
            func iconCenter(_ action: WKWebExtension.Action?) -> NSColor? {
                guard let data = action?.icon(for: NSSize(width: 24, height: 24))?.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: data) else { return nil }
                return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
            }
            func sidebarCenter() -> NSColor? {
                guard let current = actionButton(), current === button, !current.isHidden,
                      let bitmap = current.bitmapImageRepForCachingDisplay(in: current.bounds) else { return nil }
                current.cacheDisplay(in: current.bounds, to: bitmap)
                return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
            }
            func iconColor(_ action: WKWebExtension.Action?, _ color: String) -> Bool { isColor(iconCenter(action), color) }
            func sidebarColor(_ color: String) -> Bool { isColor(sidebarCenter(), color) }
            func waitAction(_ message: String, _ condition: @escaping @MainActor () async -> Bool) async throws {
                do { try await wait(message, condition) }
                catch {
                    func rgba(_ color: NSColor?) -> [Double] {
                        guard let c = color?.usingColorSpace(.sRGB) else { return [] }
                        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map(Double.init)
                    }
                    let report: [String: Any] = ["message": message, "sidebarRGBA": rgba(sidebarCenter()),
                        "defaultRGBA": rgba(iconCenter(actionContext.action(for: nil))), "tabRGBA": rgba(iconCenter(tabAction)),
                        "sameButton": actionButton() === button, "buttonHidden": button.isHidden,
                        "label": button.accessibilityHelp() ?? "", "badge": button.accessibilityValue() as? String ?? "",
                        "defaultLabel": actionContext.action(for: nil)?.label ?? "", "tabLabel": tabAction.label]
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys) {
                        print("EXTENSION_ACTION_DIAGNOSTIC " + String(decoding: data, as: UTF8.self)); fflush(stdout)
                    }
                    throw error
                }
            }
            let actionCallShapes = try await popupWeb.callAsyncJavaScript("""
                const details = {path: {16: 'action-orange.png', 32: 'action-orange.png'}, tabId: undefined};
                const report = [];
                const run = async (name, invoke) => {
                    const record = {name, callback: false, returnedPromise: false};
                    await new Promise(resolve => {
                        let done = false;
                        const finish = () => { if (done) return; done = true; clearTimeout(timer); resolve(); };
                        const timer = setTimeout(() => { record.timeout = true; finish(); }, 2500);
                        try {
                            const result = invoke(() => {
                                record.callback = true;
                                record.error = chrome.runtime.lastError?.message || '';
                                finish();
                            });
                            record.returnedPromise = !!result?.then;
                            if (result?.then) result.then(() => { record.promiseResolved = true; }, error => { record.promiseError = String(error); });
                        } catch (error) { record.exception = String(error); finish(); }
                    });
                    report.push(record);
                };
                await run('boundChromeCallback', callback => chrome.action.setIcon(details, callback));
                await run('detachedChromeCallback', callback => (chrome.action?.setIcon ?? chrome.browserAction.setIcon)(details, callback));
                globalThis.bamActionNamespaceFixture = chrome.action;
                await run('retainedDetachedChromeCallback', callback => {
                    const fn = bamActionNamespaceFixture.setIcon;
                    return fn(details, callback);
                });
                await run('retainedBoundChromeCallback', callback => {
                    const fn = bamActionNamespaceFixture.setIcon;
                    return fn.call(bamActionNamespaceFixture, details, callback);
                });
                delete globalThis.bamActionNamespaceFixture;
                return JSON.stringify(report);
                """, arguments: [:], contentWorld: .page)
            print("EXTENSION_ACTION_CALL_SHAPES " + String(describing: actionCallShapes)); fflush(stdout)
            _ = try await popupWeb.callAsyncJavaScript("""
                await browser.action.setIcon({path: {16: 'action-orange.png', 32: 'action-orange.png'}});
                await browser.action.setTitle({title: 'Fixture locked'});
                await browser.action.setBadgeText({text: 'L'});
                return true;
                """, arguments: [:], contentWorld: .page)
            try await waitAction("Global action state did not redraw the existing sidebar icon, title and badge") {
                sidebarColor("orange") && iconColor(actionContext.action(for: nil), "orange") &&
                    button.accessibilityHelp() == "Fixture locked" && button.accessibilityValue() as? String == "L"
            }
            guard let actionTabID = try await popupWeb.callAsyncJavaScript("""
                const tab = (await browser.tabs.query({active: true})).find(tab => tab.url?.includes('profile=browser-adapter'));
                if (!tab) throw new Error('Missing action fixture tab');
                await browser.action.setIcon({tabId: tab.id, path: 'action-blue.png'});
                await browser.action.setTitle({tabId: tab.id, title: 'Fixture unlocked'});
                await browser.action.setBadgeText({tabId: tab.id, text: ''});
                return tab.id;
                """, arguments: [:], contentWorld: .page) as? NSNumber else {
                throw ExtensionSmokeTest.Failure(description: "Action fixture did not return a numeric tab ID")
            }
            try await waitAction("Tab-specific action state did not replace the visible icon without changing the default action") {
                sidebarColor("blue") && iconColor(actionContext.action(for: nil), "orange") &&
                    button.accessibilityHelp() == "Fixture unlocked" && button.accessibilityValue() == nil
            }
            _ = try await popupWeb.callAsyncJavaScript("""
                const pixels = new ImageData(24, 24);
                for (let i = 0; i < pixels.data.length; i += 4) { pixels.data[i + 1] = 255; pixels.data[i + 3] = 255; }
                await browser.action.setIcon({imageData: pixels});
                return true;
                """, arguments: [:], contentWorld: .page)
            try await waitAction("ImageData action update was ignored or overwrote the active tab's icon override") {
                iconColor(actionContext.action(for: nil), "green") && sidebarColor("blue")
            }
            _ = try await popupWeb.callAsyncJavaScript("""
                const pixels = new ImageData(24, 24);
                for (let i = 0; i < pixels.data.length; i += 4) { pixels.data[i] = 255; pixels.data[i + 1] = 102; pixels.data[i + 3] = 255; }
                await browser.action.setIcon({tabId, imageData: pixels});
                return true;
                """, arguments: ["tabId": actionTabID], contentWorld: .page)
            try await waitAction("Tab-specific ImageData action update did not redraw the existing sidebar button") {
                sidebarColor("orange") && iconColor(actionContext.action(for: nil), "green")
            }
            let callShapeRecords = (actionCallShapes as? String).flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            try check(callShapeRecords.count == 4 && callShapeRecords.allSatisfy {
                $0["callback"] as? Bool == true && $0["error"] as? String == "" && $0["exception"] == nil
            }, "Chrome action callback forms did not all complete; see EXTENSION_ACTION_CALL_SHAPES")
        }
        var retiredPopovers: [WeakReference<NSPopover>] = []
        var retiredWebViews: [WeakReference<WKWebView>] = []
        for cycle in 1...20 {
            guard let shown = tabAction.popupPopover, let popupWindow = shown.contentViewController?.view.window else { throw ExtensionSmokeTest.Failure(description: "Popup lost its window before dismissal") }
            retiredPopovers.append(WeakReference(shown))
            if let popupWeb = presentedWeb(shown) { retiredWebViews.append(WeakReference(popupWeb)) }
            if cycle.isMultiple(of: 2) == false {
                guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: popupWindow.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else {
                    throw ExtensionSmokeTest.Failure(description: "Could not create popup Escape event")
                }
                popupWindow.sendEvent(escape)
            } else { shown.performClose(nil) }
            try await wait("Popup did not dismiss before reopen \(cycle)") { !shown.isShown }
            guard let currentButton = actionButton() else { throw ExtensionSmokeTest.Failure(description: "Extension shelf disappeared between popup openings") }
            currentButton.performClick(nil)
            try await wait("Reopened popup \(cycle) is empty or has no live extension document") {
                guard let shown = tabAction.popupPopover, let web = presentedWeb(shown) else { return false }
                return (try? await web.evaluateJavaScript("document.title")) as? String == "Bam fixture ready"
            }
            guard let reopened = tabAction.popupPopover, let liveWeb = presentedWeb(reopened) else { throw ExtensionSmokeTest.Failure(description: "Reopened popup detached its web view") }
            try check(reopened !== shown, "WebKit did not create a fresh popover after closing the previous one")
            let answer = try await liveWeb.callAsyncJavaScript("return (await browser.runtime.sendMessage({kind:'ping',via:'reopened'})).pong;", arguments: [:], contentWorld: .page)
            try check(answer as? String == "reopened", "Reopened popup cannot communicate with its background")
        }
        recordLifecycle("after-20-popup-cycles", retiredPopovers: retiredPopovers.filter { $0.value != nil }.count,
            retiredWebViews: retiredWebViews.filter { $0.value != nil }.count)
        if let shown = tabAction.popupPopover {
            retiredPopovers.append(WeakReference(shown))
            if let popupWeb = presentedWeb(shown) { retiredWebViews.append(WeakReference(popupWeb)) }
        }
        tabAction.closePopup()
        try await wait("Closed popup objects remained retained after 20 presentation cycles") {
            retiredPopovers.allSatisfy { $0.value == nil } && retiredWebViews.allSatisfy { $0.value == nil }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        recordLifecycle("popup-recovery", retiredPopovers: retiredPopovers.filter { $0.value != nil }.count,
            retiredWebViews: retiredWebViews.filter { $0.value != nil }.count)
        controller.setSidebar(false)
        try await wait("Sidebar did not finish collapsing around the extension shelf") { controller.sidebar.isHidden }
        let collapsedMenu = NSMenu(); controller.updateExtensionsMenu(collapsedMenu)
        try check(collapsedMenu.items.contains { $0.title == actionContext.webExtension.displayName } && collapsedMenu.items.contains { $0.title == "Add Extensions…" }, "Collapsed sidebar lost extension actions or library access")
        controller.setSidebar(true)
        try await wait("Extension shelf did not return when expanding the sidebar") { !controller.sidebar.isHidden && actionButton()?.isHidden == false }
        guard let runtime = config.webExtensionController?.delegate as? BrowserExtensionRuntime,
              let tabIndex = controller.session.tabs.firstIndex(where: { $0.id == id }) else {
            throw ExtensionSmokeTest.Failure(description: "Missing single-tab lookup fixture")
        }
        let originalSpace = controller.session.tabs[tabIndex].space
        controller.session.tabs[tabIndex].space = otherSpace
        let movedSurface = runtime.currentSurface(id)
        controller.session.tabs[tabIndex].space = originalSpace
        try check(movedSurface == nil, "A moved tab remained available through the direct resolver before reconciliation")
        controller.session.changeSpace(otherSpace); controller.showActive(); controller.refresh()
        try check(actionButton() == nil, "Sidebar exposed an extension from another login profile")
        host.performAction(extensionID: extensionID, tabID: id, anchor: controller.sidebar)
        try check(liveRuntime.popupContextID == nil, "A stale menu invocation retained an inactive profile's popup request")
        var stalePopupError: Error?
        liveRuntime.webExtensionController(liveRuntime.controller, presentActionPopup: tabAction, for: actionContext) { stalePopupError = $0 }
        try check(stalePopupError != nil && tabAction.popupPopover?.isShown != true, "An asynchronously presented popup appeared over a different profile")
        try checkLiveLookup(profile); try checkLiveLookup(other)
        host.reconcile()
        guard let context = host.context(for: extensionID), context.action(for: nil)?.popupWebView != nil else { throw ExtensionSmokeTest.Failure(description: "Missing browser-adapter action popup") }
        // Held only until its last use (below): a test-held extension web view keeps its web process, and with it every
        // CORS pattern it ever had, which would confound the withheld-fetch checks later in this run.
        var heldPopup: WKWebView? = context.action(for: nil)?.popupWebView
        var popup: WKWebView { heldPopup! }
        try await wait("Browser-adapter popup did not initialize") { (try? await popup.evaluateJavaScript("document.title")) as? String == "Bam fixture ready" }
        // A finished load must reach the extension as `tabs.onUpdated` with `status: "complete"`
        // even though the URL did not change after commit (Dashlane's sign-in check waits for it).
        try await wait("Browser adapter never reported the page load as complete to tabs.onUpdated") {
            let updates = try? await popup.callAsyncJavaScript("return JSON.stringify((await browser.runtime.sendMessage({kind: \"updates\"})).updates || []);", arguments: [:], contentWorld: .page)
            guard let text = updates as? String, let data = text.data(using: .utf8),
                  let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
            // The changeInfo must carry the status: a title-driven update also reads `status: "complete"` live.
            return records.contains { ($0["infoStatus"] as? String) == "complete" && ($0["url"] as? String)?.contains("extension-test.html") == true }
        }
        // Chrome `pinned` is a Bam kept tab. This extension's profile is in the background here (the window shows
        // `other`), so creating or changing pinned tabs must leave the window's Space, profile and selection alone.
        do {
            func pinnedPage(_ query: String) -> URL {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                components.path = "/next.html"; components.query = query
                return components.url!
            }
            func pinnedCall(_ body: String, _ arguments: [String: Any]) async throws -> [String: Any] {
                let text = try await popup.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page) as? String
                guard let data = text?.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ExtensionSmokeTest.Failure(description: "Pinned-tab probe returned \(text ?? "nil")")
                }
                return value
            }
            // One update and the tabs.onUpdated `pinned` it produced (waited for only when a change is expected).
            let updateScript = """
                let event = null;
                const listener = (tabId, info) => { if (tabId === id && 'pinned' in info) event = info.pinned; };
                browser.tabs.onUpdated.addListener(listener);
                try {
                  let result;
                  try { const tab = await browser.tabs.update(id, {pinned}); result = {ok: true, pinned: tab ? tab.pinned : null}; }
                  catch (error) { result = {ok: false, error: String(error?.message || error)}; }
                  const deadline = Date.now() + wait;
                  while (event === null && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 20));
                  result.event = event;
                  result.after = (await browser.tabs.get(id)).pinned;
                  return JSON.stringify(result);
                } finally { browser.tabs.onUpdated.removeListener(listener); }
                """
            func update(_ tabID: Int, pinned: Bool, changes: Bool) async throws -> [String: Any] {
                try await pinnedCall(updateScript, ["id": tabID, "pinned": pinned, "wait": changes ? 3000 : 300])
            }
            let place = (space: controller.session.space, profile: controller.session.currentProfileID, active: controller.session.activeID)
            func placeKept() -> Bool {
                controller.session.space == place.space && controller.session.currentProfileID == place.profile && controller.session.activeID == place.active
            }
            try check(place.profile == other, "Pinned-tab checks did not start with the extension's profile in the background")
            let pinnedURL = pinnedPage("pinned")
            let created = try await pinnedCall("""
                const tab = await browser.tabs.create({url: address, pinned: true, active: false});
                const members = await browser.tabs.query({windowId: tab.windowId});
                return JSON.stringify({id: tab.id, pinned: tab.pinned, active: tab.active, index: tab.index, last: members.length - 1});
                """, ["address": pinnedURL.absoluteString])
            guard let pinnedJS = created["id"] as? Int,
                  let pinnedID = controller.session.tabs.first(where: { $0.address == pinnedURL.absoluteString })?.id else {
                throw ExtensionSmokeTest.Failure(description: "tabs.create({pinned: true}) did not create a Bam tab: \(created)")
            }
            func pinnedTab() -> BrowserTab? { controller.session.tabs.first { $0.id == pinnedID } }
            guard let made = pinnedTab() else { throw ExtensionSmokeTest.Failure(description: "Pinned tab vanished") }
            try check(created["pinned"] as? Bool == true && created["active"] as? Bool == false, "tabs.create did not report a pinned background tab: \(created)")
            try check(made.saved?.kind == .kept && made.saved?.address == pinnedURL.absoluteString && made.folderID == nil
                      && made.saved?.customTitle == nil && controller.session.profileID(for: made) == profile,
                      "A pinned tab was not created as a kept tab at its Space's root in the extension's profile")
            try check(created["index"] as? Int == created["last"] as? Int, "A pinned tab was not appended at the end of its window: \(created)")
            try check(placeKept(), "Creating a background pinned tab moved the window's Space, profile or selection")
            try await wait("Pinned tab did not load") { controller.browsers[pinnedID]?.url == pinnedURL && controller.browsers[pinnedID]?.isLoading == false }
            let tabCount = controller.session.tabs.count
            let ownPage = try await pinnedCall("""
                try { await browser.tabs.create({url: browser.runtime.getURL('page.html'), pinned: true, active: false}); return JSON.stringify({ok: true}); }
                catch (error) { return JSON.stringify({ok: false, error: String(error?.message || error)}); }
                """, [:])
            try check(ownPage["ok"] as? Bool == false && (ownPage["error"] as? String)?.contains("HTTP and HTTPS") == true
                      && controller.session.tabs.count == tabCount, "A pinned extension page was created or refused untruthfully: \(ownPage)")
            // The session as it would be written to disk.
            func persisted() throws -> BrowserTab? {
                var restored = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(controller.session)); restored.sanitize()
                return restored.tabs.first { $0.id == pinnedID }
            }
            try check(try persisted()?.saved?.kind == .kept && persisted()?.saved?.address == pinnedURL.absoluteString, "The pinned tab was not saved as kept")

            // A wrapper around createTab (a fixture's allowed addresses) sees the kept intent while it runs and can refuse;
            // the intent never outlives that call.
            let installedCreate = host.createTab
            var wrappedKept: [Bool] = []
            host.createTab = { [weak host] _, _, _ in wrappedKept.append(host?.createsKeptTab == true); return nil }
            let wrapped = try await pinnedCall("""
                const outcome = [];
                for (const pinned of [true, false]) {
                  try { await browser.tabs.create({url: address, pinned, active: false}); outcome.push('created'); }
                  catch (error) { outcome.push('refused'); }
                }
                return JSON.stringify({outcome});
                """, ["address": pinnedPage("wrapped").absoluteString])
            host.createTab = installedCreate
            try check(wrappedKept == [true, false] && !host.createsKeptTab && wrapped["outcome"] as? [String] == ["refused", "refused"]
                      && controller.session.tabs.count == tabCount && placeKept(),
                      "A wrapped create did not see, refuse or reset the kept intent: \(wrappedKept) \(wrapped)")

            // A background kept tab for a profile whose Space is empty: selecting that Space adds a blank fallback
            // tab, and the new tab must take its place rather than leave it behind.
            guard let emptyProfile = controller.session.createProfile(name: "Pinned empty"),
                  let emptySpace = controller.session.createSpace(name: "Pinned empty", symbol: "briefcase", colorIndex: 2, profileID: emptyProfile) else {
                throw ExtensionSmokeTest.Failure(description: "Could not create an empty target Space")
            }
            let emptyURL = pinnedPage("pinned-empty")
            guard let emptyTab = host.createTab(emptyURL, profileID: emptyProfile, active: false, kept: true) else {
                throw ExtensionSmokeTest.Failure(description: "Bam did not create a background kept tab in an empty Space")
            }
            let emptyMembers = controller.session.tabs.filter { $0.space == emptySpace }
            try check(emptyMembers.map(\.id) == [emptyTab] && emptyMembers.first?.saved?.kind == .kept && emptyMembers.first?.address == emptyURL.absoluteString
                      && controller.session.lastSelectedTabIDsBySpace?[emptySpace] == emptyTab && placeKept() && !host.createsKeptTab,
                      "A background kept tab in an empty Space left a blank tab, lost its selection or moved the window: \(emptyMembers.map(\.address))")
            _ = controller.session.setRetention(id: emptyTab, kind: nil); _ = host.closeTab?(emptyTab)
            try check(controller.session.deleteSpace(id: emptySpace, movingTabsTo: place.space) && !controller.session.tabs.contains { $0.id == emptyTab } && placeKept(),
                      "The empty-Space fixture was not cleaned up")

            // Unpin with nothing to lose, then pin again: the page stays, and the event matches the returned tab.
            var result = try await update(pinnedJS, pinned: false, changes: true)
            try check(result["ok"] as? Bool == true && result["pinned"] as? Bool == false && result["event"] as? Bool == false && result["after"] as? Bool == false,
                      "Unpinning a plain kept tab failed or disagreed with tabs.onUpdated: \(result)")
            try check(pinnedTab()?.saved == nil && pinnedTab()?.address == pinnedURL.absoluteString && controller.browsers[pinnedID]?.url == pinnedURL && placeKept()
                      && persisted() != nil && persisted()?.saved == nil, "Unpinning did not leave (and save) an ordinary tab on the same page in place")
            result = try await update(pinnedJS, pinned: true, changes: true)
            try check(result["ok"] as? Bool == true && result["pinned"] as? Bool == true && result["event"] as? Bool == true
                      && pinnedTab()?.saved?.kind == .kept && pinnedTab()?.saved?.address == pinnedURL.absoluteString && placeKept()
                      && persisted()?.saved?.kind == .kept, "Pinning an ordinary tab did not keep (and save) it on its page: \(result)")
            // pinned:true on a kept tab is a no-op.
            result = try await update(pinnedJS, pinned: true, changes: false)
            try check(result["ok"] as? Bool == true && result["event"] is NSNull && pinnedTab()?.saved?.kind == .kept, "pinned:true changed a kept tab: \(result)")

            // Bam-only state refuses an unpin and survives it: custom name, folder, a different current page.
            _ = controller.session.updateSavedTab(id: pinnedID, customTitle: "Pinned fixture", customSymbol: nil)
            result = try await update(pinnedJS, pinned: false, changes: false)
            try check(result["ok"] as? Bool == false && (result["error"] as? String)?.contains("custom name") == true && result["after"] as? Bool == true
                      && pinnedTab()?.saved?.customTitle == "Pinned fixture", "Unpinning discarded a custom name: \(result)")
            _ = controller.session.updateSavedTab(id: pinnedID, customTitle: nil, customSymbol: nil)
            guard let space = pinnedTab()?.space,
                  let folder = controller.session.createFolder(name: "Pinned fixture", space: space, containing: [pinnedID]) else {
                throw ExtensionSmokeTest.Failure(description: "Could not put the pinned tab in a folder")
            }
            result = try await update(pinnedJS, pinned: false, changes: false)
            try check(result["ok"] as? Bool == false && (result["error"] as? String)?.contains("folder") == true
                      && pinnedTab()?.folderID == folder && pinnedTab()?.saved?.kind == .kept, "Unpinning took a kept tab out of its folder: \(result)")
            _ = controller.session.ungroupFolder(id: folder)
            let movedURL = pinnedPage("pinned-moved")
            controller.navigatePane(pinnedID, address: movedURL.absoluteString)
            try await wait("Pinned tab did not navigate") {
                controller.browsers[pinnedID]?.url == movedURL && controller.browsers[pinnedID]?.isLoading == false && pinnedTab()?.address == movedURL.absoluteString
            }
            result = try await update(pinnedJS, pinned: false, changes: false)
            try check(result["ok"] as? Bool == false && (result["error"] as? String)?.contains("different page") == true
                      && pinnedTab()?.saved?.address == pinnedURL.absoluteString && pinnedTab()?.address == movedURL.absoluteString,
                      "Unpinning forgot the kept page or moved the current one: \(result)")

            // A split refuses before either pane changes.
            controller.session.splits = (controller.session.splits ?? []) + [BrowserSplit(primaryID: id, secondaryID: pinnedID)]
            let pageJS = try await pinnedCall("return JSON.stringify({id: (await browser.tabs.query({})).find(tab => tab.url === address)?.id ?? null});",
                                              ["address": url.absoluteString])["id"] as? Int
            guard let pageJS else { throw ExtensionSmokeTest.Failure(description: "The adapter page was not visible to its extension") }
            result = try await update(pinnedJS, pinned: false, changes: false)
            let pageResult = try await update(pageJS, pinned: true, changes: false)
            try check(result["ok"] as? Bool == false && (result["error"] as? String)?.contains("split") == true
                      && pageResult["ok"] as? Bool == false && (pageResult["error"] as? String)?.contains("split") == true
                      && pinnedTab()?.saved?.kind == .kept && controller.session.tabs.first(where: { $0.id == id })?.saved == nil
                      && controller.session.split(for: pinnedID)?.primaryID == id, "A split pane's pinned state changed: \(result) \(pageResult)")
            controller.session.removeSplit(containing: pinnedID)

            // A Favorite is reported pinned; pinned:true leaves it a Favorite, and unpinning it is refused.
            try check(controller.session.setRetention(id: pinnedID, kind: .favorite), "Could not make the fixture tab a Favorite")
            controller.refresh()
            result = try await update(pinnedJS, pinned: true, changes: false)
            try check(result["ok"] as? Bool == true && result["after"] as? Bool == true && pinnedTab()?.isFavorite == true, "pinned:true demoted a Favorite: \(result)")
            result = try await update(pinnedJS, pinned: false, changes: false)
            try check(result["ok"] as? Bool == false && (result["error"] as? String)?.contains("Favorite") == true && pinnedTab()?.isFavorite == true && placeKept(),
                      "Unpinning a Favorite was not refused truthfully: \(result)")
            try check(controller.setExtensionTabPinned(pinnedID, profileID: other, pinned: false) != nil && pinnedTab()?.isFavorite == true,
                      "Another profile changed this profile's tab")

            // Demoting a Favorite needs its profile showing (Bam's own rule); restore the window afterwards.
            controller.session.changeSpace(space)
            _ = controller.session.setRetention(id: pinnedID, kind: nil)
            _ = host.closeTab?(pinnedID)
            controller.session.changeSpace(place.space); controller.showActive(); controller.refresh()
            try check(pinnedTab() == nil && controller.session.currentProfileID == other, "The pinned fixture tab outlived its cleanup")
            host.reconcile()
        }
        // tabs.create with an index before the end inserts the tab exactly there (in session order, which extensions
        // see), including a pinned one; later tabs shift by one without onMoved, and the window's place is unchanged.
        do {
            func indexedPage(_ query: String) -> URL {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                components.path = "/next.html"; components.query = query
                return components.url!
            }
            let firstURL = indexedPage("index-first"), middleURL = indexedPage("index-middle"), endURL = indexedPage("index-end")
            let sameURL = indexedPage("index-same"), betweenURL = indexedPage("index-between"), clampURL = indexedPage("index-clamp")
            let place = (space: controller.session.space, profile: controller.session.currentProfileID, active: controller.session.activeID)
            func placeKept() -> Bool {
                controller.session.space == place.space && controller.session.currentProfileID == place.profile && controller.session.activeID == place.active
            }
            let tabCount = controller.session.tabs.count
            let text = try await popup.callAsyncJavaScript("""
                const [win] = await browser.windows.getAll({windowTypes: ['normal'], populate: true});
                let moved = 0; const onMoved = () => { moved += 1; };
                const created = {}; const onCreated = (tab) => { created[tab.id] = {index: tab.index, pinned: tab.pinned}; };
                browser.tabs.onMoved.addListener(onMoved); browser.tabs.onCreated.addListener(onCreated);
                try {
                  const ordered = async () => (await browser.tabs.query({windowId: win.id})).sort((a, b) => a.index - b.index).map(tab => tab.id);
                  const before = await ordered();
                  const first = await browser.tabs.create({windowId: win.id, index: 0, url: first_, active: false});
                  const middle = await browser.tabs.create({windowId: win.id, index: 1, url: middle_, active: false, pinned: true});
                  const after = await ordered();
                  const end = await browser.tabs.create({windowId: win.id, index: after.length, url: end_, active: false});
                  // Two tabs with one URL: an insertion is anchored to the tab at that index, not to a URL.
                  const sameA = await browser.tabs.create({windowId: win.id, url: same_, active: false});
                  const sameB = await browser.tabs.create({windowId: win.id, url: same_, active: false});
                  const between = await browser.tabs.create({windowId: win.id, index: (await browser.tabs.get(sameB.id)).index, url: between_, active: false});
                  const sameOrder = await ordered();
                  // An index past the end (no Peek) clamps to an append.
                  const count = sameOrder.length;
                  const clamp = await browser.tabs.create({windowId: win.id, index: count + 50, url: clamp_, active: false});
                  await new Promise(resolve => setTimeout(resolve, 300));
                  const final = await ordered();
                  return JSON.stringify({before, after, moved, created, final, sameOrder,
                    first: {id: first.id, index: first.index, read: (await browser.tabs.get(first.id)).index},
                    middle: {id: middle.id, index: middle.index, pinned: middle.pinned, read: (await browser.tabs.get(middle.id)).index},
                    end: {id: end.id, index: end.index, expected: after.length},
                    same: {a: sameA.id, b: sameB.id, between: between.id},
                    clamp: {id: clamp.id, index: clamp.index, expected: count}});
                } finally { browser.tabs.onMoved.removeListener(onMoved); browser.tabs.onCreated.removeListener(onCreated); }
                """, arguments: ["first_": firstURL.absoluteString, "middle_": middleURL.absoluteString, "end_": endURL.absoluteString,
                                 "same_": sameURL.absoluteString, "between_": betweenURL.absoluteString, "clamp_": clampURL.absoluteString], contentWorld: .page) as? String
            guard let data = text?.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = value["first"] as? [String: Any], let middle = value["middle"] as? [String: Any], let end = value["end"] as? [String: Any],
                  let same = value["same"] as? [String: Any], let clamp = value["clamp"] as? [String: Any],
                  let before = value["before"] as? [Int], let after = value["after"] as? [Int], let sameOrder = value["sameOrder"] as? [Int],
                  let created = value["created"] as? [String: [String: Any]],
                  let firstJS = first["id"] as? Int, let middleJS = middle["id"] as? Int,
                  let sameA = same["a"] as? Int, let sameB = same["b"] as? Int, let betweenJS = same["between"] as? Int else {
                throw ExtensionSmokeTest.Failure(description: "Indexed tabs.create probe returned \(text ?? "nil")")
            }
            try check(first["index"] as? Int == 0 && first["read"] as? Int == 0 && middle["index"] as? Int == 1 && middle["read"] as? Int == 1
                      && middle["pinned"] as? Bool == true && after == [firstJS, middleJS] + before,
                      "An indexed tabs.create was not placed, read back or shifted exactly: \(value)")
            // onCreated reports the tab already in place (and already pinned), never a transient end position.
            try check(created[String(firstJS)]?["index"] as? Int == 0 && created[String(firstJS)]?["pinned"] as? Bool == false
                      && created[String(middleJS)]?["index"] as? Int == 1 && created[String(middleJS)]?["pinned"] as? Bool == true,
                      "tabs.onCreated did not report an inserted tab's final index and pinned state: \(created)")
            try check(end["index"] as? Int == end["expected"] as? Int && value["moved"] as? Int == 0,
                      "An append landed elsewhere, or an insertion fired onMoved: \(value)")
            try check(Array(sameOrder.suffix(3)) == [sameA, betweenJS, sameB],
                      "An insertion before one of two same-URL tabs landed by URL rather than before that tab: \(sameOrder)")
            try check(clamp["index"] as? Int == clamp["expected"] as? Int && (value["final"] as? [Int])?.last == clamp["id"] as? Int,
                      "An index past the end did not clamp to an append: \(value)")
            func bamID(_ address: URL) -> UUID? { controller.session.tabs.first(where: { $0.address == address.absoluteString })?.id }
            let sameIDs = controller.session.tabs.filter { $0.address == sameURL.absoluteString }.map(\.id)
            guard let firstID = bamID(firstURL), let middleID = bamID(middleURL), let endID = bamID(endURL),
                  let betweenID = bamID(betweenURL), let clampID = bamID(clampURL), sameIDs.count == 2 else {
                throw ExtensionSmokeTest.Failure(description: "Indexed tabs were not created in Bam")
            }
            let members = controller.session.tabs.filter { controller.session.profileID(for: $0) == profile }.map(\.id)
            let middleTab = controller.session.tabs.first { $0.id == middleID }
            try check(Array(members.prefix(2)) == [firstID, middleID] && Array(members.suffix(4)) == [sameIDs[0], betweenID, sameIDs[1], clampID]
                      && members.contains(endID) && controller.session.tabs.count == tabCount + 7,
                      "Bam's session order does not match the indices extensions were given, or an extra tab appeared")
            try check(middleTab?.saved?.kind == .kept && middleTab?.folderID == nil
                      && controller.session.tabs.first(where: { $0.id == firstID })?.saved == nil,
                      "An indexed pinned tab was not kept at its Space's root, or an ordinary one was kept")
            try check(placeKept() && host.createsTabBefore == nil && !host.createsKeptTab,
                      "Indexed background creation moved the window's Space, profile or selection, or left placement intent behind")
            _ = controller.session.setRetention(id: middleID, kind: nil)
            for id in [firstID, middleID, endID, betweenID, clampID] + sameIDs { _ = host.closeTab?(id) }
            controller.refresh(); host.reconcile()
            try check(controller.session.tabs.count == tabCount, "Indexed fixture tabs outlived their cleanup")

            // Insertion into a profile whose target Space is empty: selecting it synthesizes a blank tab, which the
            // new tab replaces; the anchor (in that profile's other Space) keeps its place right after the new tab.
            // A foreign-profile anchor is refused before anything changes.
            guard let emptyProfile = controller.session.createProfile(name: "Indexed empty"),
                  let emptySpace = controller.session.createSpace(name: "Indexed empty", symbol: "briefcase", colorIndex: 3, profileID: emptyProfile),
                  let anchorSpace = controller.session.createSpace(name: "Indexed anchor", symbol: "briefcase", colorIndex: 4, profileID: emptyProfile) else {
                throw ExtensionSmokeTest.Failure(description: "Could not create the empty-Space insertion fixture")
            }
            let anchorTab = BrowserTab(title: "Anchor", address: indexedPage("index-anchor").absoluteString, space: anchorSpace)
            controller.session.tabs.append(anchorTab)
            let foreignAnchor = controller.session.tabs.first { controller.session.profileID(for: $0) == profile }!.id
            let beforeForeign = controller.session.tabs.count
            try check(host.createTab(indexedPage("index-foreign"), profileID: emptyProfile, active: false, kept: false, before: foreignAnchor) == nil
                      && controller.session.tabs.count == beforeForeign && controller.session.tabs.allSatisfy({ $0.space != emptySpace }) && placeKept(),
                      "An anchor from another profile was not refused before anything changed")
            let insertedURL = indexedPage("index-into-empty")
            guard let inserted = host.createTab(insertedURL, profileID: emptyProfile, active: false, kept: false, before: anchorTab.id) else {
                throw ExtensionSmokeTest.Failure(description: "Insertion into an empty target Space was refused")
            }
            let emptyMembers = controller.session.tabs.filter { $0.space == emptySpace }
            let profileOrder = controller.session.tabs.filter { controller.session.profileID(for: $0) == emptyProfile }.map(\.id)
            try check(emptyMembers.map(\.id) == [inserted] && emptyMembers.first?.address == insertedURL.absoluteString
                      && profileOrder == [inserted, anchorTab.id] && controller.session.tabs.first(where: { $0.id == anchorTab.id })?.space == anchorSpace
                      && controller.session.lastSelectedTabIDsBySpace?[emptySpace] == inserted && placeKept() && host.createsTabBefore == nil,
                      "Insertion into an empty Space left its blank tab, misplaced the tab or anchor, or moved the window: \(emptyMembers.map(\.address))")
            _ = host.closeTab?(inserted)
            controller.session.tabs.removeAll { $0.id == anchorTab.id }
            try check(controller.session.deleteSpace(id: emptySpace, movingTabsTo: place.space) && controller.session.deleteSpace(id: anchorSpace, movingTabsTo: place.space)
                      && !controller.session.tabs.contains { $0.id == inserted } && placeKept(), "The empty-Space insertion fixture was not cleaned up")
            controller.refresh(); host.reconcile()
        }
        // Measurement, not a pass/fail: idle-callback availability in the three page-side worlds
        // (Proton Pass and uBOL page scripts call requestIdleCallback without a feature check).
        let idlePage = (try? await controller.browsers[id]?.evaluateJavaScript("typeof requestIdleCallback + ',' + typeof cancelIdleCallback")) as? String ?? "unknown"
        let idleContent = (try? await controller.browsers[id]?.evaluateJavaScript("document.documentElement.dataset.bamContentIdle || 'unreported'")) as? String ?? "unknown"
        let idleExtension = (try? await popup.evaluateJavaScript("typeof requestIdleCallback + ',' + typeof cancelIdleCallback")) as? String ?? "unknown"
        print("EXTENSION_ENVIRONMENT requestIdleCallback,cancelIdleCallback page=\(idlePage) content=\(idleContent) extensionPage=\(idleExtension) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)"); fflush(stdout)
        // Bam supplies them to the extension's own worlds when WebKit lacks them; the website's world is untouched.
        try check(idleContent == "function,function" && idleExtension == "function,function",
                  "Idle callbacks were missing in the extension's content-script world or page: content=\(idleContent) extensionPage=\(idleExtension)")
        if idlePage == "function,function" { print("EXTENSION_ENVIRONMENT note: the engine provides idle callbacks in website pages") }
        else { try check(idlePage == "undefined,undefined", "A website's page world gained idle callbacks from Bam: \(idlePage)") }
        let idleRun = try? await popup.callAsyncJavaScript("""
            return await new Promise(resolve => {
              const order = [];
              const cancelled = requestIdleCallback(() => order.push('cancelled'));
              requestIdleCallback(deadline => order.push(['first', deadline.didTimeout, deadline.timeRemaining() <= 50]));
              requestIdleCallback(() => { order.push('second'); resolve(JSON.stringify(order)); });
              cancelIdleCallback(cancelled);
            });
            """, arguments: [:], contentWorld: .page) as? String
        try check(idleRun == #"[["first",false,true],"second"]"#, "Idle callbacks did not run in order with a bounded deadline and cancellation in an extension page: \(idleRun ?? "nil")")
        // tabs.detectLanguage (Dashlane): page text first, then the declaration, in callback and promise forms.
        guard let languageWeb = controller.browsers[id] else { throw ExtensionSmokeTest.Failure(description: "Missing tabs.detectLanguage page") }
        _ = try await languageWeb.evaluateJavaScript("""
            document.documentElement.lang = 'pt-BR';
            const bamLanguage = document.createElement('p'); bamLanguage.id = 'bam-language';
            bamLanguage.textContent = 'Die Kinder spielen am Nachmittag im großen Garten hinter dem Haus, während ihre Eltern in der Küche gemeinsam das Abendessen vorbereiten.';
            document.body.append(bamLanguage); true
            """)
        let detectLanguage = """
            const tab = (await browser.tabs.query({})).find(tab => tab.url?.includes('profile=browser-adapter'));
            const promised = await browser.tabs.detectLanguage(tab.id);
            const callback = await new Promise(resolve => chrome.tabs.detectLanguage(tab.id, value => resolve({value, error: chrome.runtime.lastError?.message || ''})));
            let missing = '';
            try { await browser.tabs.detectLanguage(987654321); } catch (error) { missing = String(error?.message || error); }
            const missingCallback = await new Promise(resolve => chrome.tabs.detectLanguage(987654321, value => resolve(chrome.runtime.lastError ? 'error' : 'value:' + value)));
            return JSON.stringify({promised, callback, missing, missingCallback});
            """
        func detectedLanguage() async throws -> [String: Any] {
            let text = try await popup.callAsyncJavaScript(detectLanguage, arguments: [:], contentWorld: .page) as? String
            guard let data = text?.data(using: .utf8), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ExtensionSmokeTest.Failure(description: "tabs.detectLanguage returned no result: \(text ?? "nil")")
            }
            return result
        }
        let recognized = try await detectedLanguage()
        try check(recognized["promised"] as? String == "de" && (recognized["callback"] as? [String: Any])?["value"] as? String == "de"
                  && (recognized["callback"] as? [String: Any])?["error"] as? String == "", "tabs.detectLanguage did not recognize page text in both forms: \(recognized)")
        try check(!(recognized["missing"] as? String ?? "").isEmpty && recognized["missingCallback"] as? String == "error",
                  "tabs.detectLanguage did not report a missing tab as an error: \(recognized)")
        // Hidden fixture text leaves too little to recognize, so only the declaration remains.
        _ = try await languageWeb.evaluateJavaScript("document.getElementById('bam-language').remove(); for (const node of document.body.children) node.hidden = true; true")
        let declared = try await detectedLanguage()
        try check(declared["promised"] as? String == "pt-BR", "tabs.detectLanguage ignored the declared language: \(declared)")
        _ = try await languageWeb.evaluateJavaScript("document.documentElement.removeAttribute('lang'); true")
        let undetermined = try await detectedLanguage()
        try check(undetermined["promised"] as? String == "und", "tabs.detectLanguage did not report und for an undeclared page without text: \(undetermined)")
        _ = try await languageWeb.evaluateJavaScript("for (const node of document.body.children) node.hidden = false; true")

        // scripting.ExecutionWorld (Bitwarden): the enum exists in the prepared worker and in an extension
        // page, and executeScript with files/frameIds/injectImmediately/world: ExecutionWorld.ISOLATED injects.
        func executionWorldResult(_ text: Any?) -> [String: Any] {
            (text as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? ["error": "no result: \(String(describing: text))"]
        }
        let fromWorker = executionWorldResult(try await popup.callAsyncJavaScript("return JSON.stringify(await browser.runtime.sendMessage({kind: 'execution-world'}));", arguments: [:], contentWorld: .page))
        let fromPage = executionWorldResult(try await popup.callAsyncJavaScript("""
            const world = chrome.scripting.ExecutionWorld;
            try {
              const tab = (await browser.tabs.query({})).find(tab => tab.url?.includes('profile=browser-adapter'));
              const results = await chrome.scripting.executeScript({target: {tabId: tab.id, frameIds: [0]}, files: ['inject.js'], injectImmediately: true, world: world.ISOLATED});
              return JSON.stringify({type: typeof world, isolated: world.ISOLATED, main: world.MAIN, frozen: Object.isFrozen(world), result: results?.[0]?.result ?? null, frameId: results?.[0]?.frameId ?? null});
            } catch (error) { return JSON.stringify({type: typeof world, error: String(error?.message || error)}); }
            """, arguments: [:], contentWorld: .page))
        for (label, report) in [("worker", fromWorker), ("extension page", fromPage)] {
            let injected = report["result"] as? [String: Any]
            // Values only: a future engine-provided enum need not be frozen (Bam's own is checked frozen in components).
            try check(report["type"] as? String == "object" && report["isolated"] as? String == "ISOLATED" && report["main"] as? String == "MAIN",
                      "scripting.ExecutionWorld was missing or wrong in the \(label): \(report)")
            try check(injected?["injected"] as? Bool == true && injected?["title"] as? String == "Bam extension page" && report["frameId"] as? Int == 0,
                      "Bitwarden-shaped executeScript did not inject into the tab from the \(label): \(report)")
        }
        let injections = (try? await controller.browsers[id]?.evaluateJavaScript("document.documentElement.dataset.bamInjected || '0'")) as? String
        try check(injections == "2", "The two injections did not both run in the page: \(injections ?? "nil")")

        // activeTab only: no access to any tab before the user's action gesture, then only to
        // that tab, until the gesture is cleared or the tab navigates.
        let activeFixture = FileManager.default.temporaryDirectory.appendingPathComponent("bam-active-tab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: activeFixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: activeFixture) }
        try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "Bam activeTab fixture", "version": "1.0",
            "description": "Original activeTab-only fixture", "permissions": ["activeTab"], "action": ["default_title": "Bam activeTab"]])
            .write(to: activeFixture.appendingPathComponent("manifest.json"))
        try Data("<!doctype html><meta charset='utf-8'><title>activeTab page</title>".utf8).write(to: activeFixture.appendingPathComponent("page.html"))
        let activeID = try await host.importPackage(at: activeFixture, profileID: profile)
        // Built from components: `url` carries `?profile=…`, which path edits would keep.
        func secondPage(host: String? = nil, query: String? = nil) -> URL {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.path = "/next.html"; components.query = query
            if let host { components.host = host }
            return components.url!
        }
        let secondURL = secondPage()
        guard let activeContext = host.context(for: activeID), let activeConfiguration = activeContext.webViewConfiguration,
              let secondID = controller.openProfileTab(secondURL, profileID: profile, active: false) else { throw ExtensionSmokeTest.Failure(description: "activeTab fixture did not load") }
        try await wait("activeTab second tab did not load") { controller.browsers[secondID]?.url == secondURL && controller.browsers[secondID]?.isLoading == false }
        host.reconcile()
        let activePage = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: activeConfiguration)
        activePage.load(URLRequest(url: activeContext.baseURL.appendingPathComponent("page.html")))
        try await wait("activeTab extension page did not load") { activePage.title == "activeTab page" }
        func activeTabAccess() async throws -> (allowed: [Int], denied: Int, callback: String) {
            let text = try await activePage.callAsyncJavaScript("""
                const allowed = [], denied = [];
                for (const tab of await browser.tabs.query({})) {
                  try { await browser.tabs.detectLanguage(tab.id); allowed.push(tab.id); } catch (error) { denied.push(String(error?.message || error)); }
                }
                const target = allowed[0] ?? (await browser.tabs.query({}))[0].id;
                const callback = await new Promise(resolve => chrome.tabs.detectLanguage(target, value => resolve(chrome.runtime.lastError ? 'error' : 'value:' + value)));
                return JSON.stringify({allowed, denied: denied.length, callback});
                """, arguments: [:], contentWorld: .page) as? String
            guard let data = text?.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ExtensionSmokeTest.Failure(description: "activeTab detectLanguage probe failed: \(text ?? "nil")")
            }
            return (value["allowed"] as? [Int] ?? [], value["denied"] as? Int ?? -1, value["callback"] as? String ?? "")
        }
        let before = try await activeTabAccess()
        try check(before.allowed.isEmpty && before.denied >= 2 && before.callback == "error", "activeTab-only extension read a tab's language before any gesture: \(before)")
        guard let secondTab = runtime.tabs[secondID] else { throw ExtensionSmokeTest.Failure(description: "Missing activeTab second tab adapter") }
        activeContext.performAction(for: secondTab)
        let granted = try await activeTabAccess()
        try check(granted.allowed.count == 1 && granted.denied == before.denied - 1 && granted.callback.hasPrefix("value:"),
                  "activeTab gesture did not grant exactly its tab in promise and callback forms: \(granted)")
        activeContext.clearUserGesture(in: secondTab)
        let cleared = try await activeTabAccess()
        try check(cleared.allowed.isEmpty && cleared.callback == "error", "Clearing the gesture did not revoke activeTab language access: \(cleared)")
        activeContext.performAction(for: secondTab)
        try check(try await activeTabAccess().allowed == granted.allowed, "A repeated gesture did not restore activeTab access")
        // Same-origin navigation: Chrome keeps the activeTab grant. Record WebKit's actual
        // behavior; a dropped grant is a limitation, not something Bam re-grants.
        controller.navigatePane(secondID, address: secondPage(query: "same-origin").absoluteString)
        try await wait("activeTab second tab did not navigate within its origin") { controller.browsers[secondID]?.url?.query == "same-origin" && controller.browsers[secondID]?.isLoading == false }
        let sameOrigin = try await activeTabAccess()
        if sameOrigin.allowed == granted.allowed { try check(true, "") }
        else if ProcessInfo.processInfo.environment["BAM_REQUIRE_ACTIVE_TAB_SAME_ORIGIN"] == "1" {
            throw ExtensionSmokeTest.Failure(description: "Same-origin navigation ended the activeTab grant, unlike Chrome: \(sameOrigin)")
        } else {
            print("KNOWN_LIMITATION activeTab: same-origin navigation ended the grant (gesture active: \(activeContext.hasActiveUserGesture(in: secondTab))); Chrome keeps it. Not counted as passed. Set BAM_REQUIRE_ACTIVE_TAB_SAME_ORIGIN=1 for the strict reproducer."); fflush(stdout)
        }
        // Cross-origin navigation must end it. Start from a fresh gesture so the check does not
        // depend on the same-origin outcome above.
        activeContext.performAction(for: secondTab)
        try check(try await activeTabAccess().allowed == granted.allowed, "A fresh gesture did not grant access before the cross-origin check")
        let crossURL = secondPage(host: "localhost", query: "cross-origin")
        controller.navigatePane(secondID, address: crossURL.absoluteString)
        try await wait("activeTab second tab did not navigate to another origin") { controller.browsers[secondID]?.url?.host == "localhost" && controller.browsers[secondID]?.isLoading == false }
        let crossOrigin = try await activeTabAccess()
        try check(crossOrigin.allowed.isEmpty && crossOrigin.callback == "error", "Cross-origin navigation did not end the tab's activeTab grant: \(crossOrigin)")
        activePage.stopLoading()
        _ = host.closeTab?(secondID)
        try await host.remove(id: activeID)
        host.reconcile()
        _ = try await popup.evaluateJavaScript("document.getElementById('open-page').click(); true")
        // Last use of the original popup: release the test's references to it (and the first action's popup).
        heldPopup = nil
        tabAction.closePopup(); actionContext.action(for: nil)?.closePopup()
        try await wait("Browser adapter did not open its own extension page") { controller.session.tabs.contains { URLInput.extensionURL($0.address) != nil } }
        guard let tab = controller.session.tabs.first(where: { URLInput.extensionURL($0.address) != nil }), controller.browsers[tab.id] != nil else { throw ExtensionSmokeTest.Failure(description: "Missing extension renderer") }
        // Bam owns its renderers; the test only observes them weakly, so it never keeps an old one (and its process) alive.
        weak let extensionWeb = controller.browsers[tab.id]
        try await wait("Browser adapter used the wrong configuration for its extension page") { extensionWeb?.title == "Bam extension page ready" }
        try check(controller.session.profileID(for: tab) == profile && extensionWeb.map { controller.profileID(of: $0) } == profile, "Extension-created page escaped its source profile")
        let extensionURL = URL(string: tab.address)!
        try check(controller.openProfileTab(extensionURL, profileID: other, active: false) == nil, "Browser adapter opened extension page in a foreign profile")
        controller.navigatePane(tab.id, address: url.absoluteString)
        try await wait("Extension-to-HTTP navigation did not replace renderer") { controller.browsers[tab.id] !== extensionWeb && controller.browsers[tab.id]?.url == url && controller.browsers[tab.id]?.isLoading == false }
        weak let normal = controller.browsers[tab.id]
        try check(normal != nil, "The HTTP renderer was missing")
        controller.navigatePane(tab.id, address: extensionURL.absoluteString)
        try await wait("HTTP-to-extension navigation did not replace renderer") { controller.browsers[tab.id] !== normal && controller.browsers[tab.id]?.title == "Bam extension page ready" }
        // Cancellation is a no-op on the running package and signed-in storage.
        let updateFolder = FileManager.default.temporaryDirectory.appendingPathComponent("bam-action-update-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: sourceFixture, to: updateFolder)
        defer { try? FileManager.default.removeItem(at: updateFolder) }
        let updateManifest = updateFolder.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: updateManifest)) as! [String: Any]
        manifest["version"] = "2.0.0"
        manifest["optional_permissions"] = ["alarms", "cookies"]
        manifest["optional_host_permissions"] = ["http://localhost/*", "https://optional.invalid/*"]
        // The update requests one new site: the update review must list exactly it, and declining keeps the old version.
        manifest["host_permissions"] = ["http://127.0.0.1/*", "https://new.invalid/*"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: updateManifest)
        let installedManifest = host.storageURL.appendingPathComponent(extensionID.uuidString).appendingPathComponent("package/manifest.json")
        let originalBytes = try Data(contentsOf: installedManifest)
        let grantExpiry = Date(timeIntervalSinceNow: 86_400)
        let optionalGranted = try WKWebExtension.MatchPattern(string: "http://localhost/kept/*")
        let optionalDenied = try WKWebExtension.MatchPattern(string: "https://optional.invalid/blocked/*")
        let removedScope = try WKWebExtension.MatchPattern(string: "https://removed.invalid/*")
        func seedOptionalPermissions(_ context: WKWebExtensionContext) {
            context.setPermissionStatus(.grantedExplicitly, for: .alarms, expirationDate: grantExpiry)
            context.setPermissionStatus(.deniedExplicitly, for: .cookies, expirationDate: grantExpiry)
            context.setPermissionStatus(.grantedExplicitly, for: .webNavigation, expirationDate: grantExpiry)
            context.setPermissionStatus(.grantedExplicitly, for: optionalGranted, expirationDate: grantExpiry)
            context.setPermissionStatus(.deniedExplicitly, for: optionalDenied, expirationDate: grantExpiry)
            context.setPermissionStatus(.grantedExplicitly, for: removedScope, expirationDate: grantExpiry)
            host.persistPermissions(context)
        }
        // Site access on the live context through the panel's engine API (after the approved update).
        /// A Site Access change that withdraws live access restarts the extension in two phases
        /// (work/site-access-two-phase-final-contract.md): its context is nil until the restart completes. Wait for that
        /// restart by its generation before reading the context; a change that withdrew nothing returns at once.
        func settleRestart(_ label: String, from before: UInt64) async throws {
            let started = host.restartGeneration[extensionID] ?? 0
            guard started != before else { return }
            try check(started == before + 1, "\(label): \(started - before) restarts started instead of one")
            guard let result = await host.restartCompletion(id: extensionID, generation: started) else {
                throw ExtensionSmokeTest.Failure(description: "\(label): no result for restart generation \(started)")
            }
            try check(result == .restarted && host.context(for: extensionID)?.isLoaded == true && !host.isRestarting(id: extensionID),
                      "\(label): the restart finished \(result), or left no loaded context")
            _ = host.takeSiteAccessNotice(id: extensionID)
        }
        func generationNow() -> UInt64 { host.restartGeneration[extensionID] ?? 0 }
        func checkSiteAccess() async throws {
            let ip = URL(string: "http://127.0.0.1/site-access")!, newSite = URL(string: "https://new.invalid/")!
            let ipPattern = try WKWebExtension.MatchPattern(string: "http://127.0.0.1/*")
            func granted(_ url: URL) -> Bool {
                guard let status = host.context(for: extensionID)?.permissionStatus(for: url) else { return false }
                return status == .grantedExplicitly || status == .grantedImplicitly
            }
            func isFinite(_ date: Date?) -> Bool { date.map { $0 < Date.distantFuture.addingTimeInterval(-86_400) } ?? false }
            func perform(_ snapshot: BrowserExtensionSiteAccessSnapshot, _ change: BrowserExtensionSiteAccessChange) throws -> BrowserExtensionSiteAccessSnapshot {
                try host.performSiteAccess(id: extensionID, profileID: profile, revision: snapshot.revision, displayed: snapshot.declarations!, change: change)
            }
            guard let updated = host.siteAccess(id: extensionID) else { throw ExtensionSmokeTest.Failure(description: "No site access snapshot") }
            try check(updated.state.mode == .allRequested && updated.declarations?.requested == ["http://127.0.0.1/*", "https://new.invalid/*"] &&
                updated.pending.isEmpty && granted(ip) && granted(newSite), "Approved update did not grant exactly the reviewed sites: \(updated.state)")
            try check(isFinite(updated.timed.optional[optionalGranted.string]) && updated.timed.requested.isEmpty,
                "A time-limited optional grant lost its provenance or date: \(updated.timed)")
            let beforeWithhold = generationNow()
            let withheld = try perform(updated, .choose(.withheld))
            try await settleRestart("Withhold", from: beforeWithhold)
            try check(withheld.state.mode == .withheld && !granted(ip) && !granted(newSite) && withheld.timed.optional[optionalGranted.string] != nil &&
                host.context(for: extensionID)?.grantedPermissionMatchPatterns[optionalGranted] != nil,
                "Withholding must remove requested sites from the live extension and keep optional grants")
            var stale = false
            do { _ = try perform(updated, .choose(.allRequested)) } catch BrowserExtensionSiteAccessFailure.stale { stale = true }
            try check(stale && !granted(ip) && host.siteAccess(id: extensionID)?.state.mode == .withheld, "A stale action approved sites")
            // Current revision but declarations the user never saw (an update between render and click): refused.
            var unseen = false
            do { _ = try host.performSiteAccess(id: extensionID, profileID: profile, revision: withheld.revision,
                                                displayed: .init(requested: ["http://127.0.0.1/*"]), change: .choose(.allRequested)) }
            catch BrowserExtensionSiteAccessFailure.stale { unseen = true }
            try check(unseen && !granted(ip) && !granted(newSite), "An action for declarations the user never saw approved sites")
            var refusal: ExtensionSiteAccess.Refusal?
            do { _ = try perform(withheld, .addSite(input: "example.com", includeSubdomains: false)) }
            catch BrowserExtensionSiteAccessFailure.refused(let reason) { refusal = reason }
            try check(refusal == .notRequested && host.siteAccess(id: extensionID)?.revision == withheld.revision, "An unrequested site was not refused")
            let listed = try perform(withheld, .addSite(input: "127.0.0.1", includeSubdomains: false))
            try check(listed.state.mode == .specific(["http://127.0.0.1/*"]) && granted(ip) && !granted(newSite), "Adding a site must grant just that site")
            try await host.setEnabled(false, id: extensionID); try await host.setEnabled(true, id: extensionID)
            try check(host.siteAccess(id: extensionID)?.state.mode == .specific(["http://127.0.0.1/*"]) && granted(ip) && !granted(newSite),
                "Re-enabling must keep the narrower choice, never re-grant every requested site")
            // An explicit finite expiry on a permanent site constrains it until a fresh approval, across a reload.
            // Measured (work/chrome-expiry-diagnostic-runtime-3b1bd88.log): setPermissionStatus(.grantedExplicitly, for:,
            // expirationDate:) on an already-granted pattern leaves its permanent expiry. The SDK's settable
            // grantedPermissionMatchPatterns ("replace all existing entries") sets the exact expiry instead; every other
            // entry is carried over unchanged.
            // Scoped: no context is held past this block, so none survives the withdrawals below.
            do {
            guard let live = host.context(for: extensionID) else { throw ExtensionSmokeTest.Failure(description: "Re-enable failed") }
            let desiredExpiry = Date(timeIntervalSinceNow: 3_600)
            let grantsBefore = live.grantedPermissionMatchPatterns
            try check(grantsBefore[ipPattern].map { !isFinite($0) } == true, "The listed site was not permanently granted before shortening: \(String(describing: grantsBefore[ipPattern]))")
            var shortenedGrants = grantsBefore
            shortenedGrants[ipPattern] = desiredExpiry
            live.grantedPermissionMatchPatterns = shortenedGrants
            let grantsAfter = live.grantedPermissionMatchPatterns
            try check(grantsAfter[ipPattern].map { abs($0.timeIntervalSince(desiredExpiry)) < 1 } == true &&
                grantsAfter.count == grantsBefore.count && grantsBefore.allSatisfy { key, date in key == ipPattern || grantsAfter[key] == date },
                "Setting the exact native expiry failed or changed other grants: \(ipPattern.string)=\(String(describing: grantsAfter[ipPattern])), desired=\(desiredExpiry), entries \(grantsBefore.count)→\(grantsAfter.count)")
            host.persistPermissions(live)
            let shortened = host.siteAccess(id: extensionID)
            try check(shortened?.state.mode == .withheld && isFinite(shortened?.timed.requested[ipPattern.string]),
                "A shortened grant must leave the permanent choice as time-limited requested access: \(String(describing: shortened?.state)); native \(ipPattern.string) expiry=\(String(describing: live.grantedPermissionMatchPatterns[ipPattern]))")
            }
            try await host.setEnabled(false, id: extensionID); try await host.setEnabled(true, id: extensionID)
            try check(isFinite(host.context(for: extensionID)?.grantedPermissionMatchPatterns[ipPattern]) && granted(ip),
                "A reload restored a shortened grant to permanent")
            guard let reloaded = host.siteAccess(id: extensionID) else { throw ExtensionSmokeTest.Failure(description: "No snapshot after reload") }
            let beforeEnd = generationNow()
            let ended = try perform(reloaded, .choose(.withheld))
            try await settleRestart("Withholding a time-limited grant", from: beforeEnd)
            try check(ended.timed.requested.isEmpty && !granted(ip), "Withholding must end requested time-limited grants")
            // A runtime prompt whose dialog outlives a panel change neither grants nor denies (the Allow wins).
            guard let promptContext = host.context(for: extensionID), let promptController = promptContext.webExtensionController,
                  let promptRuntime = promptController.delegate as? BrowserExtensionRuntime else { throw ExtensionSmokeTest.Failure(description: "No live runtime for the prompt") }
            let previousPrompt = host.permissionPrompt
            var promptAnswer: Set<WKWebExtension.MatchPattern>?
            host.permissionPrompt = { _ in
                _ = try? host.performSiteAccess(id: extensionID, profileID: profile, revision: ended.revision, displayed: ended.declarations!,
                                                change: .addSite(input: "127.0.0.1", includeSubdomains: false))
                return false
            }
            promptRuntime.webExtensionController(promptController, promptForPermissionMatchPatterns: [ipPattern], in: nil, for: promptContext) { granted, _ in promptAnswer = granted }
            host.permissionPrompt = previousPrompt
            try check(promptAnswer == [] && granted(ip) && host.records.first { $0.id == extensionID }?.deniedPatterns[ipPattern.string] == nil &&
                promptContext.deniedPermissionMatchPatterns[ipPattern] == nil,
                "A stale prompt denial overrode a newer Allow")
            guard let allowed = host.siteAccess(id: extensionID) else { throw ExtensionSmokeTest.Failure(description: "No snapshot after prompt") }
            let restored = try perform(allowed, .choose(.allRequested))
            try check(restored.state.mode == .allRequested && restored.timed.requested.isEmpty && granted(ip) && granted(newSite) &&
                !isFinite(host.context(for: extensionID)?.grantedPermissionMatchPatterns[ipPattern]),
                "A fresh All requested approval must grant every requested site permanently")
            // Refused before any review (undeclared): answered empty, nothing shown, and no denial recorded, for both
            // prompt kinds. A stored denial would cover the whole host ahead of any later grant.
            guard let liveContext = host.context(for: extensionID) else { throw ExtensionSmokeTest.Failure(description: "No live context for refusal checks") }
            let earlierPrompt = host.permissionPrompt
            defer { host.permissionPrompt = earlierPrompt }
            var reviewsShown = 0
            host.permissionPrompt = { _ in reviewsShown += 1; return false }
            func deniedKeys(_ url: URL) -> [String] {
                (host.context(for: extensionID)?.deniedPermissionMatchPatterns.keys.filter { $0.matches(url) }.map(\.string) ?? []) +
                (host.records.first { $0.id == extensionID }?.deniedPatterns.keys.filter { (try? WKWebExtension.MatchPattern(string: $0))?.matches(url) == true } ?? [])
            }
            let undeclaredURL = URL(string: "https://undeclared.invalid/page")!
            var urlAnswer: Set<URL>?, patternAnswer: Set<WKWebExtension.MatchPattern>?
            promptRuntime.webExtensionController(promptController, promptForPermissionToAccess: [undeclaredURL], in: nil, for: liveContext) { granted, _ in urlAnswer = granted }
            promptRuntime.webExtensionController(promptController, promptForPermissionMatchPatterns: [try WKWebExtension.MatchPattern(string: "https://undeclared.invalid/*")],
                                                 in: nil, for: liveContext) { granted, _ in patternAnswer = granted }
            try check(reviewsShown == 0 && urlAnswer == [] && patternAnswer == [] && deniedKeys(undeclaredURL).isEmpty &&
                liveContext.permissionStatus(for: undeclaredURL) != .deniedExplicitly,
                "A refusal the user never saw recorded a denial or showed a review: shown=\(reviewsShown), denied=\(deniedKeys(undeclaredURL))")
        }
        /// Chrome-style consent (work/chrome-implicit-url-consent-policy.md): WebKit's *implicit* URL requests (tab reads,
        /// injection, cookies, CORS) are answered empty with no review and no denial, even for an optional or a
        /// requested-but-withheld site. Only explicit pattern requests (permissions.request) are reviewed. Runs before
        /// checkSiteAccess, from and back to All requested, so it is independent of that function's steps.
        func checkExplicitConsent() async throws {
            let ip = URL(string: "http://127.0.0.1/site-access")!, newSite = URL(string: "https://new.invalid/")!
            func granted(_ url: URL) -> Bool {
                guard let status = host.context(for: extensionID)?.permissionStatus(for: url) else { return false }
                return status == .grantedExplicitly || status == .grantedImplicitly
            }
            func perform(_ snapshot: BrowserExtensionSiteAccessSnapshot, _ change: BrowserExtensionSiteAccessChange) throws -> BrowserExtensionSiteAccessSnapshot {
                try host.performSiteAccess(id: extensionID, profileID: profile, revision: snapshot.revision, displayed: snapshot.declarations!, change: change)
            }
            func deniedKeys(_ url: URL) -> [String] {
                (host.context(for: extensionID)?.deniedPermissionMatchPatterns.keys.filter { $0.matches(url) }.map(\.string) ?? []) +
                (host.records.first { $0.id == extensionID }?.deniedPatterns.keys.filter { (try? WKWebExtension.MatchPattern(string: $0))?.matches(url) == true } ?? [])
            }
            guard let promptController = host.context(for: extensionID)?.webExtensionController,
                  let promptRuntime = promptController.delegate as? BrowserExtensionRuntime else { throw ExtensionSmokeTest.Failure(description: "No live runtime for consent checks") }
            // A withdrawal can restart the extension with a NEW context (work/extension-renderer-restart-fixture-contract.md):
            // never keep one across a Site Access change. Every use re-reads the context and requires it to be loaded and
            // owned by this profile's runtime, so nothing here can pass against a retired context.
            func live() throws -> WKWebExtensionContext {
                guard let context = host.context(for: extensionID), context.isLoaded, promptRuntime.contexts[extensionID] === context,
                      context.webExtensionController === promptController else {
                    throw ExtensionSmokeTest.Failure(description: "The extension has no loaded context owned by this profile's runtime")
                }
                return context
            }
            try check(host.siteAccess(id: extensionID)?.state.mode == .allRequested && granted(ip) && granted(newSite), "Consent checks did not start from All requested")
            let earlierPrompt = host.permissionPrompt
            defer { host.permissionPrompt = earlierPrompt }
            var reviewsShown = 0
            // A subset of the optional https://optional.invalid/* that overlaps no seeded grant or denial: WebKit can drop
            // grants a denied pattern covers, and the time-limited http://localhost/kept/* grant must survive for later steps.
            let optionalURL = URL(string: "https://optional.invalid/consent/page")!, optionalOrigin = "https://optional.invalid/consent/*"
            let beforeConsentBase = generationNow()
            let consentBase = try perform(host.siteAccess(id: extensionID)!, .choose(.withheld))
            try await settleRestart("Consent checks' first Withhold", from: beforeConsentBase)
            var implicitAnswer: Set<URL>?
            host.permissionPrompt = { _ in reviewsShown += 1; return true }
            promptRuntime.webExtensionController(promptController, promptForPermissionToAccess: [optionalURL, ip], in: nil, for: try live()) { granted, _ in implicitAnswer = granted }
            try check(reviewsShown == 0 && implicitAnswer == [] && !granted(ip) && deniedKeys(optionalURL).isEmpty && deniedKeys(ip).isEmpty &&
                host.siteAccess(id: extensionID)?.state.mode == .withheld && host.siteAccess(id: extensionID)?.revision == consentBase.revision,
                "An implicit URL request showed a review, granted, denied or changed Site Access: shown=\(reviewsShown), answer=\(String(describing: implicitAnswer))")
            // Explicit consent keeps its decision: an offered and declined pattern is denied.
            let optionalPattern = try WKWebExtension.MatchPattern(string: optionalOrigin)
            var declinedAnswer: Set<WKWebExtension.MatchPattern>?
            host.permissionPrompt = { _ in reviewsShown += 1; return false }
            promptRuntime.webExtensionController(promptController, promptForPermissionMatchPatterns: [optionalPattern], in: nil, for: try live()) { granted, _ in declinedAnswer = granted }
            try check(reviewsShown == 1 && declinedAnswer == [] && live().permissionStatus(for: optionalURL) == .deniedExplicitly && !deniedKeys(optionalURL).isEmpty,
                "An offered and declined pattern must be denied: shown=\(reviewsShown), status=\(String(describing: try? live().permissionStatus(for: optionalURL).rawValue))")
            // Test cleanup only: drop the declined denial so the installed-engine checks below start from the same state.
            func dropOptionalDenial() throws {
                let context = try live()
                for key in context.deniedPermissionMatchPatterns.keys where key.matches(optionalURL) { context.deniedPermissionMatchPatterns.removeValue(forKey: key) }
                host.persistPermissions(context)
            }
            try dropOptionalDenial()

            // The same policy through the installed engine, from a real extension page and a real 127.0.0.1 tab.
            let consentTabURL = { () -> URL in
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!; components.query = "consent"; return components.url!
            }()
            guard let consentTab = controller.openProfileTab(consentTabURL, profileID: profile, active: false) else { throw ExtensionSmokeTest.Failure(description: "No consent tab") }
            defer { _ = host.closeTab?(consentTab) }
            try await wait("The consent tab did not load") { controller.browsers[consentTab]?.url == consentTabURL && controller.browsers[consentTab]?.isLoading == false }
            // The test's own extension page, always built from the current context and rebuilt after a withdrawal; it is
            // held in exactly one place so releasing it really drops the test's reference.
            var consentPage: WKWebView?
            defer { consentPage?.stopLoading() }
            func buildConsentPage() async throws {
                let context = try live()
                guard let configuration = context.webViewConfiguration else { throw ExtensionSmokeTest.Failure(description: "No extension page configuration") }
                let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
                web.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
                consentPage = web
                try await wait("The extension page for consent checks did not load") { web.title == "Bam extension page ready" }
            }
            /// Drops the test's reference and reports (not asserts) whether WebKit deallocated it: cleanup, not policy.
            func releaseConsentPage(_ reason: String) async throws {
                weak let released = consentPage
                consentPage?.stopLoading(); consentPage = nil
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                while released != nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 40_000_000) }
                print("CONSENT_PAGE_RELEASE reason=\(reason) deallocated=\(released == nil)"); fflush(stdout)
            }
            try await buildConsentPage()
            promptRuntime.reconcile()
            guard let surface = promptRuntime.currentSurface(consentTab) else { throw ExtensionSmokeTest.Failure(description: "The consent tab is not visible to the extension") }
            let consentIndex = promptRuntime.tabIndex(consentTab, in: promptRuntime.windowKey(surface))
            func consentProbe(_ body: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
                let script = "const tab = (await browser.tabs.query({})).find((t) => t.index === index && t.windowId !== undefined); return JSON.stringify(await (async () => {\n" + body + "\n})());"
                guard let page = consentPage else { throw ExtensionSmokeTest.Failure(description: "No consent page") }
                let text = try await page.callAsyncJavaScript(script, arguments: arguments.merging(["index": consentIndex]) { a, _ in a }, contentWorld: .page) as? String
                guard let data = text?.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ExtensionSmokeTest.Failure(description: "Consent probe returned \(text ?? "nil")")
                }
                return value
            }
            let injection = "return await browser.scripting.executeScript({target: {tabId: tab.id}, func: () => document.location.host})" +
                ".then((r) => 'ran:' + (r && r[0] && r[0].result), (e) => 'refused:' + String(e && e.message));"
            // Withheld requested host: tab reads (query, get, populated windows), injection and a CORS fetch neither prompt
            // nor grant nor deny (the prompt would approve); the record and Site Access are unchanged.
            func recordState() -> String {
                guard let record = host.records.first(where: { $0.id == extensionID }) else { return "no-record" }
                return "\(record.patterns.keys.sorted()) \(record.deniedPatterns.keys.sorted()) \(record.siteAccess?.base64EncodedString() ?? "-")"
            }
            func undecided(_ url: URL) throws -> Bool { ![.grantedExplicitly, .deniedExplicitly].contains(try live().permissionStatus(for: url)) }
            func loopbackState() -> String {
                guard let context = try? live() else { return "no loaded context" }
                return "native status=\(context.permissionStatus(for: consentTabURL).rawValue) hasAccess=\(context.hasAccess(to: consentTabURL)) " +
                    "granted127=\(context.grantedPermissionMatchPatterns.keys.filter { $0.string.contains("127.0.0.1") }.map(\.string).sorted()) " +
                    "denied127=\(context.deniedPermissionMatchPatterns.keys.filter { $0.string.contains("127.0.0.1") }.map(\.string).sorted())"
            }
            let recordBefore = recordState()
            reviewsShown = 0
            host.permissionPrompt = { _ in reviewsShown += 1; return true }
            let withheldUse = try await consentProbe("""
                const read = (await browser.tabs.query({})).length;
                const got = !!(await browser.tabs.get(tab.id));
                const windows = (await browser.windows.getAll({populate: true})).length;
                const injected = await (async () => { \(injection) })();
                let fetchDetail = null;
                const fetched = await fetch(target, {credentials: 'include', cache: 'no-store'}).then(async (r) => {
                  const body = await r.text();
                  fetchDetail = {status: r.status, type: r.type, url: r.url, acao: r.headers.get('access-control-allow-origin'), length: body.length};
                  return 'read:' + r.status;
                }, (e) => { fetchDetail = {error: String(e && e.message || e)}; return 'refused'; });
                return {found: !!tab, read, got, windows, injected, fetched, fetchDetail};
                """, ["target": consentTabURL.absoluteString])
            try check(withheldUse["found"] as? Bool == true && withheldUse["got"] as? Bool == true && reviewsShown == 0 &&
                (withheldUse["injected"] as? String)?.hasPrefix("refused:") == true && withheldUse["fetched"] as? String == "refused" &&
                !granted(ip) && deniedKeys(ip).isEmpty && undecided(consentTabURL) && recordState() == recordBefore &&
                host.siteAccess(id: extensionID)?.state.mode == .withheld && host.siteAccess(id: extensionID)?.revision == consentBase.revision,
                "Using a withheld requested site prompted, granted, denied or changed Site Access: shown=\(reviewsShown), \(withheldUse); " +
                loopbackState())
            // activeTab on the withheld site: a user gesture in the tab lets injection run with no review and no lasting grant.
            guard let consentAdapter = promptRuntime.tabs[consentTab] else { throw ExtensionSmokeTest.Failure(description: "No adapter for the consent tab") }
            try live().userGesturePerformed(in: consentAdapter)
            let gestured = try await consentProbe("return {injected: await (async () => { \(injection) })()};")
            try live().clearUserGesture(in: consentAdapter)
            try check((gestured["injected"] as? String)?.hasPrefix("ran:127.0.0.1") == true && reviewsShown == 0 && recordState() == recordBefore &&
                host.siteAccess(id: extensionID)?.state.mode == .withheld,
                "activeTab on a withheld site prompted, failed or left a lasting grant: shown=\(reviewsShown), \(gestured)")
            // An explicit request reaches the pattern review once; declining denies, approving grants and injection then works.
            var reviewed: [BrowserExtensionPermissionReview] = []
            host.permissionPrompt = { review in reviewed.append(review); return false }
            let declinedRequest = try await consentProbe("return {granted: await browser.permissions.request({origins: [origin]})};", ["origin": optionalOrigin])
            try check(reviewed.count == 1 && reviewed[0].websites == [optionalOrigin] && reviewed[0].permissions.isEmpty &&
                declinedRequest["granted"] as? Bool == false && live().permissionStatus(for: optionalURL) == .deniedExplicitly,
                "A declined permissions.request did not show one pattern review or record its denial: \(reviewed.map(\.websites)) \(declinedRequest)")
            try dropOptionalDenial()
            // A stale explicit answer: Site Access changes while the review is open (the panel adds the site); the
            // dialog's Allow then grants nothing beyond the panel's change and denies nothing.
            reviewed = []
            host.permissionPrompt = { review in
                reviewed.append(review)
                if let current = host.siteAccess(id: extensionID) { _ = try? perform(current, .addSite(input: "127.0.0.1", includeSubdomains: false)) }
                return true
            }
            let staleRequest = try await consentProbe("return {granted: await browser.permissions.request({origins: ['http://127.0.0.1/*']})};")
            try check(reviewed.count == 1 && staleRequest["granted"] as? Bool == false && granted(ip) && deniedKeys(ip).isEmpty &&
                host.siteAccess(id: extensionID)?.state.mode == .specific(["http://127.0.0.1/*"]),
                "A stale explicit answer granted or denied beyond the panel's change: \(reviewed.map(\.websites)) \(staleRequest)")
            // This withdrawal may restart the extension: the old page belongs to the old context, so release it and build
            // the page for the approved request from the context loaded now.
            try await releaseConsentPage("before-second-withhold")
            let beforeSecondWithhold = generationNow()
            _ = try perform(host.siteAccess(id: extensionID)!, .choose(.withheld))
            try await settleRestart("Consent checks' second Withhold", from: beforeSecondWithhold)
            try check(!granted(ip), "The consent checks could not withhold the requested site again")
            try await buildConsentPage()
            reviewed = []
            host.permissionPrompt = { review in reviewed.append(review); return true }
            let approvedRequest = try await consentProbe("const granted = await browser.permissions.request({origins: ['http://127.0.0.1/*']}); const injected = await (async () => { \(injection) })(); return {granted, injected};")
            try check(reviewed.count == 1 && reviewed[0].websites == ["http://127.0.0.1/*"] && approvedRequest["granted"] as? Bool == true && granted(ip) &&
                (approvedRequest["injected"] as? String)?.hasPrefix("ran:127.0.0.1") == true &&
                host.siteAccess(id: extensionID)?.state.mode == .specific(["http://127.0.0.1/*"]),
                "An approved permissions.request did not review once, list the site and allow injection: \(reviewed.map(\.websites)) \(approvedRequest) mode=\(String(describing: host.siteAccess(id: extensionID)?.state.mode))")
            // Back to every requested site for the steps after this check.
            let consentRestored = try perform(host.siteAccess(id: extensionID)!, .choose(.allRequested))
            try check(consentRestored.state.mode == .allRequested && granted(ip) && granted(newSite), "Site Access was not restored after the consent checks")
        }
        let originalContext = host.context(for: extensionID)!
        seedOptionalPermissions(originalContext)
        let originalRecord = host.items(profileID: profile).first { $0.id == extensionID }!
        let catalog = ExtensionCatalogRecord(source: .local, upstreamID: nil, listingURL: nil, downloadURL: nil,
            publisher: "Bam test fixture", version: "2.0.0", sha256: "", provenance: "Original local fixture", installedAt: Date())
        var declinedReview: BrowserExtensionPermissionReview?
        host.permissionPrompt = { review in declinedReview = review; return false }
        var cancelled = false
        do { try await host.replacePackage(id: extensionID, with: updateFolder, catalog: catalog) }
        catch is BrowserExtensionUpdateCancelled { cancelled = true }
        let afterCancel = host.items(profileID: profile).first { $0.id == extensionID }
        try check(cancelled && host.context(for: extensionID) === originalContext && afterCancel?.enabled == true,
            "Canceling an update unloaded or disabled the working extension")
        try check(try Data(contentsOf: installedManifest) == originalBytes && afterCancel?.version == originalRecord.version &&
            afterCancel?.permissions == originalRecord.permissions && afterCancel?.patterns == originalRecord.patterns && afterCancel?.catalog == originalRecord.catalog,
            "Canceling an update replaced package bytes, grants or provenance")
        try check(declinedReview?.websites == ["https://new.invalid/*"] && afterCancel?.siteAccess == originalRecord.siteAccess &&
            afterCancel?.timedOptionalSiteGrants == originalRecord.timedOptionalSiteGrants &&
            originalContext.permissionStatus(for: URL(string: "https://new.invalid/")!) != .grantedExplicitly,
            "Declining an update's new site must cancel it and keep the old site access: review=\(declinedReview?.websites ?? [])")
        // The native initializer may finish synchronously for a tiny fixture.
        // Wrap the real parser so user changes happen before its result returns,
        // instead of relying on a queued Task winning an unspecified scheduling race.
        let nativeParser = host.packageParser
        defer { host.packageParser = nativeParser }
        host.permissionPrompt = { _ in true }
        var mutateStaging = true
        host.packageParser = { [weak host] package in
            let parsed = try await WKWebExtension(resourceBaseURL: package)
            if mutateStaging, let host {
                mutateStaging = false
                try await host.setEnabled(false, id: extensionID)
                try await host.setEnabled(true, id: extensionID)
            }
            return parsed
        }
        var stagingCancelled = false
        do { try await host.replacePackage(id: extensionID, with: updateFolder, catalog: catalog) }
        catch is BrowserExtensionUpdateCancelled { stagingCancelled = true }
        let stagedRecord = host.items(profileID: profile).first { $0.id == extensionID }
        try check(!mutateStaging && stagingCancelled && stagedRecord?.version == originalRecord.version && host.context(for: extensionID) != nil,
            "Staging mutation was not preserved: ran=\(!mutateStaging), canceled=\(stagingCancelled), version=\(stagedRecord?.version ?? "missing"), loaded=\(host.context(for: extensionID) != nil)")
        // Review arms the next (activation) parse. Disabling then must restore
        // the prior bytes without resurrecting the explicitly disabled extension.
        var disableOnNextParse = false, activationDisableRan = false
        host.packageParser = { [weak host] package in
            let parsed = try await WKWebExtension(resourceBaseURL: package)
            if disableOnNextParse, let host {
                disableOnNextParse = false; activationDisableRan = true
                try await host.setEnabled(false, id: extensionID)
            }
            return parsed
        }
        host.permissionPrompt = { _ in disableOnNextParse = true; return true }
        var activationCancelled = false
        do { try await host.replacePackage(id: extensionID, with: updateFolder, catalog: catalog) }
        catch is BrowserExtensionUpdateCancelled { activationCancelled = true }
        let interruptedRecord = host.items(profileID: profile).first { $0.id == extensionID }
        try check(activationDisableRan && activationCancelled && host.context(for: extensionID) == nil && interruptedRecord?.enabled == false,
            "Activation mutation was not preserved: ran=\(activationDisableRan), canceled=\(activationCancelled), enabled=\(String(describing: interruptedRecord?.enabled)), loaded=\(host.context(for: extensionID) != nil)")
        try check(try Data(contentsOf: installedManifest) == originalBytes, "Interrupted activation failed to restore the previous package")
        // Closing the library while a disabled extension is being parsed must
        // cancel before any new permission prompt or activation.
        var cancelledEnableReviews = 0
        host.permissionPrompt = { _ in cancelledEnableReviews += 1; return true }
        host.packageParser = { package in
            let parsed = try await WKWebExtension(resourceBaseURL: package)
            withUnsafeCurrentTask { $0?.cancel() }
            return parsed
        }
        let cancelledEnable = Task { @MainActor in try await host.setEnabled(true, id: extensionID) }
        var enableCancelled = false
        do { try await cancelledEnable.value }
        catch is CancellationError { enableCancelled = true }
        try check(enableCancelled && cancelledEnableReviews == 0 && host.context(for: extensionID) == nil &&
            host.items(profileID: profile).first { $0.id == extensionID }?.enabled == false && host.errors[extensionID] == nil,
            "Canceled re-enable prompted, activated, or reported a healthy disabled extension as broken")
        host.packageParser = nativeParser
        host.permissionPrompt = { _ in true }
        try await host.setEnabled(true, id: extensionID)
        guard let beforeUpdateContext = host.context(for: extensionID) else { throw ExtensionSmokeTest.Failure(description: "Update fixture could not re-enable") }
        seedOptionalPermissions(beforeUpdateContext)
        let grantedBeforeUpdate = host.items(profileID: profile).first { $0.id == extensionID }!
        // WebKit normalizes date precision. Preserve the expiry it actually
        // stored, rather than requiring the original sub-millisecond Date bits.
        let beforeValues = [grantedBeforeUpdate.permissions["alarms"], grantedBeforeUpdate.deniedPermissions["cookies"],
            grantedBeforeUpdate.patterns[optionalGranted.string], grantedBeforeUpdate.deniedPatterns[optionalDenied.string]]
        try check(beforeValues.allSatisfy { $0 != nil && abs($0!.timeIntervalSince(grantExpiry)) < 0.001 },
            "Native fixture did not store its optional grants/denials: \(beforeValues.map { $0?.timeIntervalSince1970 })")
        var approvedReview: BrowserExtensionPermissionReview?
        host.permissionPrompt = { review in approvedReview = review; return true }
        try await host.replacePackage(id: extensionID, with: updateFolder, catalog: catalog)
        try check(approvedReview?.websites == ["https://new.invalid/*"], "The update review must list exactly the new site: \(approvedReview?.websites ?? [])")
        let updatedRecord = host.items(profileID: profile).first { $0.id == extensionID }!
        let afterValues = [updatedRecord.permissions["alarms"], updatedRecord.deniedPermissions["cookies"],
            updatedRecord.patterns[optionalGranted.string], updatedRecord.deniedPatterns[optionalDenied.string]]
        try check(afterValues == beforeValues,
            "Update lost optional grants/denials: before=\(beforeValues.map { $0?.timeIntervalSince1970 }), after=\(afterValues.map { $0?.timeIntervalSince1970 }), grantedSites=\(updatedRecord.patterns.keys.sorted()), deniedSites=\(updatedRecord.deniedPatterns.keys.sorted())")
        try check(updatedRecord.permissions["webNavigation"] == nil && updatedRecord.patterns[removedScope.string] == nil && updatedRecord.permissions["storage"] != nil,
            "An update retained removed permissions or lost approved required permissions")
        try check(host.items(profileID: profile).first { $0.id == extensionID }?.version == "2.0.0" && host.context(for: extensionID) != nil,
            "Approved update did not activate its final package")
        do {
            // Scoped, so the test's reference to this popup ends here (see heldPopup above).
            guard let updatedPopup = host.context(for: extensionID)?.action(for: nil)?.popupWebView else { throw ExtensionSmokeTest.Failure(description: "Updated package has no popup") }
            try await wait("Updated extension still looked for scripts at the staging URL") { (try? await updatedPopup.evaluateJavaScript("document.title")) as? String == "Bam fixture ready" }
        }
        host.context(for: extensionID)?.action(for: nil)?.closePopup()
        // The raw CORS lifetime diagnostic (ExtensionFetchAccessProbe: deliberately held, Bam-unmanaged extension pages)
        // runs only as --extension-fetch-only. Acceptance here and in ExtensionRendererRestartAcceptance is strict.
        try await checkExplicitConsent()
        try await checkSiteAccess()
        try await host.setEnabled(false, id: extensionID)
        controller.refresh()
        try check(actionButton() == nil, "Disabling the extension left a stale sidebar action")
        controller.navigatePane(tab.id, address: extensionURL.absoluteString)
        try check(controller.tabErrors[tab.id]?.contains("unavailable") == true, "Disabled extension page had no recoverable error")
        // Exercise fresh diagnostic state across real unload/reload boundaries.
        // Keep each cycle's strong references inside this helper so the weak
        // observations below measure the host, not the test's own local values.
        func diagnosticCycle(_ cycle: Int) async throws -> WeakReference<WKWebExtensionContext> {
            try await host.setEnabled(true, id: extensionID)
            guard let context = host.context(for: extensionID), let action = context.action(for: nil), let popup = action.popupWebView else {
                throw ExtensionSmokeTest.Failure(description: "Diagnostic reload has no popup")
            }
            let bridge = liveRuntime.compatibility
            try check((bridge.diagnostics(for: context)["script_errors"] as? [String] ?? []).isEmpty,
                "Reload inherited errors from the preceding context")
            try await wait("Diagnostic reload popup did not initialize") {
                (try? await popup.evaluateJavaScript("document.title")) as? String == "Bam fixture ready"
            }
            _ = try await popup.callAsyncJavaScript("""
                const handler=globalThis.webkit.messageHandlers[handlerName];
                for(let i=0;i<25;i++) handler.postMessage({kind:'hello',url:location.href+'?diagnostic='+cycle+'-'+i,ready:'x'.repeat(3000)});
                for(let i=0;i<12;i++) handler.postMessage({kind:'scriptError',message:'cycle-'+cycle+'-'+i+'x'.repeat(3000),url:location.href,stack:'s'.repeat(3000)});
                return true;
                """, arguments: ["handlerName": bridge.handlerName, "cycle": cycle], contentWorld: .page)
            try await wait("Diagnostic fixture did not fill the bounded error log") {
                (bridge.diagnostics(for: context)["script_errors"] as? [String])?.count == 10
            }
            let diagnostics = bridge.diagnostics(for: context)
            let hello = diagnostics["documents"] as? [String] ?? [], errors = diagnostics["script_errors"] as? [String] ?? []
            try check(hello.count == 20 && errors.count == 10 && (hello + errors).allSatisfy { $0.unicodeScalars.count <= 1_200 },
                "Compatibility diagnostics exceeded their entry or text bounds")
            action.closePopup()
            // The final cycle also verifies shutdown while diagnostics are populated.
            if cycle == 3 { bridge.shutdown() }
            try await host.setEnabled(false, id: extensionID)
            let cleared = bridge.diagnostics(for: context)
            try check(cleared["installed"] as? Bool == false && (cleared["documents"] as? [String])?.isEmpty == true &&
                (cleared["script_errors"] as? [String])?.isEmpty == true, "Unloading or shutting down retained compatibility diagnostics")
            let (_, staleError) = await bridge.receiveNativeMessage(["kind": "scriptError", "message": "after-unload"], context: context)
            try check(staleError != nil && (bridge.diagnostics(for: context)["script_errors"] as? [String])?.isEmpty == true,
                "An unloaded context repopulated compatibility diagnostics")
            return WeakReference(context)
        }
        var retiredContexts: [WeakReference<WKWebExtensionContext>] = []
        for cycle in 1...3 { retiredContexts.append(try await diagnosticCycle(cycle)) }
        // An isolated bridge must release after removing its script handler even
        // while the content controller stays alive. Native WebKit context/cache
        // reclamation is observed separately rather than called a memory leak.
        let contentController = WKUserContentController()
        var isolatedBridge: ExtensionCompatibilityBridge? = ExtensionCompatibilityBridge(controller: liveRuntime.controller,
            dataStore: config.websiteDataStore, contentController: contentController, browserVersion: "lifecycle-test")
        let retiredBridge = WeakReference(isolatedBridge!)
        isolatedBridge?.shutdown(); isolatedBridge = nil
        try await wait("Shutdown retained the compatibility script handler") { retiredBridge.value == nil }
        let recoveryDeadline = ProcessInfo.processInfo.systemUptime + 2
        while retiredContexts.contains(where: { $0.value != nil }) && ProcessInfo.processInfo.systemUptime < recoveryDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        withExtendedLifetime(contentController) {}
        recordLifecycle("after-3-disable-reenable-cycles", retiredPopovers: retiredPopovers.filter { $0.value != nil }.count,
            retiredWebViews: retiredWebViews.filter { $0.value != nil }.count, retiredContexts: retiredContexts.filter { $0.value != nil }.count)
        // Independent fixtures both run, so a failure in one does not hide the other. Any failure still fails the suite.
        var compatibilityFailures: [String] = []
        do {
            let passed = try await ExtensionTabMetadataSmokeTest.run(controller: controller, host: host, pageURL: pageURL)
            checks += passed
            print("BAM_TAB_METADATA_PASS \(passed) checks"); fflush(stdout)
        } catch {
            compatibilityFailures.append("Tab metadata: \(error)")
            print("BAM_TAB_METADATA_FAIL \(error)"); fflush(stdout)
        }
        do {
            let passed = try await ExtensionSiteAccessSmokeTest.run(pageURL: pageURL)
            checks += passed
            print("BAM_SITE_ACCESS_PASS \(passed) checks"); fflush(stdout)
        } catch {
            compatibilityFailures.append("Site access: \(error)")
            print("BAM_SITE_ACCESS_FAIL \(error)"); fflush(stdout)
        }
        if !compatibilityFailures.isEmpty {
            throw ExtensionSmokeTest.Failure(description: compatibilityFailures.joined(separator: "\n"))
        }
        return checks
    }
}
