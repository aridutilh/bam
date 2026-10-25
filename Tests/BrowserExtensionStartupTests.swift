import Foundation
import WebKit

/// Exercise persistent controller construction in a standalone test process.
/// No app session, persistent website store, web view or extension is loaded.
@main @MainActor enum BrowserExtensionStartupTests {
    struct Failure: Error { let message: String }
    static func main() throws {
        guard #available(macOS 15.4, *) else { print("SKIP: Extension startup requires macOS 15.4"); return }
        try run()
    }
    @available(macOS 15.4, *)
    static func run() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(message: message) }; checks += 1
        }
        // WebKit namespaces extension storage by process identity. Never run
        // this persistent-configuration fixture inside the production app.
        try check(Bundle.main.bundleIdentifier != "com.ari.orbitprototype" &&
                  ProcessInfo.processInfo.processName == "extension-startup-tests",
                  "Persistent startup tests must use their standalone test process")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bam-extension-startup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = BrowserExtensions(storageURL: root.appendingPathComponent("Extensions"), isPrivate: false)
        let privateHost = BrowserExtensions(storageURL: nil, isPrivate: true)
        defer { host.shutdown(); privateHost.shutdown() }
        let defaultID = BrowserProfile.defaultID, namedID = UUID()
        try check(defaultID.uuidString == "00000000-0000-0000-0000-000000000001",
                  "The legacy Default profile identity must stay unchanged")
        var controllers: [UUID: WKWebExtensionController] = [:]
        for profile in [defaultID, namedID] {
            let websiteStore = WKWebsiteDataStore.nonPersistent()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = websiteStore
            // This is the production path that crashed before normal launch
            // reached its first page, even with no installed extensions.
            host.configure(configuration, profileID: profile)
            guard let controller = configuration.webExtensionController,
                  let runtime = controller.delegate as? BrowserExtensionRuntime else {
                throw Failure(message: "Persistent profile failed to construct its extension runtime")
            }
            controllers[profile] = controller
            let actual = controller.configuration
            try check(actual.isPersistent && actual.identifier == (profile == defaultID ? nil : profile),
                      "Default must use default persistent configuration; named profiles must retain their identifier")
            try check(runtime.profileID == profile && runtime.contexts.isEmpty && host.records.isEmpty,
                      "Persistent setup changed profile identity or loaded extensions")
            try check(actual.defaultWebsiteDataStore === websiteStore && runtime.dataStore === websiteStore &&
                      configuration.websiteDataStore === websiteStore && !websiteStore.isPersistent,
                      "Controller setup replaced the disposable website store")
            let again = WKWebViewConfiguration()
            again.websiteDataStore = .nonPersistent()
            host.configure(again, profileID: profile)
            try check(again.webExtensionController === controller && again.websiteDataStore === websiteStore,
                      "Repeated profile configuration must reuse its controller and website store")

            let privateConfiguration = WKWebViewConfiguration()
            privateConfiguration.websiteDataStore = .nonPersistent()
            privateHost.configure(privateConfiguration, profileID: profile)
            guard let privateController = privateConfiguration.webExtensionController else {
                throw Failure(message: "Private profile failed to construct its extension controller")
            }
            try check(!privateController.configuration.isPersistent && privateController.configuration.identifier == nil &&
                      privateController !== controller,
                      "Private Default and named profiles must remain nonpersistent and separate")
        }
        try check(controllers[defaultID] !== controllers[namedID], "Default and named profiles must not share a controller")
        // Controller storage policy: the default keeps existing behavior; the opt-in non-persistent
        // policy gives a non-private host non-persistent controllers without granting private data.
        try check(!BrowserExtensions.usesNonPersistentController(isPrivate: false, storage: .automatic) &&
                  BrowserExtensions.usesNonPersistentController(isPrivate: true, storage: .automatic) &&
                  BrowserExtensions.usesNonPersistentController(isPrivate: false, storage: .nonPersistent) &&
                  BrowserExtensions.usesNonPersistentController(isPrivate: true, storage: .nonPersistent),
                  "Controller storage policy decisions changed")
        try check(host.controllerStorage == .automatic && privateHost.controllerStorage == .automatic, "The default controller storage policy changed")
        let probeRoot = root.appendingPathComponent("NormalProbeExtensions")
        let normalProbe = BrowserExtensions(storageURL: probeRoot, isPrivate: false, controllerStorage: .nonPersistent)
        defer { normalProbe.shutdown() }
        let probeProfile = UUID()
        let probeConfiguration = WKWebViewConfiguration(); probeConfiguration.websiteDataStore = .nonPersistent()
        normalProbe.configure(probeConfiguration, profileID: probeProfile)
        guard let probeController = probeConfiguration.webExtensionController else { throw Failure(message: "The opt-in host did not configure a controller") }
        try check(!probeController.configuration.isPersistent && !normalProbe.isPrivate && normalProbe.storageURL == probeRoot,
                  "The opt-in policy did not give a non-private host a non-persistent controller with its own registry")
        print("PASS: Extension startup — \(checks)")
    }
}
