import Darwin
import Foundation

/// Moves Highball's data between homes (#24, #68): every top-level entry except the pointer file
/// and the trash is copied, checked, and only then removed at the source, so a failure part way
/// leaves the old home intact.
///
/// The copy is descriptor-relative and does not follow symbolic links. A Wine prefix contains
/// `dosdevices/z:` pointing at `/` and `drive_c/users/<user>/{Documents,Desktop,Downloads}` at
/// the real home folders. `FileManager.copyItem` is the wrong tool on a network share: it also
/// copies ACLs, `com.apple.provenance` and Spotlight's `.metadata_never_index` marker, and SMB
/// commonly refuses those — the failure reads as ".metadata_never_index couldn’t be copied
/// because you don’t have permission to access drive_c". Data and the link structure are what
/// an environment needs; Apple extra files are not, and a new marker is planted at the
/// destination so Spotlight stays out.
///
/// File bytes go through `read`/`write` whenever the destination is not the same local APFS
/// volume. `fclonefileat` (and `fcopyfile`) on smbfs can return success or hang without sending
/// a byte — macOS asks the server to clone, the source is this Mac, and the share sits idle
/// while the strip still says "Copying…". On a stream copy the check is the bytes actually
/// written, not a walk of the destination, because a flaky share can stall that walk.
public enum HomeMove {
    public static let skipped: Set<String> = ["config.json", ".trash", ".DS_Store", ".metadata_never_index"]

    /// Apple extra files that are not part of a Windows environment. Skipped at every level so a
    /// share that vetoes them (Samba often lists `.metadata_never_index`) cannot abort a move,
    /// and so a marker inside `drive_c` is not required to exist at the destination.
    static let ephemeral: Set<String> = [
        ".DS_Store",
        ".metadata_never_index",
        ".metadata_never_index_unless_rootfs",
        ".localized",
        ".Spotlight-V100",
        ".fseventsd",
        ".TemporaryItems",
        ".Trashes",
        ".Trash",
        ".AppleDouble",
        ".AppleDB",
        ".AppleDesktop",
    ]

