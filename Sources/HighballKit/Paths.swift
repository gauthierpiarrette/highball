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
