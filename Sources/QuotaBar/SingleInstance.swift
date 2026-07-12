import Foundation

enum SingleInstance {
    private static var lockFD: Int32 = -1

    /// Returns false if another QuotaBar already holds the lock (caller should exit).
    @discardableResult
    static func tryAcquire() -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuotaBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("singleton.lock").path

        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        // Keep the fd open for the process lifetime so the lock is held.
        lockFD = fd
        let pid = "\(ProcessInfo.processInfo.processIdentifier)"
        pid.withCString { ptr in
            ftruncate(fd, 0)
            _ = write(fd, ptr, strlen(ptr))
        }
        return true
    }
}
