import Foundation

@main enum ProfileHandoffLedgerTests {
    static var checks = 0
    static func require(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: Profile handoff ledger — \(message)\n", stderr); exit(1) }
        checks += 1
    }
    typealias Decision = ProfileHandoffLedger.Decision

    static func main() {
        let page = URL(string: "https://example.invalid/page")!
        let later = URL(string: "https://example.invalid/later")!
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

        // In-order launch: startup notice, focus-only request, then a URL.
        var ledger = ProfileHandoffLedger()
        let launch = UUID(), focus = UUID(), open = UUID()
        require(ledger.receive(launch: launch, request: nil, urls: [], canDeliver: true, now: start)
                == Decision(activate: true), "First focus notice of a launch activates")
        require(ledger.receive(launch: launch, request: focus, urls: [], canDeliver: true, now: start)
                == Decision(acknowledge: true), "Same-launch focus request is acknowledged without fronting again")
        require(ledger.receive(launch: launch, request: open, urls: [page], canDeliver: true, now: start)
                == Decision(activate: true, deliver: [page], acknowledge: true), "URL request activates, then delivers")
        require(ledger.receive(launch: launch, request: open, urls: [page], canDeliver: true, now: start)
                == Decision(acknowledge: true), "URL retry is acknowledged without reopening or refocusing")

        // Reordered launch: the URL arrives before that launch's focus messages.
        ledger = ProfileHandoffLedger()
        let reordered = UUID(), lateFocus = UUID()
        require(ledger.receive(launch: reordered, request: UUID(), urls: [page], canDeliver: true, now: start)
                == Decision(activate: true, deliver: [page], acknowledge: true), "Early URL opens once")
        require(ledger.receive(launch: reordered, request: lateFocus, urls: [], canDeliver: true, now: start + 0.4)
                == Decision(acknowledge: true), "Delayed same-launch focus request cannot steal focus from Little Bam")
        require(ledger.receive(launch: reordered, request: lateFocus, urls: [], canDeliver: true, now: start + 0.5)
                == Decision(acknowledge: true), "Retry of a delayed focus request still does not steal focus")
        require(ledger.receive(launch: reordered, request: nil, urls: [], canDeliver: true, now: start + 0.6)
                == Decision(), "Delayed same-launch startup notice cannot steal focus")
        require(ledger.receive(launch: reordered, request: UUID(), urls: [later], canDeliver: true, now: start + 1)
                == Decision(activate: true, deliver: [later], acknowledge: true), "Late URL from the same launch still opens")

        // A separate, intentional launch right afterwards is independent.
        let next = UUID()
        require(ledger.receive(launch: next, request: nil, urls: [], canDeliver: true, now: start + 1.1)
                == Decision(activate: true), "Unrelated later launch may front the main window immediately")
        require(ledger.receive(launch: next, request: UUID(), urls: [page], canDeliver: true, now: start + 1.1)
                == Decision(activate: true, deliver: [page], acknowledge: true), "Same URL in a new launch opens again")

        // Refusal is not acknowledged and does not consume the request or launch.
        ledger = ProfileHandoffLedger()
        let busy = UUID(), busyRequest = UUID()
        require(ledger.receive(launch: busy, request: busyRequest, urls: [page], canDeliver: false, now: start)
                == Decision(), "Owner unable to take URLs neither applies nor acknowledges them")
        require(ledger.receive(launch: busy, request: busyRequest, urls: [page], canDeliver: true, now: start + 0.1)
                == Decision(activate: true, deliver: [page], acknowledge: true), "Retry after refusal is delivered once")

        // Duplicates without launch IDs keep their previous behavior.
        ledger = ProfileHandoffLedger()
        require(ledger.receive(launch: nil, request: nil, urls: [], canDeliver: true, now: start)
                == Decision(activate: true), "Legacy focus notice activates")
        require(ledger.receive(launch: nil, request: nil, urls: [], canDeliver: true, now: start)
                == Decision(activate: true), "Each legacy focus notice activates")
        let legacy = UUID()
        require(ledger.receive(launch: nil, request: legacy, urls: [], canDeliver: true, now: start)
                == Decision(activate: true, acknowledge: true), "Uncorrelated focus request activates and is acknowledged")
        require(ledger.receive(launch: nil, request: legacy, urls: [], canDeliver: true, now: start)
                == Decision(acknowledge: true), "Uncorrelated focus retry is deduplicated by request")

        // Records are pruned only after any retry deadline has long passed.
        ledger = ProfileHandoffLedger()
        let old = UUID(), oldRequest = UUID()
        _ = ledger.receive(launch: old, request: oldRequest, urls: [page], canDeliver: true, now: start)
        require(ledger.receive(launch: old, request: oldRequest, urls: [page], canDeliver: true, now: start + 30)
                == Decision(acknowledge: true), "Request deduplication outlasts the duplicate's 5-second deadline")
        require(ledger.receive(launch: old, request: nil, urls: [], canDeliver: true, now: start + 30)
                == Decision(), "Launch correlation outlasts the duplicate's handoff")

        print("PASS: Profile handoff ledger — \(checks) ordering, retry, refusal, independence and legacy checks")
    }
}
