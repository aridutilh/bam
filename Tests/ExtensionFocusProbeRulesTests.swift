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
        mutating func type(in frame: String, input: Bool = false, value: String? = nil, valuePhase: String = "typing", valueTrusted: Bool = true) {
            for key in ["b", "a", "m"] { add(frame, "keydown", "typing", ["key": key, "trusted": true, "targetIsInput": input]) }
            if let value { add("child", "input", valuePhase, ["value": value, "trusted": valueTrusted]) }
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
        check(noAttempt.evaluate().problems == ["child timer focus attempt not recorded in the trigger phase"], "a timer pattern requires the child's attempt")
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
        check(failedControl.evaluate().problems.contains("positive control: not every typed key reached the child input"), "a positive control without child typing is incomplete")
        var noPointer = Run(probeCase: R.Case(frame: .ex, pattern: .c)); noPointer.handshake(); noPointer.type(in: "child", input: true, value: "bam")
        check(noPointer.evaluate().problems.contains { $0.contains("trusted pointer") }, "the control needs the trusted pointer")
        // The review's regressions: keys split between frames, keys in the child but not on its input, and a value that
        // is unphased or untrusted must all leave the positive control incomplete.
        func controlRun(_ build: (inout Run) -> Void) -> R.Evaluation {
            var run = Run(probeCase: R.Case(frame: .ex, pattern: .c)); run.handshake()
            run.add("child", "pointer", "pointer", ["trusted": true, "onInput": true]); build(&run); return run.evaluate()
        }
        let split = controlRun { run in
            run.add("child", "keydown", "typing", ["key": "b", "trusted": true, "targetIsInput": true])
            run.add("parent", "keydown", "typing", ["key": "a", "trusted": true]); run.add("parent", "keydown", "typing", ["key": "m", "trusted": true])
            run.add("child", "input", "typing", ["value": "bam", "trusted": true])
        }
        check(split.problems.contains("positive control: not every typed key reached the child input"), "keys split between parent and child are incomplete")
        let offInput = controlRun { run in run.type(in: "child", input: false, value: "bam") }
        check(offInput.problems.contains("positive control: not every typed key reached the child input"), "child keys not on the input are incomplete")
        let unphased = controlRun { run in run.type(in: "child", input: true, value: "bam", valuePhase: "pointer") }
        check(unphased.problems.contains { $0.contains("no trusted child input value") }, "a value seen outside the typing phase is incomplete")
        let untrustedValue = controlRun { run in run.type(in: "child", input: true, value: "bam", valueTrusted: false) }
        check(untrustedValue.problems.contains { $0.contains("no trusted child input value") }, "an untrusted input event is incomplete")
        let wrongValue = controlRun { run in run.type(in: "child", input: true, value: "ba") }
        check(wrongValue.problems.contains { $0.contains("no trusted child input value") }, "a value without the text is incomplete")
        check(controlRun { run in run.type(in: "child", input: true, value: "bam") }.complete, "all keys on the child input plus a trusted in-phase value is complete")

        // Show, its acknowledgement and the timer attempt must be received in the trigger phase.
        func shownRun(showPhase: String = "trigger", ackPhase: String = "trigger", attemptPhase: String = "trigger") -> R.Evaluation {
            var run = Run(probeCase: R.Case(frame: .xo, pattern: .p1)); run.handshake()
            run.add("parent", "trigger", "trigger", ["key": "f", "trusted": true, "hasFocus": true])
            run.add("parent", "show_sent", showPhase, ["pattern": "p1", "focusCall": "none"])
            run.add("child", "show", ackPhase, ["hasFocus": false, "activeIsInput": false])
            run.samples(); run.add("child", "focus_attempt", attemptPhase, ["trigger": "timer-17ms"]); run.type(in: "parent")
            return run.evaluate()
        }
        check(shownRun().complete, "show, acknowledgement and attempt in the trigger phase are complete")
        check(shownRun(showPhase: "typing").problems == ["show not sent after the trigger in the trigger phase"], "show_sent seen in another phase doesn't count")
        check(shownRun(ackPhase: "typing").problems == ["child show acknowledgement missing in the trigger phase"], "a show acknowledgement in another phase doesn't count")
        check(shownRun(attemptPhase: "typing").problems == ["child timer focus attempt not recorded in the trigger phase"], "a timer attempt in another phase doesn't count")

        // Protocol validation: exact integers, unique identities, unique scheduled readings.
        check(R.Record.strictInt(3) == 3 && R.Record.strictInt(NSNumber(value: 3.0)) == 3, "integers and integral doubles are exact")
        check(R.Record.strictInt(NSNumber(value: 1.5)) == nil && R.Record.strictInt(true) == nil && R.Record.strictInt(Double.infinity) == nil
              && R.Record.strictInt(NSNumber(value: 1e300)) == nil && R.Record.strictInt("3") == nil, "fractions, booleans, non-finite, huge and strings are refused")
        var fractional = Run(probeCase: R.Case(frame: .xo, pattern: .p1)); fractional.handshake()
        fractional.records.append(["frame": "child", "kind": "sample", "seq": 2.5, "t": 1, "run": "RUN-1", "case": "xo:p1", "role": "xo"])
        check(R.records(fromState: fractional.state, run: "RUN-1", case: R.Case(frame: .xo, pattern: .p1), firstSeen: [:]).malformed == 1,
              "a fractional seq is malformed, not truncated")
        var duplicateIdentity = Run(probeCase: R.Case(frame: .xo, pattern: .p1)); duplicateIdentity.handshake()
        duplicateIdentity.records.append(duplicateIdentity.records[1])   // the child's ready again, same frame:seq
        let duplicateParse = R.records(fromState: duplicateIdentity.state, run: "RUN-1", case: R.Case(frame: .xo, pattern: .p1), firstSeen: [:])
        check(duplicateParse.records.count == 3 && duplicateParse.malformed == 1, "a repeated frame:seq is malformed and only the first is kept")
        var ledger = Run(probeCase: R.Case(frame: .xo, pattern: .p1)); ledger.handshake()
        ledger.records.append(["frame": "child", "kind": "ready", "seq": 60, "t": 1, "run": "OTHER", "case": "xo:p1", "role": "xo"])
        ledger.records.append(["frame": "child", "kind": "ready", "seq": 61, "t": 1, "run": "RUN-1", "case": "xo:p1", "role": "so"])
        ledger.records.append(ledger.records[0])
        check(R.validIdentities(fromState: ledger.state, run: "RUN-1", case: R.Case(frame: .xo, pattern: .p1)) == ["child:1", "child:2", "parent:1"],
              "only validated, unique identities may enter the phase ledger")
        var duplicateSample = Run(probeCase: R.Case(frame: .xo, pattern: .p1)); duplicateSample.handshake(); duplicateSample.trigger(); duplicateSample.samples()
        duplicateSample.add("child", "sample", "trigger", ["after_ms": 100, "actual_ms": 101, "hasFocus": false, "activeIsInput": false])
        duplicateSample.add("child", "focus_attempt", "trigger", ["trigger": "timer-17ms"]); duplicateSample.type(in: "parent")
        let duplicateResult = duplicateSample.evaluate()
        check(duplicateResult.problems == ["child reading +100ms duplicated"], "a duplicated scheduled reading is a problem, and doesn't trap")
        var unscheduled = Run(probeCase: R.Case(frame: .xo, pattern: .p1)); unscheduled.handshake(); unscheduled.trigger(); unscheduled.samples()
        unscheduled.add("parent", "sample", "trigger", ["after_ms": 7, "actual_ms": 7, "hasFocus": true])
        unscheduled.add("child", "focus_attempt", "trigger", ["trigger": "timer-17ms"]); unscheduled.type(in: "parent")
        check(unscheduled.evaluate().problems == ["parent reading with an unscheduled or malformed offset"], "an unscheduled offset is a problem")
        var fractionalOffset = Run(probeCase: R.Case(frame: .xo, pattern: .p1)); fractionalOffset.handshake(); fractionalOffset.trigger(); fractionalOffset.samples()
        fractionalOffset.add("child", "sample", "trigger", ["after_ms": 20.5, "actual_ms": 20, "hasFocus": false, "activeIsInput": false])
        fractionalOffset.add("child", "focus_attempt", "trigger", ["trigger": "timer-17ms"]); fractionalOffset.type(in: "parent")
        check(fractionalOffset.evaluate().problems == ["child reading with an unscheduled or malformed offset"], "a fractional offset is malformed, not rounded")

        // Cumulative phase ledger across snapshots: capped without eviction, faults permanent.
        let xo = R.Case(frame: .xo, pattern: .p1)
        func snapshot(_ seqs: ClosedRange<Int>, run: String = "RUN-1", kind: String = "keydown", t: Int? = nil) -> [String: Any] {
            ["run": run, "case": "xo:p1", "records": seqs.map { seq -> [String: Any] in
                ["frame": "child", "kind": kind, "seq": seq, "t": t ?? seq, "run": run, "case": "xo:p1", "role": "xo", "key": "x", "trusted": true]
            }]
        }
        var growing = R.PhaseLedger(capacity: 5)
        growing.ingest(state: snapshot(1...2), run: "RUN-1", case: xo, phase: "setup")
        growing.ingest(state: snapshot(1...4), run: "RUN-1", case: xo, phase: "trigger")
        check(growing.faults.isEmpty && growing.firstSeen["child:1"] == "setup" && growing.firstSeen["child:3"] == "trigger",
              "a growing prefix keeps each record's first phase")
        var disjoint = R.PhaseLedger(capacity: 5)
        disjoint.ingest(state: snapshot(1...3), run: "RUN-1", case: xo, phase: "setup")
        disjoint.ingest(state: snapshot(1...6), run: "RUN-1", case: xo, phase: "trigger")   // individually bounded, cumulatively over
        check(disjoint.firstSeen.count == 5 && disjoint.firstSeen["child:1"] == "setup" && disjoint.faults.contains("phase ledger capacity (5) exceeded"),
              "the cap holds without evicting earlier entries, and overflow is a fault")
        disjoint.ingest(state: snapshot(1...5), run: "RUN-1", case: xo, phase: "typing")
        check(disjoint.faults.contains("phase ledger capacity (5) exceeded") && disjoint.faults.contains("a snapshot dropped previously seen records") == false,
              "a later valid snapshot never clears an earlier fault")
        var dropped = R.PhaseLedger()
        dropped.ingest(state: snapshot(1...4), run: "RUN-1", case: xo, phase: "setup")
        dropped.ingest(state: snapshot(3...6), run: "RUN-1", case: xo, phase: "trigger")
        check(dropped.faults == ["a snapshot dropped previously seen records"], "a snapshot dropping earlier records is a permanent fault")
        var changed = R.PhaseLedger()
        changed.ingest(state: snapshot(1...2), run: "RUN-1", case: xo, phase: "setup")
        changed.ingest(state: snapshot(1...2, t: 99), run: "RUN-1", case: xo, phase: "trigger")
        check(changed.faults == ["a record identity changed between snapshots"] && changed.firstSeen["child:1"] == "setup",
              "a changed record identity is a fault; its first phase is kept")
        var poisoned = R.PhaseLedger()
        poisoned.ingest(state: snapshot(1...3, run: "OTHER"), run: "RUN-1", case: xo, phase: "setup")
        poisoned.ingest(state: snapshot(1...3), run: "RUN-1", case: xo, phase: "trigger")
        check(poisoned.firstSeen["child:1"] == "trigger" && poisoned.faults.isEmpty, "a wrong-run snapshot can't pre-stamp a legitimate record's phase")
        var malformedSnapshot = R.PhaseLedger()
        var bad = snapshot(1...2); var badRecords = bad["records"] as! [[String: Any]]; badRecords[1]["seq"] = 1.5; bad["records"] = badRecords
        malformedSnapshot.ingest(state: bad, run: "RUN-1", case: xo, phase: "setup")
        malformedSnapshot.ingest(state: snapshot(1...2), run: "RUN-1", case: xo, phase: "trigger")
        check(malformedSnapshot.faults == ["a snapshot contained malformed records"], "a malformed snapshot is a permanent fault")

        // Cleanup: confirmed fixture removal is required.
        let removed: [String: Any] = ["host_temporary_storage_removed": true, "run_directory_removed": true, "fixture_removed": true]
        check(R.cleanupIsClean(removed, fixtureInstalled: true), "confirmed removal plus removed storage is clean")
        check(!R.cleanupIsClean(removed.merging(["fixture_removed": false]) { _, n in n }, fixtureInstalled: true), "unconfirmed removal is not clean")
        check(!R.cleanupIsClean(removed.merging(["fixture_removal_timed_out": true]) { _, n in n }, fixtureInstalled: true), "a removal timeout is not clean")
        check(!R.cleanupIsClean(removed.merging(["fixture_removal_error": "x"]) { _, n in n }, fixtureInstalled: true), "a removal error is not clean")
        check(!R.cleanupIsClean(["host_temporary_storage_removed": true, "run_directory_removed": true], fixtureInstalled: true), "missing removal evidence is not clean")
        check(!R.cleanupIsClean(removed.merging(["host_temporary_storage_removed": "not a temporary path; left untouched"]) { _, n in n }, fixtureInstalled: true),
              "storage left untouched is not clean")
        check(R.cleanupIsClean(["host_temporary_storage_removed": "no host was created", "run_directory_removed": true], fixtureInstalled: false),
              "nothing installed and nothing created is clean")

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
