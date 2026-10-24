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

// Editable Spaces migrate legacy state without renumbering tabs or changing metadata.
expect(BrowserSpace.defaults == BrowserSpace.legacyDefaults && BrowserSpace.defaults.map(\.id) == [0, 1, 2], "Legacy Space IDs stay stable")
expect(BrowserSpace.defaults.map(\.name) == ["Studio", "Life", "Explore"] && BrowserSpace.colorNames.count == 6, "Default labels and the six supported color choices are available")
var editableLegacy = BrowserSession.fresh()
let legacyPrimary = editableLegacy.activeID
let legacySecondary = editableLegacy.add(address: "https://example.com/legacy-right", title: "Legacy right")
_ = editableLegacy.makeSplit(primary: legacyPrimary, secondary: legacySecondary)
editableLegacy.sidebarWidth = 311; editableLegacy.sidebarVisible = false
var oldFormat = try JSONSerialization.jsonObject(with: JSONEncoder().encode(editableLegacy)) as! [String: Any]
for key in ["version", "spaces", "lastIssuedSpaceID"] { oldFormat.removeValue(forKey: key) }
try JSONSerialization.data(withJSONObject: oldFormat).write(to: spacesFile)
let migratedSpaces = SessionFile.load(spacesFile)
expect(migratedSpaces.spaces == BrowserSpace.defaults && migratedSpaces.spaceIDs == [0, 1, 2], "Old session files gain exactly the three legacy Space definitions")
expect(migratedSpaces.tabs == editableLegacy.tabs && migratedSpaces.splits == editableLegacy.splits && migratedSpaces.activeID == editableLegacy.activeID, "Space migration preserves tab identity, content, split grouping, and active selection")
expect(migratedSpaces.lastSelectedTabIDsBySpace == editableLegacy.lastSelectedTabIDsBySpace && migratedSpaces.sidebarWidth == 311 && !migratedSpaces.sidebarVisible, "Space migration preserves remembered tabs and sidebar preferences")
let migratedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(migratedSpaces)) as! [String: Any]
expect(migratedJSON["version"] as? Int == 5 && migratedJSON["spaces"] != nil, "Subsequent saves explicitly version the editable-Space format")
var futureJSON = migratedJSON; futureJSON["version"] = 999
let futureData = try JSONSerialization.data(withJSONObject: futureJSON)
expect((try? JSONDecoder().decode(BrowserSession.self, from: futureData)) == nil, "A future session format is not silently decoded as current state")

var editable = BrowserSession.fresh()
let creationSelection = editable.activeID, creationTabs = editable.tabs
expect(editable.createSpace(name: "   ", symbol: "globe", colorIndex: 0) == nil, "An empty Space name is rejected")
expect(editable.createSpace(name: String(repeating: "x", count: 61), symbol: "globe", colorIndex: 0) == nil && editable.createSpace(name: "Two\nLines", symbol: "globe", colorIndex: 0) == nil, "Overlong and multiline Space names are rejected")
expect(editable.createSpace(name: "Invalid color", symbol: "globe", colorIndex: 6) == nil, "Unknown Space color is rejected")
let createdID = editable.createSpace(name: "  Research  ", symbol: " book ", colorIndex: 4)!
expect(createdID == 3 && editable.spaceDefinition(createdID) == BrowserSpace(id: createdID, name: "Research", symbol: "book", colorIndex: 4), "Valid Space metadata is trimmed and receives the next stable ID")
expect(editable.activeID == creationSelection && editable.tabs == creationTabs && editable.space == 0, "Creating an unselected Space neither switches nor creates a background page")
expect(editable.spaceIndex(createdID) == 3 && editable.spaceIndex(999) == nil && editable.spaceDefinition(999) == nil, "Space lookup distinguishes stable IDs from missing values")
expect(editable.updateSpace(id: createdID, name: "  Reading  ", symbol: "not.a.symbol", colorIndex: 5), "A Space can be renamed and recolored")
expect(editable.spaceDefinition(createdID)?.name == "Reading" && editable.spaceDefinition(createdID)?.symbol == "sparkles" && editable.spaceDefinition(createdID)?.colorIndex == 5, "Unknown symbols normalize safely while valid metadata updates")
let beforeInvalidUpdate = editable.spaces
expect(!editable.updateSpace(id: createdID, name: "", symbol: "book", colorIndex: 0) && !editable.updateSpace(id: 999, name: "Absent", symbol: "book", colorIndex: 0) && editable.spaces == beforeInvalidUpdate, "Invalid updates do not partially mutate Space metadata")
editable.changeSpace(createdID)
let newSpaceHome = editable.activeID
expect(editable.active?.space == createdID && editable.active?.isHome == true && editable.tabs.count == creationTabs.count + 1, "Entering a new Space creates one selected local home")
editable.changeSpace(0); editable.changeSpace(createdID)
expect(editable.activeID == newSpaceHome, "Reentering a custom Space restores its page instead of allocating another")
editable.changeSpace(999)
expect(editable.space == createdID && editable.activeID == newSpaceHome, "An unknown Space ID cannot select an unrelated position")

// Reordering never changes tab membership or the selected/remembered IDs.
let savedTabs = editable.tabs, savedChoices = editable.lastSelectedTabIDsBySpace
expect(editable.reorderSpace(id: createdID, to: 0) && editable.spaceIDs == [createdID, 0, 1, 2], "Space order is independent from stable IDs")
expect(editable.tabs == savedTabs && editable.lastSelectedTabIDsBySpace == savedChoices && editable.activeID == newSpaceHome && editable.space == createdID, "Reordering preserves all tab and selection metadata")
expect(!editable.reorderSpace(id: createdID, to: 4) && !editable.reorderSpace(id: 999, to: 0) && editable.spaceIDs == [createdID, 0, 1, 2], "Invalid reorder requests are atomic no-ops")
try SessionFile.save(editable, to: spacesFile)
var editableReload = SessionFile.load(spacesFile)
expect(editableReload.spaces == editable.spaces && editableReload.tabs == editable.tabs && editableReload.activeID == editable.activeID && editableReload.lastSelectedTabIDsBySpace == editable.lastSelectedTabIDsBySpace, "Edited/reordered Space definitions and selection survive a file roundtrip")
expect(editableReload.deleteSpace(id: createdID, movingTabsTo: 0), "Deleting the selected custom Space succeeds with an explicit destination")
expect(editableReload.activeID == newSpaceHome && editableReload.space == 0 && editableReload.tabs.count == savedTabs.count && editableReload.tabs.first(where: { $0.id == newSpaceHome })?.space == 0, "Deleting the selected Space moves its page without closing or replacing it")
expect(editableReload.lastSelectedTabIDsBySpace?[createdID] == nil && editableReload.lastSelectedTabIDsBySpace?[0] == newSpaceHome, "Deleted Space choices are removed and the surviving selection is remembered at its destination")
try SessionFile.save(editableReload, to: spacesFile)
var afterSpaceDelete = SessionFile.load(spacesFile)
let afterDeletedID = afterSpaceDelete.createSpace(name: "Next", symbol: "leaf", colorIndex: 1)!
expect(afterDeletedID > createdID, "Deleting the highest Space and relaunching never reuses its ID")

// Deliberately nonsequential IDs catch accidental use of IDs as array indices.
let definitions = [BrowserSpace(id: 42, name: "Work", symbol: "briefcase", colorIndex: 3),
                   BrowserSpace(id: 7, name: "Home", symbol: "house", colorIndex: 1),
                   BrowserSpace(id: 90, name: "Listening", symbol: "music.note", colorIndex: 5)]
