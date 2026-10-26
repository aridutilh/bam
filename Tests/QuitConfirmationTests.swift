import AppKit

/// The quit confirmation's decisions: who is asked, what each choice does, and the keys.
@main @MainActor struct QuitConfirmationTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
        checks += 1
    }
    static func main() {
        do { try run(); print("PASS: \(checks) quit confirmation checks") }
        catch { print("FAIL: Quit confirmation — \(error)"); exit(1) }
    }
    static func run() throws {
        let suite = "bam-quit-confirmation-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "No test defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = QuitConfirmationPreference(defaults: defaults)

        // Asking is the default; nothing is disabled silently.
        try check(preference.asksBeforeQuitting, "A fresh profile did not ask before quitting")
        try check(QuitConfirmationModel.resolve(.cancel, preference: preference, persist: true) == false && preference.asksBeforeQuitting,
                  "Cancel quit or changed the preference")
        try check(QuitConfirmationModel.resolve(.quit, preference: preference, persist: true) && preference.asksBeforeQuitting,
                  "Quit did not quit, or stopped asking without being told to")

        // "Don't ask again" from a private window quits but leaves the normal preference alone.
        try check(QuitConfirmationModel.resolve(.quitAndStopAsking, preference: preference, persist: false) && preference.asksBeforeQuitting,
                  "A private window's 'don't ask again' changed the saved preference")
        // From a normal window it quits and is remembered, until Settings turns it back on.
        try check(QuitConfirmationModel.resolve(.quitAndStopAsking, preference: preference, persist: true) && !preference.asksBeforeQuitting,
                  "'Don't ask again' did not quit and stop asking")
        try check(!QuitConfirmationPreference(defaults: defaults).asksBeforeQuitting, "'Don't ask again' was not saved")
        QuitConfirmationPreference(defaults: defaults).asksBeforeQuitting = true
        try check(preference.asksBeforeQuitting, "Settings could not restore asking before quitting")

        // Keys: Escape cancels, Return or Enter quits; modified keys and other keys do nothing.
        try check(QuitConfirmationModel.choice(keyCode: 53, modifiers: []) == .cancel, "Escape did not cancel")
        try check(QuitConfirmationModel.choice(keyCode: 36, modifiers: []) == .quit && QuitConfirmationModel.choice(keyCode: 76, modifiers: []) == .quit,
                  "Return or Enter did not quit")
        try check(QuitConfirmationModel.choice(keyCode: 36, modifiers: .command) == nil && QuitConfirmationModel.choice(keyCode: 53, modifiers: .option) == nil,
                  "A modified Return or Escape was taken as a choice")
        try check(QuitConfirmationModel.choice(keyCode: 49, modifiers: []) == nil, "Space chose an answer")

        // The title names the running app: Bam, or Bam Preview for the preview build.
        try check(QuitConfirmationModel.title(appName: QuitConfirmationModel.appName(info: ["CFBundleDisplayName": "Bam Preview", "CFBundleName": "Bam"])) == "Quit Bam Preview?",
                  "The preview's display name was not used")
        try check(QuitConfirmationModel.appName(info: ["CFBundleName": "Bam"]) == "Bam" && QuitConfirmationModel.appName(info: [:]) == "Bam"
                  && QuitConfirmationModel.appName(info: ["CFBundleDisplayName": "  "]) == "Bam", "The app name fallback was wrong")
    }
}
