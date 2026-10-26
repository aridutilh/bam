import Foundation

/// Pure rules for the iframe keyboard-focus A/B fixture (`--extension-test --extension-focus-probe`): the case, record shape
/// and the evidence contract. Foundation only, so every rule is testable without an app.
/// A negative focus result is a valid measurement; missing required evidence is not.
enum ExtensionFocusProbeRules {
    /// Child frame origin relative to the loopback parent page.
    enum Frame: String, CaseIterable { case so, xo, ex }
    /// How focus is attempted after the parent's trusted trigger key; `c` is the pointer-click positive control.
    enum Pattern: String, CaseIterable { case p1, p2, p3, p4, c }
    struct Case: Equatable {
        let frame: Frame, pattern: Pattern
        var label: String { "\(frame.rawValue):\(pattern.rawValue)" }
        /// The child focuses its own input from a 17 ms timer after "show" (P1 HUD pattern; also P3, P4 after parent focus).
        var childTimerFocus: Bool { [.p1, .p3, .p4].contains(pattern) }
    }
    /// `BAM_FOCUS_CASE`, e.g. `xo:p1` or `ex:c`. Required; anything else is refused.
    static func parseCase(_ raw: String?) -> Case? {
        let parts = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased().split(separator: ":").map(String.init)
        guard parts.count == 2, let frame = Frame(rawValue: parts[0]), let pattern = Pattern(rawValue: parts[1]) else { return nil }
        return Case(frame: frame, pattern: pattern)
    }

