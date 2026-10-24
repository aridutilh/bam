import Foundation
import JavaScriptCore

@main enum TabResourcePolicyTests {
    @MainActor static func main() {
        var checks = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checks += 1
        }
        let policy = TabResourcePolicy()
        let now: TimeInterval = 2_000
        let tabs = (0..<7).map { index in
            TabResourcePolicy.Candidate(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                                        address: "https://example.com/\(index)", lastUsedAt: Double(index * 100))
        }
        func eligible(_ input: [TabResourcePolicy.Candidate], at time: TimeInterval = 2_000,
                      pressure: TabResourcePolicy.Pressure = .critical, downloads: Bool = false) -> [UUID] {
            policy.candidates(input, now: time, pressure: pressure, hasActiveDownloads: downloads).map(\.id)
        }
        require(eligible(tabs) == Array(tabs.prefix(4)).map(\.id), "Critical pressure orders oldest eligible tabs and protects latest three")
        require(eligible(tabs, pressure: .normal).isEmpty, "Normal pressure cannot sleep tabs")
        require(eligible(tabs, pressure: .warning).isEmpty, "Warning pressure cannot sleep tabs")
        require(eligible(tabs, downloads: true).isEmpty, "Any active download protects every page")
        require(eligible(Array(tabs.suffix(3))).isEmpty, "The only three loaded pages remain protected despite age")
        require(eligible(tabs.reversed()) == eligible(tabs), "Input/sidebar order cannot change eviction recency")
        let flags: [WritableKeyPath<TabResourcePolicy.Candidate, Bool>] = [
            \.isVisible, \.isPictureInPicture, \.isSaved, \.isLoading, \.hasError,
            \.hasPendingNavigation, \.hasRetainedPeek, \.hasHistory, \.siteKeepAwake
        ]
        for flag in flags {
            var protected = tabs; protected[0][keyPath: flag] = true
            require(!eligible(protected).contains(tabs[0].id), "A native protection flag must prevent candidate selection: \(flag)")
        }
        var unloaded = tabs; unloaded[0].isLoaded = false
        require(!eligible(unloaded).contains(tabs[0].id), "An already unloaded record cannot be slept twice")
        var unknown = tabs; unknown[0].lastUsedAt = nil
        require(!eligible(unknown).contains(tabs[0].id), "Unknown activity time remains protected")
        for invalidTime in [Double.nan, .infinity, -1, now + 1] {
            var invalid = tabs; invalid[0].lastUsedAt = invalidTime
            require(!eligible(invalid).contains(tabs[0].id), "Invalid or future recency cannot be treated as old")
        }
        require(eligible(tabs, at: .nan).isEmpty && eligible(tabs, at: -1).isEmpty, "An invalid injected clock authorizes nothing")
        var boundary = tabs
        boundary[0].lastUsedAt = 1_400
        for i in 1..<7 { boundary[i].lastUsedAt = Double(1_500 + i) }
        require(eligible(boundary).contains(tabs[0].id), "Exactly ten idle minutes qualifies beyond the three recent pages")
        boundary[0].lastUsedAt = 1_400.001
        require(!eligible(boundary).contains(tabs[0].id), "Less than ten minutes remains protected")
        var duplicates = tabs; duplicates.append(tabs[0])
        require(!eligible(duplicates).contains(tabs[0].id), "Ambiguous duplicate tab identities remain protected")
        for address in ["file:///tmp/test.html", "orbit://newtab", "javascript:alert(1)", "https://user:password@example.com/"] {
            var unsupported = tabs; unsupported[0].address = address
            require(!eligible(unsupported).contains(tabs[0].id), "Unsupported/credential-bearing URL is not an automatic sleep candidate")
        }
        let evidence = TabActivityEvidence(address: tabs[0].address, documentToken: "document-one", observedAt: now - 0.1, reasons: [])
        func permits(_ activity: TabActivityEvidence?, current: [TabResourcePolicy.Candidate]? = nil,
                     pressure: TabResourcePolicy.Pressure = .critical, downloads: Bool = false) -> Bool {
            policy.permitsSleeping(tabs[0], among: current ?? tabs, activity: activity, now: now,
                                   pressure: pressure, hasActiveDownloads: downloads)
        }
        require(permits(evidence), "Fresh matching safe evidence permits one revalidated candidate")
        require(!permits(nil), "Missing/timed-out probe never implies safety")
        var changed = evidence; changed.reasons = ["user-interaction"]
        require(!permits(changed), "Sticky interaction prevents sleep")
        changed = evidence; changed.documentToken = ""
        require(!permits(changed), "Missing document identity prevents sleep")
        changed = evidence; changed.address = "https://example.com/new"
        require(!permits(changed), "A response from a different URL cannot authorize sleep")
        for timestamp in [now - 1.001, now + 0.001, .nan, .infinity] {
            changed = evidence; changed.observedAt = timestamp
            require(!permits(changed), "Stale/future/invalid evidence is rejected")
        }
        var selectedWhileProbing = tabs; selectedWhileProbing[0].isVisible = true
        require(!permits(evidence, current: selectedWhileProbing), "Selection during an asynchronous probe invalidates the candidate")
        var usedWhileProbing = tabs; usedWhileProbing[0].lastUsedAt = now
        require(!permits(evidence, current: usedWhileProbing), "New activity during a probe invalidates prior recency")
        require(!permits(evidence, pressure: .normal) && !permits(evidence, downloads: true), "Pressure recovery or a new download cancels permission")
        require(!permits(evidence, current: Array(tabs.dropFirst())), "A removed tab cannot be slept after its probe returns")

