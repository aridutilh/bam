import AppKit
import QuartzCore
import WebKit

/// What Hide Elements has hidden, per site, by CSS selector. The rules reach
/// pages as one WebKit content rule list (`css-display-none`), which WebKit
/// applies before the page's first paint, so a hidden banner never flashes.
@MainActor final class HiddenElementStore {
    static let defaultsKey = "HiddenElements"
    private(set) var rules: [String: [String]] = [:]
    private let persists: Bool
    private let ruleStore: WKContentRuleListStore?
    private var ruleList: WKContentRuleList?
    private var compileGeneration = 0
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private static let identifier = "BamHiddenElements"

    init(persists: Bool) {
        self.persists = persists
        if persists {
            ruleStore = WKContentRuleListStore.default()
            if let saved = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: [String]] { rules = saved }
        } else {
            // A disposable session keeps its compiled rules out of the real profile's store.
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("BamHiddenElements-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            ruleStore = WKContentRuleListStore(url: folder)
        }
        compile()
    }

    /// Sites are matched without "www.", so example.com and www.example.com share rules.
    static func site(for url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    func selectors(for site: String) -> [String] { rules[site] ?? [] }

    /// Every page's content controller, so rule changes reach open tabs as well as new ones.
    func attach(_ controller: WKUserContentController) {
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        if let ruleList { controller.add(ruleList) }
    }

    func add(_ selector: String, site: String) {
        var list = rules[site] ?? []
        guard !list.contains(selector) else { return }
        list.append(selector); rules[site] = list
        changed()
    }

    func remove(_ selector: String, site: String) {
        guard var list = rules[site], let index = list.firstIndex(of: selector) else { return }
        list.remove(at: index); rules[site] = list.isEmpty ? nil : list
        changed()
    }

    /// `installed` runs once open pages' controllers carry the new rules.
    func removeAll(site: String, installed: (() -> Void)? = nil) {
        guard rules.removeValue(forKey: site) != nil else { installed?(); return }
        changed(installed: installed)
    }

    private func changed(installed: (() -> Void)? = nil) {
        if persists { UserDefaults.standard.set(rules, forKey: Self.defaultsKey) }
        compile(installed: installed)
    }

    static func encodedRules(_ rules: [String: [String]]) -> String? {
        let entries: [[String: Any]] = rules.keys.sorted().compactMap { site in
            guard let selectors = rules[site], !selectors.isEmpty else { return nil }
            return ["trigger": ["url-filter": ".*", "if-domain": ["*" + site]],
                    "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")]]
        }
        guard !entries.isEmpty, let data = try? JSONSerialization.data(withJSONObject: entries) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func compile(installed: (() -> Void)? = nil) {
        compileGeneration += 1
        let generation = compileGeneration
        guard let encoded = Self.encodedRules(rules), let ruleStore else { install(nil); installed?(); return }
        ruleStore.compileContentRuleList(forIdentifier: Self.identifier, encodedContentRuleList: encoded) { [weak self] list, error in
            DispatchQueue.main.async {
                guard let self, self.compileGeneration == generation else { return }
                if let error { NSLog("Bam: hidden elements rules did not compile: \(error.localizedDescription)") }
                self.install(list)
                installed?()
            }
        }
    }

    private func install(_ list: WKContentRuleList?) {
        for controller in controllers.allObjects {
            if let ruleList { controller.remove(ruleList) }
            if let list { controller.add(list) }
        }
        ruleList = list
    }
}

/// The ⇧⌘H picker over one page: a crosshair outlines what the pointer is
/// over, a click hides it (with a dust-off), ⌘Z brings back the last, and
/// Esc (or ⇧⌘H again) finishes. The page itself never sees these clicks.
@MainActor final class HideElementsPicker: NSView {
    let web: WKWebView
    let site: String
    var onHide: ((String) -> Void)?
    var onRestore: ((String) -> Void)?
    var onFinish: (() -> Void)?