let groupLeft = BrowserTab(title: "Left", address: "https://example.com/left", space: 42, pinned: true)
let groupRight = BrowserTab(title: "Right", address: "https://example.com/right", space: 42)
let staying = BrowserTab(title: "Stay", address: "https://example.com/stay", space: 42)
let movingBackground = BrowserTab(title: "Background", address: "https://example.com/background", space: 7)
let destinationTab = BrowserTab(title: "Destination", address: "https://example.com/destination", space: 90)
var dynamic = BrowserSession(tabs: [groupLeft, groupRight, staying, movingBackground, destinationTab], activeID: groupLeft.id, space: 42,
                             lastSelectedTabIDsBySpace: [42: groupLeft.id, 7: movingBackground.id, 90: destinationTab.id],
                             splits: [BrowserSplit(primaryID: groupLeft.id, secondaryID: groupRight.id)], spaces: definitions)
dynamic.sanitize()
expect(dynamic.tabs.count == 5 && dynamic.space == 42 && dynamic.spaceIndex(42) == 0 && dynamic.spaceIndex(90) == 2, "Sanitation retains tabs whose custom IDs are not positions")
expect(dynamic.moveTab(id: groupRight.id, toSpace: 90), "Moving either split member moves its whole group")
expect(dynamic.activeID == groupLeft.id && dynamic.space == 90 && dynamic.split(for: groupRight.id)?.primaryID == groupLeft.id, "Moving the active split follows the same selected primary and retains the pair")
expect(dynamic.tabs.filter { [groupLeft.id, groupRight.id].contains($0.id) }.allSatisfy { $0.space == 90 } && dynamic.tabs.count == 5 && dynamic.tabs.map(\.id) == [groupLeft.id, groupRight.id, staying.id, movingBackground.id, destinationTab.id], "Split movement preserves both tab IDs and tab order without creating or deleting pages")
var movedLeft = groupLeft; movedLeft.space = 90
var movedRight = groupRight; movedRight.space = 90
expect(dynamic.tabs.first { $0.id == groupLeft.id } == movedLeft && dynamic.tabs.first { $0.id == groupRight.id } == movedRight, "Moving preserves titles, URLs and pin state exactly")
expect(dynamic.lastSelectedTabIDsBySpace?[42] == staying.id && dynamic.lastSelectedTabIDsBySpace?[90] == groupLeft.id && !dynamic.visibleTabs.contains(where: { $0.id == groupRight.id }), "Moving a split repairs source memory and keeps one destination row")
expect(dynamic.moveTab(id: movingBackground.id, toSpace: 42), "A background tab can move between custom Spaces")
expect(dynamic.activeID == groupLeft.id && dynamic.space == 90 && dynamic.lastSelectedTabIDsBySpace?[42] == staying.id && dynamic.lastSelectedTabIDsBySpace?[7] == nil, "Background moves preserve the current page and existing destination choice, clearing an emptied source")
let beforeInvalidMove = dynamic.tabs
expect(!dynamic.moveTab(id: UUID(), toSpace: 90) && !dynamic.moveTab(id: groupLeft.id, toSpace: 999) && dynamic.tabs == beforeInvalidMove, "Invalid tab moves neither lose pages nor alter membership")
expect(dynamic.reorderSpace(id: 90, to: 0) && dynamic.spaceIDs == [90, 42, 7] && dynamic.activeID == groupLeft.id && dynamic.space == 90, "Reordering nonsequential IDs retains active membership")
expect(dynamic.deleteSpace(id: 90, movingTabsTo: 42), "Deleting a Space containing a selected split moves its contents")
expect(dynamic.activeID == groupLeft.id && dynamic.space == 42 && dynamic.tabs.count == 5 && dynamic.tabs.allSatisfy { $0.space == 42 } && dynamic.splits == [BrowserSplit(primaryID: groupLeft.id, secondaryID: groupRight.id)], "Deleting a Space preserves every tab and split without replacing the selected page")
expect(dynamic.lastSelectedTabIDsBySpace?[90] == nil && dynamic.lastSelectedTabIDsBySpace?[42] == groupLeft.id, "Deleting a split's Space repairs remembered selection by stable ID")
expect(dynamic.deleteSpace(id: 7, movingTabsTo: 42) && dynamic.spaceIDs == [42], "An empty background Space can be removed without affecting the selected one")
expect(!dynamic.deleteSpace(id: 42, movingTabsTo: 42) && !dynamic.deleteSpace(id: 42, movingTabsTo: 999) && dynamic.spaceIDs == [42] && dynamic.tabs.count == 5, "The final Space can never be deleted")
let customHighID = dynamic.createSpace(name: "After relayout", symbol: "terminal", colorIndex: 0)!
expect(customHighID == 91, "Deleted and reordered custom IDs still determine the monotonic allocation high-water mark")
try SessionFile.save(dynamic, to: spacesFile)
let dynamicReload = SessionFile.load(spacesFile)
expect(dynamicReload.spaces == dynamic.spaces && dynamicReload.tabs == dynamic.tabs && dynamicReload.splits == dynamic.splits && dynamicReload.activeID == dynamic.activeID, "Nonsequential Space IDs, moved split identities and metadata persist together")

// Background deletion must not steal the current tab or the destination's last choice.
var backgroundDelete = BrowserSession(tabs: [groupLeft, movingBackground, destinationTab], activeID: destinationTab.id, space: 90,
                                      lastSelectedTabIDsBySpace: [42: groupLeft.id, 7: movingBackground.id, 90: destinationTab.id], spaces: definitions)
expect(backgroundDelete.deleteSpace(id: 7, movingTabsTo: 42), "A background Space can be deleted into another background Space")
expect(backgroundDelete.activeID == destinationTab.id && backgroundDelete.space == 90 && backgroundDelete.lastSelectedTabIDsBySpace?[42] == groupLeft.id && backgroundDelete.tabs.first(where: { $0.id == movingBackground.id })?.space == 42, "Background deletion preserves the active tab and the destination's remembered page")

var fullSpaces = BrowserSession.fresh()
for index in 3..<BrowserSession.maximumSpaces { _ = fullSpaces.createSpace(name: "Space \(index)", symbol: "globe", colorIndex: index % 6) }
let maxID = fullSpaces.spaceIDs.max()!
expect(fullSpaces.spaces.count == 32 && fullSpaces.createSpace(name: "Overflow", symbol: "globe", colorIndex: 0) == nil, "A bounded Space limit rejects overflow")
_ = fullSpaces.deleteSpace(id: maxID, movingTabsTo: 0)
expect(fullSpaces.createSpace(name: "Replacement", symbol: "globe", colorIndex: 0) == maxID + 1 && fullSpaces.spaces.count == 32, "Freeing a slot permits creation but never ID reuse")

var damagedSpaces = BrowserSession(tabs: [groupLeft], activeID: groupLeft.id, space: 42, sidebarWidth: 303, sidebarVisible: false,
                                  spaces: [BrowserSpace(id: 42, name: "  Repaired  ", symbol: "invalid", colorIndex: 99),
                                           BrowserSpace(id: 42, name: "Duplicate", symbol: "book", colorIndex: 0),
                                           BrowserSpace(id: -1, name: "Invalid", symbol: "book", colorIndex: 0)])
