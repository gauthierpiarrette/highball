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

    /// Mode, flags and uid are recorded as observed BEFORE any repair, because they are the only
    /// evidence of what made an entry unremovable — the open question left by issue #38.
    public var description: String {
        "\(path): \(reason) (mode \(String(mode & 0o7777, radix: 8)) flags \(flags) uid \(uid))"
    }
}

/// Removes a directory tree, doing everything a user could do without privilege escalation.
///
/// `FileManager.removeItem` gives up on far less than the filesystem allows: it stops at the
/// first unwritable directory, immutable flag or deny ACL, and cannot delete a path over
/// `PATH_MAX` at all. A Wine prefix is written by arbitrary Windows installers, so any of those
/// can appear in one.
///
/// The walk is **fd-relative** — `openat`/`fstatat`/`unlinkat` against a directory descriptor,
/// with `O_NOFOLLOW`, never a re-resolved path string. That is not a micro-optimisation, it is
/// the safety property: every bottle contains symlinks pointing out of itself
/// (`drive_c/users/<user>/{Documents,Desktop,Downloads}` at the real home folders, `dosdevices/z:`
/// at `/`), and Wine's mountmgr writes into a live prefix. A path-based walk re-resolves each
/// component after checking it, so a directory that becomes a symlink between the check and the
/// unlink redirects the delete outside the tree — verified: a path-based version deleted every
/// file in a directory outside the bottle, 6 runs out of 6. Holding descriptors makes that
/// unrepresentable, and it removes the PATH_MAX ceiling for free, since each name is relative.
public enum Purge {
    /// Best effort. Returns what is still on disk afterwards. An empty result means the tree is
    /// genuinely gone: the caller is told so only after a positive check, never by assumption.
    @discardableResult
    public static func tree(at url: URL) -> [PurgeFailure] {
        // This deletes recursively, so refuse the shallow paths a bug upstream could produce:
        // "/", "/Users", "/Users/someone", a volume root. Everything Highball purges is at least
        // <home>/.trash/<entry>, far deeper.
        guard url.isFileURL, url.pathComponents.count >= 4 else {
            return [PurgeFailure(path: url.path, code: EINVAL)]
        }
        // Deliberately no FileManager.removeItem fast path. removefile(3) resolves paths as it
        // walks, so it has exactly the symlink-swap TOCTOU the walk below exists to remove —
        // measured destroying data outside the tree in 39 of 45 rounds. Keeping it in front "for
        // speed" would have reintroduced the bug behind the fix. The walk costs a little more on
        // a healthy prefix and is the only thing that touches user data.
        //
        // The walk holds one descriptor per directory level, so its ceiling is the file
        // limit rather than the stack. That matters because the shipping app is not the shell:
        // a GUI-launched .app gets a soft RLIMIT_NOFILE of 256, so a prefix a few hundred levels
        // deep stranded itself in .trash and blamed "Directory not empty".
        raiseFileLimit()

        var failures: [PurgeFailure] = []
        let parentPath = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        let parent = open(parentPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if parent < 0 {
            return [PurgeFailure(path: parentPath, code: errno)]
        }
        remove(in: parent, named: name, at: url.path, &failures)
        close(parent)

        // Last resort for whatever the walk could not finish — a depth past even the raised
        // file limit, most realistically. rm walks with fts, which recycles descriptors and does
        // not follow symlinks, so it is safe to point at a tree already isolated inside .trash.
        if !failures.isEmpty {
            var probe = stat()
            if lstat(url.path, &probe) == 0 {
                _ = run("/bin/rm", ["-rf", url.path])
                if lstat(url.path, &probe) != 0 { return [] }
            }
        }

        // Never report an all-clear we have not verified. A silently stranded prefix is how the
        // original bug hid: the caller believed the delete had finished.
        var st = stat()
        if lstat(url.path, &st) == 0, failures.isEmpty {
            failures.append(PurgeFailure(path: url.path, code: ENOTEMPTY,
                                         mode: st.st_mode, flags: st.st_flags, uid: st.st_uid))
        }
        return failures
    }

    /// Removes one entry by name, relative to an open descriptor for its parent directory.
    ///
    /// Iterative, with an explicit stack, deliberately. The recursive version overflowed the
    /// 512 KB stack of a Swift cooperative-pool thread at around 450 levels and wedged the
    /// process in an uninterruptible wait — a prefix deep enough to hit that is exactly the kind
    /// a runaway Windows installer produces, and it would have hung the app with no error.
    private static func remove(in parent: Int32, named name: String, at path: String,
                               _ failures: inout [PurgeFailure]) {
        var st = stat()
        guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            let e = errno
            if e != ENOENT { failures.append(PurgeFailure(path: path, code: e)) }
            return
        }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            removeLeaf(in: parent, named: name, at: path, observed: st, &failures)
            return
        }

        /// One open directory on the way down, with the children still to process.
        struct Level {
            let fd: Int32, parent: Int32
            let name: String, path: String
            let observed: stat
            var kids: [String]
            var next: Int
        }
        var stack: [Level] = []

