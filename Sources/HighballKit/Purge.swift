import Foundation

/// One entry a purge could not remove, with enough state to explain why.
///
/// Foundation's own error is useless here: a failed recursive remove reports the *top-level*
/// path it was handed and never the entry that actually blocked it, so the app has no way to
/// name the culprit without walking the tree itself (#38).
public struct PurgeFailure: Sendable, Hashable, CustomStringConvertible {
    public let path: String
    public let code: Int32
    public let mode: mode_t
    public let flags: UInt32
    public let uid: UInt32

    public init(path: String, code: Int32, mode: mode_t = 0, flags: UInt32 = 0, uid: UInt32 = 0) {
        self.path = path
        self.code = code
        self.mode = mode
        self.flags = flags
        self.uid = uid
    }

    /// The errno text, e.g. "Permission denied".
    public var reason: String { String(cString: strerror(code)) }

    /// Mode, flags and uid go in the message on purpose: they are the only evidence that can
    /// tell us what makes a directory unremovable inside a real prefix, which #38 left open.
    public var description: String {
        "\(path): \(reason) (mode \(String(mode & 0o7777, radix: 8)) flags \(flags) uid \(uid))"
    }
}

/// Removes a directory tree, doing everything a user could do without privilege escalation.
///
/// `FileManager.removeItem` gives up on far less than the filesystem actually allows: it stops
/// at the first unwritable directory, immutable flag or deny ACL, and cannot delete a path over
/// `PATH_MAX` at all. Since a Wine prefix is written by arbitrary Windows installers, any of
/// those can appear in one.
public enum Purge {
    /// Best effort. Returns what is still on disk afterwards, deepest entry first, so the
    /// caller can name the real cause rather than an ENOTEMPTY cascade above it.
    @discardableResult
    public static func tree(at url: URL) -> [PurgeFailure] {
        // This deletes recursively and eventually shells out to `rm -rf`, so refuse the shallow
        // paths a bug upstream could produce: "/", "/Users", "/Users/someone", a volume root.
        // Everything Highball actually purges is at least <home>/.trash/<entry>, far deeper.
        guard url.isFileURL, url.pathComponents.count >= 4 else {
            return [PurgeFailure(path: url.path, code: EINVAL)]
        }
        // Healthy trees, which is nearly all of them, take the cheap path.
        if (try? FileManager.default.removeItem(at: url)) != nil { return [] }

        var failures: [PurgeFailure] = []
        force(url.path, &failures)
        if !exists(url.path) { return [] }

        // Two things the walk above cannot clear: stripping an ACL needs acl(3), and unlink()
        // on a path over PATH_MAX fails with ENAMETOOLONG whatever the permissions. Both fall
        // to the system tools — chmod uses acl_set_file, and rm walks with fts, which chdirs
        // so a long path is never formed. Ordering matters: modes are already repaired here,
        // so chmod can descend.
        _ = run("/bin/chmod", ["-R", "-N", url.path])
        _ = run("/bin/rm", ["-rf", url.path])
        if !exists(url.path) { return [] }

        failures.removeAll()
        collect(url.path, &failures)
        return failures
    }

    /// Depth-first, repairing each node on the way down.
    private static func force(_ path: String, _ failures: inout [PurgeFailure]) {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            if errno != ENOENT { failures.append(PurgeFailure(path: path, code: errno)) }
            return
        }
        // uchg/uappnd block unlink and rmdir. lchflags, never chflags: every bottle links
        // drive_c/users/<user>/{Documents,Desktop,Downloads} at the real home folders and
        // dosdevices/z: at /, and chflags follows symlinks straight out of the tree.
        if st.st_flags != 0 { _ = lchflags(path, 0) }

        // Likewise lstat, never fileExists(atPath:isDirectory:) — that call follows symlinks
        // and calls a link to ~/Documents a directory, so a recursion built on it would
        // descend into and delete the user's home folders.
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            if unlink(path) != 0, errno != ENOENT { failures.append(fail(path, st)) }
            return
        }
        // A directory's contents cannot be listed or unlinked without owner rwx on it.
        if (st.st_mode & 0o700) != 0o700 { _ = chmod(path, st.st_mode | 0o700) }
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            force(path + "/" + entry, &failures)
        }
        if rmdir(path) != 0, errno != ENOENT { failures.append(fail(path, st)) }
    }

    /// Reports what survived. Directories that are merely non-empty are skipped, so the list
    /// holds the entries that actually refused to go rather than every parent above them.
    private static func collect(_ path: String, _ failures: inout [PurgeFailure]) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            if unlink(path) != 0 { failures.append(fail(path, st)) }
            return
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        for entry in entries { collect(path + "/" + entry, &failures) }
        if (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty ?? false {
            if rmdir(path) != 0 { failures.append(fail(path, st)) }
        }
    }

    private static func fail(_ path: String, _ st: stat) -> PurgeFailure {
        PurgeFailure(path: path, code: errno, mode: st.st_mode, flags: st.st_flags, uid: st.st_uid)
    }

    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