damagedSpaces.sanitize()
expect(damagedSpaces.spaceIDs == [42] && damagedSpaces.spaces[0].name == "Repaired" && damagedSpaces.spaces[0].symbol == "sparkles" && damagedSpaces.spaces[0].colorIndex == 5 && damagedSpaces.tabs == [groupLeft], "Malformed Space metadata is repaired without dropping a valid custom-Space tab")
damagedSpaces.tabs = []
damagedSpaces.sanitize()
expect(damagedSpaces.spaceIDs == [42] && damagedSpaces.active?.space == 42 && damagedSpaces.active?.isHome == true && damagedSpaces.sidebarWidth == 303 && !damagedSpaces.sidebarVisible, "An empty repaired session retains its edited Spaces and preferences while adding a safe home")
var exhaustedIDs = BrowserSession(tabs: [valid], activeID: valid.id, spaces: BrowserSpace.defaults + [BrowserSpace(id: Int.max, name: "Last possible ID", symbol: "globe", colorIndex: 0)])
expect(exhaustedIDs.createSpace(name: "Cannot overflow", symbol: "globe", colorIndex: 0) == nil, "Space ID allocation cannot overflow or wrap to a reused ID")

// Saved-tab migration preserves old pin identity and the original saved URL.
let oldPinID = UUID()
let oldPinJSON: [String: Any] = ["id": oldPinID.uuidString, "title": "Old pin", "address": "https://example.com/original", "space": 1, "pinned": true]
let migratedPin = try JSONDecoder().decode(BrowserTab.self, from: JSONSerialization.data(withJSONObject: oldPinJSON))
expect(migratedPin.id == oldPinID && migratedPin.pinned && migratedPin.saved?.kind == .kept && migratedPin.saved?.address == "https://example.com/original", "Legacy pinned JSON migrates to a kept tab with its original address")
expect(!migratedPin.isFavorite && !migratedPin.isUnloaded && migratedPin.saved?.customTitle == nil && migratedPin.displayTitle == "Old pin", "Migration does not fabricate Favorites, unloaded state or a custom label")
var oldOrdinaryJSON = oldPinJSON; oldOrdinaryJSON["pinned"] = false
let migratedOrdinary = try JSONDecoder().decode(BrowserTab.self, from: JSONSerialization.data(withJSONObject: oldOrdinaryJSON))
expect(!migratedOrdinary.isSaved, "Legacy ordinary tabs stay ordinary")
var compatibility = BrowserTab(title: "Compatibility", address: "https://example.com/start", space: 0)
compatibility.pinned = true; compatibility.address = "https://example.com/later"; compatibility.pinned = true
expect(compatibility.saved?.kind == .kept && compatibility.saved?.address == "https://example.com/start", "Repeated legacy pinned=true cannot replace the original saved URL")
compatibility.pinned = false
expect(compatibility.saved == nil && !compatibility.isSaved, "Legacy pinned=false removes saved state")
let missingUnloadedJSON: [String: Any] = ["kind": "favorite", "address": "https://example.com"]
let defaultSaved = try JSONDecoder().decode(SavedTabState.self, from: JSONSerialization.data(withJSONObject: missingUnloadedJSON))
expect(!defaultSaved.isUnloaded && defaultSaved.customTitle == nil && defaultSaved.customSymbol == nil, "Missing optional saved metadata decodes with live/default presentation")
var malformedSavedJSON = oldOrdinaryJSON; malformedSavedJSON["saved"] = ["kind": "unknown", "address": 123]
let malformedSavedTab = try JSONDecoder().decode(BrowserTab.self, from: JSONSerialization.data(withJSONObject: malformedSavedJSON))
expect(malformedSavedTab.saved == nil && malformedSavedTab.id == oldPinID, "Malformed saved metadata does not invalidate an otherwise valid ordinary tab")
for version in [1, 2, 3, 4, 5] {
    var versioned = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserSession.fresh())) as! [String: Any]
    versioned["version"] = version
    let decoded = try JSONDecoder().decode(BrowserSession.self, from: JSONSerialization.data(withJSONObject: versioned))
    expect(decoded.tabs.count == 6 && decoded.spaces == BrowserSpace.defaults, "Session format \(version) remains readable")
}

// Global Favorites retain a single identity while selections belong to each Space.
var retainedTabs = BrowserSession.fresh()
let originalFavorite = retainedTabs.add(address: "https://example.com/favorite-original", title: "Live title")
expect(retainedTabs.setRetention(id: originalFavorite, kind: .favorite), "An ordinary page can become a Favorite")
expect(retainedTabs.space == 0 && retainedTabs.activeID == originalFavorite && retainedTabs.favoriteTabs.map(\.id) == [originalFavorite], "Favoriting a selected page preserves selection and the current Space")
expect(retainedTabs.visibleTabs.first?.id == originalFavorite, "Global Favorites precede local kept and ordinary tabs")
retainedTabs.changeSpace(1)
let ordinaryLife = retainedTabs.activeID
expect(ordinaryLife != originalFavorite && retainedTabs.active?.space == 1 && retainedTabs.visibleTabs.contains(where: { $0.id == originalFavorite }), "A new Space prefers its local ordinary page while still exposing global Favorites")
retainedTabs.select(originalFavorite)
expect(retainedTabs.space == 1 && retainedTabs.activeID == originalFavorite && retainedTabs.lastSelectedTabIDsBySpace?[1] == originalFavorite, "Selecting a Favorite retains the current Space and remembers it there")
retainedTabs.changeSpace(2); let ordinaryExplore = retainedTabs.activeID
retainedTabs.select(originalFavorite); retainedTabs.changeSpace(1)
expect(retainedTabs.activeID == originalFavorite && retainedTabs.space == 1 && retainedTabs.lastSelectedTabIDsBySpace?[2] == originalFavorite, "One Favorite can be independently remembered in multiple Spaces")
retainedTabs.sanitize()
expect(retainedTabs.space == 1 && retainedTabs.activeID == originalFavorite && retainedTabs.lastSelectedTabIDsBySpace?[2] == originalFavorite, "Sanitation does not jump a selected Favorite back to its home Space")
expect(!retainedTabs.moveTab(id: originalFavorite, toSpace: 2) && retainedTabs.tabs.first(where: { $0.id == originalFavorite })?.space == 0, "A globally shared Favorite cannot be moved as a local Space tab")
expect(!retainedTabs.makeSplit(primary: originalFavorite, secondary: retainedTabs.tabs.first(where: { $0.space == 0 && !$0.isSaved })!.id), "Favorites cannot become Split primaries")
let favoriteIndex = retainedTabs.tabs.firstIndex(where: { $0.id == originalFavorite })!
retainedTabs.tabs[favoriteIndex].address = "https://example.com/navigated"
retainedTabs.tabs[favoriteIndex].title = "New live title"
expect(retainedTabs.updateSavedTab(id: originalFavorite, customTitle: "  My favorite  ", customSymbol: " heart "), "Saved titles and symbols can be explicitly customized")
expect(retainedTabs.active?.displayTitle == "My favorite" && retainedTabs.active?.symbol == "heart" && retainedTabs.active?.saved?.address == "https://example.com/favorite-original", "Custom presentation does not overwrite the original saved URL")
let customBeforeInvalid = retainedTabs.active!.saved
expect(!retainedTabs.updateSavedTab(id: originalFavorite, customTitle: "Changed", customSymbol: "invalid.symbol") && retainedTabs.active?.saved == customBeforeInvalid, "Invalid custom symbols do not partially change a saved label")
expect(!retainedTabs.updateSavedTab(id: originalFavorite, customTitle: String(repeating: "x", count: 81), customSymbol: nil) && !retainedTabs.updateSavedTab(id: originalFavorite, customTitle: "Bad\nLabel", customSymbol: nil), "Saved custom titles reject excessive length and control characters")
let closedFavorite = retainedTabs.close(originalFavorite)
expect(closedFavorite?.id == originalFavorite && retainedTabs.tabs.contains(where: { $0.id == originalFavorite && $0.isUnloaded && $0.address == "https://example.com/favorite-original" && $0.displayTitle == "My favorite" }), "Closing a Favorite unloads and resets it but retains its ID and custom label")
expect(retainedTabs.space == 1 && retainedTabs.activeID == ordinaryLife && retainedTabs.lastSelectedTabIDsBySpace?[1] != originalFavorite && retainedTabs.lastSelectedTabIDsBySpace?[2] != originalFavorite, "Closing a global Favorite repairs every remembered reference without selecting an unloaded page")
retainedTabs.changeSpace(2)
expect(retainedTabs.activeID == ordinaryExplore && retainedTabs.activeID != originalFavorite, "Space fallback does not wake an unloaded Favorite")
retainedTabs.select(originalFavorite)
expect(!retainedTabs.active!.isUnloaded && retainedTabs.space == 2 && retainedTabs.activeID == originalFavorite, "Explicitly selecting the same Favorite wakes it in the current Space")
expect(retainedTabs.updateSavedTab(id: originalFavorite, customTitle: "  ", customSymbol: nil) && retainedTabs.active?.displayTitle == "New live title" && retainedTabs.active?.symbol == "globe", "Clearing custom presentation restores the current page title and derived symbol")
expect(retainedTabs.setRetention(id: originalFavorite, kind: nil) && retainedTabs.active?.space == 2 && !retainedTabs.active!.isSaved && retainedTabs.space == 2, "Removing the selected Favorite makes it an ordinary tab in the current Space")
expect(retainedTabs.favoriteTabs.isEmpty && retainedTabs.lastSelectedTabIDsBySpace?[1] != originalFavorite, "Unfavoriting removes global presence and invalid cross-Space remembered choices")