        func push(parent: Int32, name: String, path: String, observed: stat) -> Bool {
            var fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0, errno == EACCES || errno == EPERM {
                // A directory's contents cannot be listed, or even opened, without owner rwx on
                // it — a 0000 directory fails openat outright, so the mode has to be repaired
                // before the descriptor exists. fchmodat is name-relative and does not follow a
                // symlink, so this cannot reach outside the tree.
                //
                // Order matters: chmod on an immutable directory fails, so the flag has to go
                // first, and clearing it needs a descriptor we cannot get. lchflags is the only
                // way out of that deadlock; without it a 0000+uchg directory stranded the bottle
                // in .trash forever, and rm cannot clear the flag either.
                if observed.st_flags != 0 { _ = lchflags(path, 0) }
                _ = fchmodat(parent, name, observed.st_mode | 0o700, AT_SYMLINK_NOFOLLOW)
                fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard fd >= 0 else { return false }
            if observed.st_flags != 0 { _ = fchflags(fd, 0) }
            if (observed.st_mode & 0o700) != 0o700 { _ = fchmod(fd, observed.st_mode | 0o700) }
            stack.append(Level(fd: fd, parent: parent, name: name, path: path,
                               observed: observed, kids: entries(of: fd), next: 0))
            return true
        }

        if !push(parent: parent, name: name, path: path, observed: st) {
            // Unreadable even to open: still try to unlink it, it may be empty.
            unlink(in: parent, named: name, at: path, flag: AT_REMOVEDIR, observed: st, &failures)
            return
        }

        while var level = stack.last {
            if level.next < level.kids.count {
                let kid = level.kids[level.next]
                level.next += 1
                stack[stack.count - 1] = level
                let kidPath = level.path + "/" + kid
                var kst = stat()
                guard fstatat(level.fd, kid, &kst, AT_SYMLINK_NOFOLLOW) == 0 else {
                    let e = errno
                    if e != ENOENT { failures.append(PurgeFailure(path: kidPath, code: e)) }
                    continue
                }
                if (kst.st_mode & S_IFMT) == S_IFDIR {
                    if !push(parent: level.fd, name: kid, path: kidPath, observed: kst) {
                        unlink(in: level.fd, named: kid, at: kidPath, flag: AT_REMOVEDIR,
                               observed: kst, &failures)
                    }
                } else {
                    removeLeaf(in: level.fd, named: kid, at: kidPath, observed: kst, &failures)
                }
            } else {
                // Children done: close this directory and unlink it from its own parent.
                stack.removeLast()
                close(level.fd)
                unlink(in: level.parent, named: level.name, at: level.path,
                       flag: AT_REMOVEDIR, observed: level.observed, &failures)
            }
        }
    }

    /// A non-directory: clear any flag that blocks unlink, then unlink it.
    private static func removeLeaf(in parent: Int32, named name: String, at path: String,
                                   observed: stat, _ failures: inout [PurgeFailure]) {
        // uchg/uappnd block unlink, and clearing them needs a descriptor for the entry itself.
        if observed.st_flags != 0 { clearFlags(in: parent, named: name, at: path, observed: observed) }
        unlink(in: parent, named: name, at: path, flag: 0, observed: observed, &failures)
    }

    /// Clears BSD flags on a non-directory without following a symlink and without blocking.
    ///
    /// Only the flag matters here: unlink needs write on the *parent*, not on the entry, so a
    /// mode-0000 file unlinks fine once uchg is gone. Repairing its mode first is not just
    /// unnecessary, it is impossible — chmod on an immutable file fails, and the file cannot be
    /// opened to clear the flag, which is the deadlock that left a 0000+uchg file unremovable.
    ///
    /// O_NONBLOCK matters: opening a FIFO for read otherwise waits for a writer that never
    /// arrives, and a uchg FIFO inside a prefix wedged the whole purge in openat.
    private static func clearFlags(in parent: Int32, named name: String, at path: String,
                                   observed: stat) {
        // O_SYMLINK opens a symlink itself rather than its target.
        var fd = openat(parent, name, O_SYMLINK | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        if fd >= 0 {
            _ = fchflags(fd, 0)
            close(fd)
            return
        }
        // No descriptor is obtainable (an unreadable file, an exotic node type). lchflags is the
        // only remaining route. It is path-based, which the walk otherwise avoids, but it does
        // not follow the final symlink and it changes a flag rather than removing anything.
        _ = lchflags(path, 0)
    }

    /// unlinkat, and on a permission failure one retry after stripping the entry's ACL.
    /// `chmod -h -N` takes a single path and never recurses, so unlike `chmod -R` it cannot
    /// follow a symlink out of the tree — a real defect found in review, where `chmod -R -N`
    /// stripped the ACL off the user's actual home folder through a bottle's Documents link.
    private static func unlink(in parent: Int32, named name: String, at path: String,
                               flag: Int32, observed: stat, _ failures: inout [PurgeFailure]) {
        if unlinkat(parent, name, flag) == 0 { return }
        var e = errno
        if e == ENOENT { return }
        if e == EACCES || e == EPERM {
            _ = run("/bin/chmod", ["-h", "-N", path])
            if unlinkat(parent, name, flag) == 0 { return }
            e = errno
            if e == ENOENT { return }
        }
        failures.append(PurgeFailure(path: path, code: e, mode: observed.st_mode,
                                     flags: observed.st_flags, uid: observed.st_uid))
    }

    /// Child names of an open directory, excluding "." and "..". Collected before recursing so
    /// the directory stream is closed while its entries are being removed.
    private static func entries(of fd: Int32) -> [String] {
        let copy = dup(fd)
        guard copy >= 0, let dir = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return []
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            var e = entry.pointee
            let name = withUnsafePointer(to: &e.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(e.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }

    /// Lifts the soft file limit toward the hard one. A GUI-launched app starts at 256, which is
    /// far below what a deep prefix needs, and the limit is per-process so raising it here is
    /// enough for the walk.
    private static func raiseFileLimit() {
        var lim = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return }
        // macOS refuses an unlimited value here, so aim at a large concrete one; when the hard
        // limit is effectively unlimited this simply lands on `want`.
        let target = min(rlim_t(65536), lim.rlim_max)
        guard lim.rlim_cur < target else { return }
        lim.rlim_cur = target
        _ = setrlimit(RLIMIT_NOFILE, &lim)
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
