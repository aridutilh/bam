import Foundation
import Darwin

@main enum ProfileLockTests {
    static func main() throws {
        if CommandLine.arguments.count > 2 {
            let lock = ProfileLock()
            let result = try lock.acquire(in: URL(fileURLWithPath: CommandLine.arguments[2]))
            if result == .occupied { exit(73) }
            if CommandLine.arguments[1] == "--hold" {
                print("READY"); fflush(stdout)
                while true { pause() }
            }
            exit(0)
        }
        var checks = 0
        func require(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            checks += 1
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bam-lock-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        func child(_ mode: String, at directory: URL) throws -> (Process, Pipe) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = [mode, directory.path]
            process.standardOutput = output
            try process.run()
            return (process, output)
        }
        func probe(_ directory: URL) throws -> Int32 {
            let (process, _) = try child("--probe", at: directory)
            process.waitUntilExit()
            return process.terminationStatus
        }
        let first = ProfileLock(), second = ProfileLock()
        let initialIdentity = ProfileLock.identity(for: base)
        require(try first.acquire(in: base) == .acquired && first.isHeld, "Fresh profile locks")
        require(ProfileLock.identity(for: base) == initialIdentity, "Identity is stable before and after creating the directory")
        require(try second.acquire(in: base) == .occupied && !second.isHeld, "Second descriptor is refused")
        require(try probe(base) == 73, "Separate process is refused")
        require(try probe(base.appendingPathComponent("other")) == 0, "Separate profile is independent")
        require(try first.acquire(in: base) == .acquired, "Reacquire keeps existing ownership")
        require(try probe(base) == 73, "Reacquire did not drop the lock")
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: base)
        require(try probe(alias) == 73, "Symlink aliases share the lock")
        require(ProfileLock.identity(for: alias) == ProfileLock.identity(for: base), "Aliases share activation identity")
        first.release()
        require(!first.isHeld && FileManager.default.fileExists(atPath: base.appendingPathComponent("instance.lock").path), "Release keeps the lock inode")
        require(try probe(base) == 0, "Released profile can be opened")
        require(try probe(base) == 0, "Normal process exit releases ownership")
        let (holder, output) = try child("--hold", at: base)
        defer { if holder.isRunning { holder.terminate(); holder.waitUntilExit() } }
        let ready = output.fileHandleForReading.availableData
        require(String(data: ready, encoding: .utf8) == "READY\n", "Child acquired lock before crash")
        require(try probe(base) == 73, "Live child owns profile")
        kill(holder.processIdentifier, SIGKILL); holder.waitUntilExit()
        require(try probe(base) == 0, "SIGKILL releases stale lock without deleting file")
        let invalid = base.appendingPathComponent("file")
        try Data().write(to: invalid)
        do {
            _ = try second.acquire(in: invalid)
            require(false, "Invalid profile must not launch unguarded")
        } catch { require(!second.isHeld, "I/O failure is explicit and holds no descriptor") }
        print("PASS: Profile locks — \(checks) exclusivity, process exit, SIGKILL, aliases and I/O checks")
    }
}
