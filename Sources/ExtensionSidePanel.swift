import Foundation

/// Side panel state for one profile's extensions, following Chrome's sidePanel reference
/// (options, open/close for global and tab-specific panels, action-click behavior). Phase 1:
/// a pure model with tests. Nothing here is exposed to extensions or drawn; the host will supply
/// window membership and the user-gesture verdict. Decisions where Chrome's reference is silent
/// are recorded in work/sidepanel-phase1-plan.md and repeated beside the code below.
struct ExtensionSidePanelModel {
    struct Options: Equatable { var enabled: Bool?; var path: String? }
    struct Effective: Equatable { let enabled: Bool; let path: String? }
    enum Scope: Hashable { case global(window: Int), tab(Int) }
    struct Visible: Equatable { let extensionID: String; let scope: Scope; let path: String }
    struct Change: Equatable {
        enum Kind: Equatable { case opened, closed, pathChanged }
        let kind: Kind; let extensionID: String; let path: String; let windowId: Int; let tabId: Int?
    }
    struct Instance: Equatable { let scope: Scope; let path: String; let windowId: Int; let tabId: Int? }
    enum Failure: Error, Equatable, CustomStringConvertible {
        case needsTarget, needsGesture, unknownExtension, unknownTab(Int), tabNotInWindow, noGlobalPanel, disabled, invalidPath, closeGlobalWithTabId(Int), ambiguousClose
        var description: String {
            switch self {
            case .needsTarget: return "At least one of tabId or windowId must be provided."
            case .needsGesture: return "sidePanel.open() may only be called in response to a user gesture."
            case .unknownExtension: return "This extension has no side panel."
            case .unknownTab(let id): return "No tab with id: \(id)."
            case .tabNotInWindow: return "The tab is not in the given window."
            case .noGlobalPanel: return "The extension has no global side panel to open in this window."
            case .disabled: return "The side panel is disabled for this tab."
            case .invalidPath: return "The side panel path must be a page inside the extension."
            case .closeGlobalWithTabId(let id): return "No tab-specific side panel is open in tab \(id)."
            case .ambiguousClose: return "Closing with both tabId and windowId is not supported until its behavior is verified; pass one of them."
            }
        }
    }

    private var defaults: [String: Options] = [:]
    private var tabOptions: [String: [Int: Options]] = [:]
    private var behaviors: [String: Bool] = [:]
    /// One global panel per window and one tab-specific panel per tab (opening overrides).
    private(set) var globalOpen: [Int: String] = [:]
    private(set) var tabOpen: [Int: String] = [:]
    private var tabOpenWindow: [Int: Int] = [:]

    // MARK: Registration

    mutating func register(extensionID: String, defaultPath: String?) {
        defaults[extensionID] = Options(enabled: nil, path: defaultPath.flatMap(Self.validPath))
    }
    /// Revocation, disable, update, uninstall or profile shutdown: everything for the extension closes.
    mutating func unregister(extensionID: String) -> [Change] {
        var changes: [Change] = []
        for (window, owner) in globalOpen.sorted(by: { $0.key < $1.key }) where owner == extensionID {
            globalOpen.removeValue(forKey: window)
            changes.append(Change(kind: .closed, extensionID: extensionID, path: defaultPath(extensionID) ?? "", windowId: window, tabId: nil))
        }
        for (tab, owner) in tabOpen.sorted(by: { $0.key < $1.key }) where owner == extensionID { changes.append(closeTabPanel(tab)) }
        defaults.removeValue(forKey: extensionID); tabOptions.removeValue(forKey: extensionID); behaviors.removeValue(forKey: extensionID)
        return changes
    }

    // MARK: Options and behavior

