import Foundation

/// A game that is running right now, detected from its processes rather than from an awaited
/// launch. Steam games are started through a client that outlives them, so the launch call
/// returning says nothing about the game; the process markers do (UX plan, Phase 0.6).
public struct GameSession: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let bottleName: String
    public let appid: Int?
    /// Substrings of the game's command line, in both path styles Wine reports.
    public let markers: [String]
    /// Substrings of processes that carry a marker without being the game: a Battle.net game's
    /// launcher sits in the game's folder and exits once Battle.net has the request.
    public let excluding: [String]
    public let started: Date
    /// The renderer the launch used, for the post-play report.
    public let renderer: String?
    /// The row's start notice (GameDBEntry.startNotice) and how long it stays.
    public let startNotice: String?
    public let startNoticeMinutes: Int
    public let libraryID: String?
    public init(id: UUID = UUID(), title: String, bottleName: String, appid: Int?, markers: [String], excluding: [String] = [],
                started: Date = Date(), renderer: String? = nil,
                libraryID: String? = nil, startNotice: String? = nil, startNoticeMinutes: Int? = nil) {
        self.id = id; self.title = title; self.bottleName = bottleName; self.appid = appid; self.markers = markers
        self.excluding = excluding; self.started = started
        self.renderer = renderer; self.libraryID = libraryID
        self.startNotice = startNotice.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.startNoticeMinutes = startNoticeMinutes ?? 15
    }

    /// The start notice to show at `now`, nil without one or once its time is over.
    public func notice(at now: Date) -> String? {
        guard let startNotice, now.timeIntervalSince(started) < Double(startNoticeMinutes) * 60 else { return nil }
        return startNotice
    }
}

/// What a finished session leaves behind: the post-play prompt and the funnel's last event
/// read this (UX plan §3.4, 0.6). Appended to `logs/sessions.jsonl`.
public struct SessionRecord: Codable, Sendable, Equatable {
    public var title: String
    public var bottle: String
    public var appid: Int?
    public var started: Date
    public var ended: Date
    public var seconds: Int { Int(ended.timeIntervalSince(started)) }
    /// "ended" when the game went away on its own, "stopped" when Highball ended it.
    public var reason: String
    public var renderer: String?
    public init(title: String, bottle: String, appid: Int?, started: Date, ended: Date, reason: String, renderer: String? = nil) {
        self.title = title; self.bottle = bottle; self.appid = appid; self.started = started; self.ended = ended; self.reason = reason
        self.renderer = renderer
    }
}

public enum SessionWatch {
    /// The markers a Steam game's processes carry: its install folder under steamapps/common,
    /// in the Unix and the Windows spelling Wine uses in command lines.
    public static func markers(installdir: String) -> [String] {
        ["steamapps/common/\(installdir)/", "steamapps\\common\\\(installdir)\\"]
    }

    /// The marker of a program launched by path (a pin, an Epic game): its file name, which
    /// its Wine process carries in its command line whatever the separators.
    public static func markers(executable: URL) -> [String] {
        [executable.lastPathComponent]
    }

    /// True when any process listing line carries one of the markers. `ps` is the text of
    /// `ps axww`; kept as a parameter so the rule is testable without processes.
    public static func isAlive(markers: [String], ps: String) -> Bool {
        markers.contains { ps.contains($0) }
    }

    /// The same, line by line, leaving out lines that carry one of `excluding`. With nothing to
    /// leave out it is `isAlive(markers:ps:)`.
    public static func isAlive(markers: [String], excluding: [String], ps: String) -> Bool {
        guard !excluding.isEmpty else { return isAlive(markers: markers, ps: ps) }
        return ps.split(whereSeparator: \.isNewline).contains { line in
            markers.contains { line.contains($0) } && !excluding.contains { line.contains($0) }
        }
    }

    public static func isAlive(_ session: GameSession, ps: String) -> Bool {
        isAlive(markers: session.markers, excluding: session.excluding, ps: ps)
    }

    /// The same, also counting a line that runs one of `names` (from `programNames`): the name
    /// after a path separator, a space or a quote, as the program or a path on the line.
    public static func isAlive(_ session: GameSession, names: Set<String>, ps: String) -> Bool {
        if isAlive(session, ps: ps) { return true }
        guard !names.isEmpty else { return false }
        return ps.split(whereSeparator: \.isNewline).contains { line in
            guard !session.excluding.contains(where: { line.contains($0) }) else { return false }
            let lower = line.lowercased()
            return names.contains { name in
                var from = lower.startIndex
                while let r = lower.range(of: name, range: from..<lower.endIndex) {
                    if r.lowerBound == lower.startIndex || "\\/ \"".contains(lower[lower.index(before: r.lowerBound)]) { return true }
                    from = r.upperBound
                }
                return false
            }
        }
    }