    private let outline = NSView()
    private let hint = HideElementsHint()
    private var hiddenSelectors: [String] = []
    private var lastPoint: NSPoint?
    private var pickInFlight = false
    private var pendingPick = false
    private var current: (selector: String, rect: NSRect)?
    private var tracking: NSTrackingArea?
    private var navigationObservation: NSKeyValueObservation?
    private var finished = false
    static let world = WKContentWorld.world(name: "BamPageTools")

    init(web: WKWebView, site: String) {
        self.web = web; self.site = site
        super.init(frame: web.bounds)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        identifier = NSUserInterfaceItemIdentifier("page.hideElements")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Hide Elements. Click a part of the page to hide it. Command-Z brings back the last; Escape finishes.")
        outline.wantsLayer = true
        outline.layer?.cornerRadius = 5
        outline.layer?.borderWidth = 2
        outline.isHidden = true
        addSubview(outline)
        addSubview(hint)
        applyColors()
        navigationObservation = web.observe(\.url, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.finish() }
        }
    }
    required init?(coder: NSCoder) { fatalError("Created programmatically") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func begin() {
        web.addSubview(self, positioned: .above, relativeTo: nil)
        window?.makeFirstResponder(self)
        layoutHint()
        hint.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = BamTheme.reduceMotion ? 0 : 0.18
            hint.animator().alphaValue = 1
        }
        if let window, let point = Optional(convert(window.mouseLocationOutsideOfEventStream, from: nil)), bounds.contains(point) {
            requestPick(at: point)
        }
        NSCursor.crosshair.set()
    }

    func finish() {
        guard !finished else { return }
        finished = true
        navigationObservation = nil
        let web = self.web
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = BamTheme.reduceMotion ? 0 : 0.14
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasFirst = self.window?.firstResponder === self
                let window = self.window
                self.removeFromSuperview()
                if wasFirst { window?.makeFirstResponder(web) }
                NSCursor.arrow.set()
            }
        })
        onFinish?()
    }

    override func layout() {
        super.layout()
        layoutHint()
    }

    /// Switching tabs or Spaces takes the page out of the window: the picker ends with it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil, !finished, superview != nil else { return }
        finished = true
        navigationObservation = nil
        removeFromSuperview()
        onFinish?()
    }

    private func layoutHint() {
        let size = hint.fittingSize
        hint.frame = NSRect(x: round((bounds.width - size.width) / 2), y: max(8, bounds.height - size.height - 18),
                            width: size.width, height: size.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        outline.layer?.borderColor = bamCG(BamTheme.red)
        outline.layer?.backgroundColor = bamCG(BamTheme.red.withAlphaComponent(0.12))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area); tracking = area
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseExited(with event: NSEvent) { setOutline(nil) }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        let point = convert(event.locationInWindow, from: nil)
        if hint.frame.contains(point) { setOutline(nil); return }
        requestPick(at: point)
    }

    override func scrollWheel(with event: NSEvent) {
        web.scrollWheel(with: event)
        let point = convert(event.locationInWindow, from: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.requestPick(at: point) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hint.frame.contains(point) { finish(); return }
        hideCurrent(at: point)
    }
    override func rightMouseDown(with event: NSEvent) { finish() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53, 36, 76: finish() // Esc, Return, Enter
        case 126: walk("up")    // ↑ picks the enclosing element
        case 125: walk("down")  // ↓ goes back toward the pointer
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !finished, window?.isKeyWindow == true else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "z" { undoLast(); return true }
        return false
    }

    // MARK: Page side

    private var pointScale: CGFloat { max(0.1, web.pageZoom * web.magnification) }

    private func requestPick(at point: NSPoint) {
        lastPoint = point
        guard !pickInFlight else { pendingPick = true; return }
        pickInFlight = true
        let scale = pointScale
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = try? await self.web.callAsyncJavaScript(HideElementsScript.source + "return __bamHide.pick(x, y);",
                arguments: ["x": point.x / scale, "y": point.y / scale], in: nil, contentWorld: Self.world)
            self.pickInFlight = false
            guard !self.finished else { return }
            self.apply(pick: result as? [String: Any])
            if self.pendingPick, let next = self.lastPoint { self.pendingPick = false; self.requestPick(at: next) }
        }
    }

    private func walk(_ direction: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = try? await self.web.callAsyncJavaScript(HideElementsScript.source + "return __bamHide.walk(direction);",
                arguments: ["direction": direction], in: nil, contentWorld: Self.world)
            self.apply(pick: result as? [String: Any])
        }
    }

    private func rect(from value: Any?) -> NSRect? {
        guard let box = value as? [String: Any], let x = box["x"] as? Double, let y = box["y"] as? Double,
              let w = box["w"] as? Double, let h = box["h"] as? Double, w > 0, h > 0 else { return nil }
        let s = pointScale
        return NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }

    private func apply(pick: [String: Any]?) {
        guard let pick, let selector = pick["selector"] as? String, let rect = rect(from: pick["rect"]) else {
            current = nil; setOutline(nil); return
        }
        current = (selector, rect)
        setOutline(rect)
    }

    private func setOutline(_ rect: NSRect?) {
        guard let rect else {
            if !outline.isHidden {
                NSAnimationContext.runAnimationGroup { $0.duration = 0.08; outline.animator().alphaValue = 0 }
            }
            outline.isHidden = true
            return
        }
        let target = rect.insetBy(dx: -2, dy: -2).intersection(bounds.insetBy(dx: 1, dy: 1))
        guard !target.isNull else { setOutline(nil); return }
        if outline.isHidden || BamTheme.reduceMotion {
            outline.frame = target; outline.isHidden = false; outline.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1)
                outline.animator().frame = target
                outline.animator().alphaValue = 1
            }
        }
    }

    private func hideCurrent(at point: NSPoint) {
        guard let current else { requestPick(at: point); return }
        self.current = nil
        let rect = current.rect.intersection(bounds)
        outline.isHidden = true
        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = rect
        snapshot.afterScreenUpdates = false
        web.takeSnapshot(with: snapshot) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in
                    let result = try? await self.web.callAsyncJavaScript(HideElementsScript.source + "return __bamHide.hide(selector);",
                        arguments: ["selector": current.selector], in: nil, contentWorld: Self.world)
                    guard let selector = result as? String else { return }
                    if let image, !rect.isEmpty { DustEffect.run(image: image, frame: rect, in: self.web, below: self) }
                    self.hiddenSelectors.append(selector)
                    self.onHide?(selector)
                    if let point = self.lastPoint { self.requestPick(at: point) }
                }
            }
        }
    }

    private func undoLast() {
        guard let selector = hiddenSelectors.popLast() else { NSSound.beep(); return }
        onRestore?(selector)
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.web.callAsyncJavaScript(HideElementsScript.source + "return __bamHide.restore(selector);",
                arguments: ["selector": selector], in: nil, contentWorld: Self.world)
            if let point = self.lastPoint { self.requestPick(at: point) }
        }
    }
}