        // Execute the actual isolated-world tracker in a minimal DOM-shaped
        // JavaScriptCore fixture. These are logic tests, not WebKit lifecycle tests.
        let environment = #"""
        globalThis.window=globalThis; globalThis.scrollX=12; globalThis.scrollY=34; globalThis.frames=[];
        globalThis.navigator={}; globalThis.crypto={randomUUID:()=> 'fixture-document'};
        globalThis.performance={timeOrigin:1}; globalThis.listeners={};
        globalThis.hasForm=false; globalThis.hasFrame=false; globalThis.media=[];
        globalThis.node=(tag,attrs=[])=>({nodeType:1,tagName:tag,attributes:attrs,children:[],
          getAttribute(name){return this.attributes.find(a=>a.name===name)?.value ?? null},
          querySelectorAll(){return this.children}});
        globalThis.document={URL:'https://example.com/0',readyState:'complete',designMode:'off',documentElement:node('html'),
          addEventListener(name,callback){listeners[name]=callback},
          querySelector(selector){return selector.startsWith('iframe')?(hasFrame?{}:null):(hasForm?{}:null)},
          querySelectorAll(selector){return selector==='audio,video'?media:[]}};
        globalThis.disconnections=0;
        globalThis.MutationObserver=class {constructor(callback){globalThis.mutationCallback=callback} observe(){} disconnect(){disconnections++}};
        """#
        func context(before: String = "") -> JSContext {
            guard let context = JSContext() else { fatalError("JavaScriptCore unavailable") }
            context.evaluateScript(environment + before)
            context.evaluateScript(TabActivityProbe.trackerSource)
            require(context.exception == nil, "Tracker must initialize without a JavaScript exception")
            return context
        }
        func snapshot(_ context: JSContext) -> TabActivityProbe.Snapshot? {
            TabActivityProbe.decode(context.evaluateScript(TabActivityProbe.querySource)?.toObject())
        }
        let plain = context()
        require(snapshot(plain)?.evidence.isSafeToSleep == true, "A ready plain document has no activity protection reasons")
        require(snapshot(plain)?.scrollX == 12 && snapshot(plain)?.scrollY == 34, "Probe preserves both scroll coordinates")
        require(snapshot(plain)?.documentToken == "fixture-document", "Probe includes a stable per-document token")
        require(snapshot(plain)?.evidence.observedAt.isNaN == true, "Decoded JS alone cannot manufacture a fresh native timestamp")
        plain.evaluateScript("listeners.pointerdown({isTrusted:false})")
        require(snapshot(plain)?.evidence.isSafeToSleep == true, "Synthetic page events cannot forge a trusted user interaction")
        plain.evaluateScript("listeners.keydown({isTrusted:true})")
        require(snapshot(plain)?.evidence.reasons.contains("user-interaction") == true, "Trusted keyboard interaction latches protection")
        plain.evaluateScript(TabActivityProbe.trackerSource)
        require(snapshot(plain)?.evidence.reasons.contains("user-interaction") == true, "Repeated installation cannot clear interaction state")
        require(plain.evaluateScript("listeners.scroll===undefined && listeners.wheel===undefined")?.toBool() == true, "Passive scrolling is not mistaken for unsaved editing")
        for event in ["input", "change", "pointerdown", "paste", "drop", "submit"] {
            let page = context(); page.evaluateScript("listeners.\(event)({isTrusted:true})")
            require(snapshot(page)?.evidence.reasons.contains("user-interaction") == true, "Trusted \(event) must protect the document")
        }
        let dynamic = context()
        dynamic.evaluateScript("mutationCallback([{type:'childList',addedNodes:[node('script')],removedNodes:[]}])")
        require(snapshot(dynamic)?.evidence.reasons.contains("executable-script-or-inline-handler") == true, "A transient inserted script remains protected after removal")
        require(dynamic.evaluateScript("disconnections===1")?.toBool() == true, "First script permanently disconnects mutation tracking")
        dynamic.evaluateScript("document.documentElement.children=null; Object.defineProperty(document.documentElement,'children',{get(){throw Error('must not rescan')}})")
        require(snapshot(dynamic)?.evidence.reasons.contains("executable-script-or-inline-handler") == true, "Protected script documents are not rescanned by later probes")
        let localAttribute = context()
        localAttribute.evaluateScript("var target=node('div'); Object.defineProperty(target,'children',{get(){throw Error('subtree scan')}}); mutationCallback([{type:'attributes',target,attributeName:'class',oldValue:''}]);")
        require(snapshot(localAttribute)?.evidence.isSafeToSleep == true, "An attribute mutation inspects only its target")
        let duplicateSubtree = context()
        duplicateSubtree.evaluateScript("var elementInspections=0, target=node('div'); Object.defineProperty(target,'tagName',{get(){elementInspections++;return 'div'}}); mutationCallback([{type:'childList',addedNodes:[target],removedNodes:[target]},{type:'childList',addedNodes:[target],removedNodes:[]}]);")
        require(duplicateSubtree.evaluateScript("elementInspections===1")?.toBool() == true, "Repeated added/removed subtree records inspect each element at most once per batch")
        require(plain.evaluateScript("disconnections===1")?.toBool() == true, "Trusted user interaction disconnects the mutation observer")
        for setup in [
            "document.documentElement.children=[node('script')];",
            "document.documentElement.children=[node('a',[{name:'onclick',value:'saveDraft()'}])];",
            "document.documentElement.children=[node('a',[{name:'href',value:' javascript:work()'}])];"
        ] {
            let page = context(before: setup)
            require(snapshot(page)?.evidence.reasons.contains("executable-script-or-inline-handler") == true, "Executable script and inline capability remain protected")
        }
        let inert = context(before: "document.documentElement.children=[node('script',[{name:'type',value:'application/ld+json'}])];")
        require(snapshot(inert)?.evidence.isSafeToSleep == true, "Inert JSON metadata alone does not imply running page code")
        for setup in [
            "document.documentElement.children=[node('template')];",
            "document.documentElement.children=[node('account-editor')];",
            "document.documentElement.children=[node('button',[{name:'is',value:'saved-editor'}])];",
            "document.documentElement.shadowRoot={children:[node('input')]};"
        ] {
            let page = context(before: setup)
            require(snapshot(page)?.evidence.reasons.contains("shadow-or-template-content") == true, "Templates, custom elements and open shadow roots remain protected")
        }
        let removedComponent = context()
        removedComponent.evaluateScript("mutationCallback([{type:'childList',addedNodes:[],removedNodes:[node('template')]}])")
        require(snapshot(removedComponent)?.evidence.reasons.contains("shadow-or-template-content") == true, "Removed template content cannot erase component uncertainty")
        require(removedComponent.evaluateScript("disconnections===1")?.toBool() == true, "Component uncertainty disconnects passive tracking")
        let removedHandler = context()
        removedHandler.evaluateScript("mutationCallback([{type:'attributes',target:node('a'),attributeName:'onclick',oldValue:'work()'}])")
        require(snapshot(removedHandler)?.evidence.isSafeToSleep == false, "Removing a handler cannot erase earlier script capability")
        for (setup, reason) in [
            ("document.readyState='loading';", "document-loading"),
            ("hasForm=true;", "form-or-editable"),
            ("document.designMode='on';", "form-or-editable"),
            ("frames=[{}];", "frames"),
            ("navigator.serviceWorker={controller:{}};", "service-worker"),
            ("media=[{paused:false,ended:false}];", "playing-media")
        ] {
            let page = context(); page.evaluateScript(setup)
            require(snapshot(page)?.evidence.reasons.contains(reason) == true, "Probe must expose \(reason) protection")
        }
        let removedFrame = context()
        removedFrame.evaluateScript("mutationCallback([{type:'childList',addedNodes:[],removedNodes:[node('iframe')]}])")
        require(snapshot(removedFrame)?.evidence.reasons.contains("frames") == true, "A transient frame remains conservatively protected")
        let broken = context(before: "MutationObserver=class { constructor(){throw Error('fixture')} };")
        require(snapshot(broken)?.evidence.reasons.contains("tracker-unknown") == true, "Observation failure cannot appear safe")
        let invalid = context(); invalid.evaluateScript("scrollY=NaN")
        require(snapshot(invalid) == nil, "Nonfinite restoration geometry rejects the response")
        require(TabActivityProbe.decode(nil) == nil && TabActivityProbe.decode(["version":1]) == nil, "Missing or malformed tracker response is unknown")
        var malformed: [String: Any] = ["version":1,"url":"https://example.com","documentToken":"doc","scrollX":0.0,"scrollY":0.0,"reasons":"not an array"]
        require(TabActivityProbe.decode(malformed) == nil, "Malformed reason payload cannot become an empty safe array")
        malformed["reasons"] = [String](); malformed["documentToken"] = ""
        require(TabActivityProbe.decode(malformed) == nil, "An empty document identity is rejected")
        print("PASS: \(checks) tab resource policy and passive tracker checks")
    }
}