// Kept tabs retain their saved destination across navigation, moves, close and reset.
let keptID = retainedTabs.add(address: "https://example.com/kept", title: "Kept")
expect(retainedTabs.setRetention(id: keptID, kind: .kept), "An ordinary page can become a kept tab")
retainedTabs.tabs[retainedTabs.tabs.firstIndex(where: { $0.id == keptID })!].address = "https://example.com/kept-navigation"
expect(retainedTabs.moveTab(id: keptID, toSpace: 1) && retainedTabs.space == 1 && retainedTabs.active?.saved?.address == "https://example.com/kept", "Moving a selected kept tab follows its same identity without changing its saved URL")
expect(retainedTabs.setRetention(id: keptID, kind: .favorite) && retainedTabs.space == 1 && retainedTabs.active?.saved?.address == "https://example.com/kept", "Kept-to-Favorite conversion retains the original saved destination")
retainedTabs.changeSpace(2); retainedTabs.select(keptID)
expect(retainedTabs.setRetention(id: keptID, kind: .kept) && retainedTabs.space == 2 && retainedTabs.active?.space == 2 && retainedTabs.active?.saved?.address == "https://example.com/kept", "Favorite-to-kept conversion moves the record to the current Space without replacing its URL")
_ = retainedTabs.close(keptID)
let fallbackAfterKeptClose = retainedTabs.activeID
expect(retainedTabs.tabs.first(where: { $0.id == keptID })?.isUnloaded == true && fallbackAfterKeptClose != keptID, "Closing kept content retains an unloaded row and selects another loaded page")
expect(retainedTabs.resetSavedTab(id: keptID) && retainedTabs.tabs.first(where: { $0.id == keptID })?.isUnloaded == false && retainedTabs.activeID == fallbackAfterKeptClose, "Reset wakes the saved URL without implicitly selecting it")
retainedTabs.select(keptID)
expect(retainedTabs.active?.address == "https://example.com/kept", "Explicit reset and selection return to the original saved address")
expect(!retainedTabs.resetSavedTab(id: originalFavorite) && !retainedTabs.updateSavedTab(id: originalFavorite, customTitle: "Ordinary", customSymbol: nil), "Ordinary pages reject saved-only commands")

// Favorites cap at twelve without silently replacing existing shortcuts.
var capState = BrowserSession.fresh()
for index in 0..<12 {
    let id = capState.add(address: "https://example.com/favorite-\(index)")
    expect(capState.setRetention(id: id, kind: .favorite), "Favorite \(index + 1) fits within the limit")
}
let excessID = capState.add(address: "https://example.com/excess")
let capSnapshot = capState.tabs
expect(!capState.setRetention(id: excessID, kind: .favorite) && capState.tabs == capSnapshot && capState.favoriteTabs.count == 12, "A thirteenth Favorite is rejected without changing any tab")
expect(capState.setRetention(id: capState.favoriteTabs[0].id, kind: .favorite) && capState.favoriteTabs.count == 12, "Reapplying Favorite retention is harmless at the limit")

// Split close applies each member's retention independently and never archives a kept identity away.
let splitKept = BrowserTab(title: "Kept primary", address: "https://example.com/primary", space: 0, pinned: true)
let splitOrdinary = BrowserTab(title: "Ordinary companion", address: "https://example.com/companion", space: 0)
var keptSplit = BrowserSession(tabs: [splitKept, splitOrdinary], activeID: splitKept.id)
expect(keptSplit.makeSplit(primary: splitKept.id, secondary: splitOrdinary.id), "Kept and ordinary pages can form a Split")
expect(!keptSplit.setRetention(id: splitKept.id, kind: .favorite) && !keptSplit.setRetention(id: splitOrdinary.id, kind: .favorite), "Neither member of an existing Split can become a Favorite")
_ = keptSplit.close(splitKept.id)
expect(keptSplit.tabs.contains(where: { $0.id == splitKept.id && $0.isUnloaded }) && !keptSplit.tabs.contains(where: { $0.id == splitOrdinary.id }) && keptSplit.splits?.isEmpty == true, "Closing a kept Split primary retains its saved row, removes its ordinary companion and dissolves the pair")
expect(keptSplit.active?.isHome == true && !keptSplit.active!.isUnloaded && keptSplit.activeID != splitKept.id, "A closed saved-only Space gets an ordinary home rather than reopening the saved row")
let savedCompanion = BrowserTab(title: "Saved companion", address: "https://example.com/saved-companion", space: 0, pinned: true)
var reverseRetention = BrowserSession(tabs: [splitOrdinary, savedCompanion], activeID: splitOrdinary.id)
_ = reverseRetention.makeSplit(primary: splitOrdinary.id, secondary: savedCompanion.id)
_ = reverseRetention.close(splitOrdinary.id)
expect(!reverseRetention.tabs.contains(where: { $0.id == splitOrdinary.id }) && reverseRetention.tabs.contains(where: { $0.id == savedCompanion.id && $0.isUnloaded }) && reverseRetention.splits?.isEmpty == true, "Closing an ordinary primary cannot delete its saved companion")
var bothSaved = BrowserSession(tabs: [splitKept, savedCompanion], activeID: splitKept.id)
_ = bothSaved.makeSplit(primary: splitKept.id, secondary: savedCompanion.id)
_ = bothSaved.close(savedCompanion.id)
expect(bothSaved.activeID == splitKept.id && bothSaved.tabs.first(where: { $0.id == splitKept.id })?.isUnloaded == false && bothSaved.tabs.first(where: { $0.id == savedCompanion.id })?.isUnloaded == true && bothSaved.splits?.isEmpty == true, "Closing only a saved Split secondary unloads it while leaving the primary active")
bothSaved.select(savedCompanion.id)
_ = bothSaved.makeSplit(primary: splitKept.id, secondary: savedCompanion.id)
_ = bothSaved.close(splitKept.id)
expect([splitKept.id, savedCompanion.id].allSatisfy { id in bothSaved.tabs.contains(where: { $0.id == id && $0.isUnloaded }) }, "Closing a fully saved Split retains both unloaded identities")

