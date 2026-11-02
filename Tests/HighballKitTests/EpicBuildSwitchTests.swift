import XCTest
@testable import HighballKit

/// Replacing an Epic build: the old one stays recoverable until the new one is in.
final class EpicBuildSwitchTests: XCTestCase {
    final class Log: @unchecked Sendable { var steps: [String] = [] }

    private func steps(_ log: Log, hasNew: Bool = true, replacing: Bool = true,
                       install: @escaping () async throws -> Void = {}) -> EpicBuildSwitch.Steps {
        EpicBuildSwitch.Steps(
            hasNewBuild: { log.steps.append("check"); return hasNew },
            dropOldRecord: replacing ? { log.steps.append("drop") } : nil,
            install: { log.steps.append("install"); try await install() },
            restoreOldRecord: { log.steps.append("restore") },
            deleteOldFiles: { log.steps.append("delete") })
    }

    func testTheOldFilesGoOnlyOnceTheNewBuildIsIn() async throws {
        let log = Log()
        try await EpicBuildSwitch.run(steps(log))
        XCTAssertEqual(log.steps, ["check", "drop", "install", "delete"])
    }

    func testNoNewBuildChangesNothing() async {
        let log = Log()
        do { try await EpicBuildSwitch.run(steps(log, hasNew: false)); XCTFail("no new build") } catch {
            XCTAssertEqual(error as? EpicBuildSwitch.Failure, .noNewBuild)
        }
        XCTAssertEqual(log.steps, ["check"])
    }

    /// A failed download, or legendary falling back to the old platform, puts the old record back.
    func testAFailedInstallPutsTheOldBuildBack() async {
        let log = Log()
        struct Boom: Error {}
        do { try await EpicBuildSwitch.run(steps(log, install: { throw Boom() })); XCTFail("failed") } catch { XCTAssertTrue(error is Boom) }
        XCTAssertEqual(log.steps, ["check", "drop", "install", "restore"])
    }

    /// Stop while Epic is asked: nothing is dropped.
    func testStopDuringTheCheckChangesNothing() async {
        let log = Log()
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            try await EpicBuildSwitch.run(EpicBuildSwitch.Steps(
                hasNewBuild: { log.steps.append("check"); started.continuation.yield(); try? await Task.sleep(for: .milliseconds(200)); return true },
                dropOldRecord: { log.steps.append("drop") }, install: { log.steps.append("install") },
                restoreOldRecord: { log.steps.append("restore") }, deleteOldFiles: { log.steps.append("delete") }))
        }
        for await _ in started.stream { break }
        task.cancel()
        do { try await task.value; XCTFail("stopped") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(log.steps, ["check"])
    }

