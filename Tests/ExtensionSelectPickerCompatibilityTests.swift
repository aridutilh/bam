import Foundation
import JavaScriptCore

@main struct ExtensionSelectPickerCompatibilityTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() {
        do { print("Extension select picker compatibility: \(try run()) checks passed") }
        catch { fputs("FAIL: Extension select picker compatibility: \(error)\n", stderr); exit(1) }
    }

    static let fixture = #"""
    globalThis.calls = [], globalThis.createdStyles = [];
    globalThis.overlaySupported = false, globalThis.openSupported = true;
    const elements = new WeakSet(), selects = new WeakSet(), styles = new WeakMap();
    globalThis.Element = class {
      constructor() { elements.add(this); this.open = false; this.overlay = ""; }
      matches(selector) {
        if (!elements.has(this)) throw new TypeError("Element receiver");
        if (this.matchError) throw this.matchError;
        if (selector !== "select:open") throw new Error("Unexpected selector");
        return selects.has(this) && this.open;
      }
    };
    globalThis.HTMLSelectElement = class extends Element {
      constructor() { super(); selects.add(this); }
      get multiple() { if (!selects.has(this)) throw new TypeError("Select receiver"); return false; }
    };
    globalThis.CSSStyleDeclaration = class {
      constructor(element, pseudo) { styles.set(this, {element, pseudo}); }
      getPropertyValue(property) {
        if (!styles.has(this)) throw new TypeError("Style receiver");
        if (typeof property === "symbol") throw new TypeError("Cannot convert symbol");
        const name = String(property), {element} = styles.get(this);
        calls.push({kind:"read", receiver:this, name});
        if (element.readError) throw element.readError;
        return name === "overlay" ? element.overlay : name === "color" ? "rgb(1, 2, 3)" : "";
      }
      get length() { if (!styles.has(this)) throw new TypeError("Style receiver"); return 1; }
      get cssText() { if (!styles.has(this)) throw new TypeError("Style receiver"); return ""; }
      set cssText(_) { throw new TypeError("Computed style is readonly"); }
      item(index) { if (!styles.has(this)) throw new TypeError("Style receiver"); return index === 0 ? "color" : ""; }
    };
    globalThis.CSS = {supports(property, value) {
      if (this !== CSS) throw new TypeError("CSS receiver");
      return property === "overlay" && value === "auto" ? overlaySupported :
        property === "selector(select:open)" ? openSupported : false;
    }};
    globalThis.getComputedStyle = function (element, pseudo) {
      if (this !== globalThis) throw new TypeError("Window receiver");
      if (!elements.has(element)) throw new TypeError("Element input");
      if (element.styleError) throw element.styleError;
      const style = new CSSStyleDeclaration(element, pseudo);
      calls.push({kind:"computed", receiver:this, args:Array.from(arguments)}); createdStyles.push(style);
      return style;
    };
    globalThis.originalComputed = getComputedStyle;
    globalThis.originalRead = CSSStyleDeclaration.prototype.getPropertyValue;
    globalThis.checks = 0;
    globalThis.check = (condition, message) => { if (!condition) throw new Error(message); checks++; };
    globalThis.throws = (operation, expected, message) => {
      let error; try { operation(); } catch (caught) { error = caught; }
      check(expected ? error === expected : error instanceof TypeError, message);
    };
    """#

    static func run() throws -> Int {
        var total = 0
        func scenario(_ before: String = "", _ body: String) throws {
            let context = JSContext()!
            var failure: String?
            context.exceptionHandler = { _, error in failure = error?.toString() ?? "JavaScript exception" }
            context.evaluateScript(fixture)
            context.evaluateScript(before)
            context.evaluateScript(ExtensionSelectPickerCompatibility.source)
            context.evaluateScript(body)
            if let failure { throw Failure(description: failure) }
            total += Int(context.objectForKeyedSubscript("checks")!.toInt32())
        }
        try scenario("", #"""
        const select = new HTMLSelectElement();
        const style = getComputedStyle(select, "::picker(select)");
        check(style === createdStyles[createdStyles.length - 1] && Object.getPrototypeOf(style) === CSSStyleDeclaration.prototype,
          "Adapter retains native object identity and prototype");
        check(style.getPropertyValue("overlay") === "none", "Closed native picker reports none");
        select.open = true;
        check(style.getPropertyValue("overlay") === "auto", "Already returned style detects newly opened native picker");
        select.open = false;
        check(style.getPropertyValue("overlay") === "none", "Live style detects picker closing");
        check(style.getPropertyValue("color") === "rgb(1, 2, 3)" && style.length === 1 && style.item(0) === "color" && style.cssText === "",
          "Other properties and branded native accessors remain intact");
        throws(() => { style.cssText = "overlay:none"; }, null, "Computed style remains readonly");
        check(!Object.hasOwn(style, "overlay") && style.overlay === undefined && Object.keys(style).length === 0,
          "No synthetic style properties or enumeration changes");
        check(CSS.supports("overlay", "auto") === false, "Native capability reports remain unchanged");
        for (const pseudo of [undefined, "", "::before", "::backdrop", "::picker(other)", " ::picker(select)"]) {
          check(getComputedStyle(select, pseudo).getPropertyValue("overlay") === "", "Unrelated pseudo remains native: " + pseudo);
        }
        const div = new Element();
        check(getComputedStyle(div, "::picker(select)").getPropertyValue("overlay") === "", "Non-select elements remain native");
        const forgedSelect = new Element(); Object.setPrototypeOf(forgedSelect, HTMLSelectElement.prototype);
        check(getComputedStyle(forgedSelect, "::picker(select)").getPropertyValue("overlay") === "", "A forged JavaScript prototype cannot pass native select branding");
        const foreignSelect = new HTMLSelectElement(); Object.setPrototypeOf(foreignSelect, Element.prototype);
        check(getComputedStyle(foreignSelect, "::picker(select)").getPropertyValue("overlay") === "none", "A genuine select without the local select prototype retains native branding");
        const standalone = new CSSStyleDeclaration(select, "::picker(select)");
        check(standalone.getPropertyValue("overlay") === "", "Styles not returned by adapted API remain native");
        select.overlay = "auto";
        check(style.getPropertyValue("overlay") === "auto", "Native nonempty overlay is never overridden");
        const supportedStyle = getComputedStyle(select, "::picker(select)");
        select.overlay = "";
        check(supportedStyle.getPropertyValue("overlay") === "", "A nonempty native style was not registered for adaptation");
        check(style.getPropertyValue("OVERLAY") === "" && style.getPropertyValue("unknown") === "", "Only exact overlay property is normalized");
        let conversions = 0;
        check(style.getPropertyValue({toString(){conversions++;return "overlay";}}) === "" && conversions === 1,
          "Native coercion runs once and object arguments remain unchanged");
        throws(() => style.getPropertyValue(Symbol("overlay")), null, "Native property argument exception is preserved");
        const readError = new Error("native read denied"); select.readError = readError;
        throws(() => style.getPropertyValue("overlay"), readError, "Native style error is preserved"); delete select.readError;
        const matchError = new Error("state unavailable"); select.matchError = matchError;
        check(style.getPropertyValue("overlay") === "", "Unknown native picker state fails closed to original empty style"); delete select.matchError;
        const styleError = new Error("native style failure"); select.styleError = styleError;
        throws(() => getComputedStyle(select, "::picker(select)"), styleError, "Original getComputedStyle exception is preserved"); delete select.styleError;
        throws(() => getComputedStyle.call({}, select, "::picker(select)"), null, "Original Window receiver validation remains");
        throws(() => getComputedStyle({}, "::picker(select)"), null, "Original element validation remains");
        throws(() => CSSStyleDeclaration.prototype.getPropertyValue.call({}, "overlay"), null, "Original style receiver validation remains");
        const untracked = getComputedStyle(div, "::picker(select)");
        check(style.getPropertyValue.call(untracked, "overlay") === "", "Borrowed method uses actual receiver mapping");
        Element.prototype.matches = () => true;
        check(style.getPropertyValue("overlay") === "none", "Later matches replacement cannot spoof native picker state");
        select.open = true;
        check(style.getPropertyValue("overlay") === "auto", "Captured native matcher still observes an open picker");
        globalThis.installedComputed = getComputedStyle; globalThis.installedRead = CSSStyleDeclaration.prototype.getPropertyValue;
        """#)
        // Each scenario owns fresh prototypes so no adapter state leaks between tests.
        try scenario("overlaySupported = true;", #"check(getComputedStyle === originalComputed && CSSStyleDeclaration.prototype.getPropertyValue === originalRead, "Supported overlay engine remains untouched");"#)
        try scenario("openSupported = false;", #"check(getComputedStyle === originalComputed && CSSStyleDeclaration.prototype.getPropertyValue === originalRead, "No native open-state support means no adapter");"#)
        try scenario("delete globalThis.CSS;", #"check(getComputedStyle === originalComputed && CSSStyleDeclaration.prototype.getPropertyValue === originalRead, "Absent CSS environment is unchanged");"#)
        try scenario("Object.defineProperty(globalThis, 'getComputedStyle', {writable:false,configurable:false});", #"check(getComputedStyle === originalComputed && CSSStyleDeclaration.prototype.getPropertyValue === originalRead, "Failed global installation restores original style reader");"#)
        try scenario("Object.defineProperty(CSSStyleDeclaration.prototype, 'getPropertyValue', {writable:false,configurable:false});", #"check(getComputedStyle === originalComputed && CSSStyleDeclaration.prototype.getPropertyValue === originalRead, "Nonwritable reader leaves both APIs unchanged");"#)
        let context = JSContext()!
        context.evaluateScript(fixture)
        context.evaluateScript(ExtensionSelectPickerCompatibility.source)
        context.evaluateScript("globalThis.firstComputed=getComputedStyle; globalThis.firstRead=CSSStyleDeclaration.prototype.getPropertyValue;")
        context.evaluateScript(ExtensionSelectPickerCompatibility.source)
        guard context.evaluateScript("getComputedStyle === firstComputed && CSSStyleDeclaration.prototype.getPropertyValue === firstRead")?.toBool() == true else {
            throw Failure(description: "Repeated adapter injection changed API identity")
        }
        return total + 1
    }
}
