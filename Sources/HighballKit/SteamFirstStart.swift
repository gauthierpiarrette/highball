import Foundation

/// Steam's first start on the bundled engine sometimes deadlocks right after its bootstrapper
/// finishes (the relaunched client never gets past DLL loading; issue #9, seen on the
/// 2026-09-05 from-scratch run): the process stays alive with only the updater box on screen
/// and no login window, for as long as you wait. A relaunch fixes it every time. Steam's own
/// logs tell that state apart from a live client: the bootstrap log says "Update complete,
/// launching Steam..." and the connection log then stays silent, whereas a live client
/// connects within seconds. No login has ever happened (no loginusers.vdf), so nothing is lost
/// by restarting it once.
public enum SteamFirstStart {
    /// How long a client may sit after its bootstrap without connecting before it counts as hung.
    public static let patience: TimeInterval = 240

    /// Pure decision: `bootstrapDone` is the "Update complete" moment, `lastConnection` the
    /// newest connection-log entry, `everLoggedIn` whether loginusers.vdf exists.
    public static func isHung(bootstrapDone: Date?, lastConnection: Date?, everLoggedIn: Bool, now: Date = Date()) -> Bool {
        guard !everLoggedIn, let done = bootstrapDone else { return false }
        if let last = lastConnection, last >= done { return false }   // it connected after the bootstrap: alive
        return now.timeIntervalSince(done) >= patience
    }

    /// Reads the bottle's Steam logs and decides. Missing logs mean "not hung" (nothing to judge).
    public static func isHung(steamRoot: URL, now: Date = Date()) -> Bool {
        let logs = steamRoot.appending(path: "logs")
        let done = lastTimestamp(in: logs.appending(path: "bootstrap_log.txt"), matching: "Update complete")
        let conn = lastTimestamp(in: logs.appending(path: "connection_log.txt"), matching: nil)
        let loggedIn = FileManager.default.fileExists(atPath: steamRoot.appending(path: "config/loginusers.vdf").path)
        return isHung(bootstrapDone: done, lastConnection: conn, everLoggedIn: loggedIn, now: now)
    }

    /// The newest `[YYYY-MM-DD HH:MM:SS]` stamp in the file (on a line containing `matching`,
    /// when given). Steam writes local time without a zone.
    static func lastTimestamp(in file: URL, matching: String?) -> Date? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        var newest: Date?
        for line in text.split(separator: "\n").reversed() {
            if let m = matching, !line.contains(m) { continue }
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let stamp = String(line[line.index(after: line.startIndex)..<close])
            if let d = f.date(from: stamp) { newest = d; break }
        }
        return newest
    }
}