// Reorder within the correct retention group without moving ordinary pages or changing selection.
let orderA = BrowserTab(title: "A", address: "https://example.com/a", space: 0, pinned: true)
let orderB = BrowserTab(title: "B", address: "https://example.com/b", space: 0, pinned: true)
let otherKept = BrowserTab(title: "Other Space", address: "https://example.com/other", space: 1, pinned: true)
let orderFavoriteA = BrowserTab(title: "Favorite A", address: "https://example.com/fa", space: 2, saved: SavedTabState(kind: .favorite, address: "https://example.com/fa"))
let orderFavoriteB = BrowserTab(title: "Favorite B", address: "https://example.com/fb", space: 1, saved: SavedTabState(kind: .favorite, address: "https://example.com/fb"))
var savedOrder = BrowserSession(tabs: [orderA, splitOrdinary, otherKept, orderFavoriteA, orderB, orderFavoriteB], activeID: orderA.id)
_ = savedOrder.makeSplit(primary: orderA.id, secondary: splitOrdinary.id)
expect(savedOrder.reorderSavedTab(id: splitOrdinary.id, by: 1) && savedOrder.visibleTabs.filter { !$0.isFavorite }.map(\.id) == [orderB.id, orderA.id], "Reordering a kept Split member moves its primary row among local kept rows")
expect(savedOrder.split(for: orderA.id)?.secondaryID == splitOrdinary.id && savedOrder.activeID == orderA.id && savedOrder.tabs.first(where: { $0.id == otherKept.id })?.space == 1, "Saved-row ordering preserves Split membership, active selection and another Space's kept tabs")
expect(savedOrder.reorderSavedTab(id: orderFavoriteB.id, by: -1) && savedOrder.favoriteTabs.map(\.id) == [orderFavoriteB.id, orderFavoriteA.id], "Favorite ordering is global and independent from home Space IDs")
let beforeBadOrder = savedOrder.tabs
expect(!savedOrder.reorderSavedTab(id: orderFavoriteB.id, by: -1) && !savedOrder.reorderSavedTab(id: orderA.id, by: Int.max) && savedOrder.tabs == beforeBadOrder, "Out-of-range or overflowing saved-row moves are harmless")

// A Favorite's home Space may disappear without changing the user's selected context.
var favoriteSpaceEdits = BrowserSession.fresh()
let globalID = favoriteSpaceEdits.add(address: "https://example.com/global")
_ = favoriteSpaceEdits.setRetention(id: globalID, kind: .favorite)
favoriteSpaceEdits.changeSpace(2); favoriteSpaceEdits.select(globalID)
expect(favoriteSpaceEdits.deleteSpace(id: 0, movingTabsTo: 1) && favoriteSpaceEdits.space == 2 && favoriteSpaceEdits.activeID == globalID && favoriteSpaceEdits.active?.space == 1, "Deleting a Favorite's old home Space remaps metadata without switching the current Space")
expect(favoriteSpaceEdits.deleteSpace(id: 2, movingTabsTo: 1) && favoriteSpaceEdits.space == 1 && favoriteSpaceEdits.activeID == globalID, "Deleting the selected Space preserves a global Favorite in the chosen destination context")

// Repair damaged saved fields without executing unsafe original destinations or losing shortcuts.
var repairedSaved = BrowserSession(tabs: [BrowserTab(title: "Safe live title", address: "https://example.com/safe", space: 0,
    saved: SavedTabState(kind: .kept, address: "javascript:alert(1)", customTitle: String(repeating: "x", count: 81), customSymbol: "invalid", isUnloaded: true))], activeID: UUID())
let repairedID = repairedSaved.tabs[0].id
repairedSaved.activeID = repairedID; repairedSaved.lastSelectedTabIDsBySpace = [0: repairedID]
repairedSaved.sanitize()
expect(repairedSaved.tabs.first(where: { $0.id == repairedID })?.saved?.address == "https://example.com/safe" && repairedSaved.tabs.first(where: { $0.id == repairedID })?.saved?.customTitle == nil && repairedSaved.tabs.first(where: { $0.id == repairedID })?.saved?.customSymbol == nil, "Invalid original URL and custom presentation are repaired from safe live metadata")
expect(repairedSaved.activeID != repairedID && repairedSaved.active?.isHome == true && repairedSaved.tabs.first(where: { $0.id == repairedID })?.isUnloaded == true, "Restoring an unloaded active saved ID chooses a loaded home without waking it")
var damagedFavoriteCap = capState
let excessIndex = damagedFavoriteCap.tabs.firstIndex(where: { $0.id == excessID })!
damagedFavoriteCap.tabs[excessIndex].saved = SavedTabState(kind: .favorite, address: damagedFavoriteCap.tabs[excessIndex].address)
damagedFavoriteCap.sanitize()
expect(damagedFavoriteCap.favoriteTabs.count == 12 && damagedFavoriteCap.tabs.first(where: { $0.id == excessID })?.saved?.kind == .kept && damagedFavoriteCap.tabs.count == capState.tabs.count, "Sanitation demotes excess Favorites to kept rows without losing tabs")
var invalidFavoriteSplit = savedOrder
invalidFavoriteSplit.splits = [BrowserSplit(primaryID: orderFavoriteA.id, secondaryID: orderA.id)]
invalidFavoriteSplit.sanitize()
expect(invalidFavoriteSplit.splits?.isEmpty == true && invalidFavoriteSplit.tabs.count == savedOrder.tabs.count, "Persisted Split groups containing a Favorite dissolve without deleting either page")
let globalBadSpace = BrowserTab(title: "Global", address: "https://example.com/global-safe", space: 999,
                               saved: SavedTabState(kind: .favorite, address: "https://example.com/global-safe"))
var repairedGlobal = BrowserSession(tabs: [globalBadSpace], activeID: globalBadSpace.id, space: 2, lastSelectedTabIDsBySpace: [1: globalBadSpace.id, 2: globalBadSpace.id])
repairedGlobal.sanitize()
expect(repairedGlobal.activeID == globalBadSpace.id && repairedGlobal.space == 2 && repairedGlobal.active?.space == 2 && repairedGlobal.lastSelectedTabIDsBySpace?[1] == globalBadSpace.id, "A global Favorite with a stale home ID survives and remains remembered across valid Spaces")
_ = retainedTabs.updateSavedTab(id: keptID, customTitle: "Persisted label", customSymbol: "book")
_ = retainedTabs.close(keptID)
try SessionFile.save(retainedTabs, to: spacesFile)
let savedReload = SessionFile.load(spacesFile)
expect(savedReload.tabs == retainedTabs.tabs && savedReload.activeID == retainedTabs.activeID && savedReload.lastSelectedTabIDsBySpace == retainedTabs.lastSelectedTabIDsBySpace, "Saved state, unloaded rows, original URLs, custom labels and selection survive file persistence")
let savedVersion = try JSONSerialization.jsonObject(with: Data(contentsOf: spacesFile)) as! [String: Any]
expect(savedVersion["version"] as? Int == 5, "Sessions with retention metadata save as current format 5")

