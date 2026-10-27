import AppKit
import WebKit

/// State for the page tools: Reading Mode, Hide Elements and Web Inspector.
@MainActor final class PageToolsCoordinator {
    let reading = ReadingModeCoordinator()
    private(set) var picker: HideElementsPicker?
    private var store: HiddenElementStore?

    /// Created on first use, once the controller knows whether this session persists.
    func hiddenElements(persists: Bool) -> HiddenElementStore {
        if let store { return store }
        let made = HiddenElementStore(persists: persists)
        store = made; reading.persists = persists
        return made
    }

    func setPicker(_ picker: HideElementsPicker?) { self.picker = picker }
}

@MainActor extension BrowserController {
    var hiddenElements: HiddenElementStore { pageTools.hiddenElements(persists: !privateMode) }

    /// Every page web view Bam shows: inspectable, and hidden-element rules from its first frame.
    func preparePageTools(_ web: WKWebView) {
        PageInspector.enable(web)
        preparePageTools(configuration: web.configuration)
    }
    /// For Peek and Little Bam, whose web views are made from this configuration.
    func preparePageTools(configuration: WKWebViewConfiguration) {
        hiddenElements.attach(configuration.userContentController)
        if pageTools.reading.onNoArticle == nil {
            pageTools.reading.onNoArticle = { [weak self] web in
                guard let self, let host = web.superview else { return }
                self.pageFeedback.show("No article on this page", symbol: "book", in: host)
            }
            pageTools.reading.onOpenLink = { web, url in web.load(URLRequest(url: url)) }
        }
    }

    // MARK: Reading Mode

    @objc func toggleReadingMode(_ sender: Any?) {
        guard let surface = pageCommandSurface else { return }
        pageTools.picker?.finish()
        let web = surface.web
        guard pageTools.reading.isReading(web) || HiddenElementStore.site(for: web.url) != nil else {
            pageFeedback.show("No article on this page", symbol: "book", in: surface.host); return
        }
        findBar.hide()
        preparePageTools(web)
        pageTools.reading.toggle(web)
    }

    var isReadingModeActive: Bool { pageCommandSurface.map { pageTools.reading.isReading($0.web) } ?? false }

    // MARK: Hide Elements

    @objc func hideElements(_ sender: Any?) {
        if let picker = pageTools.picker { picker.finish(); return }
        guard let surface = pageCommandSurface, let site = HiddenElementStore.site(for: surface.web.url),
              !pageTools.reading.isReading(surface.web) else { return }
        dismissAddress(); findBar.hide(); pageFeedback.hide()
        let store = hiddenElements
        store.attach(surface.web.configuration.userContentController)
        let picker = HideElementsPicker(web: surface.web, site: site)
        picker.onHide = { selector in store.add(selector, site: site) }
        picker.onRestore = { selector in store.remove(selector, site: site) }
        picker.onFinish = { [weak self, weak picker] in
            guard let self, self.pageTools.picker === picker else { return }
            self.pageTools.setPicker(nil)
        }
        pageTools.setPicker(picker)
        picker.begin()
    }

    /// Brings back everything hidden on this site, on this page at once.
    @objc func restoreHiddenElements(_ sender: Any?) {
        guard let surface = pageCommandSurface, let site = HiddenElementStore.site(for: surface.web.url) else { return }
        pageTools.picker?.finish()
        let count = hiddenElements.selectors(for: site).count
        guard count > 0 else { return }
        let web = surface.web, host = surface.host
        // WebKit applies content rules when a page loads, so the page reloads
        // once the site's rules are gone; that is what brings everything back.
        hiddenElements.removeAll(site: site) { [weak self, weak web] in
            guard let self, let web, HiddenElementStore.site(for: web.url) == site else { return }
            web.reload()
            self.pageFeedback.show(count == 1 ? "1 hidden element restored" : "\(count) hidden elements restored",
                                   symbol: "eye", in: host)
        }
    }

    func hiddenElementCount(for web: WKWebView) -> Int {
        HiddenElementStore.site(for: web.url).map { hiddenElements.selectors(for: $0).count } ?? 0
    }

    // MARK: Develop

    @objc func showWebInspector(_ sender: Any?) {
        guard let web = pageCommandSurface?.web else { return }
        PageInspector.show(web)
    }
    @objc func showJavaScriptConsole(_ sender: Any?) {
        guard let web = pageCommandSurface?.web else { return }
        PageInspector.showConsole(web)
    }
    @objc func inspectElement(_ sender: Any?) {
        guard let web = pageCommandSurface?.web else { return }
        PageInspector.inspectElement(web)
    }

    /// Menu state for the page tools; nil when the item is not one of them.
    func validatePageToolsItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(toggleReadingMode(_:)):
            guard let web = pageCommandSurface?.web else { item.title = "Show Reading Mode"; return false }
            let reading = pageTools.reading.isReading(web)
            item.title = reading ? "Hide Reading Mode" : "Show Reading Mode"
            return reading || HiddenElementStore.site(for: web.url) != nil
        case #selector(hideElements(_:)):
            if pageTools.picker != nil { item.state = .on; return true }
            item.state = .off
            guard let web = pageCommandSurface?.web else { return false }
            return HiddenElementStore.site(for: web.url) != nil && !pageTools.reading.isReading(web)
        case #selector(restoreHiddenElements(_:)):
            let count = pageCommandSurface.map { hiddenElementCount(for: $0.web) } ?? 0
            item.title = count > 0 ? "Restore Hidden Elements on This Site (\(count))" : "Restore Hidden Elements on This Site"
            return count > 0
        case #selector(showWebInspector(_:)), #selector(showJavaScriptConsole(_:)), #selector(inspectElement(_:)):
            return pageCommandSurface != nil && PageInspector.isAvailable
        default:
            return nil
        }
    }
}
