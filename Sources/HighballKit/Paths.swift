import Foundation

/// GitHub repo that receives community compatibility reports (owner/name).
public let reportRepo = "gauthierpiarrette/highball-db"

/// Filesystem layout for everything Gin owns. Mirrors the spike layout under
/// `~/Library/Application Support/Gin`, overridable with `HIGHBALL_HOME` for tests.
public struct HighballPaths: Sendable {
    public let home: URL

    public init(home: URL? = nil) {
        if let home { self.home = home; return }
        if let env = ProcessInfo.processInfo.environment["HIGHBALL_HOME"] {
            self.home = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.home = support.appending(path: "Highball", directoryHint: .isDirectory)
        }
    }

    public var downloads: URL { home.appending(path: "downloads", directoryHint: .isDirectory) }
    public var engines: URL { home.appending(path: "engines", directoryHint: .isDirectory) }
    public var bottles: URL { home.appending(path: "bottles", directoryHint: .isDirectory) }
    public var logs: URL { home.appending(path: "logs", directoryHint: .isDirectory) }
    public var manifests: URL { home.appending(path: "manifests", directoryHint: .isDirectory) }
    /// Staging for bottles on their way out. A sibling of `bottles/` rather than a child, so
    /// nothing that enumerates bottles ever sees a half-purged tree, and inside `home` rather
    /// than `~/.Trash` so the move is always same-filesystem — `rename(2)` cannot cross one,
    /// and Finder could not empty an undeletable prefix anyway.
    public var trash: URL { home.appending(path: ".trash", directoryHint: .isDirectory) }

    public func engine(_ id: String) -> URL { engines.appending(path: id, directoryHint: .isDirectory) }
    public func bottle(_ name: String) -> URL { bottles.appending(path: name, directoryHint: .isDirectory) }

