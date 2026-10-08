import Foundation
import Darwin

/// The bridge and passive publisher share a lock so a passive update cannot overwrite
/// a game's own Rich Presence. Socket I/O runs on utility threads, never the main actor.
public final class DiscordPresence: @unchecked Sendable {
    public static let shared = DiscordPresence()
    public static let enabledDefaultsKey = "discordSharingEnabled"
    private let loadCatalog: @Sendable (HighballPaths) async -> DiscordGameCatalog?
    private let socketPaths: @Sendable () -> [String]
    private let permissionLock = NSLock()
    private var enabled = false
    private var generation: UInt64 = 0
    private let lock = NSLock()
    private let bridgeLock = NSLock()
    private var richClients: Set<UUID> = []
    private var passive: DiscordSocket?
    private var passiveIdentity: String?
    private var bridge: DiscordBridge?
    private var helpers: [String: Process] = [:]
    private var message = "Waiting for a game"
    public var status: String { isEnabled ? lock.withLock { message } : "Discord sharing is off" }
    /// Whether a Discord client serves its local socket: Discord's own app, or another client that
    /// speaks its IPC, such as Vesktop with its Rich Presence (arRPC) setting on. The bridge needs
    /// nothing more, and a player on Vesktop got no game activity while Highball looked for
    /// Discord's app by its bundle id alone (Discord, 2026-10-08).
    public var clientSocketPresent: Bool { socketPaths().contains { FileManager.default.fileExists(atPath: $0) } }
    public var isEnabled: Bool { permissionLock.withLock { enabled } }
    public init() {
        let store = DiscordCatalogStore()
        loadCatalog = { await store.load(paths: $0) }
        socketPaths = { DiscordIPC.socketPaths() }
    }
    init(socketPaths: @escaping @Sendable () -> [String],
         loadCatalog: (@Sendable (HighballPaths) async -> DiscordGameCatalog?)? = nil) {
        self.socketPaths = socketPaths
        let store = DiscordCatalogStore()
        self.loadCatalog = loadCatalog ?? { await store.load(paths: $0) }
    }

    /// Revoke permission immediately, including updates waiting for a catalog response.
    /// The session worker cancels and stops its connections/helpers off the main actor.
    public func setEnabled(_ value: Bool) {
        permissionLock.withLock {
            if enabled != value { generation &+= 1 }
            enabled = value
        }
    }

    private func mayShare(generation expected: UInt64? = nil) -> Bool {
        !Task.isCancelled && permissionLock.withLock { enabled && (expected == nil || generation == expected) }
    }

