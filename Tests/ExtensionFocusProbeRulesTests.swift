import Foundation

/// Pure checks of the focus probe's case parsing, record binding and evidence contract.
@main enum ExtensionFocusProbeRulesTests {
    nonisolated(unsafe) static var checks = 0
    static func check(_ ok: Bool, _ message: String) {
        guard ok else { fputs("FAIL: Extension focus probe rules — \(message)\n", stderr); exit(1) }
        checks += 1
    }
    typealias R = ExtensionFocusProbeRules

    /// Builds a published state and its first-seen phase ledger the way the probe receives them.
    struct Run {
        let probeCase: R.Case
        var run: String { "RUN-1" }
        var records: [[String: Any]] = []
        var firstSeen: [String: String] = [:]
        var seqs = ["parent": 0, "child": 0]
        mutating func add(_ frame: String, _ kind: String, _ phase: String, _ fields: [String: Any] = [:]) {
            seqs[frame, default: 0] += 1
            let seq = seqs[frame]!
            var record: [String: Any] = ["frame": frame, "kind": kind, "seq": seq, "t": 100 + seq, "wall": 1_000 + seq, "run": run,
                                         "case": probeCase.label, "role": frame == "parent" ? "parent" : probeCase.frame.rawValue]
            record.merge(fields) { _, new in new }
            records.append(record)
            firstSeen["\(frame):\(seq)"] = phase
        }
        var state: [String: Any] { ["run": run, "case": probeCase.label, "records": records] }
        func evaluate() -> R.Evaluation {
            R.evaluate(R.records(fromState: state, run: run, case: probeCase, firstSeen: firstSeen).records, case: probeCase)
        }
        mutating func handshake() {
            add("child", "child_load", "setup"); add("child", "ready", "setup", ["pattern": probeCase.pattern.rawValue])
            add("parent", "armed", "setup", ["hasFocus": true])
        }
        mutating func trigger(phase: String = "trigger", trusted: Bool = true) {
            add("parent", "trigger", phase, ["key": "f", "trusted": trusted, "hasFocus": true])
            add("parent", "show_sent", phase, ["pattern": probeCase.pattern.rawValue, "focusCall": "none"])
            add("child", "show", phase, ["hasFocus": false, "activeIsInput": false])
        }
        mutating func samples(skip: (String, Int)? = nil, phase: String = "trigger", childFocused: Bool = false) {
            for frame in ["child", "parent"] {
                for delay in R.sampleDelaysMilliseconds where !(skip?.0 == frame && skip?.1 == delay) {
                    add(frame, "sample", phase, ["after_ms": delay, "actual_ms": delay + 1, "hasFocus": frame == "child" ? childFocused : true,
                                                "activeIsInput": frame == "child" ? childFocused : false])
                }
            }
        }
        mutating func type(in frame: String, input: Bool = false, value: String? = nil) {
            for key in ["b", "a", "m"] { add(frame, "keydown", "typing", ["key": key, "trusted": true, "targetIsInput": input]) }
            if let value { add("child", "input", "typing", ["value": value]) }
        }
    }