    /// Where the fixture page is hosted, from `BAM_FOCUS_HOST`: `bam` (default) is a real Bam window and tab
    /// (BrowserController); `plain` is a bare WKWebView in its own window with no BrowserController, sidebar, overlays or Bam
    /// navigation/UI delegates, but the same owned transient extension host, controller and non-persistent data store.
    enum Host: String, CaseIterable { case bam, plain }
    /// Absent → `bam` (the reviewed default); `bam` or `plain`; anything else is refused (nil).
    static func parseHost(_ raw: String?) -> Host? {
        guard let raw else { return .bam }
        return Host(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Vimium-like structural factors (original code only), from `BAM_FOCUS_STRUCTURE`.
    /// Not Comparable on purpose: a module-level `<` overload slows type-checking of unrelated expressions.
    enum Factor: String, CaseIterable {
        /// The iframe is created on the trigger (not preloaded); show waits for load and the handshake.
        case lazy
        /// The iframe starts under a stylesheet `iframe{display:none}`, gets class CSS shortly after, and is shown by class
        /// toggle right after "show" is posted (Vimium's UIComponent order).
        case hidden
        /// The iframe and its stylesheet sit in an open shadow root on a wrapper appended to `document.documentElement`.
        case shadow
        /// A MessageChannel port is transferred with the hello; show and all later child records travel on the port.
        case channel
        /// The child's focus target is a `contenteditable="plaintext-only"` span instead of an input.
        case editable
        /// `allow="clipboard-read; clipboard-write"` on the iframe.
        case allow
        /// The parent's trigger handler calls preventDefault/stopImmediatePropagation and suppresses later parent keydowns
        /// until the child reports focus (Vimium FindMode's suppressAllKeyboardEvents).
        case suppress
    }
    /// Factors in canonical (alphabetical) order.
    static func sortedFactors(_ factors: Set<Factor>) -> [Factor] { factors.sorted { $0.rawValue < $1.rawValue } }
    /// Absent/`none` → no structure (the reviewed baseline); `vimium` → every factor; `vimium-minus-<factor>` → all but one;
    /// otherwise a comma list of factors. Unknown or repeated factors are refused (nil).
    static func parseStructure(_ raw: String?) -> Set<Factor>? {
        let value = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if value.isEmpty || value == "none" { return [] }
        if value == "vimium" { return Set(Factor.allCases) }
        if value.hasPrefix("vimium-minus-") {
            guard let removed = Factor(rawValue: String(value.dropFirst("vimium-minus-".count))) else { return nil }
            return Set(Factor.allCases).subtracting([removed])
        }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let factors = parts.compactMap(Factor.init(rawValue:))
        guard factors.count == parts.count, Set(factors).count == factors.count else { return nil }
        return Set(factors)
    }
    /// Factors that need the trigger (lazy creates the child on it, hidden shows it on it, suppress acts on it) are refused
    /// with the pointer control, which has no trigger; otherwise nil.
    static func combinationRefusal(_ probeCase: Case, _ structure: Set<Factor>) -> String? {
        guard probeCase.pattern == .c else { return nil }
        let needsTrigger = structure.intersection([.lazy, .hidden, .suppress])
        guard !needsTrigger.isEmpty else { return nil }
        return "the pointer control (c) has no trigger, so \(structureLabel(needsTrigger)) can't apply; use those factors with p1–p4"
    }
    /// Evidence that each requested factor actually took effect, so a setup or CSS failure is incomplete rather than a
    /// mislabeled keyboard-focus result. `showSent` is nil for the pointer control.
    /// The reviewed baseline (no structure) keeps its own contract unchanged; within a structured run, factors that were
    /// not requested must be visibly absent too.
    static func factorProblems(_ records: [Record], structure: Set<Factor>, lazy: Bool, ready: Record, showSent: Record?, trigger: Record?) -> [String] {
        guard !structure.isEmpty else { return [] }
        var problems: [String] = []
        let created = records.first { $0.frame == "parent" && $0.kind == "frame_created" }
        if created == nil { problems.append("frame creation not recorded") }
        if lazy, created?.hostPhase != "trigger" { problems.append("lazy: the frame was not created in the trigger phase") }
        if structure.contains(.shadow), created?.bool("inShadow") != true || created?.string("wrapperParent") != "html" {
            problems.append("shadow: the frame is not in a shadow root on a documentElement wrapper")
        }
        if !structure.contains(.shadow), created?.bool("inShadow") != false { problems.append("baseline: the frame was expected outside a shadow root") }
        if structure.contains(.allow), created?.string("allow") != "clipboard-read; clipboard-write" { problems.append("allow: the iframe allow attribute is missing") }
        if structure.contains(.hidden) {
            let style = records.first { $0.frame == "parent" && $0.kind == "style_loaded" }
            if style == nil || (showSent.map { style!.seq > $0.seq } ?? false) { problems.append("hidden: the class stylesheet did not load before show") }
            if showSent?.string("displayBefore") != "none" { problems.append("hidden: the frame was not display:none before show") }
            if showSent?.string("frameDisplay") != "block" { problems.append("hidden: the frame was not display:block after show") }
        }
        if structure.contains(.channel) {
            if ready.bool("channel") != true { problems.append("channel: the child did not acknowledge over the MessageChannel port") }
            if let showSent, showSent.string("via") != "port" { problems.append("channel: show was not sent on the port") }
        }
        if structure.contains(.editable), ready.bool("targetEditable") != true { problems.append("editable: the child focus target is not contenteditable") }
        if !structure.contains(.editable), ready.bool("targetEditable") != false { problems.append("baseline: the child focus target should be an input") }
        if structure.contains(.suppress), trigger?.bool("suppressed") != true { problems.append("suppress: the trigger key was not suppressed") }
        return problems
    }

    /// Canonical text for a structure (sorted factors, or `none`), used in URLs and output.
    static func structureLabel(_ factors: Set<Factor>) -> String {
        factors.isEmpty ? "none" : sortedFactors(factors).map(\.rawValue).joined(separator: ",")
    }

    static let triggerKey = "f"
    static let typedKeys = ["b", "a", "m"]
    static let typedText = "bam"
    /// Readings after "show" in both frames (child and parent), scheduled in-page; actual offsets reported.
    static let sampleDelaysMilliseconds = [0, 20, 100, 1000]
    static let recordKinds: Set<String> = ["ready", "armed", "keydown", "trigger", "show_sent", "show", "focus_attempt", "focus_error",
                                           "sample", "window_focus", "window_blur", "input_focus", "input_blur", "input", "pointer",
                                           "hello_sent", "child_load", "frame_created", "style_loaded"]
    static let maximumRecords = 300

    /// One page record as the parent publishes it, with the native phase in which the host first saw it.
    struct Record {
        let frame: String      // "parent" or "child"
        let kind: String
        let seq: Int
        let hostPhase: String?
        let fields: [String: Any]
        var key: String { "\(frame):\(seq)" }
        func bool(_ name: String) -> Bool? { Self.strictBool(fields[name]) }
        func int(_ name: String) -> Int? { Self.strictInt(fields[name]) }
        func string(_ name: String) -> String? { fields[name] as? String }
        static func strictBool(_ value: Any?) -> Bool? {
            guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
            return value as? Bool
        }
        /// An exact integer only: booleans, fractions, non-finite and out-of-range numbers are refused (no truncation).
        static func strictInt(_ value: Any?) -> Int? {
            guard let value, let number = value as? NSNumber, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            guard double.isFinite, double.rounded() == double, abs(double) <= 9_007_199_254_740_991 else { return nil }
            return Int(double)
        }
    }

    /// Parses the parent's published state for this exact run and case. Records with a wrong run, case or role, an unknown
    /// kind, or a malformed shape are dropped and counted; nothing in them is trusted for anything but evidence.
    static func records(fromState state: [String: Any], run: String, case expected: Case, firstSeen: [String: String]) -> (records: [Record], malformed: Int) {
        guard state["run"] as? String == run, state["case"] as? String == expected.label,
              let raw = state["records"] as? [Any] else { return ([], 0) }
        var records: [Record] = [], malformed = 0, identities = Set<String>()
        malformed += max(0, raw.count - maximumRecords)
        for item in raw.prefix(maximumRecords) {
            guard let object = item as? [String: Any], let frame = object["frame"] as? String, ["parent", "child"].contains(frame),
                  let kind = object["kind"] as? String, recordKinds.contains(kind), let seq = Record.strictInt(object["seq"]), seq >= 1,
                  object["run"] as? String == run, object["case"] as? String == expected.label,
                  object["role"] as? String == (frame == "parent" ? "parent" : expected.frame.rawValue),
                  Record.strictInt(object["t"]) != nil else { malformed += 1; continue }
            // A repeated identity (frame + seq) is malformed: only the first is kept.
            guard identities.insert("\(frame):\(seq)").inserted else { malformed += 1; continue }
            records.append(Record(frame: frame, kind: kind, seq: seq, hostPhase: firstSeen["\(frame):\(seq)"], fields: object))
        }
        return (records, malformed)
    }
    /// The identities (`frame:seq`) of the valid records in a state for this run and case: the only ones the native
    /// phase ledger may stamp.
    static func validIdentities(fromState state: [String: Any], run: String, case expected: Case) -> [String] {
        records(fromState: state, run: run, case: expected, firstSeen: [:]).records.map(\.key)
    }

    /// The native phase ledger across every published snapshot: each validated identity is stamped once with the phase in
    /// which it was first seen, up to a total cap with no eviction. Faults are permanent (a later good snapshot never
    /// clears an earlier fault): capacity exceeded, a snapshot that drops an earlier record (the page only appends), a record
    /// whose identity changes content (kind/time), or a snapshot with malformed records.
    struct PhaseLedger {
        let capacity: Int
        private(set) var firstSeen: [String: String] = [:]
        private(set) var faults: [String] = []
        private var fingerprints: [String: String] = [:]
        init(capacity: Int = ExtensionFocusProbeRules.maximumRecords) { self.capacity = capacity }
        private mutating func fault(_ message: String) { if !faults.contains(message) { faults.append(message) } }
        mutating func ingest(state: [String: Any], run: String, case expected: Case, phase: String) {
            let parsed = ExtensionFocusProbeRules.records(fromState: state, run: run, case: expected, firstSeen: [:])
            if parsed.malformed > 0 { fault("a snapshot contained malformed records") }
            let keys = Set(parsed.records.map(\.key))
            if fingerprints.keys.contains(where: { !keys.contains($0) }) { fault("a snapshot dropped previously seen records") }
            for record in parsed.records {
                let fingerprint = "\(record.kind)|\(record.int("t") ?? -1)"
                if let known = fingerprints[record.key] {
                    if known != fingerprint { fault("a record identity changed between snapshots") }
                    continue
                }
                guard fingerprints.count < capacity else { fault("phase ledger capacity (\(capacity)) exceeded"); continue }
                fingerprints[record.key] = fingerprint
                firstSeen[record.key] = phase
            }
        }
    }

    /// Cleanup is clean only when the run's temporary storage and folder are gone **and**, if a fixture was installed, its
    /// removal was confirmed (no timeout, no error, no longer listed or loaded).
    static func cleanupIsClean(_ report: [String: Any], fixtureInstalled: Bool) -> Bool {
        let storage = report["host_temporary_storage_removed"]
        let storageClean = (storage as? Bool) == true || (storage as? String) == "no host was created"
        let directoryClean = report["run_directory_removed"] == nil || Record.strictBool(report["run_directory_removed"]) == true
        let removal = !fixtureInstalled || (Record.strictBool(report["fixture_removed"]) == true && report["fixture_removal_timed_out"] == nil
                                            && report["fixture_removal_error"] == nil)
        return storageClean && directoryClean && removal
    }

    struct Evaluation {
        var complete: Bool { problems.isEmpty }
        var problems: [String]
        var outcome: [String: Any]
    }

    /// The evidence contract. Required for P1–P4: the child's ready acknowledgement and the parent's armed record, before
    /// any trigger; the trusted parent trigger key received in the native `trigger` phase; show sent and shown; every scheduled
    /// reading in both frames; the child's own focus attempt for timer patterns; and the actual trusted typing (all three
    /// keys) received in the native `typing` phase, wherever it lands. Where it lands, and whether focus moved, are outcomes:
    /// a negative result is measured, not incomplete. For the pointer control (`c`): a trusted pointer on the child input in
    /// the `pointer` phase and all three typed keys in the child input, with its value containing the text; missing typing
    /// in the child is incomplete for the positive control.
    /// With `lazy`, the child doesn't exist before the trigger: the parent arms in setup, and the child's ready
    /// acknowledgement must arrive in the trigger phase (after the trigger) instead. The positive control has no trigger,
    /// so `lazy` doesn't apply to it.
    static func evaluate(_ records: [Record], case probeCase: Case, structure: Set<Factor> = []) -> Evaluation {
        var problems: [String] = []
        func first(_ frame: String, _ kind: String, phase: String? = nil, _ extra: (Record) -> Bool = { _ in true }) -> Record? {
            records.first { $0.frame == frame && $0.kind == kind && (phase == nil || $0.hostPhase == phase) && extra($0) }
        }
        let lazy = structure.contains(.lazy) && probeCase.pattern != .c
        if let refusal = combinationRefusal(probeCase, structure) { return Evaluation(problems: [refusal], outcome: [:]) }
        // Preloaded: the child's acknowledgement is reported first, as before; lazy: the parent's armed record first.
        if !lazy, first("child", "ready") == nil { return Evaluation(problems: ["child ready acknowledgement missing"], outcome: [:]) }
        guard let armed = first("parent", "armed") else { return Evaluation(problems: ["parent armed record missing"], outcome: [:]) }
        guard let ready = first("child", "ready") else { return Evaluation(problems: ["child ready acknowledgement missing"], outcome: [:]) }
        if armed.hostPhase != "setup" { problems.append("handshake not completed before READY") }
        if lazy {
            // The child is created by the trigger, so its ready acknowledgement belongs to the trigger phase.
            if ready.hostPhase != "trigger" { problems.append("lazy child ready acknowledgement not received in the trigger phase") }
        } else if ready.hostPhase != "setup" { problems.append("handshake not completed before READY") }

        var outcome: [String: Any] = ["case": probeCase.label, "structure": structureLabel(structure)]
        let typing = records.filter { $0.kind == "keydown" && $0.bool("trusted") == true && $0.hostPhase == "typing" }
        let typed = typing.compactMap { $0.string("key")?.lowercased() }.filter { Self.typedKeys.contains($0) }
        let childTyped = typing.filter { $0.frame == "child" }, parentTyped = typing.filter { $0.frame == "parent" }
        outcome["typed_keys_parent"] = parentTyped.compactMap { $0.string("key") }
        outcome["typed_keys_child"] = childTyped.compactMap { $0.string("key") }
        outcome["typed_into_child_input"] = childTyped.contains { $0.bool("targetIsInput") == true }
        let childValue = records.filter { $0.frame == "child" && $0.kind == "input" }.last?.string("value") ?? ""
        outcome["child_input_value"] = String(childValue.prefix(16))
        outcome["typing_landed"] = childTyped.isEmpty && parentTyped.isEmpty ? "none"
            : childTyped.isEmpty ? "parent" : parentTyped.isEmpty ? (outcome["typed_into_child_input"] as? Bool == true ? "child-input" : "child-other") : "split"
        if !Self.typedKeys.allSatisfy(typed.contains) {
            problems.append("trusted typing of \(typedText) not observed in the typing phase")
        }
        outcome["child_window_focus_fired"] = records.contains { $0.frame == "child" && $0.kind == "window_focus" && $0.hostPhase != "setup" }

        if probeCase.pattern == .c {
            if first("child", "pointer", phase: "pointer", { $0.bool("trusted") == true && $0.bool("onInput") == true }) == nil {
                problems.append("trusted pointer on the child input not observed in the pointer phase")
            }
            // Every typed key, trusted, on the child input, in the typing phase; and a trusted input event in the typing
            // phase whose value contains the text. Keys anywhere else, or an unphased or untrusted value, don't count.
            let childInputKeys = Set(childTyped.filter { $0.bool("targetIsInput") == true }.compactMap { $0.string("key")?.lowercased() })
            if !Self.typedKeys.allSatisfy(childInputKeys.contains) {
                problems.append("positive control: not every typed key reached the child input")
            }
            let trustedValue = records.contains { $0.frame == "child" && $0.kind == "input" && $0.hostPhase == "typing" && $0.bool("trusted") == true
                && ($0.string("value") ?? "").lowercased().contains(typedText) }
            if !trustedValue { problems.append("positive control: no trusted child input value containing \(typedText) in the typing phase") }
            problems += factorProblems(records, structure: structure, lazy: false, ready: ready, showSent: nil, trigger: nil)
            return Evaluation(problems: problems, outcome: outcome)
        }

        guard let trigger = first("parent", "trigger", phase: "trigger", { $0.bool("trusted") == true && $0.string("key") == triggerKey }) else {
            problems.append("trusted parent trigger key '\(triggerKey)' not observed in the trigger phase")
            return Evaluation(problems: problems, outcome: outcome)
        }
        outcome["parent_had_focus_at_trigger"] = trigger.bool("hasFocus") ?? NSNull()
        guard let showSent = first("parent", "show_sent", phase: "trigger", { $0.seq > trigger.seq }) else {
            problems.append("show not sent after the trigger in the trigger phase"); return Evaluation(problems: problems, outcome: outcome)
        }
        guard let shown = first("child", "show", phase: "trigger") else {
            problems.append("child show acknowledgement missing in the trigger phase"); return Evaluation(problems: problems, outcome: outcome)
        }
        // Each requested structural factor must have taken effect before any focus result counts (negative or positive).
        problems += factorProblems(records, structure: structure, lazy: lazy, ready: ready, showSent: showSent, trigger: trigger)
        for frame in ["child", "parent"] {
            let all = records.filter { $0.frame == frame && $0.kind == "sample" }
            if all.contains(where: { $0.int("after_ms").map { !sampleDelaysMilliseconds.contains($0) } ?? true }) {
                problems.append("\(frame) reading with an unscheduled or malformed offset")
            }
            for delay in sampleDelaysMilliseconds {
                let samples = all.filter { $0.int("after_ms") == delay }
                guard let sample = samples.first else { problems.append("\(frame) reading +\(delay)ms missing"); continue }
                if samples.count > 1 { problems.append("\(frame) reading +\(delay)ms duplicated"); continue }
                guard sample.int("actual_ms") != nil, sample.bool("hasFocus") != nil else { problems.append("\(frame) reading +\(delay)ms malformed"); continue }
                if sample.hostPhase != "trigger" { problems.append("\(frame) reading +\(delay)ms received outside the trigger phase") }
            }
        }
        if probeCase.childTimerFocus,
           first("child", "focus_attempt", phase: "trigger", { $0.string("trigger") == "timer-17ms" && $0.seq > shown.seq }) == nil {
            problems.append("child timer focus attempt not recorded in the trigger phase")
        }
        let childSamples = records.filter { $0.frame == "child" && $0.kind == "sample" }
        // First reading per offset only (duplicates are already reported as problems above); never traps.
        var focusedByOffset: [String: Bool] = [:]
        for sample in childSamples {
            guard let delay = sample.int("after_ms"), focusedByOffset["\(delay)"] == nil,
                  let focused = sample.bool("activeIsInput"), let has = sample.bool("hasFocus") else { continue }
            focusedByOffset["\(delay)"] = focused && has
        }
        outcome["child_input_focused_by_ms"] = focusedByOffset
        outcome["child_focus_attempt_recorded"] = first("child", "focus_attempt") != nil
        return Evaluation(problems: problems, outcome: outcome)
    }
}
