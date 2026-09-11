import Foundation

/// The KEY=VALUE text the environment editors take. Parsing says which lines it ignored, so an
/// editor can show them instead of dropping them without a word (2026-09-11 walkthrough: a line
/// that was not KEY=VALUE stayed on screen, was never saved, and nothing said so).
public enum EnvText {
    public struct Parsed: Equatable {
        public var environment: [String: String]
        /// Lines that are not KEY=VALUE, trimmed, blank lines left out.
        public var ignored: [String]
    }

    public static func parse(_ text: String) -> Parsed {
        var env: [String: String] = [:]
        var ignored: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let key = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            if parts.count == 2, !key.isEmpty, key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil {
                env[key] = parts[1]
            } else {
                ignored.append(line)
            }
        }
        return Parsed(environment: env, ignored: ignored)
    }

    public static func text(for environment: [String: String]) -> String {
        environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
}

/// Launch logs by name: "<stamp>-<environment>-<executable>.log", "-2.log" when two launches
/// share a second. The stamp sorts, so the newest name is the newest launch.
public enum LaunchLogs {
    public static func newest(names: [String], bottle: String, executable: String) -> String? {
        let mid = "-\(bottle)-\(executable)"
        let pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z" + NSRegularExpression.escapedPattern(for: mid) + "(-[0-9]+)?\\.log$"
        // "-2.log" follows ".log" inside one second, which plain string order gets backwards.
        func key(_ name: String) -> (String, Int) {
            let stem = String(name.dropLast(4))
            if let dash = stem.lastIndex(of: "-"), let n = Int(stem[stem.index(after: dash)...]), stem[..<dash].hasSuffix(mid) {
                return (String(stem[..<dash]), n)
            }
            return (stem, 1)
        }
        return names.filter { $0.range(of: pattern, options: .regularExpression) != nil }
            .max { a, b in let ka = key(a), kb = key(b); return ka.0 == kb.0 ? ka.1 < kb.1 : ka.0 < kb.0 }
    }
}
