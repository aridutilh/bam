import Foundation
import JavaScriptCore

/// Idle-callback semantics with a deterministic clock and task queue; no pages or engines' idle periods.
@main struct ExtensionIdleCallbackCompatibilityTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() {
        do { print("PASS: Extension idle callbacks — \(try run()) checks") }
        catch { fputs("FAIL: Extension idle callbacks: \(error)\n", stderr); exit(1) }
    }

    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(description: message) }; checks += 1 }
        func context(_ prelude: String = "") -> (JSContext, () -> [String]) {
            let js = JSContext()!
            var errors: [String] = []
            js.exceptionHandler = { _, error in errors.append(error?.toString() ?? "JavaScript error") }
            // A manual clock and FIFO task queue; each task runs isolated, as a real event loop does.
            js.evaluateScript("""
            var now = 0, tasks = [], nextTimer = 0, log = [], taskErrors = [];
            var performance = {now: function () { return now; }};
            function setTimeout(fn, delay) { var id = ++nextTimer; tasks.push({id: id, fn: fn}); return id; }
            function clearTimeout(id) { tasks = tasks.filter(function (task) { return task.id !== id; }); }
            function drain(advance) {
              while (tasks.length) { var task = tasks.shift(); now += advance || 0; try { task.fn(); } catch (error) { taskErrors.push(String(error.message)); } }
            }
            \(prelude)
            """)
            js.evaluateScript(ExtensionIdleCallbackCompatibility.source)
            return (js, { errors })
        }
        func value(_ js: JSContext, _ script: String) -> JSValue { js.evaluateScript(script)! }

        // Defined when absent, as ordinary writable globals with distinct positive handles.
        let (js, errors) = context()
        try check(value(js, "typeof requestIdleCallback === 'function' && typeof cancelIdleCallback === 'function' && Object.getOwnPropertyDescriptor(globalThis, 'requestIdleCallback').writable").toBool(),
                  "Idle callbacks were not defined where absent")
        js.evaluateScript("""
        var a = requestIdleCallback(function (deadline) { log.push(['a', deadline.didTimeout, deadline.timeRemaining()]); now += 20; log.push(['a-later', deadline.timeRemaining()]); });
        var b = requestIdleCallback(function (deadline) { log.push(['b', deadline.didTimeout, deadline.timeRemaining()]); });
        var c = requestIdleCallback(function () { log.push(['c']); });
        var synchronous = log.length;
        cancelIdleCallback(c);
        cancelIdleCallback(9999); cancelIdleCallback(undefined); cancelIdleCallback(c);
        drain();
        """)
        try check(value(js, "synchronous === 0 && a > 0 && b > a && c > b").toBool(), "Callbacks ran synchronously or handles were not increasing")
        try check(value(js, "JSON.stringify(log) === JSON.stringify([['a', false, 50], ['a-later', 30], ['b', false, 50]])").toBool(),
                  "Order, per-callback 50 ms deadlines or cancellation were wrong: \(value(js, "JSON.stringify(log)"))")

        // A timeout that elapsed before the callback ran: didTimeout and no remaining time. Otherwise false.
        js.evaluateScript("""
        log = [];
        requestIdleCallback(function (deadline) { log.push(['late', deadline.didTimeout, deadline.timeRemaining()]); }, {timeout: 10});
        requestIdleCallback(function (deadline) { log.push(['patient', deadline.didTimeout]); }, {timeout: 1000});
        requestIdleCallback(function (deadline) { log.push(['invalid', deadline.didTimeout]); }, {timeout: -5});
        drain(15);
        """)
        try check(value(js, "JSON.stringify(log) === JSON.stringify([['late', true, 0], ['patient', false], ['invalid', false]])").toBool(),
                  "didTimeout/timeRemaining did not follow the requested timeout: \(value(js, "JSON.stringify(log)"))")

        // A throwing callback does not stop later ones; the deadline cannot be altered; a non-function is refused.
        js.evaluateScript("""
        log = [];
        requestIdleCallback(function () { throw new Error('vendor failure'); });
        requestIdleCallback(function (deadline) { try { deadline.didTimeout = true; } catch (error) {} log.push(['after', deadline.didTimeout, Object.isFrozen(deadline)]); });
        drain();
        var refused = false; try { requestIdleCallback('not a function'); } catch (error) { refused = error instanceof TypeError; }
        """)
        try check(value(js, "JSON.stringify(log) === JSON.stringify([['after', false, true]]) && taskErrors[0] === 'vendor failure' && refused").toBool(),
                  "Callback isolation, deadline immutability or argument checking failed: \(value(js, "JSON.stringify([log, taskErrors, refused])"))")
        try check(errors().isEmpty, "The adapter raised errors: \(errors())")

        // Running it again is a no-op; engine-provided (even partially provided) functions are never replaced.
        js.evaluateScript("var installed = requestIdleCallback;")
        js.evaluateScript(ExtensionIdleCallbackCompatibility.source)
        try check(value(js, "requestIdleCallback === installed").toBool(), "A second run replaced the installed adapter")
        let (native, _) = context("var engine = function () { return 7; }; globalThis.requestIdleCallback = engine;")
        try check(value(native, "requestIdleCallback === engine && typeof cancelIdleCallback === 'undefined'").toBool(),
                  "An engine-provided requestIdleCallback was replaced or paired with a foreign cancel")
        // Without timers (a worker-like or stripped global) nothing is defined.
        let bare = JSContext()!
        bare.evaluateScript(ExtensionIdleCallbackCompatibility.source)
        try check(bare.evaluateScript("typeof requestIdleCallback === 'undefined'")!.toBool(), "Idle callbacks were defined without a timer source")
        return checks
    }
}