// Sleeping is recoverable current-page state, not the saved-tab close/unload state.
let sleepAddress = "https://example.com/current?query=1#position"
let sleepPosition = TabSleepState(address: sleepAddress, scrollX: -120.5, scrollY: 840.25)
let sleepingTab = BrowserTab(title: "Sleeping page", address: sleepAddress, space: 1, sleepState: sleepPosition)
expect(sleepingTab.isSleeping && !sleepingTab.isUnloaded && !sleepingTab.isSaved, "An ordinary sleeping tab remains distinct from saved unloading")
let defaultAwake = BrowserTab(title: "Awake", address: "https://example.com/awake", space: 0)
expect(defaultAwake.sleepState == nil && !defaultAwake.isSleeping, "Existing initializer calls create awake records without sleep metadata")
let sleepDecoded = try JSONDecoder().decode(BrowserTab.self, from: JSONEncoder().encode(sleepingTab))
expect(sleepDecoded == sleepingTab && sleepDecoded.sleepState == sleepPosition, "Sleep destination and fractional/RTL scroll offsets round-trip")
var oldAwakeJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sleepingTab)) as! [String: Any]
oldAwakeJSON.removeValue(forKey: "sleepState")
let oldAwakeDecoded = try JSONDecoder().decode(BrowserTab.self, from: JSONSerialization.data(withJSONObject: oldAwakeJSON))
expect(!oldAwakeDecoded.isSleeping && oldAwakeDecoded.id == sleepingTab.id, "Legacy records without sleep state keep their identity and remain awake")
oldAwakeJSON["sleepState"] = ["address": sleepAddress, "scrollX": "malformed", "scrollY": 1]
let malformedSleepDecoded = try JSONDecoder().decode(BrowserTab.self, from: JSONSerialization.data(withJSONObject: oldAwakeJSON))
expect(!malformedSleepDecoded.isSleeping && malformedSleepDecoded.address == sleepAddress, "Malformed optional sleep metadata does not discard a valid tab")

var sleepSelection = BrowserSession(tabs: [defaultAwake, sleepingTab], activeID: defaultAwake.id,
                                   lastSelectedTabIDsBySpace: [0: defaultAwake.id, 1: sleepingTab.id])
sleepSelection.changeSpace(1)
expect(sleepSelection.activeID == sleepingTab.id && sleepSelection.active?.sleepState == sleepPosition, "Remembered Space selection retains sleep state for controller wake")
sleepSelection.select(defaultAwake.id); sleepSelection.select(sleepingTab.id)
expect(sleepSelection.space == 1 && sleepSelection.active?.isSleeping == true, "Direct selection preserves current-page resume metadata until a view is created")
sleepSelection.sanitize()
expect(sleepSelection.activeID == sleepingTab.id && sleepSelection.active?.isSleeping == true && sleepSelection.lastSelectedTabIDsBySpace?[1] == sleepingTab.id, "Sanitation does not discard an active or remembered sleeping page")
var sleepingFavorite = sleepingTab
sleepingFavorite.saved = SavedTabState(kind: .favorite, address: "https://example.com/original")
var favoriteSleepSelection = BrowserSession(tabs: [defaultAwake, sleepingFavorite], activeID: defaultAwake.id, space: 0)
favoriteSleepSelection.select(sleepingFavorite.id)
expect(favoriteSleepSelection.space == 0 && favoriteSleepSelection.active?.sleepState == sleepPosition, "Sleeping Favorite selection keeps current Space and current-page resume URL")
favoriteSleepSelection.sanitize()
expect(favoriteSleepSelection.space == 0 && favoriteSleepSelection.activeID == sleepingFavorite.id && favoriteSleepSelection.active?.isSleeping == true, "Sleeping global selection survives sanitation independently of its home Space")

let invalidSleepStates = [
    TabSleepState(address: "https://example.com/old", scrollX: 0, scrollY: 0),
    TabSleepState(address: sleepAddress, scrollX: .nan, scrollY: 0),
    TabSleepState(address: sleepAddress, scrollX: 0, scrollY: .infinity),
    TabSleepState(address: sleepAddress, scrollX: -.infinity, scrollY: 0),
    TabSleepState(address: sleepAddress, scrollX: 10_000_001, scrollY: 0),
    TabSleepState(address: sleepAddress, scrollX: 0, scrollY: -10_000_001)
]
for (index, invalidSleep) in invalidSleepStates.enumerated() {
    var bad = sleepingTab; bad.sleepState = invalidSleep
    var state = BrowserSession(tabs: [bad], activeID: bad.id, space: 1)
    state.sanitize()
    expect(state.activeID == bad.id && state.active?.sleepState == nil && state.active?.address == sleepAddress, "Invalid sleep metadata case \(index) drops only resume state")
}
var boundarySleep = sleepingTab
boundarySleep.sleepState = TabSleepState(address: sleepAddress, scrollX: -10_000_000, scrollY: 10_000_000)
var boundarySleepSession = BrowserSession(tabs: [boundarySleep], activeID: boundarySleep.id, space: 1)
boundarySleepSession.sanitize()
expect(boundarySleepSession.active?.sleepState == boundarySleep.sleepState, "Finite scroll offsets at the documented bounds survive")
for address in ["orbit://newtab", "orbit://video"] {
    let internalSleep = BrowserTab(title: "Internal", address: address, space: 0,
                                  sleepState: TabSleepState(address: address, scrollX: 0, scrollY: 12))
    var state = BrowserSession(tabs: [internalSleep], activeID: internalSleep.id)
    state.sanitize()
    expect(state.activeID == internalSleep.id && !state.active!.isSleeping, "Internal page \(address) cannot carry HTTP resume state")
}
var conflictingSleep = sleepingTab
conflictingSleep.saved = SavedTabState(kind: .kept, address: "https://example.com/saved", isUnloaded: true)
var conflictingSleepSession = BrowserSession(tabs: [defaultAwake, conflictingSleep], activeID: defaultAwake.id)
conflictingSleepSession.sanitize()
let repairedSleepingSaved = conflictingSleepSession.tabs.first { $0.id == conflictingSleep.id }!
expect(repairedSleepingSaved.isUnloaded && !repairedSleepingSaved.isSleeping && repairedSleepingSaved.address == "https://example.com/saved", "Saved unload takes precedence over incompatible current-page sleep")

var savedSleep = sleepingTab
savedSleep.saved = SavedTabState(kind: .kept, address: "https://example.com/original", customTitle: "Retained")
var savedSleepSession = BrowserSession(tabs: [defaultAwake, savedSleep], activeID: savedSleep.id, space: 1)
expect(savedSleepSession.resetSavedTab(id: savedSleep.id) && savedSleepSession.active?.sleepState == nil
       && savedSleepSession.active?.address == "https://example.com/original" && savedSleepSession.active?.displayTitle == "Retained", "Explicit saved reset clears sleep and uses original address without losing its label")
savedSleepSession.tabs[savedSleepSession.tabs.firstIndex { $0.id == savedSleep.id }!] = savedSleep
_ = savedSleepSession.close(savedSleep.id)
let closedSleepingSaved = savedSleepSession.tabs.first { $0.id == savedSleep.id }!
expect(closedSleepingSaved.isUnloaded && !closedSleepingSaved.isSleeping && closedSleepingSaved.address == "https://example.com/original", "Closing a sleeping kept tab clears resume state and retains the saved original")
var ordinarySleepClose = sleepSelection
let closedSleepingOrdinary = ordinarySleepClose.close(sleepingTab.id)
expect(closedSleepingOrdinary?.sleepState == sleepPosition && !ordinarySleepClose.tabs.contains { $0.id == sleepingTab.id }, "Closing a sleeping ordinary tab still removes its identity")
var movedSleep = sleepSelection
expect(movedSleep.moveTab(id: sleepingTab.id, toSpace: 2) && movedSleep.active?.sleepState == sleepPosition && movedSleep.space == 2, "Moving a sleeping page keeps its resume state and selected identity")
expect(movedSleep.deleteSpace(id: 2, movingTabsTo: 0) && movedSleep.active?.sleepState == sleepPosition && movedSleep.space == 0, "Deleting a sleeping page's Space remaps membership without losing resume state")
try SessionFile.save(sleepSelection, to: spacesFile)
let sleepReloaded = SessionFile.load(spacesFile)
expect(sleepReloaded.tabs == sleepSelection.tabs && sleepReloaded.activeID == sleepingTab.id
       && sleepReloaded.lastSelectedTabIDsBySpace?[1] == sleepingTab.id, "Session file round-trip preserves sleeping selected and remembered pages")