    public func ensure() throws {
        for dir in [home, downloads, engines, bottles, logs, manifests, trash] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Builds a pre-filled GitHub bug-report URL: system info and a digest of the most relevant
/// log land in the issue form (field ids: what/chip/version/log in .github/ISSUE_TEMPLATE/bug.yml),
/// so every report arrives with the context that triage always needs.
public enum BugReport {
    /// Strings that prove a log recorded a real graphics-stack launch. Backend names only —
    /// never a game or exe name, so this keeps working for titles nobody has heard of.
    ///
    /// Picking the log by CONTENT rather than by filename is the whole point. A game that can
    /// only be started from a launcher's own UI (legacy CS:GO's CEG chooser) never gets a wine
    /// log of its own: Wine hands the entire process tree one pipe, so the game's DXVK output
    /// lands in the LAUNCHER's log. The previous picker skipped launcher logs by name and so
    /// attached the one file guaranteed not to mention the game — in issue #21 that was a
    /// wineboot log, and it cost four rounds of guessing.
    static let backendMarkers = [
        "info:  Game:",             // DXVK/d9vk banner: names the exe that created the device
        "DXVK-Kegworks",
        "DXVK:",
        "Found config file:",
        "Effective configuration:",
        "winemetal",                // DXMT
        "D3DMetal",
        "wined3d_adapter_create",
    ]

    /// Kept in the digest for context, but deliberately NOT used to choose a log: every wine
    /// process emits `init_peb starting`, so treating it as a backend signal would make almost
    /// any log "informative" and collapse selection back to newest-wins.
    static let contextMarkers = ["init_peb starting"]

    static let errorMarkers = ["err:", "[mvk-error]", "Assertion Failed", "Backtrace:"]
    /// Wine shouts these on every single launch and they have never explained a failure. Left in
    /// the budget they crowd the real errors out: one issue #21 log carries 24 HID lines and 740
    /// identical font-handle lines before anything diagnostic.
    static let benignMarkers = [
        "handle_DeviceMatchingCallback",
        "kerberos_LsaApInitializePackage",
        "ntlm_check_version",
        "ntlm_LsaApInitializePackage",
        "process_run_key Error running cmd",
        "RoGetActivationFactory",
    ]
    static let maxErrorLines = 40
    static let tailLines = 40
    static let maxDigestCharacters = 8000
    /// How many of the newest logs to open. The directory accumulates hundreds of files.
    static let maxLogsExamined = 15
    /// GitHub answers a request URI over roughly 8 KB with 414, and percent-encoding a log can
    /// several-fold its length (every newline becomes %0A), so the ENCODED url is what must be
    /// budgeted — not the digest's character count.
    static let maxURLCharacters = 7000
    /// A single launch here has produced a 167 MB log, so never read one whole. The banner and
    /// the effective configuration are written when the game creates its device, early in its
    /// output; the runaway repetition that makes a log enormous always comes later. Kept modest
    /// because `url()` scans up to `maxLogsExamined` of these on the calling thread.
    static let maxHeadBytes = 1 << 20
    static let maxTailBytes = 256 << 10

    /// Where a launch can leave a log: Highball's own directory, plus the per-process files DXVK
    /// writes inside each bottle (DXVK_LOG_PATH, set in `Bottle.environment`). The DXVK files
    /// matter because they survive the one case Highball cannot otherwise observe — a game
    /// started by a launcher client that Highball did not spawn.
    static func logDirectories(_ paths: HighballPaths) -> [URL] {
        var dirs = [paths.logs]
        let bottles = (try? FileManager.default.contentsOfDirectory(at: paths.bottles, includingPropertiesForKeys: nil)) ?? []
        dirs += bottles.map { $0.appending(path: "drive_c/highball/logs") }
        return dirs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Head and tail of a log, bounded. A gap marker records what was skipped so nobody reads
    /// the result as complete.
    static func boundedText(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        guard size > UInt64(maxHeadBytes + maxTailBytes) else {
            return (try? handle.readToEnd()).map { String(decoding: $0, as: UTF8.self) }
        }
        let head = (try? handle.read(upToCount: maxHeadBytes)) ?? Data()
        try? handle.seek(toOffset: size - UInt64(maxTailBytes))
        let tail = (try? handle.readToEnd()) ?? Data()
        let skipped = size - UInt64(maxHeadBytes) - UInt64(maxTailBytes)
        return String(decoding: head, as: UTF8.self)
            + "\n… \(skipped) bytes not scanned …\n"
            + String(decoding: tail, as: UTF8.self)
    }

    /// Condenses a wine log to the lines triage actually reads: the launch header and exit
    /// footer, the first sighting of each graphics-backend marker (with the indented block that
    /// follows a configuration dump), the errors, and the tail. Runs of an identical line
    /// collapse to one `(xN)`.
    ///
    /// A blind `suffix(30)` — what this replaced — is structurally useless on a wine log: the
    /// end is always MoltenVK warning spam, while the block naming the backend sits thousands of
    /// lines earlier (line 6547 of 8185 in the issue #21 logs).
    public static func digest(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return "" }
        var keep = Set<Int>()
        var note: [Int: String] = [:]
        // The "# …" launch header and the "# exit=" footer.
        for (i, line) in lines.enumerated() where line.hasPrefix("#") { keep.insert(i) }
        for marker in backendMarkers + contextMarkers {
            guard let i = lines.firstIndex(where: { $0.contains(marker) }) else { continue }
            keep.insert(i)
            // The indented report that follows a configuration dump.
            var j = i + 1
            while j < lines.count, lines[j].hasPrefix("info:    ") { keep.insert(j); j += 1 }
        }
        // Errors: benign startup noise dropped, the rest deduplicated across the whole log so a
        // failure repeated 740 times costs one line and still reports its true count.
        var firstIndex: [String: Int] = [:]
        var occurrences: [String: Int] = [:]
        var order: [String] = []
        var errorKey: [Int: String] = [:]
        for (i, line) in lines.enumerated()
        where errorMarkers.contains(where: line.contains) && !benignMarkers.contains(where: line.contains) {
            let key = normalizedError(line)
            errorKey[i] = key
            if firstIndex[key] == nil { firstIndex[key] = i; order.append(key) }
            occurrences[key, default: 0] += 1
        }
        for key in order.prefix(maxErrorLines) {
            guard let i = firstIndex[key] else { continue }
            keep.insert(i)
            if let n = occurrences[key], n > 1 { note[i] = "(x\(n))" }
        }
        // The tail: where a crash lands, and where a freeze simply stops. An error already
        // represented above is skipped here, so one failure can never appear twice carrying two
        // different counts.
        for i in max(0, lines.count - tailLines)..<lines.count {
            if let key = errorKey[i], firstIndex[key] != i { continue }
            keep.insert(i)
        }

        var out: [String] = []
        var previous = -1
        var repeats = 0
        func collapse() {
            if repeats > 1, !out.isEmpty { out[out.count - 1] += "  (x\(repeats))" }
            repeats = 0
        }
        for i in keep.sorted() {
            let rendered = note[i].map { "\(clip(lines[i]))  \($0)" } ?? clip(lines[i])
            if i == previous + 1, repeats > 0, rendered == out.last { repeats += 1; previous = i; continue }
            collapse()
            if previous >= 0, i > previous + 1 { out.append("… \(i - previous - 1) lines …") }
            out.append(rendered)
            repeats = 1
            previous = i
        }
        collapse()
        return redactHome(trim(out))
    }

    /// Longest single line kept. Bounds the digest and, not incidentally, stops a very long opaque
    /// value — a launcher URL carrying an auth token, which real Epic logs here do contain — from
    /// being pasted whole into a public GitHub issue.
    static let maxLineCharacters = 300
    static func clip(_ line: String) -> String {
        guard line.count > maxLineCharacters else { return line }
        return line.prefix(maxLineCharacters) + "… (+\(line.count - maxLineCharacters) chars)"
    }

    /// Joins the kept lines, and if they exceed the budget keeps BOTH ENDS: the head carries the
    /// launch header, the backend banner and the effective configuration; the tail carries how the
    /// run ended. A plain `suffix` would drop exactly the head — the content this function exists
    /// to preserve — and keep the MoltenVK spam, reinstating the failure it was written to fix.
    static func trim(_ lines: [String]) -> String {
        let whole = lines.joined(separator: "\n")
        guard whole.count > maxDigestCharacters else { return whole }
        let headBudget = maxDigestCharacters * 2 / 3
        var head: [String] = [], used = 0
        for line in lines {
            if used + line.count + 1 > headBudget, !head.isEmpty { break }
            head.append(line); used += line.count + 1
        }
        var tail: [String] = [], tailUsed = 0
        for line in lines[head.count...].reversed() {
            if used + tailUsed + line.count + 1 > maxDigestCharacters { break }
            tail.append(line); tailUsed += line.count + 1
        }
        let dropped = lines.count - head.count - tail.count
        guard dropped > 0 else { return whole }
        return (head + ["… \(dropped) digest lines dropped …"] + tail.reversed()).joined(separator: "\n")
    }

    /// Replaces the user's home directory with `~`. Wine command lines and DLL search paths are
    /// absolute, so they carry the account name into a public issue for no diagnostic gain.
    static func redactHome(_ text: String) -> String {
        let home = NSHomeDirectory()
        return home.count > 1 ? text.replacingOccurrences(of: home, with: "~") : text
    }

    /// An error line stripped of what varies between otherwise identical occurrences: Wine's
    /// per-thread id prefix and any hex addresses. Without this, the same failure on eight
    /// threads reads as eight different problems.
    static func normalizedError(_ line: String) -> String {
        var text = line
        if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) == 4,
           text[text.startIndex..<colon].allSatisfy(\.isHexDigit) {
            text = String(text[text.index(after: colon)...])
        }
        return text.replacingOccurrences(of: "0x[0-9a-fA-F]+", with: "0x…", options: .regularExpression)
    }

    /// The log most likely to explain what went wrong: the newest one that actually recorded a
    /// graphics backend, falling back to the newest of all.
    static func mostInformativeLog(in directories: [URL]) -> (url: URL, text: String)? {
        let key: Set<URLResourceKey> = [.contentModificationDateKey]
        var logs: [URL] = []
        for dir in directories {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(key))) ?? []
            logs += files.filter { $0.pathExtension == "log" }
        }
        let modified: (URL) -> Date = {
            (try? $0.resourceValues(forKeys: key))?.contentModificationDate ?? .distantPast
        }
        let newestFirst = logs.sorted { modified($0) > modified($1) }.prefix(maxLogsExamined)
        // A wineboot log is the prefix booting, and it ends before the game starts, so it can
        // never show a game failing. It nonetheless matches a backend marker, because wineboot
        // creates a d3d adapter and Wine shouts `wined3d_adapter_create` while doing it — so the
        // marker test alone ranked it "informative". In issue #21 the reporter sent one twice,
        // both times chosen by this picker, and each round cost days. Repair runs wineboot, so it
        // is also the log most likely to be the newest one after someone follows fix instructions.
        let isPrefixBoot: (URL) -> Bool = { $0.lastPathComponent.hasSuffix("-wineboot.log") }
        var fallback: (url: URL, text: String)?
        var bootFallback: (url: URL, text: String)?
        for url in newestFirst {
            guard let text = boundedText(of: url) else { continue }
            if isPrefixBoot(url) {
                if bootFallback == nil { bootFallback = (url, text) }
                continue
            }
            if backendMarkers.contains(where: text.contains) { return (url, text) }
            if fallback == nil { fallback = (url, text) }
        }
        // Only when it is genuinely the only thing on disk — a bottle that has never run anything.
        return fallback ?? bootFallback
    }

    public static func url(version: String, paths: HighballPaths = HighballPaths()) -> URL {
        let chip = (try? Shell.capture("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown chip"
        let macos = (try? Shell.capture("/usr/bin/sw_vers", ["-productVersion"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        var logDigest = ""
        if let found = mostInformativeLog(in: logDirectories(paths)) {
            // Name the full file too: the digest is a summary, and triage may want the original.
            logDigest = "\(redactHome(found.url.path)):\n\(digest(found.text))"
        }
        func url(log: String) -> URL {
            var comps = URLComponents(string: "https://github.com/gauthierpiarrette/highball/issues/new")!
            comps.queryItems = [
                URLQueryItem(name: "template", value: "bug.yml"),
                URLQueryItem(name: "chip", value: "\(chip), macOS \(macos)"),
                URLQueryItem(name: "version", value: version),
                URLQueryItem(name: "log", value: log),
            ]
            return comps.url!
        }
        // Shrink from the tail until the encoded URL fits: the head holds the launch header, the
        // backend banner and the effective configuration, which are what triage reads first.
        var result = url(log: logDigest)
        while result.absoluteString.count > maxURLCharacters, logDigest.count > 400 {
            logDigest = String(logDigest.prefix(logDigest.count * 3 / 4))
            result = url(log: logDigest)
        }
        return result
    }
}
