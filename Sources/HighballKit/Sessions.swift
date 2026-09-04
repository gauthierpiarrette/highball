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
    public let started: Date
    /// The renderer the launch used, for the post-play report.
    public let renderer: String?
    public init(id: UUID = UUID(), title: String, bottleName: String, appid: Int?, markers: [String], started: Date = Date(), renderer: String? = nil) {
        self.id = id; self.title = title; self.bottleName = bottleName; self.appid = appid; self.markers = markers; self.started = started
        self.renderer = renderer
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

    public static func currentProcessList() -> String {
        (try? Shell.capture("/bin/ps", ["axww"])) ?? ""
    }

    /// Process ids of the game's own processes inside a prefix, by command line. Used by Stop;
    /// Steam and the wineserver are left alone so a second game can follow without a cold start.
    public static func pids(ofPrefix prefix: URL, markers: [String]) -> [pid_t] {
        ProcessTable.processes(ofPrefix: prefix).filter { pid in
            guard let cl = ProcessTable.commandLineAndEnvironment(of: pid) else { return false }
            let joined = cl.arguments.joined(separator: " ")
            return markers.contains { joined.contains($0) }
        }
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
