import Foundation
import Darwin

/// The descriptor, not the file's presence or PID, owns the profile. Keep the
/// inode in place on release so contenders can never lock different files.
final class ProfileLock {
    enum Acquisition { case acquired, occupied }
    private var descriptor: CInt = -1
    private var directory: URL?
    var isHeld: Bool { descriptor >= 0 }

    static func identity(for directory: URL) -> URL {
        // Foundation can resolve a missing leaf differently once it exists
        // (notably /var -> /private/var). Resolve the existing ancestor first.
        var ancestor = directory.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in missing.reversed() { resolved.appendPathComponent(component) }
        return URL(fileURLWithPath: resolved.path, isDirectory: true)
    }

    @discardableResult func acquire(in directory: URL) throws -> Acquisition {
        let directory = Self.identity(for: directory)
        if isHeld {
            guard self.directory == directory else { throw POSIXError(.EBUSY) }
            return .acquired
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return .occupied }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        self.directory = directory
        descriptor = fd
        return .acquired
    }

    func release() {
        guard isHeld else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
        directory = nil
    }

    deinit { release() }
}