    /// Stop during the download: the old record is put back.
    func testStopDuringTheDownloadPutsTheOldBuildBack() async {
        let log = Log()
        let task = Task { try await EpicBuildSwitch.run(steps(log, install: { try await Task.sleep(for: .seconds(5)) })) }
        while !log.steps.contains("install") { await Task.yield() }
        task.cancel()
        do { try await task.value; XCTFail("stopped") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(log.steps, ["check", "drop", "install", "restore"])
    }

    func testAPlainInstallHasNothingToDropOrDelete() async throws {
        let log = Log()
        try await EpicBuildSwitch.run(steps(log, replacing: false))
        XCTAssertEqual(log.steps, ["check", "install"])
    }

    func testOnlyAFolderInsideHighballsGameFoldersIsDeleted() {
        let roots = [URL(fileURLWithPath: "/E/drive_c/Games"), URL(fileURLWithPath: "/U/Applications/Highball Games")]
        XCTAssertTrue(EpicBuildSwitch.isSafeToDelete(URL(fileURLWithPath: "/E/drive_c/Games/Gungeon"), roots: roots))
        XCTAssertTrue(EpicBuildSwitch.isSafeToDelete(URL(fileURLWithPath: "/u/applications/highball games/Garlic"), roots: roots))
        XCTAssertFalse(EpicBuildSwitch.isSafeToDelete(URL(fileURLWithPath: "/E/drive_c/Games"), roots: roots))
        XCTAssertFalse(EpicBuildSwitch.isSafeToDelete(URL(fileURLWithPath: "/E/drive_c/Games/"), roots: roots))
        XCTAssertFalse(EpicBuildSwitch.isSafeToDelete(URL(fileURLWithPath: "/E/drive_c/Games2/X"), roots: roots))
        XCTAssertFalse(EpicBuildSwitch.isSafeToDelete(URL(fileURLWithPath: "/U/Applications"), roots: roots))
    }

    // MARK: The old record, kept aside

    /// A fake legendary config: installed.json with a Windows game, its DLC in the same folder and
    /// another game, and the manifests legendary 0.21.0 names after them.
    private func legendaryHome() throws -> (EpicStore, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "hb-epic-switch-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let config = home.appending(path: "legendary", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: config.appending(path: "manifests"), withIntermediateDirectories: true)
        let installed = """
        {"Garlic": {"app_name": "Garlic", "install_path": "/E/drive_c/Games/Gungeon", "platform": "Windows", "version": "1.0-w", "title": "Enter the Gungeon"},
         "GarlicDLC": {"app_name": "GarlicDLC", "install_path": "/E/drive_c/Games/Gungeon", "platform": "Windows", "version": "2", "is_dlc": true},
         "Duck": {"app_name": "Duck", "install_path": "/E/drive_c/Games/Duck", "platform": "Windows", "version": "3"}}
        """
        try Data(installed.utf8).write(to: config.appending(path: "installed.json"))
        for name in ["Garlic_Windows_1.0-w", "GarlicDLC_2", "Duck_Windows_3"] {
            try Data(name.utf8).write(to: config.appending(path: "manifests/\(name).manifest"))
        }
        return (EpicStore(paths: HighballPaths(home: home)), config)
    }

    private func installed(_ config: URL) throws -> [String: [String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config.appending(path: "installed.json"))) as? [String: [String: Any]])
    }

    /// What `legendary uninstall --keep-files` does to the config: the game's and its DLC's entries go.
    private func dropRecord(_ config: URL, manifestsToo: Bool = false) throws {
        var games = try installed(config)
        games["Garlic"] = nil; games["GarlicDLC"] = nil
        try JSONSerialization.data(withJSONObject: games).write(to: config.appending(path: "installed.json"))
        if manifestsToo {
            for name in ["Garlic_Windows_1.0-w", "GarlicDLC_2"] { try FileManager.default.removeItem(at: config.appending(path: "manifests/\(name).manifest")) }
        }
    }

    func testAKeptRecordGoesBackWithItsDLCAndManifestsAndNoNetwork() throws {
        let (store, config) = try legendaryHome()
        try store.saveRecord("Garlic")
        XCTAssertEqual(store.switchesInFlight(), ["Garlic"], "a switch in flight leaves its marker")
        try dropRecord(config, manifestsToo: true)
        XCTAssertTrue(try store.restoreSavedRecord("Garlic"))
        let games = try installed(config)
        XCTAssertEqual(Set(games.keys), ["Garlic", "GarlicDLC", "Duck"])
        XCTAssertEqual(games["Garlic"]?["version"] as? String, "1.0-w")
        XCTAssertEqual(games["GarlicDLC"]?["is_dlc"] as? Bool, true)
        for name in ["Garlic_Windows_1.0-w", "GarlicDLC_2", "Duck_Windows_3"] {
            XCTAssertEqual(try String(contentsOf: config.appending(path: "manifests/\(name).manifest"), encoding: .utf8), name)
        }
        XCTAssertEqual(store.switchesInFlight(), [], "the marker goes once the record is back")
    }

    /// The new build finished (legendary records the game again), or the record was never dropped:
    /// nothing is written over it, and the marker goes.
    func testARecordLegendaryHasIsLeftAsItIs() throws {
        let (store, config) = try legendaryHome()
        try store.saveRecord("Garlic")
        var games = try installed(config)
        games["Garlic"] = ["app_name": "Garlic", "install_path": "/U/Applications/Highball Games/Garlic", "platform": "Mac", "version": "1.0-m"]
        games["GarlicDLC"] = nil
        try JSONSerialization.data(withJSONObject: games).write(to: config.appending(path: "installed.json"))
        XCTAssertFalse(try store.restoreSavedRecord("Garlic"))
        XCTAssertEqual(try installed(config)["Garlic"]?["platform"] as? String, "Mac")
        XCTAssertNil(try installed(config)["GarlicDLC"])
        XCTAssertEqual(store.switchesInFlight(), [])
    }

    func testNothingIsKeptForAGameLegendaryHasNoRecordOf() throws {
        let (store, _) = try legendaryHome()
        XCTAssertThrowsError(try store.saveRecord("Nope"))
        XCTAssertEqual(store.switchesInFlight(), [])
        XCTAssertFalse(try store.restoreSavedRecord("Nope"))
    }

    /// A legendary still running holds its install lock: nothing is written, the marker stays for
    /// the next launch, and the undo goes through once the lock is free.
    func testTheUndoWaitsForLegendarysLock() throws {
        let (store, config) = try legendaryHome()
        try store.saveRecord("Garlic")
        try dropRecord(config)
        let fd = open(config.appending(path: "installed.json.lock").path, O_RDWR | O_CREAT, 0o644)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try store.restoreSavedRecord("Garlic"))
        XCTAssertNil(try installed(config)["Garlic"])
        XCTAssertEqual(store.switchesInFlight(), ["Garlic"])
        close(fd)
        XCTAssertTrue(try store.restoreSavedRecord("Garlic"))
        XCTAssertNotNil(try installed(config)["Garlic"])
    }

    func testLegendarysManifestNames() {
        XCTAssertEqual(EpicStore.manifestNames("Garlic", entry: ["version": "1.0+5", "platform": "Mac"]),
                       ["Garlic_Mac_1.0+5.manifest", "Garlic_1.0+5.manifest"])
        XCTAssertEqual(EpicStore.manifestNames("A", entry: ["version": "v1:2/3"]), ["A_Windows_v123.manifest", "A_v123.manifest"])
        XCTAssertEqual(EpicStore.manifestNames("A", entry: [:]), [])
    }
}
