import Foundation

/// `chrome.offscreen`: at most one hidden document per loaded extension context.
/// This type owns only the rules and lifecycle; the host supplies how a document
/// is loaded and discarded (a hidden extension web view in the app).
@MainActor final class ExtensionOffscreenDocuments<Document: AnyObject> {
    struct Failure: Error, Equatable, CustomStringConvertible { let description: String }
    struct Entry: Equatable { let url: URL; let id: UUID; let isLoaded: Bool }
    /// Chrome's reasons; an unknown reason is rejected rather than ignored. Bam validates
    /// reasons but does not enforce reason-specific lifetimes (such as AUDIO_PLAYBACK's
    /// 30-second close without audio) or privileges.
    static var reasons: [String] {
        ["TESTING", "AUDIO_PLAYBACK", "IFRAME_SCRIPTING", "DOM_SCRAPING", "BLOBS", "DOM_PARSER", "USER_MEDIA", "DISPLAY_MEDIA",
         "WEB_RTC", "CLIPBOARD", "LOCAL_STORAGE", "WORKERS", "BATTERY_STATUS", "MATCH_MEDIA", "GEOLOCATION"]
    }
    // Chrome's messages. Bitwarden recognizes the first one exactly and treats it as success.
    static var alreadyExists: String { "Only a single offscreen document may be created." }
    static var noDocument: String { "No current offscreen document." }
    static var closedWhileLoading: String { "The offscreen document was closed before it finished loading." }

    private enum Slot { case loading(Document, URL, UUID), open(Document, URL, UUID) }
    private var slots: [String: Slot] = [:]
    private let start: @MainActor (String, URL) throws -> (Document, @MainActor () async throws -> Void)
    private let discard: @MainActor (Document) -> Void

    /// `start` creates the document and begins loading it, returning a wait that must not
    /// retain the document. `discard` must stop the document and end that wait promptly,
    /// whether it is loading or loaded: close and revocation never wait for a stalled load.
    init(start: @escaping @MainActor (String, URL) throws -> (Document, @MainActor () async throws -> Void),
         discard: @escaping @MainActor (Document) -> Void) {
        self.start = start; self.discard = discard
    }

    /// Validates Chrome's parameters against the owning extension's base URL.
    static func validate(url: String, reasons: [String], justification: String, baseURL: URL) throws -> URL {
        guard !reasons.isEmpty else { throw Failure(description: "At least one offscreen reason is required.") }
        if let unknown = reasons.first(where: { !Self.reasons.contains($0) }) { throw Failure(description: "Unknown offscreen reason: \(unknown).") }
        guard !justification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure(description: "An offscreen justification is required.") }
        guard let resolved = URL(string: url, relativeTo: baseURL)?.absoluteURL, resolved.scheme == baseURL.scheme, resolved.host == baseURL.host,
              resolved.port == baseURL.port, resolved.user == nil, resolved.password == nil else {
            throw Failure(description: "Offscreen documents must be pages of this extension.")
        }
        return resolved
    }

    func entry(for owner: String) -> Entry? {
        switch slots[owner] {
        case .loading(_, let url, let id): return Entry(url: url, id: id, isLoaded: false)
        case .open(_, let url, let id): return Entry(url: url, id: id, isLoaded: true)
        case nil: return nil
        }
    }
    /// True from the start of creation, as in Chrome, so a second create cannot race the first.
    func has(_ owner: String) -> Bool { slots[owner] != nil }
    func document(for owner: String) -> Document? { if case .open(let document, _, _) = slots[owner] { return document }; return nil }
    /// The live document, loading or loaded.
    func currentDocument(for owner: String) -> Document? {
        switch slots[owner] { case .loading(let document, _, _), .open(let document, _, _): return document; case nil: return nil }
    }

    /// Resolves once the document has loaded, so messages sent afterwards reach its listeners.
    /// Each creation is a generation: a late outcome never touches a replacement document.
    func create(owner: String, url: URL) async throws {
        guard slots[owner] == nil else { throw Failure(description: Self.alreadyExists) }
        let id = UUID()
        let wait: @MainActor () async throws -> Void
        do {
            // Only the slot holds the document while it loads.
            let (document, loaded) = try start(owner, url)
            slots[owner] = .loading(document, url, id)
            wait = loaded
        }
        var failure: Error?
        do { try await wait() } catch { failure = error }
        guard case .loading(let document, _, let current) = slots[owner], current == id else {
            // Closed, revoked or replaced meanwhile; that path already discarded this generation.
            throw Failure(description: Self.closedWhileLoading)
        }
        if let failure { slots.removeValue(forKey: owner); discard(document); throw failure }
        slots[owner] = .open(document, url, id)
    }

    func close(owner: String) throws {
        guard let slot = slots.removeValue(forKey: owner) else { throw Failure(description: Self.noDocument) }
        switch slot { case .loading(let document, _, _), .open(let document, _, _): discard(document) }
    }
    /// Unload, disable, update, revocation and profile shutdown: never an error.
    func discard(owner: String) { try? close(owner: owner) }
    func discardAll() { for owner in Array(slots.keys) { discard(owner: owner) } }
    /// The host lost the document itself (its web content process ended).
    func documentEnded(_ document: Document, owner: String) {
        if currentDocument(for: owner) === document { discard(owner: owner) }
    }
}
