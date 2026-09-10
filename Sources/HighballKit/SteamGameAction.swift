import Foundation

/// Steam can stop a launch dead and wait for an answer the player never sees.
///
/// A publisher licence agreement is the common one: Steam draws an "EULA … Accept / Cancel"
/// dialog inside its own window, and until it is answered the game process starts and then
/// sits at a few megabytes forever. From outside, that is indistinguishable from a hang — the
/// run log is clean, the process exists, and if the Steam window is behind something else the
/// dialog is never seen at all (issue #74). Seen with two different publishers on first launch
/// after install.
///
/// Steam says so plainly in `logs/console_log.txt`:
///
///     GameAction [AppID 1174180, ActionID 1] : LaunchApp changed task to ShowEula with ""
///     GameAction [AppID 1174180, ActionID 1] : LaunchApp waiting for user response to ShowEula ""
///
/// and, once answered, either continues the same action:
///
///     GameAction [AppID 3240220, ActionID 2] : LaunchApp continues with user response "ShowInterstitials"
///
/// or starts a new one. So the newest GameAction line tells the whole story.
///
/// The catch is that Steam passes through several "waiting for user response" states it answers
/// itself within the same second (ShowInterstitials, CreatingProcess). Only a wait that *stands*
/// is a wait on a person, which is what `patience` is for.
public enum SteamGameAction {
    /// How long a wait must stand before it counts as waiting on a person rather than on Steam.
    public static let patience: TimeInterval = 10

    public struct Pending: Equatable, Sendable {
        /// The Steam app being launched.
        public var appID: Int
        /// Steam's own name for what it is waiting on, e.g. `ShowEula`.
        public var task: String
        /// When the wait started.
        public var since: Date
        /// Identifies one launch attempt, so a caller can act once per attempt.
        public var actionID: Int

        public init(appID: Int, task: String, since: Date, actionID: Int) {
            self.appID = appID; self.task = task; self.since = since; self.actionID = actionID
        }
    }

    /// Pure decision over `console_log.txt` lines in file order. Returns the wait only if the
    /// newest GameAction line is a wait that has stood for `patience`.
    public static func pending(lines: [String], now: Date) -> Pending? {
        guard let last = lines.reversed().lazy.compactMap(parse).first else { return nil }
        guard case .waiting(let task) = last.step else { return nil }
        guard now.timeIntervalSince(last.at) >= patience else { return nil }
        return Pending(appID: last.appID, task: task, since: last.at, actionID: last.actionID)
    }

    /// Reads the bottle's Steam console log and decides. No log means nothing to judge.
    public static func pending(steamRoot: URL, now: Date = Date()) -> Pending? {
        let log = steamRoot.appending(path: "logs/console_log.txt")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        // Split on isNewline, never on the character "\n": Steam's logs are CRLF and Swift treats
        // CRLF as one Character, so splitting on "\n" hands back the whole file as one line.
        return pending(lines: text.split(whereSeparator: \.isNewline).map(String.init), now: now)
    }

    /// A sentence for the player. `name` is the game's title when we know it.
    public static func message(for pending: Pending, name: String?) -> String {
        let game = name ?? "this game"
        switch pending.task {
        case "ShowEula":
            return "Steam is waiting for you to accept the licence agreement for \(game). It is in the Steam window."
        default:
            return "Steam is waiting for an answer before it starts \(game). It is in the Steam window."
        }
    }

    // MARK: - Parsing

    enum Step: Equatable {
        case waiting(String)   // waiting for user response to <task>
        case other             // changed task to …, continues with user response …
    }

    struct Line: Equatable {
        var at: Date
        var appID: Int
        var actionID: Int
        var step: Step
    }

    /// `[2026-09-10 02:42:04] GameAction [AppID 1174180, ActionID 1] : LaunchApp waiting for user response to ShowEula ""`
    static func parse(_ line: String) -> Line? {
        guard line.contains("GameAction [AppID ") else { return nil }
        guard let at = timestamp(line) else { return nil }
        guard let ids = line.range(of: "GameAction [AppID ") else { return nil }
        let rest = line[ids.upperBound...]
        guard let close = rest.firstIndex(of: "]") else { return nil }
        let inside = rest[rest.startIndex..<close]                   // "1174180, ActionID 1"
        let parts = inside.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let appID = Int(parts.first ?? "") else { return nil }
        let actionID = Int(parts.count > 1 ? parts[1].replacingOccurrences(of: "ActionID ", with: "") : "") ?? 0

        let tail = String(rest[rest.index(after: close)...])
        let marker = "waiting for user response to "
        guard let m = tail.range(of: marker) else {
            return Line(at: at, appID: appID, actionID: actionID, step: .other)
        }
        let task = tail[m.upperBound...]
            .prefix { !$0.isWhitespace }
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !task.isEmpty else { return Line(at: at, appID: appID, actionID: actionID, step: .other) }
        return Line(at: at, appID: appID, actionID: actionID, step: .waiting(task))
    }

    /// Steam writes `[yyyy-MM-dd HH:MM:SS]` in local time, with no zone.
    static func timestamp(_ line: String) -> Date? {
        guard line.first == "[", let close = line.firstIndex(of: "]") else { return nil }
        let stamp = String(line[line.index(after: line.startIndex)..<close])
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        return f.date(from: stamp)
    }
}
