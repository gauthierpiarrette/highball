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

    public func engine(_ id: String) -> URL { engines.appending(path: id, directoryHint: .isDirectory) }
    public func bottle(_ name: String) -> URL { bottles.appending(path: name, directoryHint: .isDirectory) }

    public func ensure() throws {
        for dir in [home, downloads, engines, bottles, logs, manifests] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Builds a pre-filled GitHub bug-report URL: system info and the newest log's tail land in
/// the issue form (field ids: what/chip/version/log in .github/ISSUE_TEMPLATE/bug.yml), so
/// every report arrives with the context that triage always needs.
public enum BugReport {
    public static func url(version: String, paths: HighballPaths = HighballPaths()) -> URL {
        let chip = (try? Shell.capture("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown chip"
        let macos = (try? Shell.capture("/usr/bin/sw_vers", ["-productVersion"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        var logTail = ""
        if let files = try? FileManager.default.contentsOfDirectory(at: paths.logs, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let logs = files.filter { $0.pathExtension == "log" }
            let byNewest: (URL, URL) -> Bool = { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da < db
            }
            // Prefer the newest program log over a launcher's own log. When a game is
            // started through Steam/Epic/etc the launcher process usually writes last,
            // so the plain newest log is the launcher's, not the game's (issue #22).
            let launcherMarkers = ["steam.exe", "epicgameslauncher", "ubisoftconnect", "galaxyclient", "battle.net", "launcher.exe", "rockstarservice"]
            let isLauncher: (URL) -> Bool = { url in
                let name = url.lastPathComponent.lowercased()
                return launcherMarkers.contains { name.contains($0) }
            }
            let newest = logs.filter { !isLauncher($0) }.max(by: byNewest) ?? logs.max(by: byNewest)
            if let newest, let text = try? String(contentsOf: newest, encoding: .utf8) {
                var tail = text.split(separator: "\n").suffix(30).joined(separator: "\n")
                if tail.count > 3000 { tail = String(tail.suffix(3000)) }
                logTail = "\(newest.lastPathComponent):\n\(tail)"
            }
        }
        var comps = URLComponents(string: "https://github.com/gauthierpiarrette/highball/issues/new")!
        comps.queryItems = [
            URLQueryItem(name: "template", value: "bug.yml"),
            URLQueryItem(name: "chip", value: "\(chip), macOS \(macos)"),
            URLQueryItem(name: "version", value: version),
            URLQueryItem(name: "log", value: logTail),
        ]
        return comps.url!
    }
}