let sleepVersion = try JSONSerialization.jsonObject(with: Data(contentsOf: spacesFile)) as! [String: Any]
expect(sleepVersion["version"] as? Int == 5, "Current-page sleeping metadata uses session format 5")


// Login profiles: default migration, explicit Favorite ownership and stable stores.
var loginProfiles = BrowserSession.fresh()
expect(loginProfiles.currentProfileID == BrowserProfile.defaultID && loginProfiles.profiles == BrowserProfile.defaults, "Existing sessions start in the persistent default login profile")
let workProfile = loginProfiles.createProfile(name: "  Work  ")!
let lifeProfile = loginProfiles.createProfile(name: "Personal")!
expect(loginProfiles.profileName(workProfile) == "Work" && workProfile != lifeProfile, "Named profiles trim names and receive distinct stable UUIDs")
expect(loginProfiles.createProfile(name: "work") == nil && loginProfiles.createProfile(name: "\n") == nil, "Duplicate or empty profile names are rejected")
expect(loginProfiles.createProfile(name: "Zero", id: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))) == nil, "An invalid zero WebKit store identifier cannot be created")
expect(loginProfiles.renameProfile(id: workProfile, name: "Team") && loginProfiles.profileName(workProfile) == "Team", "Renaming a profile preserves its storage identity")
expect(!loginProfiles.renameProfile(id: workProfile, name: "personal"), "A rename cannot make the profile picker ambiguous")
expect(loginProfiles.createSpace(name: "Unknown", symbol: "book", colorIndex: 0, profileID: UUID()) == nil, "A newly created Space cannot reference an undefined profile")
let profileDefinitions = [
    BrowserSpace(id: 10, name: "Work A", symbol: "briefcase", colorIndex: 0, profileID: workProfile),
    BrowserSpace(id: 20, name: "Personal", symbol: "heart", colorIndex: 1, profileID: lifeProfile),
    BrowserSpace(id: 30, name: "Work B", symbol: "book", colorIndex: 2, profileID: workProfile)
]
let workTab = BrowserTab(title: "Work tab", address: "https://example.com/work", space: 10)
let personalTab = BrowserTab(title: "Personal tab", address: "https://example.com/personal", space: 20)
let otherWorkTab = BrowserTab(title: "Other work", address: "https://example.com/other-work", space: 30)
var profileTabs = BrowserSession(tabs: [workTab, personalTab, otherWorkTab], activeID: workTab.id, space: 10,
                                 spaces: profileDefinitions, profiles: loginProfiles.profiles)
expect(profileTabs.setRetention(id: workTab.id, kind: .favorite) && profileTabs.active?.saved?.profileID == workProfile, "Creating a Favorite binds it to its login profile")
profileTabs.changeSpace(30); profileTabs.select(workTab.id)
expect(profileTabs.space == 30 && profileTabs.favoriteTabs.map(\.id) == [workTab.id], "Spaces sharing a profile share the same Favorite identity without changing Space")
profileTabs.changeSpace(20)
expect(profileTabs.favoriteTabs.isEmpty && !profileTabs.visibleTabs.contains { $0.id == workTab.id }, "Other profiles do not expose a foreign Favorite or its live page")
let foreignConversionBefore = profileTabs.tabs
expect(!profileTabs.setRetention(id: workTab.id, kind: .kept) && profileTabs.tabs == foreignConversionBefore, "Converting a foreign-profile Favorite cannot silently move it into personal logins")
profileTabs.select(workTab.id)
expect(profileTabs.space == 10 && profileTabs.currentProfileID == workProfile, "Cross-profile Favorite selection returns to a matching Space")
expect(profileTabs.updateSpace(id: 10, name: "Work A renamed", symbol: "briefcase", colorIndex: 0) && profileTabs.spaceDefinition(10)?.profileID == workProfile, "Legacy appearance-only Space edits preserve its login assignment")
expect(profileTabs.updateSpace(id: 10, name: "Now personal", symbol: "heart", colorIndex: 0, profileID: lifeProfile), "A Space can change its login profile")
expect(profileTabs.tabs.first { $0.id == workTab.id }?.saved?.profileID == workProfile && profileTabs.currentProfileID == lifeProfile && profileTabs.activeID != workTab.id, "Reassigning a Favorite's original Space does not move the Favorite's login or retain an invalid active selection")
profileTabs.select(workTab.id)
expect(profileTabs.space == 30 && profileTabs.activeID == workTab.id, "A Favorite selects another matching Space when its old home uses a different profile")
expect(profileTabs.setRetention(id: workTab.id, kind: .kept) && profileTabs.active?.space == 30 && profileTabs.active?.saved?.profileID == nil, "Same-profile un-Favorite becomes a kept tab in the current Space")
expect(profileTabs.setRetention(id: workTab.id, kind: .favorite), "The converted tab can become a profile Favorite again")
expect(profileTabs.deleteSpace(id: 30, movingTabsTo: 20), "The last Space using a profile can be removed without deleting its saved data")
let orphanActive = profileTabs.activeID, orphanSpace = profileTabs.space
profileTabs.select(workTab.id)
expect(profileTabs.activeID == orphanActive && profileTabs.space == orphanSpace && profileTabs.spaceID(forProfile: workProfile) == nil, "Selecting a temporarily unassigned profile does not fall back to personal logins")
expect(profileTabs.tabs.first { $0.id == workTab.id }?.saved?.profileID == workProfile && profileTabs.favorites(in: workProfile).count == 1, "An orphan profile's Favorite remains recoverable")
expect(profileTabs.updateSpace(id: 10, name: "Work restored", symbol: "briefcase", colorIndex: 0, profileID: workProfile), "An existing profile can be reassigned without creating a new identity")
profileTabs.select(workTab.id)
expect(profileTabs.space == 10 && profileTabs.currentProfileID == workProfile, "Reassigning the profile restores access to its existing Favorite")
let privateSleep = TabSleepState(address: workTab.address, scrollX: 12, scrollY: 480)
var moveProfiles = BrowserSession(tabs: [
    BrowserTab(id: workTab.id, title: workTab.title, address: workTab.address, space: 10, sleepState: privateSleep),
    BrowserTab(id: otherWorkTab.id, title: "Partner", address: "https://example.com/partner", space: 10)
], activeID: workTab.id, space: 10, spaces: profileDefinitions, profiles: loginProfiles.profiles)
expect(moveProfiles.makeSplit(primary: workTab.id, secondary: otherWorkTab.id), "Profile move fixture creates a whole Split group")
expect(moveProfiles.moveTab(id: otherWorkTab.id, toSpace: 30) && moveProfiles.active?.sleepState == privateSleep, "Same-profile Split move retains current-page resume state")
expect(moveProfiles.moveTab(id: workTab.id, toSpace: 20) && moveProfiles.tabs.allSatisfy { $0.space == 20 } && moveProfiles.active?.sleepState == nil, "Cross-profile move moves both Split members and drops old-profile resume state")
expect(moveProfiles.split(for: workTab.id)?.secondaryID == otherWorkTab.id && Set(moveProfiles.tabs.map(\.id)) == Set([workTab.id, otherWorkTab.id]), "Profile moves preserve tab and Split identities")
var cappedProfiles = BrowserSession(tabs: [workTab, personalTab, otherWorkTab], activeID: workTab.id, space: 10, spaces: profileDefinitions, profiles: loginProfiles.profiles)
for profileSpace in [10, 20] {
    cappedProfiles.changeSpace(profileSpace)
    for i in 0..<12 {
        let id = cappedProfiles.add(address: "https://example.com/favorite-\(profileSpace)-\(i)")
        expect(cappedProfiles.setRetention(id: id, kind: .favorite), "Each login profile has its own Favorite capacity")
    }
    let excess = cappedProfiles.add(address: "https://example.com/excess-\(profileSpace)")
    expect(!cappedProfiles.setRetention(id: excess, kind: .favorite), "A thirteenth Favorite is rejected within its own profile")
}
expect(cappedProfiles.favorites(in: workProfile).count == 12 && cappedProfiles.favorites(in: lifeProfile).count == 12, "The Favorite limit is per profile, not globally shared")
let workOrder = cappedProfiles.favorites(in: workProfile).map(\.id)
let personalOrder = cappedProfiles.favorites(in: lifeProfile).map(\.id)
expect(cappedProfiles.reorderSavedTab(id: workOrder[1], by: -1) && cappedProfiles.favorites(in: workProfile).first?.id == workOrder[1]
       && cappedProfiles.favorites(in: lifeProfile).map(\.id) == personalOrder, "Favorite reordering stays inside its profile")
