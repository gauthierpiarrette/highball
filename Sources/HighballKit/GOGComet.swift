import Foundation

/// comet beside a GOG game: the stand-in for Galaxy's communication service that GOG's SDK in the
/// game talks to, on 127.0.0.1:9977, which Wine's processes reach as the Mac's own. With it a game
/// signs in, achievements and stats reach the player's account, and the "could not restore your
/// progress" notice some games show without Galaxy goes away.
///
/// comet is a helper, never a requirement: if it cannot start, the game starts without it, and a
/// game that crashes at once with comet running is started again without it and remembered, so a
/// comet problem costs that game its achievements and nothing else.
public struct GOGComet: Sendable {
    public let store: GOGStore
    public init(store: GOGStore) { self.store = store }

    /// comet's home: it reads Heroic's auth file from $HOME/Library/Application Support/heroic,
    /// so a private HOME hands it the tokens through a file (never the command line, which a process
    /// list shows) and keeps its own data inside the Highball home.
    var home: URL { store.dir.appending(path: "comet-home", directoryHint: .isDirectory) }
    var authCopy: URL { home.appending(path: "Library/Application Support/heroic/gog_store/auth.json") }

    /// The arguments: the account name only. `--quit` ends comet once every game has disconnected.
    static func arguments(username: String) -> [String] { ["--from-heroic", "--username", username, "--quit"] }

    /// Starts comet with fresh tokens. Throws when it cannot (not signed in, no name, no binary);
    /// the caller launches the game anyway.
    public func start(log: URL) throws -> Process {
        guard let username = store.username ?? (try? store.refreshUser()) ?? nil else {
            throw HighballError.failed("comet needs the GOG account name, which GOG did not return")
        }
        _ = try store.credentials()   // refreshes an expired token into auth.json first
        try FileManager.default.createDirectory(at: authCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: authCopy)
        try store.withAuthFile { try FileManager.default.copyItem(at: store.authFile, to: authCopy) }   // never mid-rewrite
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authCopy.path)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let p = Process()
        p.executableURL = store.cometBinary
        p.arguments = Self.arguments(username: username)
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        // Long enough for a game that restarts itself once (a launcher handing over to the game).
        env["COMET_IDLE_WAIT"] = "30"
        p.environment = env
        p.standardOutput = handle
        p.standardError = handle
        defer { try? handle.close() }   // comet holds its own copy once it runs
        try p.run()
        return p
    }

    /// Ends comet and removes its copy of the tokens.
    public func stop(_ process: Process?) {
        if let process, process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: authCopy)
    }

    /// Removes a copy of the tokens left by a session that never reached `stop` (Highball or the
    /// command line quit mid-game), unless a comet is still running on it. pgrep exits 1 when
    /// nothing matches, which `capture` throws for.
    public func removeStaleTokens() {
        guard FileManager.default.fileExists(atPath: authCopy.path) else { return }
        let running = (try? Shell.capture("/usr/bin/pgrep", ["-f", store.cometBinary.path])) != nil
        if !running { try? FileManager.default.removeItem(at: authCopy) }
    }

    /// Ends every comet on this Mac and removes the token copy. One left by a Highball that quit
    /// or crashed mid-game keeps running when no game ever connected to it (`--quit` waits for
    /// one) and holds port 9977, so the next comet could not listen.
    public func stopStrays() {
        _ = try? Shell.capture("/usr/bin/pkill", ["-f", store.cometBinary.path])
        try? FileManager.default.removeItem(at: authCopy)
    }

    /// comet's database of a game's achievements, for the unlock pop-up (GOGAchievements).
    public func achievementDatabase(clientID: String) -> URL? { GOGAchievements.database(home: home, clientID: clientID) }

    /// Whether comet came up and is listening, read from its log ("Listening on port 9977").
    public static func isListening(log: URL) -> Bool {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("Listening on port")
    }

    /// Whether the game reached comet during the run ("Client identified as …").
    public static func gameConnected(log: URL) -> Bool {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("Client identified")
    }

    /// The placeholder service some SDK versions wait for: GalaxyCommunication.exe where Galaxy
    /// puts it, registered as a service, and Galaxy's install path in the registry, which is what
    /// Heroic sets up in each prefix. Wine commands to run once per environment, in order.
    public static let servicePath = #"C:\ProgramData\GOG.com\Galaxy\redists\GalaxyCommunication.exe"#

    public static func serviceFile(driveC: URL) -> URL {
        driveC.appending(path: "ProgramData/GOG.com/Galaxy/redists/GalaxyCommunication.exe")
    }

    /// Puts the placeholder service in the environment once: the file where Galaxy keeps it, then
    /// the registration commands. True when it was set up now, false when it already was.
    @discardableResult
    public static func installService(from file: URL, runner: WineRunner) async throws -> Bool {
        let target = serviceFile(driveC: runner.bottle.driveC)
        guard !FileManager.default.fileExists(atPath: target.path) else { return false }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: target)
        // The registry entry is what the SDK checks; `sc create` may report a service that is
        // already there. Without the entry, no file either, so the next Play tries again.
        var registered = false
        do {
            for command in serviceCommands {
                let result = try await runner.run(command, renderer: .wined3d, label: "gog-comet-service")
                if command.first == "reg" { registered = result.exitStatus == 0 }
            }
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        guard registered else {
            try? FileManager.default.removeItem(at: target)
            throw HighballError.failed("Wine could not register GOG's service placeholder for comet")
        }
        return true
    }

    static var serviceCommands: [[String]] {
        [["sc", "create", "GalaxyCommunication", "binpath=\(servicePath)"],
         ["reg", "add", #"HKLM\SOFTWARE\WOW6432Node\GOG.com\GalaxyClient\paths"#, "/v", "client", "/t", "REG_SZ",
          "/d", #"C:\Program Files\GOG Galaxy"#, "/f"]]
    }
}

/// The player's per-game GOG choices, beside the tokens: the launch task picked on a game's page,
/// games that run without comet (turned off, or after a crash with it), games without cloud saves.
public struct GOGSettings: Codable, Sendable, Equatable {
    public var launchChoice: [String: Int] = [:]
    public var cometOff: [String: String] = [:]   // game id → why: turnedOff or crashedWithComet
    public static let turnedOff = "turned off"
    public static let crashedWithComet = "crashed with comet"
    public var cloudSavesOff: Set<String> = []
    /// Programs added by hand whose settings, name and cover were carried to their GOG tile once
    /// (LibraryIndex.carryOver); never again, so a later change on the GOG tile stays.
    public var carriedOverPins: Set<String> = []

    public init() {}

    // Every field optional on read: a file written before a field existed keeps the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchChoice = try c.decodeIfPresent([String: Int].self, forKey: .launchChoice) ?? [:]
        cometOff = try c.decodeIfPresent([String: String].self, forKey: .cometOff) ?? [:]
        cloudSavesOff = try c.decodeIfPresent(Set<String>.self, forKey: .cloudSavesOff) ?? []
        carriedOverPins = try c.decodeIfPresent(Set<String>.self, forKey: .carriedOverPins) ?? []
    }

    static func file(_ store: GOGStore) -> URL { store.dir.appending(path: "settings.json") }

    public static func load(_ store: GOGStore) -> GOGSettings {
        (try? JSONDecoder().decode(GOGSettings.self, from: Data(contentsOf: file(store)))) ?? GOGSettings()
    }

    public func save(_ store: GOGStore) {
        store.secureDirectory()
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Self.file(store), options: .atomic)
    }
}