    static func main() {
        // Case parsing.
        check(R.parseCase("xo:p1") == R.Case(frame: .xo, pattern: .p1) && R.parseCase(" EX:C ") == R.Case(frame: .ex, pattern: .c), "cases parse")
        check(R.parseCase(nil) == nil && R.parseCase("xo") == nil && R.parseCase("zz:p1") == nil && R.parseCase("so:p9") == nil && R.parseCase("so:p1:x") == nil,
              "missing or unknown cases are refused")
        check(R.Case(frame: .so, pattern: .p1).childTimerFocus && !R.Case(frame: .so, pattern: .p2).childTimerFocus, "timer patterns")

        // A negative P1 outcome (focus never reaches the child; typing lands in the parent) is a complete measurement.
        var negative = Run(probeCase: R.Case(frame: .xo, pattern: .p1))
        negative.handshake(); negative.trigger(); negative.samples()
        negative.add("child", "focus_attempt", "trigger", ["trigger": "timer-17ms", "hasFocus": false, "activeIsInput": false])
        negative.type(in: "parent")
        let negativeResult = negative.evaluate()
        check(negativeResult.complete, "negative focus with typing in the parent is measured: \(negativeResult.problems)")
        check(negativeResult.outcome["typing_landed"] as? String == "parent" && negativeResult.outcome["typed_into_child_input"] as? Bool == false,
              "the outcome says typing landed in the parent")
        check((negativeResult.outcome["child_input_focused_by_ms"] as? [String: Bool])?["100"] == false, "the child input was not focused at +100 ms")

        // A positive P1 outcome.
        var positive = Run(probeCase: R.Case(frame: .so, pattern: .p1))
        positive.handshake(); positive.trigger(); positive.samples(childFocused: true)
        positive.add("child", "focus_attempt", "trigger", ["trigger": "timer-17ms"])
        positive.type(in: "child", input: true, value: "bam")
        check(positive.evaluate().complete && positive.evaluate().outcome["typing_landed"] as? String == "child-input", "focus and typing in the child input")

        // Required evidence.
        var noTrigger = Run(probeCase: R.Case(frame: .xo, pattern: .p1)); noTrigger.handshake(); noTrigger.type(in: "parent")
        check(noTrigger.evaluate().problems.contains { $0.contains("trigger key") }, "a missing trigger is incomplete")
        var earlyTrigger = Run(probeCase: R.Case(frame: .xo, pattern: .p1)); earlyTrigger.handshake(); earlyTrigger.trigger(phase: "setup")
        earlyTrigger.samples(); earlyTrigger.type(in: "parent")
        check(!earlyTrigger.evaluate().complete, "a trigger seen before READY doesn't count")
        var untrusted = Run(probeCase: R.Case(frame: .xo, pattern: .p1)); untrusted.handshake(); untrusted.trigger(trusted: false)
        untrusted.samples(); untrusted.type(in: "parent")
        check(!untrusted.evaluate().complete, "an untrusted trigger doesn't count")
        var missingSample = Run(probeCase: R.Case(frame: .xo, pattern: .p1)); missingSample.handshake(); missingSample.trigger()
        missingSample.samples(skip: ("child", 1000)); missingSample.add("child", "focus_attempt", "trigger", ["trigger": "timer-17ms"])
        missingSample.type(in: "parent")
        check(missingSample.evaluate().problems == ["child reading +1000ms missing"], "one missing reading is reported")
        var lateSample = Run(probeCase: R.Case(frame: .xo, pattern: .p1)); lateSample.handshake(); lateSample.trigger()
        lateSample.samples(phase: "typing"); lateSample.add("child", "focus_attempt", "trigger", ["trigger": "timer-17ms"]); lateSample.type(in: "parent")
        check(lateSample.evaluate().problems.contains { $0.contains("outside the trigger phase") }, "readings received in the typing phase don't count")
        var noAttempt = Run(probeCase: R.Case(frame: .ex, pattern: .p1)); noAttempt.handshake(); noAttempt.trigger(); noAttempt.samples(); noAttempt.type(in: "parent")
        check(noAttempt.evaluate().problems == ["child timer focus attempt not recorded"], "a timer pattern requires the child's attempt")
        var p2 = Run(probeCase: R.Case(frame: .ex, pattern: .p2)); p2.handshake(); p2.trigger(); p2.samples(); p2.type(in: "parent")
        check(p2.evaluate().complete && p2.evaluate().outcome["child_window_focus_fired"] as? Bool == false,
              "P2 without a child window focus event is a measured outcome, not missing evidence")
        var noTyping = Run(probeCase: R.Case(frame: .xo, pattern: .p1)); noTyping.handshake(); noTyping.trigger(); noTyping.samples()
        noTyping.add("child", "focus_attempt", "trigger", ["trigger": "timer-17ms"])
        check(noTyping.evaluate().problems.contains { $0.contains("trusted typing") }, "missing typing is incomplete")
        var lateHandshake = Run(probeCase: R.Case(frame: .xo, pattern: .p1))
        lateHandshake.add("child", "ready", "trigger"); lateHandshake.add("parent", "armed", "trigger")
        lateHandshake.trigger(); lateHandshake.samples(); lateHandshake.add("child", "focus_attempt", "trigger", ["trigger": "timer-17ms"]); lateHandshake.type(in: "parent")
        check(lateHandshake.evaluate().problems.contains("handshake not completed before READY"), "the handshake must precede READY")
        let noReady = Run(probeCase: R.Case(frame: .xo, pattern: .p1))
        check(noReady.evaluate().problems == ["child ready acknowledgement missing"], "no handshake at all is incomplete")

        // Pointer positive control.
        var control = Run(probeCase: R.Case(frame: .ex, pattern: .c)); control.handshake()
        control.add("child", "pointer", "pointer", ["trusted": true, "onInput": true]); control.type(in: "child", input: true, value: "bam")
        check(control.evaluate().complete, "the positive control with typing in the child input is measured")
        var failedControl = Run(probeCase: R.Case(frame: .ex, pattern: .c)); failedControl.handshake()
        failedControl.add("child", "pointer", "pointer", ["trusted": true, "onInput": true]); failedControl.type(in: "parent")
        check(failedControl.evaluate().problems.contains("positive control: typing did not reach the child input"), "a positive control without child typing is incomplete")
        var noPointer = Run(probeCase: R.Case(frame: .ex, pattern: .c)); noPointer.handshake(); noPointer.type(in: "child", input: true, value: "bam")
        check(noPointer.evaluate().problems.contains { $0.contains("trusted pointer") }, "the control needs the trusted pointer")

        // Binding: records from another run, case or role, unknown kinds and malformed shapes are dropped and counted.
        var bound = Run(probeCase: R.Case(frame: .xo, pattern: .p1)); bound.handshake()
        bound.records.append(["frame": "child", "kind": "ready", "seq": 50, "t": 1, "run": "OTHER", "case": "xo:p1", "role": "xo"])
        bound.records.append(["frame": "child", "kind": "ready", "seq": 51, "t": 1, "run": "RUN-1", "case": "xo:p1", "role": "ex"])
        bound.records.append(["frame": "child", "kind": "teleport", "seq": 52, "t": 1, "run": "RUN-1", "case": "xo:p1", "role": "xo"])
        bound.records.append(["frame": "child", "kind": "ready", "seq": true, "t": 1, "run": "RUN-1", "case": "xo:p1", "role": "xo"])
        let parsed = R.records(fromState: bound.state, run: "RUN-1", case: R.Case(frame: .xo, pattern: .p1), firstSeen: bound.firstSeen)
        check(parsed.records.count == 3 && parsed.malformed == 4, "wrong run/role, unknown kind and a boolean seq are dropped and counted")
        check(R.records(fromState: bound.state, run: "RUN-2", case: R.Case(frame: .xo, pattern: .p1), firstSeen: [:]).records.isEmpty,
              "a state for another run is ignored")
        check(R.records(fromState: bound.state, run: "RUN-1", case: R.Case(frame: .so, pattern: .p1), firstSeen: [:]).records.isEmpty,
              "a state for another case is ignored")

        print("PASS: Extension focus probe rules — \(checks) checks")
    }
}
