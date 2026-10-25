import Foundation

/// Pure checks of the gesture probe's rules: configuration, loopback scoping and the install-review decision.
@main enum ExtensionGestureProbeRulesTests {
    nonisolated(unsafe) static var checks = 0
    static func check(_ ok: Bool, _ message: String) {
        guard ok else { fputs("FAIL: Extension gesture probe rules — \(message)\n", stderr); exit(1) }
        checks += 1
    }
    typealias R = ExtensionGestureProbeRules

    static func main() {
        // Click wait: default 40 s, may only be shortened, junk ignored.
        check(R.clickSeconds(nil) == 40 && R.clickSeconds("abc") == 40 && R.clickSeconds("0") == 40 && R.clickSeconds("-3") == 40,
              "missing, junk, zero and negative waits keep the default")
        check(R.clickSeconds("12") == 12 && R.clickSeconds(" 5.5 ") == 5.5, "a shorter wait is honoured")
        check(R.clickSeconds("90") == 40 && R.clickSeconds("inf") == 40, "a wait can't exceed 40 s")

        // Toolbar mode.
        check(R.toolbarMode(nil) == .button && R.toolbarMode("REAL") == .real && R.toolbarMode(" off ") == .off, "known toolbar modes")
        check(R.toolbarMode("pointer") == nil && R.toolbarMode("") == nil, "unknown toolbar modes are refused")

        // Loopback only.
        let page = URL(string: "http://127.0.0.1:8123/fixture/extension-test.html?x=1#frag")!
        check(R.isLoopback(page) && R.isLoopback(URL(string: "https://localhost/a")!) && R.isLoopback(URL(string: "http://[::1]:9/")!),
              "loopback pages are accepted")
        check(!R.isLoopback(URL(string: "http://example.com/")!) && !R.isLoopback(URL(string: "http://user:pw@127.0.0.1/")!)
              && !R.isLoopback(URL(string: "file:///tmp/x.html")!) && !R.isLoopback(URL(string: "http://127.0.0.2/")!),
              "non-loopback, credentialed, file and other 127/8 hosts are refused")
        check(R.matchPatterns(for: page) == ["http://127.0.0.1/*"], "match pattern is the page's scheme and host, any port")
        check(R.matchPatterns(for: URL(string: "http://[::1]:9/x")!) == ["http://[::1]/*"], "IPv6 loopback is bracketed")
        check(R.matchPatterns(for: URL(string: "https://example.com/")!).isEmpty, "no pattern for a non-loopback page")
        let probe = R.probeURL(page)
        check(probe?.absoluteString == "http://127.0.0.1:8123/fixture/extension-test.html?bam-gesture-probe=1",
              "probe URL keeps the page and port, with only the marker query and no fragment")
        check(R.probeURL(URL(string: "https://example.com/")!) == nil, "no probe URL off loopback")

        // Install review: loopback websites only, no API permissions, only Bam's own worker transport tolerated.
        let site = ["http://127.0.0.1/*"]
        check(R.allowsInstall(permissions: [], unsupported: [], websites: site, isOptional: false), "plain loopback install review approved")
        check(R.allowsInstall(permissions: [], unsupported: ["nativeMessaging"], websites: site, isOptional: false),
              "Bam's internal worker transport listed as unsupported is tolerated (never granted by the review)")
        check(!R.allowsInstall(permissions: ["alarms"], unsupported: [], websites: site, isOptional: false), "any API permission is refused")
        check(!R.allowsInstall(permissions: [], unsupported: ["sidePanel"], websites: site, isOptional: false), "other unsupported entries are refused")
        check(!R.allowsInstall(permissions: [], unsupported: [], websites: site, isOptional: true), "every optional review is refused")
        check(!R.allowsInstall(permissions: [], unsupported: [], websites: [], isOptional: false), "a review without the loopback site is refused")
        check(!R.allowsInstall(permissions: [], unsupported: [], websites: site + ["https://example.com/*"], isOptional: false),
              "any non-loopback website is refused")
        check(!R.allowsInstall(permissions: [], unsupported: [], websites: ["<all_urls>"], isOptional: false)
              && !R.allowsInstall(permissions: [], unsupported: [], websites: ["*://*/*"], isOptional: false)
              && !R.allowsInstall(permissions: [], unsupported: [], websites: ["http://127.0.0.1/private/*"], isOptional: false),
              "broad or path-narrowed patterns are refused")

        // Worker replies, as the content script publishes them and the probe parses them (JSON text).
        func entry(_ json: String) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] }
        func reply(kind: String, _ response: String) -> String { #"{"kind":""# + kind + #"","sentAt":1,"response":"# + response + "}" }
        let denied = #"{"kind":"click","sequence":2,"badge":"C2","receivedAt":10,"settledAt":12,"request":{"outcome":"resolved","granted":false}}"#
        check(R.reply(entry(reply(kind: "click", denied)), kind: "click") == .measured(badge: "C2", outcome: "resolved not granted"),
              "a structured denied reply is measured")
        let rejected = #"{"kind":"click","sequence":2,"badge":"C2","receivedAt":10,"settledAt":12,"request":{"outcome":"rejected","error":"needs a user gesture"}}"#
        let threw = #"{"kind":"toolbar","sequence":3,"badge":"T3","receivedAt":10,"settledAt":12,"request":{"outcome":"threw","error":"sync"}}"#
        check(R.reply(entry(reply(kind: "click", rejected)), kind: "click") == .measured(badge: "C2", outcome: "rejected")
              && R.reply(entry(reply(kind: "toolbar", threw)), kind: "toolbar") == .measured(badge: "T3", outcome: "threw"),
              "legitimate rejected and thrown permission attempts are measured outcomes")
        check(R.reply(entry(#"{"kind":"click","sentAt":1}"#), kind: "click") == nil && R.reply(nil, kind: "click") == nil, "no answer yet is nil")
        if case .transportFailure = R.reply(entry(reply(kind: "click", "null")), kind: "click") {} else { check(false, "a null response is a transport failure, not measured") }
        if case .transportFailure(let why) = R.reply(entry(#"{"kind":"click","sentAt":1,"error":"Could not establish connection"}"#), kind: "click") {
            check(why == "Could not establish connection", "a sendMessage error is a transport failure with its text")
        } else { check(false, "a sendMessage error is a transport failure") }
        func malformed(_ response: String, kind: String = "click") -> Bool {
            if case .malformed = R.reply(entry(reply(kind: kind, response)), kind: kind) { return true }
            return false
        }
        check(malformed(denied, kind: "baseline"), "a reply for another phase is malformed")
        check(malformed(denied.replacingOccurrences(of: "\"C2\"", with: "\"C3\"")), "a badge that doesn't match the sequence is malformed")
        check(malformed(denied.replacingOccurrences(of: "\"sequence\":2", with: "\"sequence\":true")), "a boolean sequence is malformed")
        check(malformed(denied.replacingOccurrences(of: "\"receivedAt\":10,", with: "")), "missing timing is malformed")
        check(malformed(denied.replacingOccurrences(of: "\"granted\":false", with: "\"granted\":0")), "a non-boolean granted is malformed")
        check(malformed(rejected.replacingOccurrences(of: "\"error\":\"needs a user gesture\"", with: "\"error\":\"\"")), "a rejection without error text is malformed")
        check(malformed(denied.replacingOccurrences(of: "\"resolved\"", with: "\"maybe\"")), "an unknown outcome is malformed")
        check(malformed(#"{"kind":"click","sequence":2,"badge":"C2","receivedAt":10,"settledAt":12}"#), "a reply without a request outcome is malformed")
        if case .transportFailure = R.reply(entry(reply(kind: "click", #""text""#)), kind: "click") {} else {
            check(false, "a non-object response is not a worker reply")
        }
        checks += 1

        // Phase verdicts: measured only with the arrival observed; failures kept as such.
        let measured = R.reply(entry(reply(kind: "click", denied)), kind: "click")
        check(R.isMeasured(R.phaseVerdict(measured, observedBadges: ["B1", "C2"])), "a structured reply with its observed arrival is measured")
        check(!R.isMeasured(R.phaseVerdict(measured, observedBadges: ["B1"])), "a reply whose arrival wasn't observed is not measured")
        check(!R.isMeasured(R.phaseVerdict(R.reply(entry(reply(kind: "click", "null")), kind: "click"), observedBadges: ["C2"]))
              && R.phaseVerdict(R.reply(entry(reply(kind: "click", "null")), kind: "click"), observedBadges: []).hasPrefix("transport failure"),
              "a transport failure stays a failure in the verdict")
        check(!R.isMeasured(R.phaseVerdict(nil, observedBadges: [])) && !R.isMeasured("done") && !R.isMeasured(nil), "no reply is not measured")

        // Host-world evidence, phase-bound. Events as the probe logs them (host_phase / host_t_ms added on receipt).
        let delays = [0, 20, 100, 1000, 3000]
        var clock = 0
        func message(_ event: String, _ phase: String, _ extra: [String: Any]) -> [String: Any] {
            clock += 1
            return ["event": event, "perf": clock, "wall": 1_000_000 + clock, "host_t_ms": clock, "host_phase": phase,
                    "activation": ["isActive": false, "hasBeenActive": true]].merging(extra) { _, new in new }
        }
        func readings(_ id: String, _ phase: String, active: Bool = false, skip: Int? = nil, phaseFor: (Int) -> String = { _ in "" }) -> [[String: Any]] {
            delays.filter { $0 != skip }.map { delay in
                let receivedIn = phaseFor(delay).isEmpty ? phase : phaseFor(delay)
                return message("activation", receivedIn, ["source": "x", "id": id, "scheduled_ms": delay, "actual_ms": delay + 1,
                                                          "activation": ["isActive": active, "hasBeenActive": true]])
            }
        }
        func trigger(click id: String, _ phase: String) -> [[String: Any]] {
            [message("click", phase, ["id": id, "trusted": true, "detail": 1, "pointerType": "mouse"])] + readings(id, phase, active: true)
        }
        func record(_ kind: String, _ index: Int, _ phase: String, skip: Int? = nil, phaseFor: (Int) -> String = { _ in "" }) -> [[String: Any]] {
            let id = "record-\(kind)-\(index)"
            return [message("record", phase, ["id": id, "kind": kind])] + readings(id, phase, skip: skip, phaseFor: phaseFor)
        }
        let armed = [message("armed", "baseline", ["id": "armed"])]
        func problems(_ phase: String, _ events: [[String: Any]]) -> [String] { R.phaseSampleProblems(phase, in: events, delays: delays) }

        let baselineOK = record("baseline", 0, "baseline")
        check(problems("baseline", baselineOK).isEmpty, "a baseline record with all in-phase readings has no problems")
        check(R.armedAcknowledged(in: armed) && !R.armedAcknowledged(in: baselineOK), "the armed acknowledgement is required, not implied")

        // The review's regression: an early trusted click during baseline must not satisfy page_click's input trigger.
        let early = trigger(click: "input-click-1", "baseline")
        let clickRecord = record("click", 1, "page_click")
        let withoutRealClick = baselineOK + armed + early + clickRecord
        check(!problems("page_click", withoutRealClick).isEmpty && problems("page_click", withoutRealClick).contains { $0.contains("input:trusted-click") },
              "an early baseline click plus a valid click record but no page_click input trigger is incomplete")
        check(R.triggerEvent(.trustedClick, phase: "page_click", in: withoutRealClick) == nil, "the early click is never the page_click trigger")
        let withRealClick = withoutRealClick + trigger(click: "input-click-2", "page_click")
        check(problems("page_click", withRealClick).isEmpty, "adding a correctly stamped page_click input and readings makes it measured")
        check((R.triggerEvent(.trustedClick, phase: "page_click", in: withRealClick)?["id"] as? String) == "input-click-2",
              "the page_click trigger is the one received in page_click")

        // Wrong phase throughout: a trigger whose readings are all consistently stamped another phase still fails.
        let wrong = baselineOK + armed + [message("click", "toolbar", ["id": "input-click-3", "trusted": true])] + readings("input-click-3", "toolbar") + clickRecord
        check(!problems("page_click", wrong).isEmpty, "a click trigger and readings all stamped toolbar never satisfy page_click")

        // Whole trigger removed while the phase's other evidence stays; one reading missing; a late reading in the next phase.
        check(problems("toolbar", baselineOK + clickRecord).contains("record:toolbar: trigger not reported in toolbar"),
              "a missing toolbar record is explicit incomplete evidence, never vacuous")
        check(problems("baseline", record("baseline", 0, "baseline", skip: 3000)) == ["record:baseline+3000ms missing"], "one missing reading is reported")
        let late = record("click", 1, "page_click", phaseFor: { $0 == 3000 ? "toolbar" : "" }) + trigger(click: "input-click-2", "page_click")
        check(problems("page_click", late) == ["record:click+3000ms received outside page_click"],
              "a +3 s reading delivered during toolbar does not count for the click phase")

        // Event-specific shape: readings need numeric offsets and boolean activation fields; triggers need timestamps.
        var malformed = record("baseline", 0, "baseline")
        malformed[2]["activation"] = ["isActive": 1, "hasBeenActive": true]
        check(problems("baseline", malformed) == ["record:baseline+20ms malformed"], "a reading with non-boolean activation is malformed")
        var badTime = record("baseline", 0, "baseline")
        badTime[0]["perf"] = "1"
        check(problems("baseline", badTime) == ["record:baseline: trigger timestamps malformed"], "a trigger without numeric timestamps fails")
        var boolTrusted = trigger(click: "input-click-2", "page_click")
        boolTrusted[0]["trusted"] = 1
        check(R.triggerEvent(.trustedClick, phase: "page_click", in: boolTrusted) == nil, "trusted must be a real boolean")

        print("PASS: Extension gesture probe rules — \(checks) checks")
    }
}
