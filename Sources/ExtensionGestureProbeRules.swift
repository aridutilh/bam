import Foundation

/// Pure rules for the extension gesture probe (`--extension-test --extension-gesture-probe`): configuration,
/// loopback scoping and the install-review decision. Foundation only, so they are testable without an app.
enum ExtensionGestureProbeRules {
    /// The real-click wait; `BAM_GESTURE_CLICK_SECONDS` can only shorten it.
    static let maximumClickSeconds: TimeInterval = 40
    static let marker = "bam-gesture-probe"

    enum ToolbarMode: String { case button, real, off }

    static func clickSeconds(_ raw: String?) -> TimeInterval {
        guard let raw, let value = TimeInterval(raw.trimmingCharacters(in: .whitespaces)), value.isFinite, value > 0 else { return maximumClickSeconds }
        return min(value, maximumClickSeconds)
    }
    /// Absent means `button`; anything unknown is refused (nil).
    static func toolbarMode(_ raw: String?) -> ToolbarMode? {
        guard let raw else { return .button }
        return ToolbarMode(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]
    static func isLoopback(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && loopbackHosts.contains(url.host?.lowercased() ?? "")
            && url.user == nil && url.password == nil
    }
    /// Content-script match patterns for exactly the fixture page's scheme and host (any port, as match patterns allow).
    static func matchPatterns(for page: URL) -> [String] {
        guard isLoopback(page), let scheme = page.scheme?.lowercased(), let host = page.host?.lowercased() else { return [] }
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return ["\(scheme)://\(bracketed)/*"]
    }
    /// The fixture page with only the probe marker as its query.
    static func probeURL(_ page: URL) -> URL? {
        guard isLoopback(page), var components = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: marker, value: "1")]
        components.fragment = nil
        return components.url
    }
    /// What one phase's page entry shows. Only a structured worker reply for this phase counts as measured.
    enum Reply: Equatable {
        /// The worker answered this phase: its badge (arrival signal) and the gesture-gated request's outcome.
        case measured(badge: String, outcome: String)
        /// The message never reached a worker reply (sendMessage rejected, or no response was delivered).
        case transportFailure(String)
        /// Something answered, but not a well-formed reply for this phase.
        case malformed(String)
    }
    static let badgeLetters = ["baseline": "B", "click": "C", "toolbar": "T"]
    /// Classifies a page entry (`{kind, response?, error?}` as the content script publishes it) for `kind`.
    /// nil while there is no answer yet.
    static func reply(_ entry: [String: Any]?, kind: String) -> Reply? {
        guard let entry else { return nil }
        if let error = entry["error"] as? String { return .transportFailure(String(error.prefix(300))) }
        guard entry.keys.contains("response") else { return nil }
        guard let response = entry["response"] as? [String: Any] else { return .transportFailure("no reply from the worker (null response)") }
        guard response["kind"] as? String == kind else { return .malformed("reply kind \(response["kind"] ?? "missing") for \(kind)") }
        guard let rawSequence = response["sequence"], CFGetTypeID(rawSequence as CFTypeRef) != CFBooleanGetTypeID(),
              let sequence = rawSequence as? Int, sequence >= 1, let letter = badgeLetters[kind],
              let badge = response["badge"] as? String, badge == "\(letter)\(sequence)" else { return .malformed("reply sequence/badge mismatch") }
        guard response["receivedAt"] is NSNumber, response["settledAt"] is NSNumber else { return .malformed("reply timing missing") }
        guard let request = response["request"] as? [String: Any], let outcome = request["outcome"] as? String else {
            return .malformed("reply without a request outcome")
        }
        switch outcome {
        case "resolved":
            guard let granted = request["granted"], CFGetTypeID(granted as CFTypeRef) == CFBooleanGetTypeID() else { return .malformed("resolved without a boolean granted") }
            return .measured(badge: badge, outcome: (granted as? Bool) == true ? "resolved granted" : "resolved not granted")
        case "rejected", "threw":
            guard let error = request["error"] as? String, !error.isEmpty else { return .malformed("\(outcome) without error text") }
            return .measured(badge: badge, outcome: outcome)
        default:
            return .malformed("unknown request outcome \(outcome)")
        }
    }
    /// A phase is measured only with a well-formed reply whose arrival badge the host actually observed.
    static func phaseVerdict(_ reply: Reply?, observedBadges: Set<String>) -> String {
        switch reply {
        case nil: return "no reply"
        case .transportFailure(let why): return "transport failure: \(why)"
        case .malformed(let why): return "malformed reply: \(why)"
        case .measured(let badge, let outcome):
            return observedBadges.contains(badge) ? "measured (\(outcome))" : "reply without an observed arrival (\(badge))"
        }
    }
    static func isMeasured(_ verdict: String?) -> Bool { verdict?.hasPrefix("measured") == true }

    // MARK: Host-world evidence (passive observer messages, as the probe logs them with host_phase / host_t_ms)

    /// A trigger a phase requires: a published worker record of a kind, or the trusted input click on the probe button.
    enum HostTrigger: Hashable {
        case record(String), trustedClick
        var label: String { switch self { case .record(let kind): return "record:\(kind)"; case .trustedClick: return "input:trusted-click" } }
    }
    /// Required triggers per phase. The armed acknowledgement is required separately (it gates READY).
    static let phaseTriggers: [String: [HostTrigger]] = ["baseline": [.record("baseline")], "page_click": [.trustedClick, .record("click")],
                                                         "toolbar": [.record("toolbar")]]
    private static func isNumber(_ value: Any?) -> Bool {
        guard let value, value is NSNumber else { return false }
        return CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID()
    }
    private static func isBool(_ value: Any?) -> Bool {
        guard let value else { return false }
        return CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }
    /// The trigger message for `trigger` received **in `phase`** (the first such). A matching event received in any other
    /// phase (for example an early trusted click during baseline) never satisfies this phase.
    static func triggerEvent(_ trigger: HostTrigger, phase: String, in events: [[String: Any]]) -> [String: Any]? {
        events.first { event in
            guard event["host_phase"] as? String == phase else { return false }
            switch trigger {
            case .record(let kind): return event["event"] as? String == "record" && event["kind"] as? String == kind
            case .trustedClick: return event["event"] as? String == "click" && event["trusted"] as? Bool == true && isBool(event["trusted"])
            }
        }
    }
    /// Problems with one required trigger in `phase`: trigger missing (in this phase) or malformed, or any scheduled
    /// reading missing, malformed, or received outside `phase`.
    static func sampleProblems(_ trigger: HostTrigger, phase: String, in events: [[String: Any]], delays: [Int]) -> [String] {
        guard let event = triggerEvent(trigger, phase: phase, in: events), let id = event["id"] as? String, !id.isEmpty else {
            return ["\(trigger.label): trigger not reported in \(phase)"]
        }
        guard isNumber(event["perf"]), isNumber(event["wall"]), isNumber(event["host_t_ms"]) else { return ["\(trigger.label): trigger timestamps malformed"] }
        let samples = events.filter { $0["event"] as? String == "activation" && $0["id"] as? String == id }
        var problems: [String] = []
        for delay in delays {
            let matching = samples.filter { ($0["scheduled_ms"] as? NSNumber)?.intValue == delay && isNumber($0["scheduled_ms"]) }
            guard !matching.isEmpty else { problems.append("\(trigger.label)+\(delay)ms missing"); continue }
            if matching.contains(where: { $0["host_phase"] as? String != phase }) {
                problems.append("\(trigger.label)+\(delay)ms received outside \(phase)"); continue
            }
            let wellFormed = matching.allSatisfy { sample in
                guard isNumber(sample["actual_ms"]), isNumber(sample["host_t_ms"]), let activation = sample["activation"] as? [String: Any] else { return false }
                return isBool(activation["isActive"]) && isBool(activation["hasBeenActive"])
            }
            if !wellFormed { problems.append("\(trigger.label)+\(delay)ms malformed") }
        }
        return problems
    }
    /// All problems for a phase's required triggers.
    static func phaseSampleProblems(_ phase: String, in events: [[String: Any]], delays: [Int]) -> [String] {
        (phaseTriggers[phase] ?? []).flatMap { sampleProblems($0, phase: phase, in: events, delays: delays) }
    }
    /// The armed acknowledgement must have arrived (it is received during baseline, before READY).
    static func armedAcknowledged(in events: [[String: Any]]) -> Bool {
        events.contains { $0["event"] as? String == "armed" && isNumber($0["perf"]) && isNumber($0["host_t_ms"]) }
    }

    /// Bam's MV3 worker preparation adds its internal `nativeMessaging` transport to the private copy; the install
    /// review lists it as unsupported, and approving the review never grants it (that transport is a separate grant).
    static let toleratedUnsupported: Set<String> = ["nativeMessaging"]
    /// The install review may only ask for the loopback content-script websites: no API permissions, nothing
    /// unsupported except Bam's own worker transport. Every optional review is refused.
    static func allowsInstall(permissions: [String], unsupported: [String], websites: [String], isOptional: Bool) -> Bool {
        guard !isOptional, permissions.isEmpty, Set(unsupported).isSubset(of: toleratedUnsupported), !websites.isEmpty else { return false }
        return websites.allSatisfy { pattern in
            guard let url = URL(string: pattern) else { return false }
            return isLoopback(url) && url.port == nil && url.path == "/*" && url.query == nil
        }
    }
}