    /// Called with the *effective* Wine environment, after server sync adoption. The helper
    /// must not cold-start a wineserver with different sync flags from the game it serves.
    public func ensureBridge(engine: InstalledEngine, bottle: Bottle, environment: [String: String], helperURL: URL? = nil) {
        guard mayShare(), socketPaths().contains(where: { FileManager.default.fileExists(atPath: $0) }) else { return }
        guard FileManager.default.fileExists(atPath: bottle.driveC.appending(path: "windows").path) else { return }
        let helper = helperURL ?? Bundle.main.url(forResource: "highball-discord-bridge", withExtension: "exe")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "spike/discord-bridge/highball-discord-bridge.exe")
        guard FileManager.default.fileExists(atPath: helper.path) else { return }
        var waiting: (Process, DiscordBridge, String)?
        bridgeLock.withLock {
            guard mayShare() else { return }
            let prefix = bottle.url.resolvingSymlinksInPath().path
            if let process = helpers[prefix], process.isRunning { return }
            do {
                if bridge == nil { bridge = try DiscordBridge(socketPaths: socketPaths) { [weak self] id, active in self?.richActivity(id, active: active) } }
                guard let bridge else { return }
                let process = Process()
                process.executableURL = engine.wineBinary
                process.arguments = [helper.path]
                process.environment = environment.merging([
                    "HIGHBALL_DISCORD_PORT": String(bridge.port), "HIGHBALL_DISCORD_TOKEN": bridge.token,
                    "HIGHBALL_DISCORD_PREFIX": prefix,
                ]) { $1 }
                // Windows plumbing directory: SessionWatch and the idle-prefix rule must not
                // mistake the helper for a game or prevent a renderer/engine restart.
                process.currentDirectoryURL = bottle.driveC.appending(path: "windows")
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                guard mayShare() else { return }
                try process.run()
                helpers[prefix] = process
                waiting = (process, bridge, prefix)
            } catch { /* Presence must never keep a game from launching. */ }
        }
        // This runs on the session worker after launch. Shutdown does not wait on readiness.
        if let (process, bridge, prefix) = waiting {
            let deadline = Date().addingTimeInterval(3)
            while mayShare() && process.isRunning && !bridge.isReady(prefix: prefix) && Date() < deadline { usleep(20_000) }
        }
    }

    public func retainBridges(for prefixes: [URL]) {
        let active = Set(prefixes.map { $0.resolvingSymlinksInPath().path })
        bridgeLock.withLock {
            for prefix in Array(helpers.keys) where !active.contains(prefix) {
                bridge?.stopControl(prefix: prefix)
                // A failed/slow helper may not have established its control connection yet.
                if let process = helpers[prefix], process.isRunning, bridge?.isReady(prefix: prefix) != true {
                    process.terminate()
                }
                helpers[prefix] = nil
            }
        }
    }

    func richActivity(_ id: UUID, active: Bool) {
        lock.withLock {
            if active && mayShare() {
                richClients.insert(id)
                clearPassive() // Clear BEFORE forwarding the richer activity to Discord.
                message = "Game Rich Presence connected"
            } else { richClients.remove(id) }
        }
    }

    public func update(games: [DiscordRunningGame], paths: HighballPaths = HighballPaths()) async {
        guard mayShare() else { return }
        let revision = permissionLock.withLock { generation }
        guard !games.isEmpty else {
            lock.withLock { clearPassive(); message = richClients.isEmpty ? "Waiting for a game" : "Game Rich Presence connected" }
            return
        }
        // Avoid the public catalog request unless a local Discord client is available.
        guard socketPaths().contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
            lock.withLock { clearPassive(); message = "Open Discord to share your game" }
            return
        }
        if lock.withLock({ !richClients.isEmpty }) { return }
        let catalog = await loadCatalog(paths)
        guard mayShare(generation: revision) else { return }
        publish(games: games, catalog: catalog, generation: revision)
    }

    func publish(games: [DiscordRunningGame], catalog: DiscordGameCatalog?, generation: UInt64? = nil) {
        lock.withLock {
            guard mayShare(generation: generation) else { return }
            guard richClients.isEmpty else { clearPassive(); message = "Game Rich Presence connected"; return }
            guard !games.isEmpty else { clearPassive(); message = "Waiting for a game"; return }
            guard let catalog else { clearPassive(); message = "Discord's game catalog is unavailable"; return }
            // Keep a live selected game stable; otherwise the most recently started game wins.
            let ordered = games.sorted {
                if $0.identity == $1.identity { return false }
                if $0.identity == passiveIdentity { return true }
                if $1.identity == passiveIdentity { return false }
                return $0.started > $1.started
            }
            guard let (game, app) = ordered.compactMap({ game in
                catalog.match(steamID: game.steamID, title: game.title, executable: game.executable).map { (game, $0) }
            }).first else { clearPassive(); message = "This game is not in Discord's catalog"; return }
            do {
                if passiveIdentity == game.identity, let passive {
                    // A closed Discord socket must reconnect even if the game did not change.
                    var p = pollfd(fd: passive.fd, events: Int16(POLLIN), revents: 0)
                    if poll(&p, 1, 0) == 0 { return }
                    let frame = try passive.readFrame(timeout: 0.5)
                    if frame.opcode == 3 {
                        try passive.write(DiscordIPC.Frame(opcode: 4, payload: frame.payload))
                        return
                    }
                    if frame.opcode == 1 { return }
                    clearPassive()
                } else { clearPassive() }
                let socket = try DiscordIPC.connect(paths: socketPaths())
                do {
                    try socket.write(DiscordIPC.Frame(opcode: 0, json: ["v": 1, "client_id": app.id]))
                    try waitFor(socket, event: "READY", nonce: nil)
                    guard mayShare(generation: generation) else { throw CancellationError() }
                    let nonce = UUID().uuidString
                    try socket.write(DiscordIPC.Frame(opcode: 1, json: [
                        "cmd": "SET_ACTIVITY", "nonce": nonce,
                        "args": ["pid": Int(getpid()), "activity": ["timestamps": ["start": Int(game.started.timeIntervalSince1970)]]],
                    ]))
                    try waitFor(socket, event: nil, nonce: nonce)
                    guard mayShare(generation: generation) else { throw CancellationError() }
                    passive = socket; passiveIdentity = game.identity
                    message = "Sharing \(app.name)"
                } catch { socket.stop(); throw error }
            } catch { clearPassive(); message = "Discord could not accept this game's activity" }
        }
    }

    private func waitFor(_ socket: DiscordSocket, event: String?, nonce: String?) throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            guard mayShare() else { throw CancellationError() }
            let frame = try socket.readFrame(timeout: max(0.01, deadline.timeIntervalSinceNow))
            if frame.opcode == 3 { try socket.write(DiscordIPC.Frame(opcode: 4, payload: frame.payload)); continue }
            guard frame.opcode == 1, let json = frame.json else { throw HighballError.failed("Discord rejected IPC") }
            if json["evt"] as? String == "ERROR" { throw HighballError.failed("Discord rejected activity") }
            if let event, json["evt"] as? String == event { return }
            if let nonce, json["nonce"] as? String == nonce { return }
        }
        throw HighballError.failed("Discord IPC timed out")
    }
    // Caller owns lock.
    private func clearPassive() {
        if let passive {
            if let clear = try? DiscordIPC.Frame(opcode: 1, json: ["cmd": "SET_ACTIVITY", "nonce": UUID().uuidString,
                                                                   "args": ["pid": Int(getpid()), "activity": NSNull()]]) {
                try? passive.write(clear)
            }
            passive.stop()
        }
        passive = nil; passiveIdentity = nil
    }
    public func stop() {
        bridgeLock.withLock {
            bridge?.stop(); bridge = nil
            // The control connection ends the Windows helper without killing its prefix.
            helpers.removeAll()
        }
        lock.withLock { clearPassive(); richClients.removeAll(); message = "Discord sharing stopped" }
    }
}
