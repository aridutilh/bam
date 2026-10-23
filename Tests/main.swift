import Foundation
var count = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) }; count += 1 }
expect(URLInput.resolve(" example.com ") == "https://example.com", "Bare host")
expect(URLInput.resolve("http://localhost:8123/a") == "http://localhost:8123/a", "Local navigation")
expect(URLInput.resolve("javascript:alert(1)") == nil, "No executable address input")
expect(URLInput.resolve("file:///etc/passwd") == nil, "No implicit local file browsing")
expect(URLInput.resolve("https://user:secret@example.com") == nil, "No embedded credentials")
let query = URLComponents(string: URLInput.resolve("native mac & swift")!)!.queryItems!.first!.value
expect(query == "native mac & swift", "Search encoding")
var s = BrowserSession.fresh()
let initial = s.tabs.count
let new = s.add(); expect(s.activeID == new && s.tabs.count == initial + 1, "New tab selection")
s.changeSpace(1); expect(s.active?.space == 1, "Space isolation")
let old = s.activeID; s.close(old); expect(s.active != nil && s.active?.space == 1, "Close last space tab creates home")
s.select(new); expect(s.space == 0, "Selecting changes workspace")
s.sidebarWidth = 900; s.tabs.append(s.tabs[0]); s.sanitize()
expect(s.sidebarWidth == 500 && Set(s.tabs.map(\.id)).count == s.tabs.count, "Persisted state sanitation")
let file = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("unit-session.json")
try SessionFile.save(s, to: file)
let restored = SessionFile.load(file)
expect(restored.tabs == s.tabs && restored.activeID == s.activeID, "Atomic persistence roundtrip")

// Address regressions: preserve URLs rather than treating them as search terms.
expect(URLInput.resolve(" \n\t ") == nil, "Empty address does not navigate")
expect(URLInput.resolve("about:blank") == "orbit://newtab", "Blank maps to the internal home page")
expect(URLInput.resolve("localhost:8123/path?q=1") == "http://localhost:8123/path?q=1", "Bare localhost retains its port and path")
expect(URLInput.resolve("127.0.0.1:8123/path") == "http://127.0.0.1:8123/path", "Bare loopback uses HTTP")
expect(URLInput.resolve("[::1]:8123/path") == "http://[::1]:8123/path", "IPv6 loopback is a URL")
let escapedAddress = "https://example.com/a%20b?q=a%2Bb#fragment"
expect(URLInput.resolve(escapedAddress) == escapedAddress, "Existing escapes, query, and fragment survive")
expect(URLInput.resolve("ftp://example.com/file") == nil, "Unsupported explicit scheme is not silently rewritten")
expect(URLInput.resolve("https://") == nil, "Malformed explicit URL does not become a search")
let punctuationQuery = "Swift & AppKit #1 + 50%?"
let punctuationURL = URLComponents(string: URLInput.resolve(punctuationQuery)!)!
expect(punctuationURL.host == "duckduckgo.com" && punctuationURL.queryItems?.first?.value == punctuationQuery, "Search punctuation is encoded exactly once")

// Closing a different tab must not change the current selection.
var closing = BrowserSession.fresh()
let selectedBeforeClose = closing.activeID
let inactiveID = closing.tabs.first { $0.id != selectedBeforeClose && $0.space == closing.space }!.id
let removedInactive = closing.close(inactiveID)
expect(removedInactive?.id == inactiveID && closing.activeID == selectedBeforeClose, "Closing inactive tab preserves active selection")
let beforeUnknown = closing.tabs
closing.select(UUID())
expect(closing.tabs == beforeUnknown && closing.activeID == selectedBeforeClose, "Unknown selection is ignored")
expect(closing.close(UUID()) == nil && closing.tabs == beforeUnknown, "Closing unknown tab is harmless")
let last = BrowserTab(title: "Only tab", address: "https://example.com", space: 2)
var single = BrowserSession(tabs: [last], activeID: last.id, space: 2)
single.close(last.id)
expect(single.tabs.count == 1 && single.active?.isHome == true && single.active?.space == 2, "Closing the last tab creates one home in the same space")
expect(single.activeID != last.id, "Replacement home receives a new stable identifier")

