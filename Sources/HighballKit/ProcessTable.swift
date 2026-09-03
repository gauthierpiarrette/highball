import Foundation
import Darwin

/// The processes of a Wine prefix, seen from outside, and how to end them.
///
/// `wineserver -k` asks the server to kill its clients, and the server does so by signalling
/// each client thread. A client parked in the Mac driver's Cocoa run loop does not always act
/// on that before the server is gone, and once the server is gone nobody kills it: on this
/// machine a bottle's `services.exe`, `svchost.exe`, `plugplay.exe`, `explorer.exe` and
/// `rpcss.exe` outlived a day of stops, still holding the prefix's server directory (issue #48).
/// A server that died abnormally leaves the same debris, and `wineserver -w` only waits for
/// the server.
///
/// Every Wine process of a prefix runs with its working directory inside the prefix (Highball
/// launches into `drive_c`, Wine's own system processes sit in `drive_c/windows`), and the
/// server's working directory is the prefix's server directory, named from the prefix path's
/// device and inode. Both come from `proc_pidinfo`, no `lsof` or `ps` parsing. The one gap is
/// a program started with a working directory outside the prefix (a Z: drive launch), which
/// the server itself still kills on a normal stop.
public enum ProcessTable {
    /// Wine's server directory for a prefix: `/tmp/.wine-<uid>/server-<dev>-<inode>`.
    public static func serverDirectory(forPrefix prefix: URL) -> URL? {
        var st = stat()
        guard stat(prefix.path, &st) == 0 else { return nil }
        return URL(fileURLWithPath: "/tmp/.wine-\(getuid())/server-\(String(UInt64(st.st_dev), radix: 16))-\(String(st.st_ino, radix: 16))")
    }

    /// All process ids visible to this user.
    static func allPIDs() -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 64)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        return buf[0..<Int(got) / MemoryLayout<pid_t>.size].filter { $0 > 0 }
    }

    /// Working directory of a process, or nil when it cannot be read (not ours, gone).
    public static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Resolves symlinks and private/tmp aliases the way the kernel reports them.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Whether a working directory belongs to the prefix: inside it, or its server directory.
    /// Pure, so it is tested without processes.
    public static func belongs(workingDirectory cwd: String, toPrefix prefix: String, serverDirectory: String?) -> Bool {
        let root = prefix.hasSuffix("/") ? prefix : prefix + "/"
        if cwd == prefix || cwd.hasPrefix(root) { return true }
        if let server = serverDirectory, cwd == server || cwd.hasPrefix(server + "/") { return true }
        return false
    }

    /// Process ids that belong to the prefix, never our own.
    public static func processes(ofPrefix prefix: URL) -> [pid_t] {
        let root = canonical(prefix.path)
        let server = serverDirectory(forPrefix: prefix).map { canonical($0.path) }
        let me = getpid()
        return allPIDs().filter { pid in
            guard pid != me, let cwd = workingDirectory(of: pid) else { return false }
            return belongs(workingDirectory: canonical(cwd), toPrefix: root, serverDirectory: server)
        }
    }

    /// Ends the given processes: SIGTERM, a grace period, then SIGKILL for whatever is left.
    /// Returns the ids that had to be killed the hard way.
    @discardableResult
    public static func terminate(_ pids: [pid_t], grace: TimeInterval = 2) -> [pid_t] {
        guard !pids.isEmpty else { return [] }
        for pid in pids { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        var alive = pids
        while !alive.isEmpty && Date() < deadline {
            usleep(100_000)
            alive = alive.filter { kill($0, 0) == 0 }
        }
        for pid in alive { kill(pid, SIGKILL) }
        return alive
    }
}
