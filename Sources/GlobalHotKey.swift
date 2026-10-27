import AppKit
import Carbon.HIToolbox

/// ⌥⌘N from any app (Settings › Links). A Carbon hot key, registered only while the setting is on.
/// Another app (Arc, Yab…) may already own the chord; then registration fails and Settings says so.
@MainActor final class GlobalLittleBamHotKey {
    static let shared = GlobalLittleBamHotKey()
    enum Status: Equatable {
        case off
        case active
        /// Registration failed; the OSStatus explains why (usually another app holds ⌥⌘N).
        case unavailable(OSStatus)
    }
    private(set) var status: Status = .off
    var onPress: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    static let signature: OSType = 0x42414D4E // 'BAMN'

    /// Registers or releases the key to match the preference. Safe to call often.
    @discardableResult func update(enabled: Bool = LinkBehavior.isOn(.globalLittleBamKey)) -> Status {
        if !enabled { release(); status = .off; return status }
        if hotKey != nil { return status }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
        if result == noErr, let ref { hotKey = ref; status = .active } else { status = .unavailable(result) }
        return status
    }
    private func release() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == GlobalLittleBamHotKey.signature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalLittleBamHotKey.shared.onPress?() } }
            return noErr
        }, 1, &spec, nil, &handler)
    }
    /// macOS gives a shared hot key to every app that registered it, so another browser that also
    /// answers ⌥⌘N opens its own window at the same time. Names the ones running now.
    var sharedWith: [String] {
        guard status == .active else { return [] }
        let known = ["company.thebrowser.Browser": "Arc", "Arc": "Arc", "Yab": "Yab"]
        return Array(Set(NSWorkspace.shared.runningApplications.compactMap { app in
            known[app.bundleIdentifier ?? ""] ?? known[app.localizedName ?? ""]
        })).sorted()
    }
    /// For Settings: a sentence when the key couldn't be taken.
    var problem: String? {
        guard case .unavailable(let code) = status else { return nil }
        return code == OSStatus(eventHotKeyExistsErr)
            ? "Another app already uses ⌥⌘N (Arc and some launchers take it). Quit it or change its key, then try again."
            : "macOS didn’t give Bam ⌥⌘N (error \(code)). Try again."
    }
}