// Sanitation repairs impossible restored state without retaining unsafe addresses.
let valid = BrowserTab(title: "Valid", address: "https://example.com", space: 1)
let invalidScheme = BrowserTab(title: "Invalid scheme", address: "javascript:alert(1)", space: 1)
let invalidSpace = BrowserTab(title: "Invalid space", address: "https://example.org", space: 8)
var damaged = BrowserSession(tabs: [valid, valid, invalidScheme, invalidSpace], activeID: UUID(), space: 1, sidebarWidth: .nan, sidebarVisible: false)
damaged.sanitize()
expect(damaged.tabs == [valid] && damaged.activeID == valid.id, "Sanitation removes duplicate, invalid URL, and invalid-space records")
expect(damaged.space == 1 && damaged.sidebarWidth == 228 && !damaged.sidebarVisible, "Sanitation repairs nonfinite width and preserves visibility")
damaged.sidebarWidth = -100; damaged.sanitize()
expect(damaged.sidebarWidth == 164, "Restored width is lower-bounded")
damaged.sidebarWidth = .infinity; damaged.sanitize()
expect(damaged.sidebarWidth == 228, "Infinite width uses a finite fallback")
damaged.space = 0; damaged.sanitize()
expect(damaged.space == 1 && damaged.active?.space == damaged.space, "Existing selection and restored space agree")
var absentSpace = BrowserSession(tabs: [valid], activeID: UUID(), space: 0)
absentSpace.sanitize()
expect(absentSpace.active?.space == 0 && absentSpace.active?.isHome == true && absentSpace.tabs.contains(valid), "Missing active tab in an empty space gets a local home without deleting other spaces")
let visiblePinned = BrowserSession.fresh().visibleTabs.map(\.pinned)
expect(!visiblePinned.drop(while: { $0 }).contains(true), "Visible pinned tabs precede ordinary tabs")

// Exercise the production file loader, including malformed and incomplete files.
let detailedFile = file.deletingLastPathComponent().appendingPathComponent("detailed-session.json")
damaged.sidebarWidth = 317; damaged.sidebarVisible = false
try SessionFile.save(damaged, to: detailedFile)
let detailed = SessionFile.load(detailedFile)
expect(detailed.tabs == damaged.tabs && detailed.activeID == damaged.activeID && detailed.space == damaged.space, "Roundtrip preserves tab identity, URL, title, and selected space")
expect(detailed.sidebarWidth == 317 && !detailed.sidebarVisible, "Roundtrip preserves width and hidden sidebar")
try Data("{ broken json".utf8).write(to: detailedFile)
let fallback = SessionFile.load(detailedFile)
expect(fallback.active != nil && fallback.active?.space == fallback.space && !fallback.tabs.isEmpty, "Corrupt session produces a valid fresh session")
try Data("{}".utf8).write(to: detailedFile)
let incomplete = SessionFile.load(detailedFile)
expect(incomplete.active != nil && incomplete.sidebarWidth.isFinite, "Incomplete session also recovers safely")
let missing = SessionFile.load(file.deletingLastPathComponent().appendingPathComponent("missing-\(UUID().uuidString).json"))
expect(missing.active != nil && missing.active?.isHome == true, "First launch with no file has a selected home")

// Every space remembers its own selection, including pinned tabs and new tabs.
var spaces = BrowserSession.fresh()
let studioFirst = spaces.add(address: "https://example.com/studio-first")
let studioLast = spaces.add(address: "https://example.com/studio-last")
spaces.changeSpace(1)
let lifeFirst = spaces.add(address: "https://example.com/life-first")
let lifeLast = spaces.add(address: "https://example.com/life-last")
spaces.changeSpace(0)
expect(spaces.activeID == studioLast, "Returning to Studio restores its last selected tab rather than its first ordinary tab")
spaces.select(studioFirst); spaces.changeSpace(1)
expect(spaces.activeID == lifeLast, "Each space keeps an independent selected tab")
spaces.select(lifeFirst); spaces.changeSpace(0)
expect(spaces.activeID == studioFirst, "Explicit selection replaces only that space's remembered tab")
let studioPinned = spaces.visibleTabs.first(where: \.pinned)!.id
spaces.select(studioPinned); spaces.changeSpace(1); spaces.changeSpace(0)
expect(spaces.activeID == studioPinned, "Pinned selections are restored ahead of ordinary-tab fallback")
spaces.select(lifeLast); spaces.changeSpace(0)
expect(spaces.activeID == studioPinned, "Selecting directly into another space preserves the departing selection")
spaces.changeSpace(1)
expect(spaces.activeID == lifeLast, "Cross-space selection becomes that space's remembered choice")

// Persist while a different space is visible, then return after a simulated launch.
let spacesFile = file.deletingLastPathComponent().appendingPathComponent("space-selections.json")
try SessionFile.save(spaces, to: spacesFile)
var reloadedSpaces = SessionFile.load(spacesFile)
expect(reloadedSpaces.lastSelectedTabIDsBySpace == spaces.lastSelectedTabIDsBySpace, "All per-space choices survive JSON persistence")
reloadedSpaces.changeSpace(0)
expect(reloadedSpaces.activeID == studioPinned, "A nonvisible space restores its selection after relaunch")
reloadedSpaces.close(studioPinned)
let studioFallback = reloadedSpaces.activeID
expect(studioFallback != studioPinned && reloadedSpaces.active?.space == 0, "Closing a remembered active tab chooses a same-space fallback")
reloadedSpaces.changeSpace(1); reloadedSpaces.changeSpace(0)
expect(reloadedSpaces.activeID == studioFallback, "Closed-tab fallback becomes the restored selection")
reloadedSpaces.close(lifeLast)
expect(reloadedSpaces.activeID == studioFallback && reloadedSpaces.space == 0, "Closing a remembered tab in another space preserves the current tab")
reloadedSpaces.changeSpace(1)
expect(reloadedSpaces.activeID == lifeFirst, "A closed background-space selection is replaced by a valid same-space tab")
try SessionFile.save(reloadedSpaces, to: spacesFile)
var afterClosing = SessionFile.load(spacesFile)
afterClosing.changeSpace(0)
expect(afterClosing.activeID == studioFallback, "Fallback choices survive a second launch after closing tabs")

