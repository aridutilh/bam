import AppKit

/// Air Traffic Control: links from other apps go where Settings › Links says.
@MainActor extension BrowserController {
    /// Every link handed to Bam by another app (or forwarded by a second launch) comes through here.
    func openExternal(_ url: URL) {
        guard URLInput.directURL(url.absoluteString) != nil else { return }
        let routing = LinkRoutePreference.routing
        switch routing.destination(for: url, spaceExists: { [session] in session.spaceDefinition($0) != nil }).destination {
        case .littleBam: openLittleOrbit(url: url)
        case .mostRecentSpace: openExternal(url, inSpace: session.space)
        case .space(let id): openExternal(url, inSpace: id)
        }
    }
    /// A routed link becomes a new tab in that Space, with the main window in front.
    func openExternal(_ url: URL, inSpace id: Int) {
        guard session.spaceDefinition(id) != nil else { openLittleOrbit(url: url); return }
        cancelPaging(); dismissAddress()
        if session.space != id { session.changeSpace(id); onSpacesChanged?() }
        _ = session.add(address: url.absoluteString)
        showActive(); save()
        view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    /// The person put a page in a Space by hand; three times for one site and Settings › Links suggests a route.
    func noteLinkMove(_ address: String?, toSpace id: Int) {
        guard let address, let url = URL(string: address) else { return }
        LinkRoutePreference.noteMove(url, toSpace: id)
    }
}