    /// `entry` is the top-level name (`bottles`, `engines`, …); `copied` is bytes written and
    /// `items` is files and folders created, so a tree of tiny files is not stuck on "0 MB".
    public static func move(from source: URL, to target: URL,
                            progress: (_ entry: String, _ copied: Int64, _ items: Int) -> Void = { _, _, _ in }) throws {
        // NSOpenPanel sometimes hands back a file URL without a directory hint; appending
        // "bottles" would then replace the folder name and write into the share's root.
        let source = URL(fileURLWithPath: source.path, isDirectory: true)
        let target = URL(fileURLWithPath: target.path, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // Decide clone after the destination exists: a missing path makes statfs fail closed,
        // which would stream a same-disk copy.
        try move(from: source, to: target, clone: sameLocalVolume(source, target), progress: progress)
    }

    /// `clone` is the same-disk APFS fast path. Tests pass `false` to prove the stream copy
    /// (network shares, and clonefile falling back) still lands a complete tree on this disk.
    static func move(from source: URL, to target: URL, clone: Bool,
                     progress: (_ entry: String, _ copied: Int64, _ items: Int) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        // Plant the marker before the bulk copy so Spotlight does not start on a 90 GB tree mid-move.
        // A share that vetoes the name is fine: ensure() retries after relaunch, and a missing
        // marker must not block the move (that is the bug).
        HighballPaths(home: target).excludeFromSpotlight()
        let entries = try fm.contentsOfDirectory(atPath: source.path)
            .filter { !skipped.contains($0) && !isEphemeral($0) }
            .sorted()
        for name in entries {
            let from = source.appending(path: name), to = target.appending(path: name)
            // Do not walk the tree first: on a large environment that is minutes of zero
            // network while the strip already says Copying. Bytes start moving immediately.
            progress(name, 0, 0)
            try replaceDestination(to, name: name)
            var copied: Int64 = 0
            var items = 0
            var lastReport = Date.distantPast
            func publish() {
                let now = Date()
                guard now.timeIntervalSince(lastReport) >= 0.1 else { return }
                lastReport = now
                progress(name, copied, items)
            }
            func wrote(_ n: Int64) { copied += n; publish() }
            func item() { items += 1; publish() }
            try copyTree(from: from, to: to, clone: clone, wrote: wrote, item: item)
            progress(name, copied, items)
            let sourceTally = try tally(from)
            if clone {
                let destTally = try tally(to)
                guard sourceTally == destTally else {
                    throw HighballError.failed("'\(name)' did not copy completely (\(sourceTally.files) files, \(sourceTally.bytes) bytes at the source, \(destTally.files) files, \(destTally.bytes) bytes at the destination); nothing was removed")
                }
            } else if sourceTally.bytes != copied {
                // Walking the destination on a network share is slow and can stall; the bytes
                // we actually wrote still have to match the source before anything is removed.
                throw HighballError.failed("'\(name)' did not copy completely (\(sourceTally.files) files, \(sourceTally.bytes) bytes at the source, \(copied) bytes written); nothing was removed")
            }
        }
        for name in entries { try fm.removeItem(at: source.appending(path: name)) }
    }

    /// File count and byte total under a path, links counted as themselves and not followed.
    /// Ephemeral Apple files are omitted so a skipped marker cannot make a complete copy look short.
    public static func tally(_ root: URL) throws -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        var files = 0, bytes: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let rootValues = try? root.resourceValues(forKeys: Set(keys + [.isDirectoryKey])) else { return (0, 0) }
        if isEphemeral(root.lastPathComponent) { return (0, 0) }
        if rootValues.isDirectory != true { return (1, Int64(rootValues.fileSize ?? 0)) }
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else { return (0, 0) }
        for case let url as URL in e {
            if isEphemeral(url.lastPathComponent) { continue }
            let v = try url.resourceValues(forKeys: Set(keys))
            if v.isSymbolicLink == true { files += 1; continue }
            if v.isRegularFile == true { files += 1; bytes += Int64(v.fileSize ?? 0) }
        }
        return (files, bytes)
    }

    static func isEphemeral(_ name: String) -> Bool {
        ephemeral.contains(name) || name.hasPrefix("._")
    }

    /// Clonefile is APFS and same-volume only. smbfs often advertises copy-offload; clonefile
    /// then hangs or "succeeds" without putting bytes on the wire.
    static func sameLocalVolume(_ a: URL, _ b: URL) -> Bool {
        var sa = statfs(), sb = statfs()
        guard statfs(a.path, &sa) == 0, statfs(b.path, &sb) == 0 else { return false }
        let local = UInt32(MNT_LOCAL)
        guard (UInt32(sa.f_flags) & local) != 0, (UInt32(sb.f_flags) & local) != 0 else { return false }
        guard fsTypeName(sa) == "apfs", fsTypeName(sb) == "apfs" else { return false }
        return sa.f_fsid.val.0 == sb.f_fsid.val.0 && sa.f_fsid.val.1 == sb.f_fsid.val.1
    }

    private static func fsTypeName(_ s: statfs) -> String {
        withUnsafeBytes(of: s.f_fstypename) { raw in
            raw.withMemoryRebound(to: CChar.self) { String(cString: $0.baseAddress!) }
        }
    }

    /// Removes a leftover destination entry without following it. `removeItem` is enough on a
    /// healthy tree; Purge is the fallback when a previous failed copy left SMB permissions that
    /// Foundation will not unlink, so a retry is not stuck on the debris.
    private static func replaceDestination(_ to: URL, name: String) throws {
        var st = stat()
        guard lstat(to.path, &st) == 0 else { return }
        do {
            try FileManager.default.removeItem(at: to)
        } catch {
            if to.pathComponents.count >= 4 { _ = Purge.tree(at: to) }
        }
        guard lstat(to.path, &st) != 0 else {
            throw HighballError.failed("Could not replace “\(name)” in the destination folder. Remove that folder and try again. Nothing was removed from the original location.")
        }
    }

