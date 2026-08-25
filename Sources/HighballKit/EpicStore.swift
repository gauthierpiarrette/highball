import Foundation

/// Installs and launches Epic Games titles through Legendary (github.com/legendary-gl/legendary),
/// bypassing the Epic launcher's install flow, which cannot pass its permission audit under Wine
/// (issue #14; the launcher audits Windows ACLs Wine does not persist). Legendary is GPL-3 like
/// Highball, maintained by the Heroic team, and authenticates with the user's own Epic account.
public struct EpicStore: Sendable {
    public let paths: HighballPaths
    public init(paths: HighballPaths = HighballPaths()) { self.paths = paths }

    // Pinned like an engine component. Update deliberately, never float.
    static let binaryURL = URL(string: "https://github.com/legendary-gl/legendary/releases/download/0.21.0/legendary_macOS_arm64")!
    static let binarySHA256 = "28f5f7d0eb8c029679d4faaa483ec85888af17a9a75977ae9170c21d8ce3428b"

    /// The page where the user signs into their existing Epic account. It ends by showing an
    /// authorizationCode to paste back into `highball epic auth <code>`.
    public static let loginURL = URL(string: "https://legendary.gl/epiclogin")!

    public var binary: URL { paths.home.appending(path: "tools/legendary", directoryHint: .notDirectory) }
    var configDir: URL { paths.home.appending(path: "legendary", directoryHint: .isDirectory) }

    /// Downloads and verifies the pinned Legendary binary if missing.
    public func ensureInstalled(progress: DownloadProgress? = nil) async throws -> URL {
        if FileManager.default.fileExists(atPath: binary.path) { return binary }
        let component = EngineManifest.Component(kind: "tool", url: Self.binaryURL, sha256: Self.binarySHA256,
                                                 size: 15_270_304, license: nil, optional: nil,
                                                 acceptance: nil, extract: nil, note: nil, version: "0.21.0")
        let file = try await EngineStore(paths: paths).download(component, name: "legendary", progress: progress)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: binary)
        try FileManager.default.copyItem(at: file, to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        // Checksum-verified above; quarantine would otherwise block the unsigned PyInstaller binary.
        try? Shell.run("/usr/bin/xattr", ["-c", binary.path])
        return binary
    }

    var environment: [String: String] { ["LEGENDARY_CONFIG_PATH": configDir.path] }

    /// Captures stdout only. Legendary writes its log lines to stderr and JSON to stdout;
    /// merging them (Shell.capture) breaks JSON parsing.
    @discardableResult
    func capture(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw HighballError.processFailed(command: "legendary " + args.joined(separator: " "),
                                              status: p.terminationStatus,
                                              output: String(decoding: errData.suffix(2000), as: UTF8.self))
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs legendary streaming each output line (installs are long and progress matters).
    @discardableResult
    public func runStreaming(_ args: [String], onLine: (@Sendable (String) -> Void)? = nil) throws -> Int32 {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let reader = pipe.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                onLine?(String(decoding: buffer[..<nl], as: UTF8.self))
                buffer.removeSubrange(...nl)
            }
        }
        if !buffer.isEmpty { onLine?(String(decoding: buffer, as: UTF8.self)) }
        p.waitUntilExit()
        return p.terminationStatus
    }

    public var isAuthenticated: Bool {
        FileManager.default.fileExists(atPath: configDir.appending(path: "user.json").path)
    }

    public func authenticate(code: String) throws {
        _ = try capture(["auth", "--disable-webview", "--code", code])
    }

    public func logout() throws { _ = try capture(["auth", "--delete"]) }

    public struct Game: Codable, Sendable {
        public let app_name: String
        public let app_title: String
    }

    /// Games the account owns (Windows builds).
    public func ownedGames() throws -> [Game] {
        let out = try capture(["list", "--platform", "Windows", "--json"])
        return try JSONDecoder().decode([Game].self, from: Data(out.utf8))
    }

    public func installedGames() throws -> [Game] {
        let out = try capture(["list-installed", "--json"])
        return try JSONDecoder().decode([Game].self, from: Data(out.utf8))
    }

    /// Installs a game's Windows build into the bottle at drive_c/Games/<folder>.
    @discardableResult
    public func install(_ appName: String, into bottle: Bottle, onLine: (@Sendable (String) -> Void)? = nil) throws -> Int32 {
        let base = bottle.driveC.appending(path: "Games", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return try runStreaming(["install", appName, "--platform", "Windows",
                                 "--base-path", base.path, "-y"], onLine: onLine)
    }

    public struct LaunchInfo: Sendable {
        public let executable: URL
        public let arguments: [String]
        public let workingDirectory: URL
        public let environment: [String: String]
    }

    /// Fresh launch parameters. The auth token inside is single use and expires within minutes,
    /// so call this immediately before each launch and never persist the result.
    public func launchInfo(_ appName: String, offline: Bool = false) throws -> LaunchInfo {
        // --no-wine: we spawn Wine ourselves; without it legendary tries to locate a wine
        // binary on macOS and crashes with IndexError when none is configured.
        var args = ["launch", appName, "--json", "--skip-version-check", "--no-wine"]
        if offline { args.append("--offline") }
        let out = try capture(args)
        guard let start = out.firstIndex(of: "{"),
              let obj = try JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any] else {
            throw HighballError.invalid("unexpected legendary launch output")
        }
        let gameDir = (obj["game_directory"] as? String) ?? ""
        let exe = (obj["game_executable"] as? String) ?? ""
        let workdir = (obj["working_directory"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? gameDir
        let params = ((obj["egl_parameters"] as? [String]) ?? [])
                   + ((obj["game_parameters"] as? [String]) ?? [])
                   + ((obj["user_parameters"] as? [String]) ?? [])
        let env = (obj["environment"] as? [String: String]) ?? [:]
        guard !gameDir.isEmpty, !exe.isEmpty else {
            throw HighballError.invalid("legendary returned no executable for \(appName)")
        }
        return LaunchInfo(executable: URL(fileURLWithPath: gameDir).appending(path: exe),
                          arguments: params,
                          workingDirectory: URL(fileURLWithPath: workdir),
                          environment: env)
    }
}
