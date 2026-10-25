import CryptoKit
import Foundation

/// Static declarativeNetRequest audit on original temporary packages: counts, path safety, bounds, disclosure text.
@main struct ExtensionStaticRuleAuditTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() {
        do { print("PASS: Extension static rule audit — \(try run()) checks") }
        catch { fputs("FAIL: Extension static rule audit: \(error)\n", stderr); exit(1) }
    }

    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(description: message) }; checks += 1 }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bam-static-audit-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func write(_ value: Any, _ url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value).write(to: url)
        }
        func rule(_ id: Int, _ condition: [String: Any], action: String = "block") -> [String: Any] {
            ["id": id, "priority": 1, "action": ["type": action], "condition": condition]
        }
        func digest(_ folder: URL) throws -> [String: String] {
            var result: [String: String] = [:]
            for case let url as URL in fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])! where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                result[url.path] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            }
            return result
        }
        let all = Array(ExtensionStaticRuleAudit.webkitResourceTypes).sorted()

        // Counted shapes per ruleset, default state kept, clean rulesets omitted, rule text never disclosed.
        let package = root.appendingPathComponent("package", isDirectory: true)
        try write([rule(1, ["urlFilter": "||secret-filter.example^", "requestMethods": ["post"]]),
                   rule(2, ["urlFilter": "/a", "excludedRequestMethods": ["get"]], action: "allow"),
                   rule(3, ["urlFilter": "/b", "requestMethods": [] as [String]]),
                   rule(4, ["urlFilter": "/c", "excludedResourceTypes": all + ["webtransport"]]),
                   rule(5, ["urlFilter": "/d", "excludedResourceTypes": ["image"]]),
                   rule(6, ["urlFilter": "/e"]), "not a rule"], package.appendingPathComponent("rules/main.json"))
        try write([rule(1, ["urlFilter": "/f"])], package.appendingPathComponent("rules/clean.json"))
        try write([rule(1, ["urlFilter": "/g", "requestMethods": ["head"]], action: "redirect")], package.appendingPathComponent("off.json"))
        try write(["not": "an array"], package.appendingPathComponent("object.json"))
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try write([rule(1, ["urlFilter": "/h", "requestMethods": ["get"]])], outside.appendingPathComponent("escape.json"))
        try fm.createSymbolicLink(at: package.appendingPathComponent("linked.json"), withDestinationURL: outside.appendingPathComponent("escape.json"))
        try fm.createSymbolicLink(at: package.appendingPathComponent("linkdir"), withDestinationURL: outside)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Audit fixture", "version": "2.1",
            "declarative_net_request": ["rule_resources": [
                ["id": "main", "enabled": true, "path": "/rules/main.json"], ["id": "clean", "enabled": true, "path": "rules/clean.json"],
                ["id": "off", "enabled": false, "path": "off.json"], ["id": "missing", "enabled": true, "path": "missing.json"],
                ["id": "traversal", "enabled": true, "path": "rules/../../outside/escape.json"], ["id": "link", "enabled": true, "path": "linked.json"],
                ["id": "linkdir", "enabled": true, "path": "linkdir/escape.json"], ["id": "object", "enabled": true, "path": "object.json"],
                ["id": "scheme", "enabled": true, "path": "file:///etc/hosts"], ["enabled": true, "path": "rules/main.json"]]]]
        try write(manifest, package.appendingPathComponent("manifest.json"))
        let before = try digest(package)
        let audit = ExtensionStaticRuleAudit.audit(package: package, version: "2.1")
        try check(audit.rulesets == [.init(id: "main", enabledByDefault: true, methodRules: 2, excludesAllTypesRules: 1),
                                     .init(id: "off", enabledByDefault: false, methodRules: 1, excludesAllTypesRules: 0),
                                     .init(id: "#10", enabledByDefault: true, methodRules: 2, excludesAllTypesRules: 1)],
                  "Counts, default state or omission of clean rulesets were wrong: \(audit.rulesets)")
        try check(audit.unreadable == ["missing", "traversal", "link", "linkdir", "object", "scheme"],
                  "Unsafe, missing or malformed rulesets were not reported as unchecked: \(audit.unreadable)")
        try check(try digest(package) == before, "The audit changed package files")
        let note = audit.note ?? ""
        try check(note.contains("5 use request-method conditions") && note.contains("2 exclude every resource type this browser supports") &&
                  note.contains("main (on by default)") && note.contains("off (off by default)") && note.contains("Bam leaves them unchanged") &&
                  note.contains("The extension can turn rulesets on or off") && note.contains("could not check static rulesets missing, traversal, link, linkdir, object, scheme") &&
                  !note.contains("secret-filter") && !note.contains("/rules/") && !note.contains("escape.json"),
                  "The disclosure was incomplete or exposed rule text/paths: \(note)")

        // Freshness is per version and format; a package without static rules says nothing.
        try check(audit.isCurrent(for: "2.1") && !audit.isCurrent(for: "2.2") &&
                  !ExtensionStaticRuleAudit(format: ExtensionStaticRuleAudit.currentFormat - 1, extensionVersion: "2.1", rulesets: [], unreadable: []).isCurrent(for: "2.1"),
                  "Audit freshness ignored the extension version or audit format")
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try write(["manifest_version": 3, "name": "Plain", "version": "1"], plain.appendingPathComponent("manifest.json"))
        let plainAudit = ExtensionStaticRuleAudit.audit(package: plain, version: "1")
        try check(plainAudit.rulesets.isEmpty && plainAudit.unreadable.isEmpty && plainAudit.note == nil, "A package without static rules produced a disclosure")
        try check(ExtensionStaticRuleAudit.audit(package: root.appendingPathComponent("absent"), version: "1").note == nil, "A package without a manifest produced a disclosure")

        // Bounded: at most 100 rulesets are read and the list in the note is capped.
        let many = root.appendingPathComponent("many", isDirectory: true)
        try write([rule(1, ["urlFilter": "/m", "requestMethods": ["get"]])], many.appendingPathComponent("r.json"))
        let resources = (0..<102).map { ["id": "set\($0)", "enabled": false, "path": "r.json"] as [String: Any] }
        try write(["manifest_version": 3, "name": "Many", "version": "1", "declarative_net_request": ["rule_resources": resources]], many.appendingPathComponent("manifest.json"))
        let manyAudit = ExtensionStaticRuleAudit.audit(package: many, version: "1")
        try check(manyAudit.rulesets.count == 100 && manyAudit.unreadable == ["set100", "set101"] && (manyAudit.note ?? "").contains("and 92 more"),
                  "Ruleset bounds or note capping failed: \(manyAudit.rulesets.count) \(manyAudit.unreadable)")

        // The aggregate byte budget is spent by every read, including files that then fail to parse.
        let budget = root.appendingPathComponent("budget", isDirectory: true)
        try Data("[not json at all]".utf8).write(to: { try? fm.createDirectory(at: budget, withIntermediateDirectories: true); return budget.appendingPathComponent("bad.json") }())
        try write([rule(1, ["urlFilter": "/z", "requestMethods": ["get"]])], budget.appendingPathComponent("good.json"))
        let badSize = try Data(contentsOf: budget.appendingPathComponent("bad.json")).count, goodSize = try Data(contentsOf: budget.appendingPathComponent("good.json")).count
        let budgetManifest: [String: Any] = ["declarative_net_request": ["rule_resources": [["id": "bad", "enabled": true, "path": "bad.json"], ["id": "good", "enabled": true, "path": "good.json"]]]]
        let starved = ExtensionStaticRuleAudit.audit(package: budget, manifest: budgetManifest, version: "1", totalLimit: badSize + goodSize - 1)
        let funded = ExtensionStaticRuleAudit.audit(package: budget, manifest: budgetManifest, version: "1", totalLimit: badSize + goodSize)
        try check(starved.unreadable == ["bad", "good"] && starved.rulesets.isEmpty && funded.unreadable == ["bad"] && funded.rulesets.map(\.id) == ["good"],
                  "A malformed file did not spend the aggregate budget: starved=\(starved.unreadable) funded=\(funded.unreadable)")

        // Persisted form round-trips.
        let encoded = try JSONEncoder().encode(audit)
        try check(try JSONDecoder().decode(ExtensionStaticRuleAudit.self, from: encoded) == audit, "The audit did not round-trip through its persisted form")
        return checks
    }
}
