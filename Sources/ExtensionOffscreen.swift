import Foundation

/// `chrome.offscreen`: at most one hidden document per loaded extension context.
/// This type owns only the rules and lifecycle; the host supplies how a document
/// is loaded and discarded (a hidden extension web view in the app).
@MainActor final class ExtensionOffscreenDocuments<Document: AnyObject> {
    struct Failure: Error, Equatable, CustomStringConvertible { let description: String }
    struct Entry: Equatable { let url: URL; let id: UUID; let isLoaded: Bool }
    /// Chrome's reasons; an unknown reason is rejected rather than ignored.
    static var reasons: [String] {
        ["TESTING", "AUDIO_PLAYBACK", "IFRAME_SCRIPTING", "DOM_SCRAPING", "BLOBS", "DOM_PARSER", "USER_MEDIA", "DISPLAY_MEDIA",
         "WEB_RTC", "CLIPBOARD", "LOCAL_STORAGE", "WORKERS", "BATTERY_STATUS", "MATCH_MEDIA", "GEOLOCATION"]
    }
    // Chrome's messages. Bitwarden recognizes the first one exactly and treats it as success.
    static var alreadyExists: String { "Only a single offscreen document may be created." }
    static var noDocument: String { "No current offscreen document." }
    static var closedWhileLoading: String { "The offscreen document was closed before it finished loading." }

    private enum Slot { case loading(URL, UUID), open(Document, URL, UUID) }
    private var slots: [String: Slot] = [:]
    private let load: @MainActor (String, URL) async throws -> Document
    private let discard: @MainActor (Document) -> Void

    init(load: @escaping @MainActor (String, URL) async throws -> Document, discard: @escaping @MainActor (Document) -> Void) {
        self.load = load; self.discard = discard
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
        case .loading(let url, let id): return Entry(url: url, id: id, isLoaded: false)
        case .open(_, let url, let id): return Entry(url: url, id: id, isLoaded: true)
        case nil: return nil
        }
    }
    /// True from the start of creation, as in Chrome, so a second create cannot race the first.
    func has(_ owner: String) -> Bool { slots[owner] != nil }
    func document(for owner: String) -> Document? { if case .open(let document, _, _) = slots[owner] { return document }; return nil }

    /// Resolves once the document has loaded, so messages sent afterwards reach its listeners.
    func create(owner: String, url: URL) async throws {
        guard slots[owner] == nil else { throw Failure(description: Self.alreadyExists) }
        let id = UUID()
        slots[owner] = .loading(url, id)
        let document: Document
        do { document = try await load(owner, url) } catch {
            if case .loading(_, let current) = slots[owner], current == id { slots.removeValue(forKey: owner) }
            throw error
        }
        guard case .loading(_, let current) = slots[owner], current == id else {
            discard(document); throw Failure(description: Self.closedWhileLoading)
        }
        slots[owner] = .open(document, url, id)
    }

    func close(owner: String) throws {
        guard let slot = slots.removeValue(forKey: owner) else { throw Failure(description: Self.noDocument) }
        if case .open(let document, _, _) = slot { discard(document) }
    }
    /// Unload, disable, update, revocation and profile shutdown: never an error.
    func discard(owner: String) { try? close(owner: owner) }
    func discardAll() { for owner in Array(slots.keys) { discard(owner: owner) } }
    /// The host lost the document itself (its web content process ended).
    func documentEnded(_ document: Document, owner: String) {
        if case .open(let current, _, _) = slots[owner], current === document { slots.removeValue(forKey: owner); discard(document) }
    }
}
