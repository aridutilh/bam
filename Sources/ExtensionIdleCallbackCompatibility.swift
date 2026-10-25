import Foundation

/// `requestIdleCallback`/`cancelIdleCallback` for an extension's own pages and its isolated
/// content-script world, where WebKit on macOS 27.0.1 has neither (measured in the canonical
/// fixture). Proton Pass and uBlock Origin Lite call them there without a feature check.
/// Defined only when both are absent; never in service workers (Chrome has none there) and
/// never in a website's own main world.
///
/// Semantics follow the HTML idle-callback model as closely as a page can without engine
/// idle periods: callbacks run asynchronously in request order, each with a deadline of at
/// most 50 ms from when it starts; `didTimeout` is true (and `timeRemaining()` 0) only when
/// the requested timeout had already elapsed; cancelled callbacks never run.
enum ExtensionIdleCallbackCompatibility {
    static let source = #"""
    // Bam compatibility: requestIdleCallback/cancelIdleCallback where the engine has neither.
    (() => {
      if (typeof globalThis.requestIdleCallback === "function" || typeof globalThis.cancelIdleCallback === "function") return;
      const schedule = globalThis.setTimeout, unschedule = globalThis.clearTimeout, clock = globalThis.performance;
      if (typeof schedule !== "function" || !clock || typeof clock.now !== "function") return;
      const pending = new Map();
      let next = 0;
      const requestIdleCallback = function requestIdleCallback(callback, options) {
        if (typeof callback !== "function") throw new TypeError("requestIdleCallback requires a callback function.");
        const requested = clock.now();
        const timeout = options && Number(options.timeout) > 0 ? Number(options.timeout) : 0;
        const id = ++next;
        pending.set(id, schedule(() => {
          if (!pending.delete(id)) return;
          const started = clock.now();
          const didTimeout = timeout > 0 && started - requested >= timeout;
          const deadline = Object.freeze({
            didTimeout,
            timeRemaining() { return didTimeout ? 0 : Math.max(0, 50 - (clock.now() - started)); }
          });
          callback.call(undefined, deadline);
        }, 0));
        return id;
      };
      const cancelIdleCallback = function cancelIdleCallback(handle) {
        const timer = pending.get(handle);
        if (timer === undefined) return;
        pending.delete(handle);
        if (typeof unschedule === "function") unschedule(timer);
      };
      for (const [name, value] of [["requestIdleCallback", requestIdleCallback], ["cancelIdleCallback", cancelIdleCallback]]) {
        try { Object.defineProperty(globalThis, name, { value, writable: true, configurable: true, enumerable: true }); } catch (error) {}
      }
    })();
    """#
}
