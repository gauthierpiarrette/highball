import XCTest
import Darwin
@testable import HighballKit

final class DiscordPresenceTests: XCTestCase {
    private let catalogData = Data(#"""
    [{"id":"356942674672091136","name":"Geometry Dash","aliases":["GD"],
      "executables":[{"name":"geometry dash/geometrydash.exe","os":"win32"}],
      "third_party_skus":[{"distributor":"steam","id":"322170"},{"distributor":"battlenet","id":null}]},
     {"id":"2","name":"First","executables":[{"name":"game.exe","os":"win32"}]},
     {"id":"3","name":"Second","executables":[{"name":"game.exe","os":"win32"}]},
     {"id":"4","name":"A launcher","executables":[{"name":"launcher.exe","os":"win32","is_launcher":true}]}]
    """#.utf8)

    func testCurrentPublicCatalogWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["HIGHBALL_DISCORD_CATALOG_FIXTURE"] else {
            throw XCTSkip("Set HIGHBALL_DISCORD_CATALOG_FIXTURE to validate a downloaded public catalog")
        }
        let catalog = try DiscordGameCatalog(data: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertGreaterThan(catalog.applications.count, 1000)
        XCTAssertEqual(catalog.match(steamID: 322170, title: "Renamed game", executable: nil)?.name, "Geometry Dash")
    }

    func testCatalogPrefersSteamIDAndRejectsAmbiguousExecutables() throws {
        let catalog = try DiscordGameCatalog(data: catalogData)
        XCTAssertEqual(catalog.match(steamID: 322170, title: "My renamed game", executable: nil)?.name, "Geometry Dash")
        XCTAssertEqual(catalog.match(steamID: nil, title: "gd", executable: nil)?.id, "356942674672091136")
        XCTAssertEqual(catalog.match(steamID: nil, title: "", executable: #"C:\Games\GeometryDash.exe"#)?.name, "Geometry Dash")
        XCTAssertNil(catalog.match(steamID: nil, title: "", executable: "game.exe"))
        XCTAssertNil(catalog.match(steamID: nil, title: "", executable: "launcher.exe"))
        XCTAssertNil(catalog.match(steamID: nil, title: "Geometry", executable: nil))
    }

    func testPresenceFollowsTrackedSessionsWithStableIdentityAndStartTime() {
        let since = Date(timeIntervalSince1970: 100)
        let first = GameSession(title: "Renamed game", bottleName: "a", appid: 322170,
                                markers: SessionWatch.markers(installdir: "Geometry Dash"), started: since)
        let second = GameSession(title: "Another game", bottleName: "b", appid: nil,
                                 markers: ["game.exe"], started: since.addingTimeInterval(10))
        let games = DiscordSessions.games([first, second])
        XCTAssertEqual(games[0].identity, first.id.uuidString)
        XCTAssertEqual(games[0].steamID, 322170)
        XCTAssertEqual(games[0].title, "Renamed game")
        XCTAssertEqual(games[0].started, since)
        XCTAssertNil(games[0].executable)
        XCTAssertEqual(games[1].executable, "game.exe")
        XCTAssertNotEqual(games[0].identity, games[1].identity)
        XCTAssertEqual(DiscordSessions.games([second]), [games[1]], "Ending a session removes only that game's activity")
    }

    func testSharingDefaultsOffAndDoesNotAccessDiscordOrCatalog() async throws {
        let access = DiscordAccessProbe()
        let presence = DiscordPresence(socketPaths: { access.record(); return [] }, loadCatalog: { _ in
            access.record(); return nil
        })
        defer { presence.stop() }
        let catalog = try DiscordGameCatalog(data: catalogData)
        let game = DiscordRunningGame(identity: "gd", title: "Geometry Dash", steamID: 322170,
                                      executable: nil, started: Date())
        let engine = InstalledEngine(manifest: EngineManifest(id: "test", displayName: "test", arch: "x86_64",
                                                              minMacOS: "14.0", components: [:]),
                                     root: URL(fileURLWithPath: "/tmp/unused-discord-engine"))
        let bottle = Bottle(url: URL(fileURLWithPath: "/tmp/unused-discord-prefix"),
                            settings: BottleSettings(name: "test", engineID: "test"))
        XCTAssertFalse(presence.isEnabled)
        await presence.update(games: [game])
        presence.publish(games: [game], catalog: catalog)
        presence.ensureBridge(engine: engine, bottle: bottle, environment: [:])
        XCTAssertEqual(access.count, 0, "Disabled sharing must not inspect Discord sockets, load the catalog, or start helpers")
        XCTAssertEqual(presence.status, "Discord sharing is off")
    }

    func testRevokingConsentDiscardsCatalogResponseEvenAfterReenabling() async throws {
        let fake = try FakeDiscord()
        defer { fake.stop() }
        let catalog = try DiscordGameCatalog(data: catalogData)
        let loading = expectation(description: "Catalog request started while enabled")
        let (gate, release) = AsyncStream<Void>.makeStream()
        let presence = DiscordPresence(socketPaths: { [fake.path] }, loadCatalog: { _ in
            loading.fulfill()
            for await _ in gate { break }
            return catalog
        })
        presence.setEnabled(true)
        defer { presence.stop() }
        let game = DiscordRunningGame(identity: "gd", title: "Geometry Dash", steamID: 322170,
                                      executable: nil, started: Date())
        let update = Task { await presence.update(games: [game]) }
        await fulfillment(of: [loading], timeout: 2)
        presence.setEnabled(false)
        presence.setEnabled(true)
        release.yield(())
        release.finish()
        await update.value
        XCTAssertTrue(fake.handshakes.isEmpty, "An update from the previous consent period must never publish")
    }

    func testFragmentedFrameAndPIDTranslationPreserveRichData() throws {
        let (writer, reader) = try pair()
        let frame = try DiscordIPC.Frame(opcode: 1, json: ["cmd": "SET_ACTIVITY", "nonce": "n",
            "args": ["pid": 123, "activity": ["state": "In game", "secrets": ["join": "secret"], "assets": ["large_image": "map"]]]])
        DispatchQueue.global().async { for byte in frame.bytes { try? writer.write(Data([byte])) } }
        let received = try reader.readFrame(timeout: 2)
        let rewritten = try received.hostPID(456)
        XCTAssertEqual((rewritten.json?["args"] as? [String: Any])?["pid"] as? Int, 456)
        let activity = (rewritten.json?["args"] as? [String: Any])?["activity"] as? [String: Any]
        XCTAssertEqual((activity?["secrets"] as? [String: String])?["join"], "secret")
        XCTAssertEqual(rewritten.json?["nonce"] as? String, "n")
        XCTAssertEqual(received.activity, true)
        let ping = DiscordIPC.Frame(opcode: 3, payload: Data([0, 255, 1]))
        XCTAssertEqual(try ping.hostPID(456).bytes, ping.bytes)
    }

    func testRejectsOversizeAndTruncatedFrames() throws {
        let (writer, reader) = try pair()
        var header = Data([1, 0, 0, 0]); var size = UInt32(DiscordIPC.maximumPayload + 1).littleEndian
        withUnsafeBytes(of: &size) { header.append(contentsOf: $0) }
        try writer.write(header)
        XCTAssertThrowsError(try reader.readFrame(timeout: 1))
        let (writer2, reader2) = try pair()
        try writer2.write(Data([1, 0, 0])); writer2.stop()
        XCTAssertThrowsError(try reader2.readFrame(timeout: 1))
    }

    /// Any client serving Discord's socket counts, not only Discord's own app (Vesktop, 2026-10-08).
    func testAClientSocketCountsAsDiscordOpen() throws {
        XCTAssertFalse(DiscordPresence(socketPaths: { ["/nonexistent/discord-ipc-0"] }).clientSocketPresent)
        let fake = try FakeDiscord()
        defer { fake.stop() }
        XCTAssertTrue(DiscordPresence(socketPaths: { ["/nonexistent/discord-ipc-0", fake.path] }).clientSocketPresent)
    }

    func testPassiveUsesGameIDClearsOnRichPresenceAndResumes() throws {
        let fake = try FakeDiscord()
        defer { fake.stop() }
        let presence = DiscordPresence(socketPaths: { [fake.path] })
        presence.setEnabled(true)
        defer { presence.stop() }
        let catalog = try DiscordGameCatalog(data: catalogData)
        let game = DiscordRunningGame(identity: "gd", title: "My title", steamID: 322170, executable: nil, started: Date(timeIntervalSince1970: 123))
        presence.publish(games: [game], catalog: catalog)
        XCTAssertEqual(presence.status, "Sharing Geometry Dash")
        XCTAssertEqual(fake.handshakes.last, "356942674672091136")
        let id = UUID()
        presence.richActivity(id, active: true)
        presence.publish(games: [game], catalog: catalog)
        XCTAssertEqual(presence.status, "Game Rich Presence connected")
        XCTAssertEqual(fake.handshakes.count, 1)
        presence.richActivity(id, active: false)
        presence.publish(games: [game], catalog: catalog)
        XCTAssertEqual(presence.status, "Sharing Geometry Dash")
        XCTAssertEqual(fake.handshakes.count, 2)
        presence.publish(games: [], catalog: catalog)
        XCTAssertEqual(presence.status, "Waiting for a game")
    }

    func testPassiveReconnectsAfterDiscordRestartAndRespondsToPing() throws {
        let fake = try FakeDiscord()
        defer { fake.stop() }
        let presence = DiscordPresence(socketPaths: { [fake.path] })
        presence.setEnabled(true)
        defer { presence.stop() }
        let catalog = try DiscordGameCatalog(data: catalogData)
        let game = DiscordRunningGame(identity: "gd", title: "Geometry Dash", steamID: 322170,
                                      executable: nil, started: Date())
        presence.publish(games: [game], catalog: catalog)
        try fake.ping()
        presence.publish(games: [game], catalog: catalog)
        XCTAssertEqual(fake.handshakes.count, 1, "Ping must not republish the activity")
        fake.disconnectClients()
        presence.publish(games: [game], catalog: catalog)
        presence.publish(games: [game], catalog: catalog)
        XCTAssertEqual(presence.status, "Sharing Geometry Dash")
        XCTAssertEqual(fake.handshakes.count, 2)
    }

    func testBridgeIsBidirectionalAndStopsConnections() throws {
        let fake = try FakeDiscord()
        defer { fake.stop() }
        let bridge = try DiscordBridge(socketPaths: { [fake.path] }) { _, _ in }
        defer { bridge.stop() }
        let client = try tcp(port: bridge.port)
        try client.write(Data(bridge.token.utf8) + Data([0]))
        try client.write(DiscordIPC.Frame(opcode: 0, json: ["v": 1, "client_id": "356942674672091136"]))
        XCTAssertEqual(try client.readFrame(timeout: 2).json?["evt"] as? String, "READY")
        try client.write(DiscordIPC.Frame(opcode: 1, json: ["cmd": "SET_ACTIVITY", "nonce": "win",
            "args": ["pid": 999, "activity": ["state": "A level"]]]))
        let reply = try client.readFrame(timeout: 2)
        XCTAssertEqual((reply.json?["args"] as? [String: Any])?["pid"] as? Int, Int(getpid()))
        XCTAssertEqual(reply.json?["nonce"] as? String, "win")
        bridge.stop()
        XCTAssertThrowsError(try client.readFrame(timeout: 2))
    }

    func testWineNamedPipeSmokeWhenRequested() throws {
        guard let enginePath = ProcessInfo.processInfo.environment["HIGHBALL_DISCORD_SMOKE_ENGINE"] else {
            throw XCTSkip("Set HIGHBALL_DISCORD_SMOKE_ENGINE to an installed engine directory for the Wine smoke")
        }
        let engineRoot = URL(fileURLWithPath: enginePath)
        let engine = InstalledEngine(manifest: try EngineManifest.load(from: engineRoot.appending(path: "manifest.json")), root: engineRoot)
        let root = URL(fileURLWithPath: "/tmp/hb-discord-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bottle = Bottle(url: root, settings: BottleSettings(name: "discord-smoke", engineID: engine.id))
        var env = engine.baseEnvironment().merging(ProcessInfo.processInfo.environment) { original, _ in original }
        env["WINEPREFIX"] = root.path; env["WINEDEBUG"] = "-all"
        env["WINEMSYNC"] = "0"; env["WINEESYNC"] = "0"
        let boot = Process(); boot.executableURL = engine.wineBinary; boot.arguments = ["wineboot.exe", "--init"]
        boot.environment = env; boot.standardOutput = FileHandle.nullDevice; boot.standardError = FileHandle.nullDevice
        try boot.run()
        defer {
            let kill = Process(); kill.executableURL = engine.wineserverBinary; kill.arguments = ["-k"]
            kill.environment = env; try? kill.run(); kill.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertTrue(waitUntil(seconds: 90) { !boot.isRunning }, "Wine boot timed out")
        guard !boot.isRunning else { boot.terminate(); return }
        XCTAssertEqual(boot.terminationStatus, 0)
        let fake = try FakeDiscord()
        defer { fake.stop() }
        let presence = DiscordPresence(socketPaths: { [fake.path] })
        presence.setEnabled(true)
        defer { presence.stop() }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = repo.appending(path: "spike/discord-bridge/highball-discord-bridge.exe")
        let probe = repo.appending(path: "spike/discord-bridge/probe.exe")
        for cycle in 0..<2 {
            presence.setEnabled(true)
            presence.ensureBridge(engine: engine, bottle: bottle, environment: env, helperURL: helper)
            let session = GameSession(title: "Bridge environment probe", bottleName: bottle.name, appid: nil,
                                      markers: ["highball-discord-bridge.exe"])
            let inherited = DiscordSessions.environment(for: session, prefix: root, processList: SessionWatch.currentProcessList())
            XCTAssertEqual(inherited?["WINEPREFIX"], root.path)
            XCTAssertEqual(inherited?["WINEMSYNC"], env["WINEMSYNC"], "The session-side helper must inherit the game's sync mode")
            XCTAssertNil(DiscordSessions.environment(for: session, prefix: root.appending(path: "another-prefix"),
                                                     processList: SessionWatch.currentProcessList()))
            for slot in [0, 9, 0] {
                let process = Process(), output = Pipe()
                process.executableURL = engine.wineBinary; process.arguments = [probe.path, String(slot)]
                process.environment = env; process.currentDirectoryURL = bottle.driveC
                process.standardOutput = output; process.standardError = FileHandle.nullDevice
                try process.run()
                XCTAssertTrue(waitUntil(seconds: 15) { !process.isRunning }, "Named-pipe probe hung (cycle \(cycle), slot \(slot))")
                guard !process.isRunning else { process.terminate(); return }
                XCTAssertEqual(process.terminationStatus, 0, "Wine pipe probe failed")
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                XCTAssertEqual(lines.count, 2)
                if let last = lines.last, let json = try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any] {
                    XCTAssertEqual((json["args"] as? [String: Any])?["pid"] as? Int, Int(getpid()))
                    XCTAssertEqual(json["nonce"] as? String, "wine-probe")
                }
            }
            presence.setEnabled(false)
            presence.stop()
            XCTAssertTrue(waitUntil(seconds: 5) {
                !ProcessTable.allPIDs().contains { pid in
                    guard let command = ProcessTable.commandLineAndEnvironment(of: pid), command.environment["WINEPREFIX"] == root.path else { return false }
                    return command.arguments.contains { $0.contains("highball-discord-bridge.exe") }
                }
            }, "Bridge shutdown left the Wine helper alive")
            presence.ensureBridge(engine: engine, bottle: bottle, environment: env, helperURL: helper)
            XCTAssertFalse(ProcessTable.allPIDs().contains { pid in
                guard let command = ProcessTable.commandLineAndEnvironment(of: pid), command.environment["WINEPREFIX"] == root.path else { return false }
                return command.arguments.contains { $0.contains("highball-discord-bridge.exe") }
            }, "Disabled sharing must not restart the helper")
        }
    }

    func testEndingOnePrefixDoesNotStopAnotherBridgeControl() throws {
        let bridge = try DiscordBridge(socketPaths: { [] }) { _, _ in }
        defer { bridge.stop() }
        func control(_ prefix: String) throws -> DiscordSocket {
            let client = try tcp(port: bridge.port)
            let path = Data(prefix.utf8)
            var length = UInt16(path.count).littleEndian
            var header = Data(bridge.token.utf8) + Data([255])
            withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
            try client.write(header + path)
            return client
        }
        let first = try control("/tmp/first"), second = try control("/tmp/second")
        defer { first.stop(); second.stop() }
        XCTAssertTrue(waitUntil(seconds: 2) { bridge.isReady(prefix: "/tmp/first") && bridge.isReady(prefix: "/tmp/second") })
        bridge.stopControl(prefix: "/tmp/first")
        XCTAssertThrowsError(try first.read(1, timeout: 1))
        XCTAssertTrue(waitUntil(seconds: 2) { !bridge.isReady(prefix: "/tmp/first") })
        XCTAssertTrue(bridge.isReady(prefix: "/tmp/second"), "A game ending must not close another environment's helper")
    }

    private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { usleep(20_000) }
        return condition()
    }

    private func pair() throws -> (DiscordSocket, DiscordSocket) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw HighballError.failed("socketpair") }
        return (DiscordSocket(fd: fds[0]), DiscordSocket(fd: fds[1]))
    }
}

private func tcp(port: UInt16) throws -> DiscordSocket {
    let sock = try DiscordSocket(domain: AF_INET)
    var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = port.bigEndian
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result == 0 else { throw HighballError.failed("connect") }
    return sock
}

/// Real local Unix sockets, with no network access and no activity sent to the user's Discord.
private final class FakeDiscord: @unchecked Sendable {
    let path = "/tmp/hb-\(UUID().uuidString.prefix(12)).sock"
    private let listener: DiscordSocket
    private let lock = NSLock()
    private var stopped = false
    private var sockets: [DiscordSocket] = []
    private var ids: [String] = []
    var handshakes: [String] { lock.withLock { ids } }
    init() throws {
        listener = try DiscordSocket(domain: AF_UNIX)
        let socket = listener
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: bytes.count) { $0.update(from: bytes, count: bytes.count) }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket.fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, listen(socket.fd, 16) == 0 else { throw HighballError.failed("fake bind") }
        DispatchQueue.global().async { [self] in
            while !lock.withLock({ stopped }) {
                var p = pollfd(fd: socket.fd, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 100) > 0 else { continue }
                let fd = accept(socket.fd, nil, nil)
                guard fd >= 0 else { continue }
                let client = DiscordSocket(fd: fd)
                lock.withLock { sockets.append(client) }
                DispatchQueue.global().async { [self] in
                    do {
                        let handshake = try client.readFrame(timeout: 2)
                        lock.withLock { ids.append(handshake.json?["client_id"] as? String ?? "") }
                        try client.write(DiscordIPC.Frame(opcode: 1, json: ["cmd": "DISPATCH", "evt": "READY", "data": [:]]))
                        while true {
                            let frame = try client.readFrame()
                            try client.write(frame) // echo nonce and rewritten args
                        }
                    } catch { client.stop() }
                }
            }
        }
    }
    func ping() throws {
        guard let client = lock.withLock({ sockets.last }) else { throw HighballError.failed("No fake client") }
        try client.write(DiscordIPC.Frame(opcode: 3, payload: Data("ping".utf8)))
    }
    func disconnectClients() { lock.withLock { for client in sockets { client.stop() } } }
    func stop() {
        lock.withLock { stopped = true; listener.stop(); for client in sockets { client.stop() } }
        unlink(path)
    }
}

private final class DiscordAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var accesses = 0
    var count: Int { lock.withLock { accesses } }
    func record() { lock.withLock { accesses += 1 } }
}
