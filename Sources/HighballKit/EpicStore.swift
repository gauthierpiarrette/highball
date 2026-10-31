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
    /// `control` lets the caller stop it the way Ctrl-C in a terminal does.
    @discardableResult
    public func runStreaming(_ args: [String], control: LegendaryControl? = nil,
                             onLine: (@Sendable (String) -> Void)? = nil) throws -> Int32 {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        control?.started(p)
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
        /// Epic's own catalog art, embedded by legendary in `list --json` metadata.keyImages.
        /// Wide (DieselGameBox) fits the 460:215 game card; tall (DieselGameBoxTall) is the
        /// 2:3 cover for the future unified library. Same type mapping Heroic uses.
        public let artworkWide: URL?
        public let artworkTall: URL?
        /// The catalog item lists a Mac release beside the Windows one (metadata.releaseInfo's
        /// platforms), which the same purchase includes.
        public let listsMac: Bool
        /// The catalog item names a cloud save folder (metadata.customAttributes.CloudSaveFolder):
        /// Epic's cloud keeps its saves when Epic's own launcher syncs them.
        public var cloudSaves = false

        public init(app_name: String, app_title: String, artworkWide: URL? = nil, artworkTall: URL? = nil, listsMac: Bool = false) {
            self.app_name = app_name; self.app_title = app_title
            self.artworkWide = artworkWide; self.artworkTall = artworkTall; self.listsMac = listsMac
        }

        private enum CodingKeys: String, CodingKey { case app_name, app_title, metadata }
        private enum MetadataKeys: String, CodingKey { case keyImages, releaseInfo, customAttributes }
        private struct KeyImage: Codable { let type: String?; let url: String? }
        private struct ReleaseInfo: Codable { let platform: [String]? }
        private struct CustomAttribute: Codable { let value: String? }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            app_name = try c.decode(String.self, forKey: .app_name)
            app_title = try c.decode(String.self, forKey: .app_title)
            var images: [KeyImage] = []
            var releases: [ReleaseInfo] = []
            if let md = try? c.nestedContainer(keyedBy: MetadataKeys.self, forKey: .metadata) {
                images = (try? md.decode([KeyImage].self, forKey: .keyImages)) ?? []
                releases = (try? md.decode([ReleaseInfo].self, forKey: .releaseInfo)) ?? []
                let attributes = (try? md.decode([String: CustomAttribute].self, forKey: .customAttributes)) ?? [:]
                cloudSaves = !(attributes["CloudSaveFolder"]?.value ?? "").isEmpty
            }
            listsMac = releases.contains { $0.platform?.contains("Mac") == true }
            func first(_ types: [String]) -> URL? {
                for t in types {
                    if let u = images.first(where: { $0.type == t })?.url, let url = URL(string: u) { return url }
                }
                return nil
            }
            artworkWide = first(["DieselGameBox", "OfferImageWide"])
            artworkTall = first(["DieselGameBoxTall", "OfferImageTall", "DieselStoreFrontTall"])
        }

        public func encode(to encoder: Encoder) throws {
            // Artwork and platforms are derived from legendary's metadata on every decode; only
            // identity persists.
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(app_name, forKey: .app_name)
            try c.encode(app_title, forKey: .app_title)
        }
    }

    /// Games the account owns (Windows builds).
    public func ownedGames() throws -> [Game] {
        let out = try capture(["list", "--platform", "Windows", "--json"])
        return try JSONDecoder().decode([Game].self, from: Data(out.utf8))
    }

    public struct InstalledGame: Codable, Sendable {
        public let app_name: String
        public let install_path: String?
        /// legendary's record of the installed size, in bytes.
        public var install_size: Int64? = nil
        /// Where the game keeps the saves legendary syncs, once it has synced them.
        public var save_path: String? = nil
        /// "Windows" or "Mac": which build legendary installed (one per game).
        public var platform: String? = nil

        public var isMac: Bool { platform?.lowercased() == "mac" }
    }

    /// Everything legendary has installed, with where. Legendary's install state is global
    /// across bottles; the bottle association lives in the path, so callers must check it
    /// with `isInstalled(path:inDriveC:)` — a game installed in bottle A is NOT installed
    /// in bottle B (the old Set-of-names API showed Play in bottles that had no files).
    public func installedGames() throws -> [InstalledGame] {
        let out = try capture(["list-installed", "--json"])
        return try JSONDecoder().decode([InstalledGame].self, from: Data(out.utf8))
    }

    /// Legendary's install records, app name to path, keeping only the ones whose folder still
    /// exists. Legendary never notices a removed environment or a deleted game folder, and a
    /// record it keeps showed Guardians of the Galaxy as installed after its bottle was gone (#63).
    public static func installMap(_ games: [InstalledGame]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: games.compactMap { g in
            g.install_path.flatMap { FileManager.default.fileExists(atPath: $0) ? (g.app_name, $0) : nil }
        })
    }

    /// True when an install path lies inside the given bottle's drive_c.
    public static func isInstalled(path: String, inDriveC driveC: URL) -> Bool {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path + "/"
        let c = driveC.standardizedFileURL.path + "/"
        return p.hasPrefix(c)
    }

    /// The install command line. Legendary runs without a terminal here, so every prompt must
    /// be answered on the command line: `-y` covers the confirmations, and `--skip-sdl` the
    /// selective-download prompt (optional language packs), which `-y` does not cover and which
    /// otherwise dies with EOFError the moment it reads stdin (Hogwarts Legacy on Epic, #110).
    /// The defaults install the required data only; language packs can be added later.
    static func installArguments(appName: String, basePath: String, platform: String = "Windows") -> [String] {
        ["install", appName, "--platform", platform, "--base-path", basePath, "-y", "--skip-sdl"]
    }

    /// Installs a game's Mac build into the Mac games folder, beside GOG's (GOGStore.macGamesDir).
    /// legendary keeps one install per game, so the Windows one must be removed first.
    @discardableResult
    public func installMac(_ appName: String, control: LegendaryControl? = nil,
                           onLine: (@Sendable (String) -> Void)? = nil) throws -> Int32 {
        let base = GOGStore.macGamesDir
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return try runStreaming(Self.installArguments(appName: appName, basePath: base.path, platform: "Mac"), control: control, onLine: onLine)
    }

    /// Installs a game's Windows build into the bottle at drive_c/Games/<folder>.
    @discardableResult
    public func install(_ appName: String, into bottle: Bottle, control: LegendaryControl? = nil,
                        onLine: (@Sendable (String) -> Void)? = nil) throws -> Int32 {
        let base = bottle.driveC.appending(path: "Games", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return try runStreaming(Self.installArguments(appName: appName, basePath: base.path), control: control, onLine: onLine)
    }

    /// legendary refuses to start an install while another legendary holds its install lock,
    /// and returns as if it had succeeded, status 0, so the strip said Done over nothing
    /// installed (highball#323, a download from before a restart still running).
    public static func refusedForLock(_ line: String) -> Bool {
        line.contains("Failed to acquire installed data lock")
    }

    /// legendary's reason for refusing an install, as a sentence for the player, from one line of its
    /// output, or nil. Its checks print "[cli] CRITICAL: Not enough available disk space! 51200.00 MiB <
    /// 123456.00 MiB" and exit 1, which reached the player as only "epic install exited with 1, see the
    /// log above" (highball#409, Red Dead Redemption 2, well over 100 GB).
    public static func installFailure(_ line: String) -> String? {
        guard let r = line.range(of: "CRITICAL: ") ?? line.range(of: "ERROR: ") else { return nil }
        let message = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !message.isEmpty, !message.hasPrefix("Installation cannot proceed") else { return nil }
        if message.hasPrefix("Not enough available disk space") {
            let gb = { (bytes: Int64) in String(format: "%.0f GB", Double(bytes) / 1_073_741_824) }
            if let free = mebibytes(after: "disk space!", in: message), let needed = mebibytes(after: "< ", in: message) {
                return "This Mac doesn't have enough free space for the game. It needs \(gb(needed)) and \(gb(free)) are free. Free some space, then press Install again."
            }
            return "This Mac doesn't have enough free space for the game. Free some space, then press Install again."
        }
        return "Epic's installer stopped with this message. \(message)"
    }

    /// legendary's install log names the download's size before it starts ("Download size:
    /// 95232.19 MiB (Compression savings: 2.1%)") and then, about once a second, how much has
    /// arrived (" - Downloaded: 9075.51 MiB, Written: 9415.55 MiB"). The activity strip shows
    /// them like an engine download's bytes (highball#287). Bytes, or nil for any other line.
    public static func downloadSize(inLegendaryLine line: String) -> Int64? { mebibytes(after: "Download size:", in: line) }
    public static func downloaded(inLegendaryLine line: String) -> Int64? { mebibytes(after: "- Downloaded:", in: line) }

    private static func mebibytes(after label: String, in line: String) -> Int64? {
        guard let r = line.range(of: label) else { return nil }
        let rest = line[r.upperBound...].drop { $0 == " " }
        let number = rest.prefix { $0.isNumber || $0 == "." }
        guard !number.isEmpty, rest.dropFirst(number.count).hasPrefix(" MiB"), let value = Double(number) else { return nil }
        return Int64(value * 1_048_576)
    }

    static func moveArguments(appName: String, basePath: String) -> [String] { ["move", appName, basePath] }

    /// Moves an installed game's folder into another environment's drive_c/Games and rewrites
    /// legendary's record of it, so the game alone plays there (highball#566: the engine switch
    /// moves every game of an environment). Legendary renames the folder, which takes a moment
    /// whatever the game's size, and it refuses another disk. It prints its refusals and still
    /// exits 0, so the files decide: nil when the folder now sits in the new place, else why not.
    public func move(_ appName: String, from installPath: String, into bottle: Bottle,
                     onLine: (@Sendable (String) -> Void)? = nil) throws -> String? {
        let base = bottle.driveC.appending(path: "Games", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let refusals = Collector()
        _ = try runStreaming(Self.moveArguments(appName: appName, basePath: base.path)) { line in
            if let r = line.range(of: "ERROR: ") { refusals.append(String(line[r.upperBound...])) }
            onLine?(line)
        }
        let moved = base.appending(path: URL(fileURLWithPath: installPath).lastPathComponent).path
        if FileManager.default.fileExists(atPath: moved), !FileManager.default.fileExists(atPath: installPath) { return nil }
        return refusals.lines.last.map(Self.moveFailure) ?? "Its folder is still at \(installPath)."
    }

    /// Legendary's refusal to move, as a sentence for the player.
    static func moveFailure(_ message: String) -> String {
        if message.hasPrefix("Moving to a different drive is not supported") {
            return "The game is on another disk than that environment, and Epic's tool only moves a game within one disk."
        }
        // 0.21.0 renames straight onto the target: an empty folder there is replaced, a full one
        // fails with errno 66 (measured 2026-10-30). Its own check for that case reads this way.
        if message.contains("Directory not empty") || message.hasPrefix("The target path already contains a folder called") {
            return "That environment already has a folder of that name in drive_c/Games. Remove or rename it, then try again."
        }
        return message
    }

    static func uninstallArguments(appName: String) -> [String] { ["uninstall", appName, "-y"] }

    /// Removes a game legendary installed. Legendary owns the Epic install state, so it does the
    /// deleting and its library stays right; deleting the folder ourselves would leave it
    /// believing the game is still there (highball#185).
    @discardableResult
    public func uninstall(_ appName: String, onLine: (@Sendable (String) -> Void)? = nil) throws -> Int32 {
        try runStreaming(Self.uninstallArguments(appName: appName), onLine: onLine)
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

/// Stops a running legendary the way Ctrl-C in a terminal does. A terminal signals the whole
/// process group, and legendary's downloader runs in child processes, so SIGINT goes to
/// legendary and everything it started. legendary answers by keeping the download's progress,
/// and the same install picks up from there later ("Downloads are resumable, you can interrupt
/// the download with CTRL-C and resume it using the same command later on", its install
/// output). Whatever is still running after the grace period gets SIGTERM, and SIGKILL half a
/// period later, including a child left behind by a parent that already exited. Each process
/// is signalled only while it is the one seen at Stop, by its start time, so a pid taken over
/// in the meantime is never hit. Before this the strip's Stop cancelled a task nothing was
/// listening to, and the download outlived the app (highball#323).
public final class LegendaryControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopRequested = false
    /// Seconds between SIGINT and SIGTERM, and SIGKILL at one and a half times that.
    private let grace: TimeInterval

    public init(grace: TimeInterval = 10) { self.grace = grace }

    func started(_ process: Process) {
        let stopNow = lock.withLock { () -> Bool in self.process = process; return stopRequested }
        if stopNow { stop() }
    }

    public func stop() {
        let process = lock.withLock { () -> Process? in stopRequested = true; return self.process }
        guard let process else { return }
        let seen = Self.members(of: process)
        Self.signal(seen, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { Self.signal(seen + Self.members(of: process), SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace * 1.5) { Self.signal(seen + Self.members(of: process), SIGKILL) }
    }

    struct Member: Hashable {
        let pid: pid_t
        let started: UInt64
    }

    /// legendary and every process under it, each with its start time, or none once legendary
    /// itself has exited.
    private static func members(of process: Process) -> [Member] {
        guard process.isRunning else { return [] }
        return tree(process.processIdentifier).compactMap { pid in startTime(pid).map { Member(pid: pid, started: $0) } }
    }

    private static func signal(_ members: [Member], _ signal: Int32) {
        for member in Set(members) where startTime(member.pid) == member.started { kill(member.pid, signal) }
    }

    /// When the process started, in microseconds, or nil when there is no such process.
    static func startTime(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    /// A process and every process under it, parents first.
    static func tree(_ root: pid_t) -> [pid_t] {
        var pids = [root], next = 0
        while next < pids.count {
            let parent = pids[next]; next += 1
            let count = proc_listchildpids(parent, nil, 0)
            guard count > 0 else { continue }
            var children = [pid_t](repeating: 0, count: Int(count) + 8)
            let found = children.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
            for child in children.prefix(Int(max(found, 0))) where child > 0 && !pids.contains(child) { pids.append(child) }
        }
        return pids
    }
}
