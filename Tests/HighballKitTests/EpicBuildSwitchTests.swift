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
        let oldPath = try installed(config)["Garlic"]?["install_path"] as? String
        XCTAssertNotNil(oldPath)
        XCTAssertEqual(store.savedInstallPath("Garlic"), oldPath, "the old build's folder, for deleting it at launch")
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

    // MARK: Finishing at launch, and deleting the old build's files

    /// A switch Highball quit in the middle of, as launch finds it.
    func testLaunchFinishesASwitchOnlyFromARecordItCanRead() throws {
        let (store, config) = try legendaryHome()
        // Quit after the record was kept, before legendary dropped it: the build is still installed.
        try store.saveRecord("Garlic")
        XCTAssertEqual(try store.finishSwitch("Garlic"), .leftAsItWas, "the installed build is never taken for a leftover")
        XCTAssertEqual(store.switchesInFlight(), [])
        // installed.json unreadable: nothing changes, and the marker stays for the next launch.
        try store.saveRecord("Garlic")
        let good = try Data(contentsOf: config.appending(path: "installed.json"))
        try Data("{not json".utf8).write(to: config.appending(path: "installed.json"))
        XCTAssertEqual(try store.finishSwitch("Garlic"), .unreadable)
        XCTAssertEqual(store.switchesInFlight(), ["Garlic"])
        XCTAssertThrowsError(try store.restoreSavedRecord("Garlic"), "an unreadable installed.json is not written over")
        XCTAssertEqual(try Data(contentsOf: config.appending(path: "installed.json")), Data("{not json".utf8))
        try good.write(to: config.appending(path: "installed.json"))
        // Dropped and nothing new in: the old record goes back.
        try dropRecord(config)
        XCTAssertEqual(try store.finishSwitch("Garlic"), .restored)
        XCTAssertEqual(try installed(config)["Garlic"]?["install_path"] as? String, "/E/drive_c/Games/Gungeon")
        // The new build in, in another folder: the old build's files are to go, the marker stays till then.
        try store.saveRecord("Garlic")
        var games = try installed(config)
        games["Garlic"] = ["app_name": "Garlic", "install_path": "/U/Applications/Highball Games/Garlic", "platform": "Mac", "version": "1.0-m"]
        try JSONSerialization.data(withJSONObject: games).write(to: config.appending(path: "installed.json"))
        XCTAssertEqual(try store.finishSwitch("Garlic"), .deleteOldBuild("/E/drive_c/Games/Gungeon"))
        XCTAssertEqual(store.switchesInFlight(), ["Garlic"])
        // The same folder, written differently, is the same build.
        games["Garlic"] = ["app_name": "Garlic", "install_path": "/e/DRIVE_C/Games/Gungeon/", "platform": "Windows", "version": "1.0-w"]
        try JSONSerialization.data(withJSONObject: games).write(to: config.appending(path: "installed.json"))
        XCTAssertEqual(try store.finishSwitch("Garlic"), .leftAsItWas)
    }

    /// A stand-in legendary whose `list-files --manifest <file> --json` prints the file (the test
    /// manifests hold the JSON list), or fails when `fails` is set.
    private func fakeLegendary(_ store: EpicStore, fails: Bool = false) throws {
        try FileManager.default.createDirectory(at: store.binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/bin/sh
        [ "$1" = list-files ] && [ "$2" = --manifest ] && [ "$4" = --json ] || exit 2
        \(fails ? "echo '[cli] ERROR: bad manifest' >&2; exit 1" : "cat \"$3\"")
        """.write(to: store.binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.binary.path)
    }

    /// An old build in a Highball game folder: its manifest's files, a DLC's, and what the game
    /// wrote there itself (a save, a mod).
    private func oldBuild(_ store: EpicStore, _ config: URL) throws -> (root: URL, folder: URL) {
        let root = store.paths.home.appending(path: "E/drive_c/Games", directoryHint: .isDirectory)
        let folder = root.appending(path: "Gungeon", directoryHint: .isDirectory)
        var games = try installed(config)
        games["Garlic"]?["install_path"] = folder.path
        games["GarlicDLC"]?["install_path"] = folder.path
        try JSONSerialization.data(withJSONObject: games).write(to: config.appending(path: "installed.json"))
        try Data(#"[{"filename": "Game.exe"}, {"filename": "Data/Pak0.pak"}, {"filename": "Data/Movies/Intro.bk2"}, {"filename": "../Duck/x"}]"#.utf8)
            .write(to: config.appending(path: "manifests/Garlic_Windows_1.0-w.manifest"))
        try Data(#"[{"filename": "DLC/Pak1.pak"}]"#.utf8).write(to: config.appending(path: "manifests/GarlicDLC_2.manifest"))
        let fm = FileManager.default
        for file in ["GAME.EXE", "Data/Pak0.pak", "Data/Movies/Intro.bk2", "DLC/Pak1.pak", "Saved/slot1.sav", "Data/mods/mod.pak"] {
            let url = folder.appending(path: file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try fm.createDirectory(at: root.appending(path: "Duck"), withIntermediateDirectories: true)
        try Data("duck".utf8).write(to: root.appending(path: "Duck/x"))
        return (root, folder)
    }

    /// highball#609: an old build's folder went whole, saves and mods with it. Now only what its
    /// manifests list goes, then the folders that leaves empty, as legendary's uninstall does.
    func testOnlyTheOldBuildsListedFilesAreDeleted() throws {
        let (store, config) = try legendaryHome()
        try fakeLegendary(store)
        let (root, folder) = try oldBuild(store, config)
        try store.saveRecord("Garlic")
        XCTAssertEqual(store.deleteOldBuild("Garlic", at: folder.path, roots: [root]), .deleted(files: 4, failed: 0))
        let fm = FileManager.default
        for gone in ["GAME.EXE", "Data/Pak0.pak", "Data/Movies", "DLC"] {
            XCTAssertFalse(fm.fileExists(atPath: folder.appending(path: gone).path), gone)
        }
        for kept in ["Saved/slot1.sav", "Data/mods/mod.pak"] {
            XCTAssertTrue(fm.fileExists(atPath: folder.appending(path: kept).path), kept)
        }
        XCTAssertTrue(fm.fileExists(atPath: root.appending(path: "Duck/x").path), "a name leaving the folder is skipped")
        XCTAssertEqual(store.switchesInFlight(), [], "the kept record goes once the files have")
    }

    func testAnEmptiedFolderGoesWithIt() throws {
        let (store, config) = try legendaryHome()
        try fakeLegendary(store)
        let (root, folder) = try oldBuild(store, config)
        let fm = FileManager.default
        try fm.removeItem(at: folder.appending(path: "Saved"))
        try fm.removeItem(at: folder.appending(path: "Data/mods"))
        try store.saveRecord("Garlic")
        XCTAssertEqual(store.deleteOldBuild("Garlic", at: folder.path, roots: [root]), .deleted(files: 4, failed: 0))
        XCTAssertFalse(fm.fileExists(atPath: folder.path))
        XCTAssertTrue(fm.fileExists(atPath: root.path))
    }

    /// No list, nothing deleted: a failed legendary, a manifest that was not kept, a folder
    /// outside Highball's game folders.
    func testWithoutAFileListNothingIsDeleted() throws {
        let (store, config) = try legendaryHome()
        try fakeLegendary(store, fails: true)
        let (root, folder) = try oldBuild(store, config)
        try store.saveRecord("Garlic")
        guard case .noFileList = store.deleteOldBuild("Garlic", at: folder.path, roots: [root]) else { return XCTFail("listed") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "GAME.EXE").path))
        XCTAssertEqual(store.switchesInFlight(), [])

        try fakeLegendary(store)
        try store.saveRecord("Garlic")
        try FileManager.default.removeItem(at: store.paths.home.appending(path: "epic-switch/Garlic/manifests/Garlic_Windows_1.0-w.manifest"))
        guard case .noFileList = store.deleteOldBuild("Garlic", at: folder.path, roots: [root]) else { return XCTFail("listed") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "GAME.EXE").path))

        try store.saveRecord("Garlic")
        XCTAssertEqual(store.deleteOldBuild("Garlic", at: folder.path, roots: [folder]), .outsideGameFolders)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "GAME.EXE").path))
    }
}
