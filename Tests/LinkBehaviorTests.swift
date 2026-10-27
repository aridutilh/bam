import Foundation

/// Settings › Links toggles: what each click does with each toggle, and the defaults (all on as in
/// Arc, except that a fresh preview or fixture never takes the global ⌥⌘N unless asked).
@main enum LinkBehaviorTests {
    static func main() {
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { print("FAILED: \(message)"); exit(1) }; checks += 1
        }
        let allOn: (LinkBehavior.Toggle) -> Bool = { _ in true }
        func off(_ toggle: LinkBehavior.Toggle) -> (LinkBehavior.Toggle) -> Bool { { $0 != toggle } }
        func click(_ c: Bool = false, _ o: Bool = false, _ s: Bool = false, saved: Bool = false, visible: Bool = true,
                   on isOn: @escaping (LinkBehavior.Toggle) -> Bool = { _ in true }) -> LinkBehavior.ClickResult {
            LinkBehavior.click(command: c, option: o, shift: s, fromSavedToOtherSite: saved, sourceVisible: visible, isOn: isOn)
        }
        require(click(true, true) == .littleBam, "⌥⌘-click opens Little Bam")
        require(click(true, true, on: off(.optionCommandClickLittleBam)) == .newTab, "with that off, ⌥⌘-click is a ⌘-click (new tab)")
        require(click(true) == .newTab && click(true, false, true) == .newTab, "⌘-click and ⇧⌘-click open tabs")
        require(click(false, false, true) == .peek, "Shift-click peeks")
        require(click(false, false, true, on: off(.shiftClickPeek)) == .navigate, "with Shift-click Peek off, the link just opens")
        require(click(saved: true) == .peek, "a kept tab's link to another site peeks")
        require(click(saved: true, on: off(.peekOtherSitesFromSaved)) == .navigate, "unless that's off")
        require(click(false, false, true, saved: true, visible: false) == .navigate, "a page not on screen never peeks")
        require(click(saved: false, on: allOn) == .navigate, "a plain click navigates")

        // Defaults.
        require(LinkBehavior.isDisposableLaunch(["Bam", "--fresh-preview"]) && !LinkBehavior.isDisposableLaunch(["Bam"]), "disposable launches")
        let saved = LinkBehavior.defaults
        LinkBehavior.defaults = nil
        require(!LinkBehavior.isOn(.globalLittleBamKey), "a fresh preview doesn't take ⌥⌘N")
        require(LinkBehavior.isOn(.shiftClickPeek) && LinkBehavior.isOn(.optionCommandClickLittleBam) && LinkBehavior.isOn(.peekOtherSitesFromSaved), "the rest start on")
        LinkBehavior.set(.globalLittleBamKey, true)
        require(LinkBehavior.isOn(.globalLittleBamKey), "unless turned on in that session")
        let suite = "bam.linkbehavior.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        LinkBehavior.defaults = defaults
        require(LinkBehavior.Toggle.allCases.allSatisfy(LinkBehavior.isOn), "a real profile starts with every toggle on, as in Arc")
        LinkBehavior.set(.shiftClickPeek, false)
        require(!LinkBehavior.isOn(.shiftClickPeek) && defaults.object(forKey: "ShiftClickPeek") as? Bool == false, "a toggle is saved")
        require(LinkBehavior.littleBamArchive == .sixHours && LinkBehavior.LittleBamArchive.allCases.map(\.title) == ["1 hour", "6 hours", "12 hours"],
                "Little Bams archive after Arc's 6 hours by default; Arc's three choices")
        LinkBehavior.littleBamArchive = .oneHour
        require(LinkBehavior.littleBamArchive.seconds == 3600, "a choice is saved")
        defaults.removePersistentDomain(forName: suite)
        LinkBehavior.defaults = saved
        print("PASS: \(checks) link behavior checks")
    }
}