    private static func copyTree(from src: URL, to dst: URL, clone: Bool,
                                 wrote: (Int64) -> Void, item: () -> Void) throws {
        raiseFileLimit()
        let name = src.lastPathComponent
        let srcParent = open(src.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard srcParent >= 0 else { throw fail(name) }
        defer { close(srcParent) }
        let dstParent = open(dst.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dstParent >= 0 else { throw fail(name) }
        defer { close(dstParent) }

        var stack: [DirLevel] = []
        defer {
            while let level = stack.popLast() {
                close(level.srcFd)
                close(level.dstFd)
            }
        }
        try copyEntry(name, from: srcParent, to: dstParent, display: name,
                      clone: clone, wrote: wrote, item: item, stack: &stack)
        while var level = stack.last {
            if level.next < level.kids.count {
                let kid = level.kids[level.next]
                level.next += 1
                stack[stack.count - 1] = level
                try copyEntry(kid, from: level.srcFd, to: level.dstFd,
                              display: level.display + "/" + kid,
                              clone: clone, wrote: wrote, item: item, stack: &stack)
            } else {
                stack.removeLast()
                close(level.srcFd)
                close(level.dstFd)
            }
        }
    }

    private struct DirLevel {
        let srcFd: Int32, dstFd: Int32
        let kids: [String]
        var next: Int
        let display: String
    }

    private static func copyEntry(_ name: String, from srcParent: Int32, to dstParent: Int32,
                                  display: String, clone: Bool, wrote: (Int64) -> Void, item: () -> Void,
                                  stack: inout [DirLevel]) throws {
        guard isSafeName(name) else { throw fail(display, EINVAL) }
        if isEphemeral(name) { return }
        var st = stat()
        guard fstatat(srcParent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw fail(display) }
        switch st.st_mode & S_IFMT {
        case S_IFLNK:
            try copySymlink(name, from: srcParent, to: dstParent, display: display)
            item()
        case S_IFDIR:
            try copyDirectory(name, from: srcParent, to: dstParent, observed: st,
                              display: display, stack: &stack)
            item()
        case S_IFREG:
            try copyFile(name, from: srcParent, to: dstParent, observed: st,
                         display: display, clone: clone, wrote: wrote)
            item()
        default:
            // Sockets, FIFOs and device nodes are runtime leftovers, not environment data.
            return
        }
    }

    private static func copyDirectory(_ name: String, from srcParent: Int32, to dstParent: Int32,
                                      observed: stat, display: String, stack: inout [DirLevel]) throws {
        let mode = (observed.st_mode & 0o777) | 0o700
        if mkdirat(dstParent, name, mode) != 0 {
            try makeWritable(dstParent)
            guard mkdirat(dstParent, name, mode) == 0 else { throw fail(display) }
        }
        _ = fchmodat(dstParent, name, mode, AT_SYMLINK_NOFOLLOW)

        let srcFd = openat(srcParent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard srcFd >= 0 else { throw fail(display) }
        var dstFd = openat(dstParent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if dstFd < 0 {
            try makeWritable(dstParent)
            dstFd = openat(dstParent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard dstFd >= 0 else {
            close(srcFd)
            throw fail(display)
        }
        guard let kids = entries(of: srcFd) else {
            let code = errno
            close(srcFd)
            close(dstFd)
            throw fail(display, code)
        }
        stack.append(DirLevel(srcFd: srcFd, dstFd: dstFd, kids: kids, next: 0, display: display))
    }

    private static func copyFile(_ name: String, from srcParent: Int32, to dstParent: Int32,
                                 observed: stat, display: String, clone: Bool,
                                 wrote: (Int64) -> Void) throws {
        let srcFd = openat(srcParent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard srcFd >= 0 else {
            // Became a symlink between lstat and open: copy the link, never the target.
            if errno == ELOOP { try copySymlink(name, from: srcParent, to: dstParent, display: display); return }
            throw fail(display)
        }
        defer { close(srcFd) }

        if clone, fclonefileat(srcFd, dstParent, name, 0) == 0 {
            wrote(Int64(observed.st_size))
            return
        }

        let mode = observed.st_mode & 0o777
        var dstFd = openat(dstParent, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        if dstFd < 0 {
            try makeWritable(dstParent)
            dstFd = openat(dstParent, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        }
        guard dstFd >= 0 else { throw fail(display) }

        do {
            try writeCopy(from: srcFd, to: dstFd, display: display, wrote: wrote)
        } catch {
            close(dstFd)
            _ = unlinkat(dstParent, name, 0)
            throw error
        }
        _ = fchmod(dstFd, mode)
        close(dstFd)
    }

    /// Plain POSIX copy. `fcopyfile` is not used: on smbfs it can take the server-side copy
    /// path and stall the same way clonefile does.
    private static func writeCopy(from srcFd: Int32, to dstFd: Int32, display: String,
                                  wrote: (Int64) -> Void) throws {
        let bufSize = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while true {
            let n = read(srcFd, buf, bufSize)
            if n == 0 { return }
            if n < 0 {
                if errno == EINTR { continue }
                throw fail(display, errno)
            }
            var off = 0
            while off < n {
                let w = write(dstFd, buf + off, n - off)
                if w < 0 {
                    if errno == EINTR { continue }
                    throw fail(display, errno)
                }
                off += w
            }
            wrote(Int64(n))
        }
    }

    private static func copySymlink(_ name: String, from srcParent: Int32, to dstParent: Int32,
                                    display: String) throws {
        var buf = [CChar](repeating: 0, count: 4096)
        var n = readlinkat(srcParent, name, &buf, buf.count)
        while n == buf.count {
            buf = [CChar](repeating: 0, count: buf.count * 2)
            n = readlinkat(srcParent, name, &buf, buf.count)
        }
        guard n >= 0 else { throw fail(display) }
        var target = [CChar](repeating: 0, count: n + 1)
        for i in 0..<n { target[i] = buf[i] }
        if symlinkat(target, dstParent, name) != 0 {
            try makeWritable(dstParent)
            guard symlinkat(target, dstParent, name) == 0 else { throw fail(display) }
        }
    }

    private static func makeWritable(_ dirFd: Int32) throws {
        var st = stat()
        guard fstat(dirFd, &st) == 0 else { return }
        _ = fchmod(dirFd, (st.st_mode & 0o777) | 0o700)
    }

    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private static func entries(of fd: Int32) -> [String]? {
        let copy = dup(fd)
        guard copy >= 0, let dir = fdopendir(copy) else {
            let e = errno
            if copy >= 0 { close(copy) }
            errno = e
            return nil
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

    private static func raiseFileLimit() {
        var lim = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return }
        let target = min(rlim_t(65536), lim.rlim_max)
        guard lim.rlim_cur < target else { return }
        lim.rlim_cur = target
        _ = setrlimit(RLIMIT_NOFILE, &lim)
    }

    private static func fail(_ display: String, _ code: Int32 = errno) -> HighballError {
        let reason = String(cString: strerror(code))
        let shown = display.count <= 96 ? display : (display.split(separator: "/").suffix(2).joined(separator: "/"))
        switch code {
        case EACCES, EPERM:
            return .failed("“\(shown)” couldn’t be copied onto that drive (\(reason)). On a network share, sign in with an account that can create files. Nothing was removed from the original location.")
        case ENOTSUP, EOPNOTSUPP, EILSEQ:
            return .failed("That drive rejected “\(shown)”. An environment needs symbolic links and names like c:. Nothing was removed from the original location.")
        default:
            return .failed("Could not copy “\(shown)” (\(reason)). Nothing was removed from the original location.")
        }
    }
}