/// "Click what should go · ⌘Z brings back the last · esc when done"
@MainActor private final class HideElementsHint: NSView {
    private let glass = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.material = .hudWindow; glass.blendingMode = .withinWindow; glass.state = .active
        glass.wantsLayer = true; glass.layer?.cornerRadius = 15; glass.layer?.masksToBounds = true
        addSubview(glass)
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 10; layer?.shadowOffset = CGSize(width: 0, height: -3)
        let text = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let quiet: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        text.append(NSAttributedString(string: "Click what should go", attributes: body))
        text.append(NSAttributedString(string: "   ⌘Z brings back the last   esc when done", attributes: quiet))
        label.attributedStringValue = text
        label.isSelectable = false
        addSubview(label)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let size = label.attributedStringValue.size()
        return NSSize(width: ceil(size.width) + 36, height: 32)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 15, cornerHeight: 15, transform: nil)
        let height = ceil(label.attributedStringValue.size().height) + 2
        label.frame = NSRect(x: 18, y: (bounds.height - height) / 2, width: bounds.width - 32, height: height)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The hidden element crumbles into dust that drifts up and away, sweeping
/// from one side, while the page has already closed up beneath it.
@MainActor enum DustEffect {
    static func run(image: NSImage, frame: NSRect, in host: NSView, below sibling: NSView?) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), frame.width >= 1, frame.height >= 1 else { return }
        let stage = DustStage(frame: frame)
        if let sibling, sibling.superview === host { host.addSubview(stage, positioned: .below, relativeTo: sibling) }
        else { host.addSubview(stage) }
        guard let root = stage.layer else { stage.removeFromSuperview(); return }
        if BamTheme.reduceMotion {
            let layer = CALayer(); layer.frame = stage.bounds; layer.contents = cg; root.addSublayer(layer)
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; stage.animator().alphaValue = 0 },
                                                 completionHandler: { stage.removeFromSuperview() })
            return
        }
        let w = frame.width, h = frame.height
        // About 1,600 grains at most, never finer than 3 points.
        let grain = max(3, ceil(sqrt(w * h / 1600)))
        let columns = Int(ceil(w / grain)), rows = Int(ceil(h / grain))
        let pxX = CGFloat(cg.width) / w, pxY = CGFloat(cg.height) / h
        let sweep: Double = min(0.55, 0.25 + Double(w) / 2400)
        var longest: Double = 0
        CATransaction.begin()
        for row in 0..<rows {
            for column in 0..<columns {
                let x = CGFloat(column) * grain, y = CGFloat(row) * grain
                let tile = NSRect(x: x, y: y, width: min(grain, w - x), height: min(grain, h - y))
                guard let piece = cg.cropping(to: CGRect(x: tile.minX * pxX, y: tile.minY * pxY,
                                                         width: tile.width * pxX, height: tile.height * pxY)) else { continue }
                let layer = CALayer()
                layer.frame = tile
                layer.contents = piece
                layer.contentsScale = pxX
                root.addSublayer(layer)
                let delay = Double(x / w) * sweep + Double.random(in: 0...0.12) + Double(y / h) * 0.04
                let duration = Double.random(in: 0.5...0.85)
                longest = max(longest, delay + duration)
                let drift = CABasicAnimation(keyPath: "transform")
                var t = CATransform3DMakeTranslation(CGFloat.random(in: 16...64), CGFloat.random(in: -54 ... -8), 0)
                t = CATransform3DRotate(t, CGFloat.random(in: -0.9...0.9), 0, 0, 1)
                t = CATransform3DScale(t, 0.35, 0.35, 1)
                drift.toValue = NSValue(caTransform3D: t)
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.toValue = 0
                let group = CAAnimationGroup()
                group.animations = [drift, fade]
                group.beginTime = CACurrentMediaTime() + delay
                group.duration = duration
                group.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.0, 0.6, 1)
                group.fillMode = .both
                group.isRemovedOnCompletion = false
                layer.add(group, forKey: "dust")
            }
        }
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + longest + 0.05) { stage.removeFromSuperview() }
    }
}