    /// The game's program names, from the listing lines that carry its markers: the file name of
    /// the first `.exe` after the marker, lowercased. Wine shows a process's Windows command line
    /// in `ps`, and a game that starts itself again with only its file name on that line shows no
    /// folder ("relaunch.exe child", measured 2026-11-12), so its session ended within ten seconds
    /// while it ran on (Civilization IV's tutorial, highball-db#1168). Names seen while the markers
    /// matched keep the session alive.
    public static func programNames(_ session: GameSession, ps: String) -> Set<String> {
        var names: Set<String> = []
        for line in ps.split(whereSeparator: \.isNewline) where !session.excluding.contains(where: { line.contains($0) }) {
            for marker in session.markers {
                guard let at = line.range(of: marker),
                      let exe = line[at.upperBound...].range(of: ".exe", options: .caseInsensitive) else { continue }
                let path = line[at.lowerBound..<exe.upperBound]
                let name = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map { $0.lowercased() } ?? ""
                if !name.isEmpty { names.insert(name) }
            }
        }
        return names
    }

    public static func currentProcessList() -> String {
        (try? Shell.capture("/bin/ps", ["axww"])) ?? ""
    }

    /// Process ids of the game's own processes inside a prefix, by command line. Used by Stop;
    /// Steam and the wineserver are left alone so a second game can follow without a cold start.
    public static func pids(ofPrefix prefix: URL, markers: [String], excluding: [String] = []) -> [pid_t] {
        ProcessTable.processes(ofPrefix: prefix).filter { pid in
            guard let cl = ProcessTable.commandLineAndEnvironment(of: pid) else { return false }
            let joined = cl.arguments.joined(separator: " ")
            return markers.contains { joined.contains($0) } && !excluding.contains { joined.contains($0) }
        }
    }

    public static func pids(ofPrefix prefix: URL, session: GameSession) -> [pid_t] {
        pids(ofPrefix: prefix, markers: session.markers, excluding: session.excluding)
    }

    public static func append(_ record: SessionRecord, to logs: URL) {
        let file = logs.appending(path: "sessions.jsonl")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard var data = try? enc.encode(record) else { return }
        data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: file) { try? h.seekToEnd(); try? h.write(contentsOf: data); try? h.close() }
        else { try? data.write(to: file) }
    }
}

/// The games the app sees running, by library id, kept in a small file in the home for the command
/// line: `highball play --wait` returns once its game has quit, so a frontend that starts games
/// (ES-DE, highball#432) gets control back then, and Highball and Steam stay as they are. The app
/// rewrites the file at every change; its process id and executable make a file left behind by an
/// app that is gone read as nothing known, never as a game still running.
public struct RunningGames: Codable, Sendable, Equatable {
    public var pid: Int32
    public var executable: String
    public var games: [String]

    public init(pid: Int32, executable: String, games: [String]) {
        self.pid = pid; self.executable = executable; self.games = games
    }

    public static func file(in paths: HighballPaths) -> URL { paths.home.appending(path: "running.json") }

    /// What the running app writes: its own process and the library ids of its sessions.
    public static func write(_ games: [String], paths: HighballPaths) {
        let me = RunningGames(pid: getpid(), executable: Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? "", games: games)
        try? paths.ensure()
        if let data = try? JSONEncoder().encode(me) { try? data.write(to: file(in: paths), options: .atomic) }
    }

    public static func read(paths: HighballPaths) -> RunningGames? {
        guard let data = try? Data(contentsOf: file(in: paths)) else { return nil }
        return try? JSONDecoder().decode(RunningGames.self, from: data)
    }

    /// The library ids running now, or nil when no app that wrote the file is running.
    public static func current(paths: HighballPaths, isLive: (RunningGames) -> Bool = RunningGames.isLive) -> Set<String>? {
        guard let state = read(paths: paths), isLive(state) else { return nil }
        return Set(state.games)
    }

    /// The writer still runs: its process exists and is the same program, so a process id reused
    /// after a crash does not count.
    public static func isLive(_ state: RunningGames) -> Bool {
        guard state.pid > 0, kill(state.pid, 0) == 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(state.pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        return state.executable.isEmpty || path == state.executable
    }
}

/// How `highball play --wait` follows its game, one look at a time: first until the app lists the
/// game as running, then until it no longer does or the app has quit. A game that never starts (a
/// question in the app left unanswered, a launch that failed) stops the wait after `startTimeout`.
public enum PlayWait {
    public enum Phase: Equatable, Sendable { case starting, running }
    public enum Step: Equatable, Sendable {
        case keepWaiting(Phase)
        case ended
        case neverStarted
    }

    /// `running` is what RunningGames.current read: nil when no Highball app runs.
    public static func step(_ phase: Phase, id: String, running: Set<String>?, waited: TimeInterval,
                            startTimeout: TimeInterval) -> Step {
        let listed = running?.contains(id) == true
        switch phase {
        case .starting:
            if listed { return .keepWaiting(.running) }
            return waited >= startTimeout ? .neverStarted : .keepWaiting(.starting)
        case .running:
            return listed ? .keepWaiting(.running) : .ended
        }
    }
}