var legacyProfiles = try JSONSerialization.jsonObject(with: JSONEncoder().encode(retainedTabs)) as! [String: Any]
legacyProfiles["version"] = 4; legacyProfiles.removeValue(forKey: "profiles")
legacyProfiles["spaces"] = (legacyProfiles["spaces"] as! [[String: Any]]).map { raw in var raw = raw; raw.removeValue(forKey: "profileID"); return raw }
legacyProfiles["tabs"] = (legacyProfiles["tabs"] as! [[String: Any]]).map { raw in
    var raw = raw
    if var saved = raw["saved"] as? [String: Any] { saved.removeValue(forKey: "profileID"); raw["saved"] = saved }
    return raw
}
var migratedProfiles = try JSONDecoder().decode(BrowserSession.self, from: JSONSerialization.data(withJSONObject: legacyProfiles)); migratedProfiles.sanitize()
expect(migratedProfiles.spaces.allSatisfy { $0.profileID == BrowserProfile.defaultID } && migratedProfiles.profiles == BrowserProfile.defaults, "Version 4 sessions keep the existing default cookies/store")
expect(migratedProfiles.tabs.map(\.id) == retainedTabs.tabs.map(\.id) && migratedProfiles.tabs.map(\.address) == retainedTabs.tabs.map(\.address), "Profile migration preserves existing tab identities and destinations")
let unknownProfile = UUID(), unknownFavoriteProfile = UUID()
let recoveredFavorite = BrowserTab(title: "Recovered", address: "https://example.com/recovered", space: 10,
                                   saved: SavedTabState(kind: .favorite, address: "https://example.com/recovered", profileID: unknownFavoriteProfile))
var missingDefinitions = BrowserSession(tabs: [workTab, recoveredFavorite], activeID: workTab.id, space: 10,
    spaces: [BrowserSpace(id: 10, name: "Recovered Space", symbol: "book", colorIndex: 0, profileID: unknownProfile)])
missingDefinitions.sanitize()
expect(missingDefinitions.profiles.contains { $0.id == unknownProfile } && missingDefinitions.profiles.contains { $0.id == unknownFavoriteProfile }, "Missing valid profile UUID definitions are recovered instead of routed to Default")
expect(missingDefinitions.currentProfileID == unknownProfile && missingDefinitions.profileID(for: recoveredFavorite) == unknownFavoriteProfile
       && missingDefinitions.favoriteTabs.isEmpty, "Recovered Space and Favorite stores remain distinct")
var invalidProfileJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(missingDefinitions)) as! [String: Any]
var invalidProfileSpaces = invalidProfileJSON["spaces"] as! [[String: Any]]
invalidProfileSpaces[0]["profileID"] = "not-a-uuid"; invalidProfileJSON["spaces"] = invalidProfileSpaces
expect((try? JSONDecoder().decode(BrowserSession.self, from: JSONSerialization.data(withJSONObject: invalidProfileJSON))) == nil, "Malformed Space profile UUID fails decoding instead of opening its tabs with default cookies")
invalidProfileSpaces[0]["profileID"] = NSNull(); invalidProfileJSON["spaces"] = invalidProfileSpaces
expect((try? JSONDecoder().decode(BrowserSession.self, from: JSONSerialization.data(withJSONObject: invalidProfileJSON))) == nil, "An explicit null profile binding is not treated as a legacy absent key")
var invalidFavoriteJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recoveredFavorite)) as! [String: Any]
var badBinding = invalidFavoriteJSON["saved"] as! [String: Any]; badBinding["profileID"] = "not-a-uuid"; invalidFavoriteJSON["saved"] = badBinding
expect((try? JSONDecoder().decode(BrowserTab.self, from: JSONSerialization.data(withJSONObject: invalidFavoriteJSON))) == nil, "Malformed Favorite profile binding cannot fall through optional retention recovery")
try SessionFile.save(profileTabs, to: spacesFile)
let storedProfiles = SessionFile.load(spacesFile)
expect(storedProfiles.profiles == profileTabs.profiles && storedProfiles.spaces == profileTabs.spaces
       && storedProfiles.tabs == profileTabs.tabs && storedProfiles.activeID == profileTabs.activeID, "Profile names, UUID bindings, Favorites and selection survive a disk round trip")
let profileVersion = try JSONSerialization.jsonObject(with: Data(contentsOf: spacesFile)) as! [String: Any]
expect(profileVersion["version"] as? Int == 5, "Login profile metadata uses session format 5")

badBinding["profileID"] = unknownFavoriteProfile.uuidString; badBinding["kind"] = "unknown"; invalidFavoriteJSON["saved"] = badBinding
expect((try? JSONDecoder().decode(BrowserTab.self, from: JSONSerialization.data(withJSONObject: invalidFavoriteJSON))) == nil, "Malformed retention with an explicit profile binding cannot become a personal ordinary tab")
let extensionAddress = "webkit-extension://\(UUID().uuidString)/onboarding/start.html?step=1#intro"
expect(URLInput.extensionURL(extensionAddress) != nil && URLInput.directURL(extensionAddress) == nil, "Extension page restoration has separate URL validation from web navigation")
for badExtension in ["webkit-extension://not-a-uuid/page", "webkit-extension:///page", "webkit-extension://user@\(UUID().uuidString)/page", "webkit-extension://\(UUID().uuidString):443/page", "https://\(UUID().uuidString)/page"] {
    expect(URLInput.extensionURL(badExtension) == nil, "Invalid extension origin is rejected: \(badExtension)")
}
let extensionTab = BrowserTab(title: "Extension setup", address: extensionAddress, space: 0)
var extensionSession = BrowserSession(tabs: [extensionTab], activeID: extensionTab.id)
extensionSession.sanitize()
expect(extensionSession.tabs == [extensionTab] && extensionSession.activeID == extensionTab.id, "Valid extension tab identity, title and destination survive sanitation")
expect(!extensionSession.setRetention(id: extensionTab.id, kind: .favorite) && !extensionSession.setRetention(id: extensionTab.id, kind: .kept), "Extension setup/vault pages are not promoted into saved web destinations")
let extensionRoundTrip = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(extensionSession))
expect(extensionRoundTrip.tabs == extensionSession.tabs, "Extension page restoration metadata round-trips without broadening typed web URLs")

print("PASS: \(count) model, URL, space, and persistence checks")