@MainActor private final class DustStage: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Page-side helpers, run in Bam's own content world so the page's scripts
/// can neither see nor tamper with them.
enum HideElementsScript {
    static let source = #"""
    if (!window.__bamHide) {
      const stableID = (id) => /^[A-Za-z][\w-]{1,48}$/.test(id) && !/\d{4,}/.test(id) && !/^(ember|react|radix|headlessui|mui|yui|ext-gen)/i.test(id);
      const stableClass = (c) => /^[A-Za-z][\w-]{1,40}$/.test(c) && !/\d{3,}/.test(c) && !/[0-9a-f]{6,}/i.test(c)
        && !/(^css-|^sc-|^jsx-|^svelte-|^tw-|__[A-Za-z0-9]{5}$|^is-|^has-|hover|active|focus|open|visible|hidden|show)/.test(c);
      const unique = (sel, el) => { try { const all = document.querySelectorAll(sel); return all.length === 1 && all[0] === el; } catch (e) { return false; } };
      const matches = (sel, el) => { try { return document.querySelector(sel) === el; } catch (e) { return false; } };
      const part = (el, withIndex) => {
        let s = el.localName;
        if (!/^[a-z][a-z0-9-]*$/.test(s)) s = '*';
        const classes = Array.from(el.classList || []).filter(stableClass).slice(0, 3);
        for (const c of classes) s += '.' + CSS.escape(c);
        if (withIndex && el.parentElement) {
          const same = Array.from(el.parentElement.children).filter((n) => n.localName === el.localName);
          if (same.length > 1) s += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
        }
        return s;
      };
      const selectorFor = (el) => {
        if (el.id && stableID(el.id) && unique('#' + CSS.escape(el.id), el)) return '#' + CSS.escape(el.id);
        const plain = [], indexed = [];
        let node = el;
        for (let depth = 0; node && node.nodeType === 1 && node !== document.documentElement && depth < 8; depth++) {
          if (node !== el && node.id && stableID(node.id)) {
            const anchor = '#' + CSS.escape(node.id);
            if (unique(anchor, node)) { plain.unshift(anchor); indexed.unshift(anchor); break; }
          }
          if (node.localName === 'body') { plain.unshift('body'); indexed.unshift('body'); break; }
          plain.unshift(part(node, false)); indexed.unshift(part(node, true));
          const a = plain.join(' > '); if (unique(a, el)) return a;
          const b = indexed.join(' > '); if (unique(b, el)) return b;
          node = node.parentElement;
        }
        const last = indexed.join(' > ');
        return matches(last, el) ? last : null;
      };
      const box = (el) => { const r = el.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height }; };
      const meaningful = (el) => {
        // The outermost wrapper that is the same box as what is under the pointer.
        while (el.parentElement && el.parentElement !== document.body && el.parentElement !== document.documentElement) {
          const a = el.getBoundingClientRect(), b = el.parentElement.getBoundingClientRect();
          if (Math.abs(a.left - b.left) > 2 || Math.abs(a.top - b.top) > 2 || Math.abs(a.width - b.width) > 4 || Math.abs(a.height - b.height) > 4) break;
          el = el.parentElement;
        }
        return el;
      };
      const state = { el: null, trail: [], hidden: [] };
      const report = (el) => {
        if (!el) { state.el = null; return null; }
        const selector = selectorFor(el);
        if (!selector) { state.el = null; return null; }
        state.el = el;
        return { selector, rect: box(el), tag: el.localName };
      };
      window.__bamHide = {
        pick(x, y) {
          let el = document.elementFromPoint(x, y);
          if (!el || el === document.documentElement || el === document.body) { state.trail = []; return report(null); }
          el = meaningful(el);
          const v = box(el);
          if (v.w >= innerWidth - 2 && v.h >= innerHeight - 2 && (el.parentElement === document.body)) { state.trail = []; return report(null); }
          state.trail = [];
          return report(el);
        },
        walk(direction) {
          if (!state.el) return null;
          if (direction === 'up') {
            const parent = state.el.parentElement;
            if (!parent || parent === document.body || parent === document.documentElement) return report(state.el);
            state.trail.push(state.el); return report(parent);
          }
          const child = state.trail.pop();
          return report(child || state.el);
        },
        hide(selector) {
          let el = null; try { el = document.querySelector(selector); } catch (e) {}
          if (!el) return null;
          state.hidden.push({ selector, el, display: el.style.getPropertyValue('display'), priority: el.style.getPropertyPriority('display') });
          el.style.setProperty('display', 'none', 'important');
          state.el = null;
          return selector;
        },
        restore(selector) {
          for (let i = state.hidden.length - 1; i >= 0; i--) {
            const entry = state.hidden[i];
            if (entry.selector !== selector) continue;
            state.hidden.splice(i, 1);
            if (entry.display) entry.el.style.setProperty('display', entry.display, entry.priority);
            else entry.el.style.removeProperty('display');
            entry.el.animate && entry.el.animate([{ opacity: 0, transform: 'scale(0.98)' }, { opacity: 1, transform: 'none' }], { duration: 220, easing: 'cubic-bezier(.22,.61,.36,1)' });
            return true;
          }
          return false;
        },
        restoreAll() {
          for (const entry of state.hidden.splice(0)) {
            if (entry.display) entry.el.style.setProperty('display', entry.display, entry.priority);
            else entry.el.style.removeProperty('display');
          }
          return true;
        },
        count(selectors) {
          let n = 0; for (const s of selectors) { try { if (document.querySelector(s)) n++; } catch (e) {} } return n;
        }
      };
    }

    """#
}