    /// Upsert of the provided fields: without a tab they set the defaults, with a tab only that tab.
    mutating func setOptions(extensionID: String, tabId: Int?, enabled: Bool?, path: String?) throws -> [Change] {
        guard defaults[extensionID] != nil else { throw Failure.unknownExtension }
        var validated: String?
        if let path { guard let valid = Self.validPath(path) else { throw Failure.invalidPath }; validated = valid }
        var changes: [Change] = []
        if let tabId {
            var options = tabOptions[extensionID]?[tabId] ?? Options()
            let previousPath = options.path
            if let enabled { options.enabled = enabled }
            if let validated { options.path = validated }
            tabOptions[extensionID, default: [:]][tabId] = options
            // Disabling a tab only hides its panel there (Chrome: it shows again where it is open);
            // the open tab-specific panel is kept, so re-enabling shows it again.
            if tabOpen[tabId] == extensionID {
                if let validated, validated != previousPath, let window = tabOpenWindow[tabId] {
                    changes.append(Change(kind: .pathChanged, extensionID: extensionID, path: validated, windowId: window, tabId: tabId))
                }
            }
        } else {
            let previousPath = defaults[extensionID]?.path
            if let enabled { defaults[extensionID]?.enabled = enabled }
            if let validated { defaults[extensionID]?.path = validated }
            if let validated, validated != previousPath {
                for (window, owner) in globalOpen.sorted(by: { $0.key < $1.key }) where owner == extensionID {
                    changes.append(Change(kind: .pathChanged, extensionID: extensionID, path: validated, windowId: window, tabId: nil))
                }
            }
        }
        return changes
    }

    /// getOptions: the tab's own options merged over the defaults, or the defaults without a tab.
    func options(extensionID: String, tabId: Int?) -> Effective {
        let base = defaults[extensionID] ?? Options()
        let own = tabId.flatMap { tabOptions[extensionID]?[$0] } ?? Options()
        return Effective(enabled: own.enabled ?? base.enabled ?? true, path: own.path ?? base.path)
    }
    mutating func setBehavior(extensionID: String, openPanelOnActionClick: Bool?) {
        if let openPanelOnActionClick { behaviors[extensionID] = openPanelOnActionClick }
    }
    func behavior(extensionID: String) -> Bool { behaviors[extensionID] ?? false }

    // MARK: Open and close

    mutating func open(extensionID: String, tabId: Int?, windowId: Int?, windowOfTab: (Int) -> Int?, hasGesture: Bool) throws -> [Change] {
        guard tabId != nil || windowId != nil else { throw Failure.needsTarget }
        guard hasGesture else { throw Failure.needsGesture }
        guard defaults[extensionID] != nil else { throw Failure.unknownExtension }
        var changes: [Change] = []
        if let tabId {
            guard let window = windowOfTab(tabId) else { throw Failure.unknownTab(tabId) }
            // Decision: with both IDs, the tab must be in that window; the tab rule then applies.
            if let windowId, windowId != window { throw Failure.tabNotInWindow }
            let effective = options(extensionID: extensionID, tabId: tabId)
            guard effective.enabled else { throw Failure.disabled }
            if let ownPath = tabOptions[extensionID]?[tabId]?.path {
                // Tab-specific panel: only for that tab, overriding whatever is active there.
                if tabOpen[tabId] == extensionID { return [] }
                if tabOpen[tabId] != nil { changes.append(closeTabPanel(tabId)) }
                tabOpen[tabId] = extensionID; tabOpenWindow[tabId] = window
                changes.append(Change(kind: .opened, extensionID: extensionID, path: ownPath, windowId: window, tabId: tabId))
            } else {
                guard let path = defaultPath(extensionID) else { throw Failure.noGlobalPanel }
                // The global panel opens in this tab and in other tabs without an open tab-specific
                // panel; it overrides another extension's panel active in this tab.
                if let other = tabOpen[tabId], other != extensionID { changes.append(closeTabPanel(tabId)) }
                changes += openGlobal(extensionID, path: path, window: window)
            }
        } else if let windowId {
            guard let path = defaultPath(extensionID), defaults[extensionID]?.enabled != false else { throw Failure.noGlobalPanel }
            changes += openGlobal(extensionID, path: path, window: windowId)
        }
        return changes
    }

    mutating func close(extensionID: String, tabId: Int?, windowId: Int?, windowOfTab: (Int) -> Int?) throws -> [Change] {
        guard tabId != nil || windowId != nil else { throw Failure.needsTarget }
        // Chrome's reference does not define close() with both IDs; refuse rather than guess.
        guard tabId == nil || windowId == nil else { throw Failure.ambiguousClose }
        var changes: [Change] = []
        if let tabId {
            if tabOpen[tabId] == extensionID { changes.append(closeTabPanel(tabId)) }
            else if let window = windowOfTab(tabId), globalOpen[window] == extensionID {
                // Chrome 145+: closing by tab when only the global panel is open rejects.
                throw Failure.closeGlobalWithTabId(tabId)
            }
        }
        // Closing nothing is a no-op.
        if let windowId, globalOpen[windowId] == extensionID {
            globalOpen.removeValue(forKey: windowId)
            changes.append(Change(kind: .closed, extensionID: extensionID, path: defaultPath(extensionID) ?? "", windowId: windowId, tabId: nil))
        }
        return changes
    }

