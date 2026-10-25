import Foundation

/// Some WebKit versions expose select:open and ::picker(select), but not the
/// overlay property. Extension anti-tamper checks can mistake that unavailable
/// style for an open picker. Install only before isolated-world content scripts;
/// the page world and the extension's security checks remain untouched.
enum ExtensionSelectPickerCompatibility {
    static let source = #"""
    (() => {
      "use strict";
      const scope = globalThis;
      const css = scope.CSS;
      const stylePrototype = scope.CSSStyleDeclaration?.prototype;
      const selectPrototype = scope.HTMLSelectElement?.prototype;
      const matches = scope.Element?.prototype?.matches;
      const computed = scope.getComputedStyle;
      const apply = Reflect.apply;
      const marker = Symbol.for("com.ari.bam.select-picker-overlay.v1");
      if (!css || typeof css.supports !== "function" || !stylePrototype || !selectPrototype ||
          typeof matches !== "function" || typeof computed !== "function" || computed[marker]) return;
      try {
        if (css.supports("overlay", "auto") || !css.supports("selector(select:open)")) return;
      } catch (_) { return; }
      const readDescriptor = Object.getOwnPropertyDescriptor(stylePrototype, "getPropertyValue");
      const computedDescriptor = Object.getOwnPropertyDescriptor(scope, "getComputedStyle");
      const selectBrand = Object.getOwnPropertyDescriptor(selectPrototype, "multiple")?.get;
      if (!readDescriptor || typeof readDescriptor.value !== "function" ||
          !computedDescriptor || computedDescriptor.value !== computed || typeof selectBrand !== "function") return;
      const read = readDescriptor.value;
      const styles = new WeakMap();
      const get = WeakMap.prototype.get, set = WeakMap.prototype.set;
      const readOverlay = function (...args) {
        // Preserve native argument validation, coercion, and error behavior.
        const value = apply(read, this, args);
        if (args[0] !== "overlay" || value !== "") return value;
        const select = apply(get, styles, [this]);
        if (!select) return value;
        // :open is maintained by WebKit, including genuinely open native
        // pickers. Sample it on every read because computed styles are live.
        try { return apply(matches, select, ["select:open"]) ? "auto" : "none"; }
        catch (_) { return value; }
      };
      const getComputedStyle = function (...args) {
        const result = apply(computed, this, args);
        if (args[1] !== "::picker(select)") return result;
        try {
          // A native getter checks the DOM brand even across realms; a changed
          // JavaScript prototype must not turn another element into a select.
          apply(selectBrand, args[0], []);
          if (apply(read, result, ["overlay"]) === "") apply(set, styles, [result, args[0]]);
        } catch (_) { /* An unusual native style result remains unchanged. */ }
        return result;
      };
      Object.defineProperty(getComputedStyle, marker, { value: true });
      // Retain the native CSSStyleDeclaration itself, its prototype, accessors,
      // property enumeration, and readonly behavior. No proxy or fake CSS object.
      try {
        Object.defineProperty(stylePrototype, "getPropertyValue", { ...readDescriptor, value: readOverlay });
        try { Object.defineProperty(scope, "getComputedStyle", { ...computedDescriptor, value: getComputedStyle }); }
        catch (_) { Object.defineProperty(stylePrototype, "getPropertyValue", readDescriptor); }
      } catch (_) { /* A non-writable native surface is left intact. */ }
    })();
    """#
}