// Older session files have no map. They must retain their existing tabs and selection.
var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spaces)) as! [String: Any]
legacyJSON.removeValue(forKey: "lastSelectedTabIDsBySpace")
try JSONSerialization.data(withJSONObject: legacyJSON).write(to: spacesFile)
var legacy = SessionFile.load(spacesFile)
expect(legacy.tabs == spaces.tabs && legacy.activeID == spaces.activeID, "Sessions without per-space selection data remain backward compatible")
legacy.changeSpace(0); legacy.changeSpace(1)
expect(legacy.activeID == lifeLast, "Legacy current selection is remembered on first space change")

// Reject stale IDs, mismatched spaces and impossible map keys from restored data.
var invalidSelections = spaces
invalidSelections.lastSelectedTabIDsBySpace = [0: lifeFirst, 1: UUID(), 2: studioFirst, 99: studioLast]
invalidSelections.sanitize()
expect(invalidSelections.lastSelectedTabIDsBySpace == [1: lifeLast], "Sanitation removes foreign-space, missing-tab and invalid-space remembered IDs and preserves active selection")
var missingActive = spaces
missingActive.activeID = UUID()
missingActive.space = 0
missingActive.sanitize()
expect(missingActive.activeID == studioPinned, "A valid remembered tab repairs a missing global active tab")
let soleBackground = BrowserTab(title: "Background", address: "https://example.com/background", space: 2)
var emptyBackground = BrowserSession(tabs: [valid, soleBackground], activeID: valid.id, space: 1, lastSelectedTabIDsBySpace: [1: valid.id, 2: soleBackground.id])
emptyBackground.close(soleBackground.id)
expect(emptyBackground.lastSelectedTabIDsBySpace?[2] == nil && emptyBackground.activeID == valid.id, "Closing the only background-space tab clears its remembered ID without creating an inactive tab")
emptyBackground.changeSpace(2)
expect(emptyBackground.active?.isHome == true && emptyBackground.lastSelectedTabIDsBySpace?[2] == emptyBackground.activeID, "Entering an emptied space creates and remembers one replacement home")

// The bundled video demo is an internal navigable page, distinct from home.
expect(URLInput.resolve("orbit://video") == "orbit://video", "Video demo internal route resolves")
expect(URLInput.resolve("orbit://unsupported") == nil, "Unknown internal routes remain rejected")
var demoSession = BrowserSession.fresh()
let demoID = demoSession.add(address: "orbit://video")
expect(demoSession.active?.isVideoDemo == true && demoSession.active?.isHome == false, "Video demo is not treated as the new-tab page")
expect(demoSession.active?.symbol == "play.rectangle.fill", "Video demo has its own play symbol")
demoSession.changeSpace(1)
try SessionFile.save(demoSession, to: spacesFile)
var demoRestored = SessionFile.load(spacesFile)
demoRestored.changeSpace(0)
expect(demoRestored.activeID == demoID && demoRestored.active?.address == "orbit://video", "Demo route and its remembered selection survive sanitation and relaunch")

// Split groups remain one visible row while preserving two independent tabs.
var splitState = BrowserSession.fresh()
let leftID = splitState.activeID
let rightID = splitState.add(address: "https://example.com/right")
expect(splitState.makeSplit(primary: leftID, secondary: rightID), "Same-space tabs form split")
expect(splitState.activeID == leftID && !splitState.visibleTabs.contains(where: { $0.id == rightID }), "Split companion is folded into primary row")
splitState.select(rightID)
expect(splitState.activeID == leftID, "Selecting companion selects its split group")
let splitRoundtrip = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(splitState))
expect(splitRoundtrip.split(for: leftID)?.secondaryID == rightID, "Split group persists")
var invalidSplit = splitState
invalidSplit.splits?.append(BrowserSplit(primaryID: leftID, secondaryID: UUID()))
invalidSplit.sanitize()
expect(invalidSplit.splits?.count == 1, "Stale and overlapping split groups are repaired")
splitState.removeSplit(containing: leftID)
expect(splitState.visibleTabs.contains(where: { $0.id == rightID }), "Unsplit restores companion row")
_ = splitState.makeSplit(primary: leftID, secondary: rightID)
_ = splitState.close(leftID)
expect(!splitState.tabs.contains(where: { $0.id == leftID || $0.id == rightID }) && splitState.splits?.isEmpty == true, "Closing split group removes both members")

print("PASS: \(count) model, URL, space, and persistence checks")