    /// openPanelOnActionClick: the action click toggles the extension's panel instead of the popup.
    mutating func actionClicked(extensionID: String, tabId: Int, windowId: Int, windowOfTab: (Int) -> Int?) -> (handled: Bool, changes: [Change]) {
        guard behavior(extensionID: extensionID) else { return (false, []) }
        if let shown = visible(windowId: windowId, activeTabId: tabId), shown.extensionID == extensionID {
            switch shown.scope {
            case .tab(let tab): return (true, [closeTabPanel(tab)])
            case .global(let window):
                globalOpen.removeValue(forKey: window)
                return (true, [Change(kind: .closed, extensionID: extensionID, path: shown.path, windowId: window, tabId: nil)])
            }
        }
        let changes = (try? open(extensionID: extensionID, tabId: tabId, windowId: nil, windowOfTab: windowOfTab, hasGesture: true)) ?? []
        return (true, changes)
    }

    /// A closed tab loses its options and its open tab-specific panel.
    mutating func tabClosed(_ tabId: Int) -> [Change] {
        var changes: [Change] = []
        if tabOpen[tabId] != nil { changes.append(closeTabPanel(tabId)) }
        for key in Array(tabOptions.keys) { tabOptions[key]?.removeValue(forKey: tabId) }
        return changes
    }

    // MARK: What the host shows

    /// The panel a window shows for its active tab: an open, enabled tab-specific panel there,
    /// else the window's open global panel if enabled in that tab and the tab has no own path.
    func visible(windowId: Int, activeTabId: Int?) -> Visible? {
        if let tab = activeTabId, let owner = tabOpen[tab], options(extensionID: owner, tabId: tab).enabled,
           let path = tabOptions[owner]?[tab]?.path {
            return Visible(extensionID: owner, scope: .tab(tab), path: path)
        }
        guard let owner = globalOpen[windowId], let path = defaultPath(owner) else { return nil }
        if let tab = activeTabId {
            guard options(extensionID: owner, tabId: tab).enabled, tabOptions[owner]?[tab]?.path == nil else { return nil }
        }
        return Visible(extensionID: owner, scope: .global(window: windowId), path: path)
    }
    /// Open panels of one extension (the basis for runtime.getContexts SIDE_PANEL later).
    func openInstances(extensionID: String) -> [Instance] {
        var result: [Instance] = []
        for (window, owner) in globalOpen.sorted(by: { $0.key < $1.key }) where owner == extensionID {
            result.append(Instance(scope: .global(window: window), path: defaultPath(extensionID) ?? "", windowId: window, tabId: nil))
        }
        for (tab, owner) in tabOpen.sorted(by: { $0.key < $1.key }) where owner == extensionID {
            result.append(Instance(scope: .tab(tab), path: tabOptions[extensionID]?[tab]?.path ?? "", windowId: tabOpenWindow[tab] ?? -1, tabId: tab))
        }
        return result
    }

    // MARK: Helpers

    private func defaultPath(_ extensionID: String) -> String? { defaults[extensionID]?.path }
    private mutating func openGlobal(_ extensionID: String, path: String, window: Int) -> [Change] {
        guard globalOpen[window] != extensionID else { return [] }
        var changes: [Change] = []
        if let other = globalOpen[window], let otherPath = defaultPath(other) {
            changes.append(Change(kind: .closed, extensionID: other, path: otherPath, windowId: window, tabId: nil))
        }
        globalOpen[window] = extensionID
        changes.append(Change(kind: .opened, extensionID: extensionID, path: path, windowId: window, tabId: nil))
        return changes
    }
    private mutating func closeTabPanel(_ tab: Int) -> Change {
        let owner = tabOpen.removeValue(forKey: tab) ?? ""
        let window = tabOpenWindow.removeValue(forKey: tab) ?? -1
        return Change(kind: .closed, extensionID: owner, path: tabOptions[owner]?[tab]?.path ?? "", windowId: window, tabId: tab)
    }
    /// A local page of the extension: relative, no scheme, no network-path or parent references.
    static func validPath(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("/") && !path.hasPrefix("//") { path.removeFirst() }
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("://"), !path.contains("\\"),
              !path.components(separatedBy: "?")[0].split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty }) else { return nil }
        return path
    }
}
