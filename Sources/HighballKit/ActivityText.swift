import Foundation

/// The numbers the activity strip shows. Nothing here predicts: bytes, rate and elapsed are
/// measured, a stated range comes from a recipe, and time remaining is never computed, because
/// a wrong "about a minute left" at 90% is the surest way to make someone quit a download that
/// was about to succeed (UX plan §3.3).
public enum ActivityText {
    /// Bytes received so far, at a moment.
    public struct Sample: Sendable, Equatable {
        public let bytes: Int64
        public let at: Date
        public init(bytes: Int64, at: Date) { self.bytes = bytes; self.at = at }
    }

    /// Bytes per second over the samples inside `window` seconds of the latest, nil until they
    /// span at least a second. A sample below the previous one starts a new transfer.
    public static func rate(_ samples: [Sample], window: TimeInterval = 5) -> Double? {
        guard let last = samples.last else { return nil }
        var first = last
        for s in samples.reversed() {
            if s.bytes > first.bytes { break }          // an earlier, larger count: another file
            if last.at.timeIntervalSince(s.at) > window { break }
            first = s
        }
        let dt = last.at.timeIntervalSince(first.at)
        guard dt >= 1, last.bytes >= first.bytes else { return nil }
        return Double(last.bytes - first.bytes) / dt
    }

    /// "164 of 270 MB · 2.4 MB/s"; "164 MB" alone when the total is unknown; no rate until one
    /// is measured.
    public static func transfer(received: Int64, total: Int64?, rate: Double?) -> String {
        var parts: [String] = []
        if let total, total > 0 {
            parts.append("\(megabytes(received)) of \(megabytes(total)) MB")
        } else {
            parts.append("\(megabytes(received)) MB")
        }
        if let rate, rate > 0 { parts.append(Self.rateText(rate)) }
        return parts.joined(separator: " · ")
    }

    /// The fraction for a determinate bar, nil without a known total.
    public static func fraction(received: Int64, total: Int64?) -> Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(total)))
    }

    /// The step counter of a stage line ("Step 2 of 3 — Battle.net-Setup"), if it names one.
    public static func steps(in stage: String) -> (done: Int, total: Int)? {
        guard let m = stage.firstMatch(of: #/^Step (?<a>\d+) of (?<b>\d+)/#),
              let a = Int(m.a), let b = Int(m.b), b > 0 else { return nil }
        return (a, b)
    }

    /// Whole minutes for the strip: nil under a minute (the caller says "just started").
    public static func minutes(since start: Date, now: Date = Date()) -> Int? {
        let m = Int(now.timeIntervalSince(start) / 60)
        return m < 1 ? nil : m
    }

    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f", Double(bytes) / 1_048_576)
    }

    static func rateText(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 { return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576) }
        return String(format: "%.0f KB/s", bytesPerSecond / 1024)
    }
}
