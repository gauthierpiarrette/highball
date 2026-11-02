import XCTest
@testable import HighballKit

/// EpicSaves against a stand-in for legendary 0.21.0's `sync-saves`: the same decisions as cli.py
/// and core.py (newest wins by age, 60 seconds of slack, a download deletes the folder's files
/// first and carries on past a failed download, an upload ignores whether its files arrived),
/// over a folder that plays Epic's cloud.
final class EpicFakeLegendaryTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appending(path: "home") }
    private var config: URL { home.appending(path: "legendary") }
    private var cloud: URL { home.appending(path: "fake-cloud") }
    private var prefix: URL { root.appending(path: "Env") }
    private var install: URL { root.appending(path: "Env/drive_c/Games/Game") }
    private var userHome: URL { root.appending(path: "user") }
    private var folder: URL { prefix.appending(path: "drive_c/users/player/AppData/Local/Game/Saved") }
    private let app = "Game"

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("needs python3") }
        root = FileManager.default.temporaryDirectory.appending(path: "fake-legendary-\(UUID().uuidString)")
        for dir in [home.appending(path: "tools"), config.appending(path: "metadata"), cloud, install, userHome,
                    prefix.appending(path: "drive_c/users/player")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let legendary = home.appending(path: "tools/legendary")
        try Self.script.write(to: legendary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legendary.path)
        try #"{"app_name":"Game","metadata":{"customAttributes":{"CloudSaveFolder":{"type":"STRING","value":"{AppData}/Game/Saved"}}}}"#
            .write(to: config.appending(path: "metadata/Game.json"), atomically: true, encoding: .utf8)
        try installed(savePath: nil)
        // Where the stand-in resolves the save folder, inside the WINEPREFIX it is given.
        try "drive_c/users/player/AppData/Local/Game/Saved".write(to: home.appending(path: "fake-save-path"), atomically: true, encoding: .utf8)
    }
    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var saves: EpicSaves { EpicSaves(store: EpicStore(paths: HighballPaths(home: home))) }
    private func sync(_ direction: EpicSaves.Direction) -> EpicSaves.Outcome {
        saves.sync(app, install: install, prefix: prefix, direction: direction, home: userHome)
    }

    private func installed(savePath: String?) throws {
        let game: [String: Any] = ["app_name": app, "title": "Game", "install_path": install.path, "save_path": savePath ?? NSNull()]
        try JSONSerialization.data(withJSONObject: [app: game]).write(to: config.appending(path: "installed.json"))
    }
    private func write(_ text: String, to url: URL, at date: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func flag(_ name: String, _ text: String = "") throws { try text.write(to: home.appending(path: name), atomically: true, encoding: .utf8) }
    private func unflag(_ name: String) { try? FileManager.default.removeItem(at: home.appending(path: name)) }

    /// Another device uploads a save: a new cloud manifest named by its files' date.
    private func cloudSave(_ text: String, at date: Date) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy.MM.dd-HH.mm.ss"
        let name = formatter.string(from: date) + ".manifest"
        try write(text, to: cloud.appending(path: "\(name)/slot.sav"), at: date)
        // Uploaded now: the newest by upload time, as Epic's listing orders them.
        let index = cloud.appending(path: "index.json")
        var list = (try? JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]]) ?? []
        list.append(["name": name, "uploaded": Date().timeIntervalSince1970 + Double(list.count)])
        try JSONSerialization.data(withJSONObject: list).write(to: index)
    }
    private var cloudSaveCount: Int {
        ((try? JSONSerialization.jsonObject(with: Data(contentsOf: cloud.appending(path: "index.json"))) as? [Any]) ?? []).count
    }

    private let hourAgo = Date().addingTimeInterval(-3_600)
    private let dayAgo = Date().addingTimeInterval(-86_400)

    /// Synced once from the cloud, so later tests start with a record.
    private func syncedOnce() throws {
        try cloudSave("v1", at: dayAgo)
        XCTAssertEqual(sync(.download), .synced)
        XCTAssertEqual(read(folder.appending(path: "slot.sav")), "v1")
    }

    func testAFirstDownloadIntoAnEmptyFolder() throws {
        try syncedOnce()
        let record = try XCTUnwrap(saves.records()[EpicSaves.key(app: app, install: install)])
        XCTAssertNotNil(record.cloud, "the cloud save the Mac matched is kept")
        XCTAssertEqual(record.path, folder.path)
        XCTAssertNil(record.restoring)
    }

    /// A newer cloud save from another device comes down, after a backup of this Mac's.
    func testANewerCloudSaveComesDownAfterABackup() throws {
        try syncedOnce()
        try cloudSave("v2", at: hourAgo)
        XCTAssertEqual(sync(.download), .synced)
        XCTAssertEqual(read(folder.appending(path: "slot.sav")), "v2")
        let backup = try XCTUnwrap(saves.backups.backups(in: saves.backups.folder("epic-\(app)", install: install)).first)
        XCTAssertEqual(read(backup.appending(path: "slot.sav")), "v1")
    }

    /// legendary deletes the folder's files, then fails to download and still exits 0: the
    /// backup goes back, and the outcome says so (the game must not start on an empty folder).
    func testADownloadThatFailsAfterEmptyingTheFolderIsUndone() throws {
        try syncedOnce()
        try cloudSave("v2", at: hourAgo)
        try flag("fake-fail-download")
        guard case .restored = sync(.download) else { return XCTFail("expected the saves put back") }
        XCTAssertEqual(read(folder.appending(path: "slot.sav")), "v1")
        XCTAssertNil(saves.records()[EpicSaves.key(app: app, install: install)]?.restoring)
        unflag("fake-fail-download")
        XCTAssertEqual(sync(.download), .synced, "the next try still sees the cloud as changed")
        XCTAssertEqual(read(folder.appending(path: "slot.sav")), "v2")
    }

    func testAFailedBackupStopsTheDownload() throws {
        try syncedOnce()
        try cloudSave("v2", at: hourAgo)
        let locked = folder.appending(path: "locked")
        try write("x", to: locked.appending(path: "f"), at: dayAgo)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        guard case let .failed(why) = sync(.download) else { return XCTFail() }
        XCTAssertTrue(why.contains("backed up"))
        XCTAssertEqual(read(folder.appending(path: "slot.sav")), "v1", "nothing was deleted")
    }

    /// The Mac's saves are newer than the cloud's by age, but the cloud also changed since the
    /// last sync: asked in both directions, never decided by age.
    func testBothChangedIsAskedEvenWhenTheMacIsNewer() throws {
        try syncedOnce()
        try cloudSave("from the PC", at: hourAgo)
        try write("played here", to: folder.appending(path: "slot.sav"), at: Date())
        XCTAssertEqual(sync(.download), .conflict(firstSync: false))
        XCTAssertEqual(sync(.upload), .conflict(firstSync: false))
        XCTAssertEqual(read(folder.appending(path: "slot.sav")), "played here")
        XCTAssertEqual(cloudSaveCount, 2, "nothing went up")
    }

    func testAFirstSyncWithSavesOnBothSidesIsAsked() throws {
        try cloudSave("cloud", at: dayAgo)
        try write("mac", to: folder.appending(path: "slot.sav"), at: hourAgo)
        try installed(savePath: folder.path)
        XCTAssertEqual(sync(.download), .conflict(firstSync: true))
        XCTAssertEqual(sync(.upload), .conflict(firstSync: true))
        XCTAssertEqual(read(folder.appending(path: "slot.sav")), "mac")
    }

    /// Only the Mac changed: Play leaves it, and the upload after the game takes it.
    func testOnlyTheMacChangedGoesUpAfterTheGame() throws {
        try syncedOnce()
        try write("played here", to: folder.appending(path: "slot.sav"), at: Date())
        XCTAssertEqual(sync(.download), .left)
        XCTAssertEqual(sync(.upload), .synced)
        XCTAssertEqual(cloudSaveCount, 2)
        XCTAssertEqual(sync(.download), .synced, "in step afterwards")
    }

    /// legendary reports a finished upload whether or not the files arrived; a new cloud save in
    /// step with the Mac is what counts.
    func testAnUploadThatNeverArrivedFails() throws {
        try syncedOnce()
        let before = saves.records()[EpicSaves.key(app: app, install: install)]
        try write("played here", to: folder.appending(path: "slot.sav"), at: Date())
        try flag("fake-fail-upload")
        guard case let .failed(why) = sync(.upload) else { return XCTFail() }
        XCTAssertTrue(why.contains("confirm"))
        XCTAssertEqual(saves.records()[EpicSaves.key(app: app, install: install)], before, "not noted as synced")
    }

    /// A save folder that holds more than the game's saves is never synced: legendary would
    /// empty it.
    func testABroadSaveFolderIsRefused() throws {
        let documents = prefix.appending(path: "drive_c/users/player/Documents")
        try write("someone else's file", to: documents.appending(path: "letter.txt"), at: dayAgo)
        try installed(savePath: documents.path)
        try cloudSave("v1", at: hourAgo)
        guard case let .failed(why) = sync(.download) else { return XCTFail() }
        XCTAssertTrue(why.contains("holds more than"))
        XCTAssertEqual(read(documents.appending(path: "letter.txt")), "someone else's file")
    }

    /// A save folder legendary stored for another environment (the game moved) is worked out
    /// again inside this one.
    func testASaveFolderFromAnotherEnvironmentIsResolvedAgain() throws {
        let elsewhere = root.appending(path: "OtherEnv/drive_c/users/player/AppData/Local/Game/Saved")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try installed(savePath: elsewhere.path)
        try cloudSave("v1", at: dayAgo)
        XCTAssertEqual(sync(.download), .synced)
        XCTAssertEqual(saves.savePath(app)?.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertEqual(read(folder.appending(path: "slot.sav")), "v1")
    }

    /// An uninstall has legendary work out a save folder it hasn't stored yet, or stored for
    /// another environment, comparing without moving anything; told not to, it doesn't.
    func testAnUninstallResolvesTheSaveFolder() throws {
        try write("save", to: folder.appending(path: "slot.sav"), at: hourAgo)
        try cloudSave("v1", at: dayAgo)
        XCTAssertNil(saves.uninstallSaveFolder(app, install: install, prefix: prefix, resolve: false, home: userHome))
        XCTAssertNil(saves.savePath(app))
        try installed(savePath: root.appending(path: "OtherEnv/drive_c/users/player/AppData/Local/Game/Saved").path)
        let found = saves.uninstallSaveFolder(app, install: install, prefix: prefix, resolve: true, home: userHome)
        XCTAssertEqual(found?.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertEqual(read(folder.appending(path: "slot.sav")), "save")
        XCTAssertEqual(cloudSaveCount, 1)
    }

    /// A download Highball was in the middle of when it quit: its backup goes back first.
    func testAnInterruptedDownloadIsUndoneNextTime() throws {
        try syncedOnce()
        let backup = try XCTUnwrap(try saves.backups.backUpLocal(folder, into: saves.backups.folder("epic-\(app)", install: install)))
        saves.update(EpicSaves.key(app: app, install: install)) { $0?.restoring = backup.path }
        try write("half written", to: folder.appending(path: "slot.sav"), at: Date())
        try write("stray", to: folder.appending(path: "partial.sav"), at: Date())
        _ = sync(.download)
        XCTAssertEqual(read(folder.appending(path: "slot.sav")), "v1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "partial.sav").path))
        XCTAssertNil(saves.records()[EpicSaves.key(app: app, install: install)]?.restoring)
    }

    /// A leftover download marker restores its old backup, but what the folder holds now (saves
    /// written while sync was off or signed out) is copied first, kept. With nothing changed since
    /// the download's backup, that backup becomes the kept copy and still goes back.
    func testAnInterruptedDownloadKeepsWhatTheFolderHeldFirst() throws {
        try syncedOnce()
        let key = EpicSaves.key(app: app, install: install), dir = saves.backups.folder("epic-\(app)", install: install)
        let backup = try XCTUnwrap(try saves.backups.backUpLocal(folder, into: dir))
        try SaveBackups.pin(backup)
        saves.update(key) { $0?.restoring = backup.path }
        try write("played while sync was off", to: folder.appending(path: "slot.sav"), at: Date())
        _ = sync(.download)
        XCTAssertEqual(read(folder.appending(path: "slot.sav")), "v1")
        let kept = saves.backups.backups(in: dir).filter(SaveBackups.isKept)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(read(kept[0].appending(path: "slot.sav")), "played while sync was off")
        XCTAssertFalse(SaveBackups.isPinned(backup))

        // Nothing changed since the marker's backup: reused as the kept copy, and put back.
        let again = try XCTUnwrap(try saves.backups.backUpLocal(folder, into: dir))
        try SaveBackups.pin(again)
        saves.update(key) { $0?.restoring = again.path }
        _ = sync(.download)
        XCTAssertEqual(read(folder.appending(path: "slot.sav")), "v1")
        XCTAssertNil(saves.records()[key]?.restoring)
        XCTAssertTrue(saves.backups.backups(in: dir).filter(SaveBackups.isKept).allSatisfy { !SaveBackups.isPinned($0) })
    }

    /// Epic's backups are named like GOG's (<date>-mac), so they rotate per kind; the one made
    /// for the player's pick in a conflict is kept, never pruned.
    func testThePlayersPickKeepsItsBackup() throws {
        try syncedOnce()
        try cloudSave("from the PC", at: hourAgo)
        try write("played here", to: folder.appending(path: "slot.sav"), at: Date())
        XCTAssertEqual(sync(.download), .conflict(firstSync: false))
        XCTAssertEqual(saves.sync(app, install: install, prefix: prefix, direction: .forceDownload, keepBackups: true, home: userHome), .synced)
        XCTAssertEqual(read(folder.appending(path: "slot.sav")), "from the PC")
        let backup = try XCTUnwrap(saves.backups.backups(in: saves.backups.folder("epic-\(app)", install: install)).first)
        XCTAssertEqual(SaveBackups.kind(of: backup), .mac)
        XCTAssertTrue(SaveBackups.isKept(backup))
        XCTAssertEqual(read(backup.appending(path: "slot.sav")), "played here")
        XCTAssertFalse(SaveBackups.isPinned(backup), "unpinned once the download is done")
    }

    /// Two syncs of one game never run at once: the second waits.
    func testSyncsOfOneGameDoNotOverlap() throws {
        try syncedOnce()
        try flag("fake-slow")
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global().async { _ = self.sync(.upload); group.leave() }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
        XCTAssertNil(read(home.appending(path: "fake-overlap")), "two legendary runs overlapped")
    }

    private func manifest(_ app: String, _ names: [String]) throws {
        try JSONSerialization.data(withJSONObject: names).write(to: home.appending(path: "fake-manifest-\(app).json"))
    }
    private func relative(_ backup: URL) -> [String] { SaveBackups.files(in: backup).map { SaveBackups.relativePath($0, in: backup) } }

    /// An install from before the history was kept: legendary's installed manifests (the game's
    /// and its DLC's, sharing the folder) tell its files apart, names in any case, and what no
    /// manifest names is the game's. With no manifest, or one whose names aren't on disk (an
    /// encrypted one lists obfuscated names), and no history, nothing tells them apart.
    func testKeepCopiesWhatNoManifestNames() throws {
        let game: [String: Any] = ["app_name": app, "title": "Game", "install_path": install.path]
        let dlc: [String: Any] = ["app_name": "GameDLC", "title": "DLC", "install_path": install.path]
        try JSONSerialization.data(withJSONObject: [app: game, "GameDLC": dlc]).write(to: config.appending(path: "installed.json"))
        let old = dayAgo.addingTimeInterval(-86_400)
        for name in ["Game.exe", "Data/base.pak", "DLC/extra.pak", "Config/Default.ini"] {
            try write("installed", to: install.appending(path: name), at: old)
        }
        try write("profile", to: install.appending(path: "Profiles/p1.ini"), at: old)
        try write("log", to: install.appending(path: "Logs/game.log"), at: hourAgo)
        XCTAssertNil(saves.gameFiles(app, install: install, prefix: prefix), "no manifest, no history")
        try manifest(app, ["Game.exe", "data/Base.pak", "Config/Default.ini"])
        XCTAssertNil(saves.gameFiles(app, install: install, prefix: prefix), "the DLC sharing the folder has no list")
        try manifest("GameDLC", ["DLC/extra.pak"])
        let files = try XCTUnwrap(saves.gameFiles(app, install: install, prefix: prefix))
        XCTAssertNil(files.history.firstSetup)
        let kept = try saves.backUpForUninstall(app, install: install, prefix: prefix, saveFolder: nil, gameFiles: files)
        XCTAssertEqual(kept.map(\.name), [EpicSaves.gameFolderName])
        XCTAssertEqual(relative(kept[0].backup), ["Logs/game.log", "Profiles/p1.ini"], "not what a manifest names")

        try manifest(app, ["0a1b2c", "3d4e5f"])
        XCTAssertNil(saves.gameFiles(app, install: install, prefix: prefix), "obfuscated names")
        // With a history too, a file the game rewrote after Highball installed it also counts.
        try manifest(app, ["Game.exe", "data/Base.pak", "Config/Default.ini"])
        EpicSaves.recordInstall(app: app, driveC: prefix.appending(path: "drive_c"), start: old.addingTimeInterval(-60), end: old.addingTimeInterval(1), finished: true)
        try write("rewritten", to: install.appending(path: "Config/Default.ini"), at: hourAgo)
        let both = try saves.backUpForUninstall(app, install: install, prefix: prefix, saveFolder: nil)
        XCTAssertEqual(relative(both[0].backup), ["Config/Default.ini", "Logs/game.log", "Profiles/p1.ini"])
    }

    /// legendary's uninstall deletes the files its manifest names and leaves the folder when the
    /// game wrote others there, but its record of the game is gone: what an uninstall waits for.
    /// Delete save data too then deletes a save folder left inside it.
    func testAnUninstallIsDoneWhenLegendarysRecordIsGone() throws {
        let store = EpicStore(paths: HighballPaths(home: home))
        try manifest(app, ["Game.exe", "Data/base.pak"])
        try write("exe", to: install.appending(path: "Game.exe"), at: dayAgo)
        try write("pak", to: install.appending(path: "Data/base.pak"), at: dayAgo)
        try write("save", to: install.appending(path: "Saved/slot1.sav"), at: hourAgo)
        XCTAssertEqual(store.isRecorded(app), true)
        XCTAssertEqual(try store.installedFiles(app), ["Game.exe", "Data/base.pak"])
        XCTAssertEqual(try store.uninstall(app), 0)
        XCTAssertEqual(store.isRecorded(app), false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: install.path), "the save keeps the folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: install.appending(path: "Data").path))
        XCTAssertThrowsError(try store.installedFiles(app), "no manifest once uninstalled")
        XCTAssertTrue(saves.removeSaves(app, folder: install.appending(path: "Saved"), install: install, prefix: prefix))
        XCTAssertFalse(FileManager.default.fileExists(atPath: install.appending(path: "Saved").path))
        XCTAssertFalse(saves.removeSaves(app, folder: install, install: install, prefix: prefix), "never the install folder itself")
        try "not json".write(to: config.appending(path: "installed.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(store.isRecorded(app), "unreadable records say nothing")
        try FileManager.default.removeItem(at: config.appending(path: "installed.json"))
        XCTAssertEqual(store.isRecorded(app), false, "nothing installed")
    }

    /// legendary 0.21.0's sync-saves, reduced to what EpicSaves relies on.
    static let script = #"""
    #!/usr/bin/python3 -I
    import json, os, sys, shutil, time
    from datetime import datetime, timezone

    args = sys.argv[1:]
    debug = args and args[0] == '-v'
    if debug: args = args[1:]
    if args[0] in ('list-files', 'uninstall'):
        config = os.environ['LEGENDARY_CONFIG_PATH']
        installed_file = os.path.join(config, 'installed.json')
        installed = json.load(open(installed_file))
        app = args[1]
        manifest = os.path.join(os.path.dirname(config), f'fake-manifest-{app}.json')
        names = json.load(open(manifest)) if os.path.exists(manifest) else None
        if args[0] == 'list-files':
            # cli.py list_files: the installed manifest, read locally; with none on disk,
            # load_manifest(None) raises and legendary exits non-zero.
            if app not in installed or names is None: sys.exit(1)
            print(json.dumps([dict(filename=n, sha_hash='00', install_tags=[], file_size=0, flags=0) for n in names]))
            sys.exit(0)
        # core.py uninstall_game, utils.py delete_filelist: the manifest's files, the folders they
        # leave empty, the root only if nothing else is in it (os.rmdir), then the record.
        if app not in installed: sys.exit(0)
        root = installed[app]['install_path']
        dirs = set()
        for n in names or []:
            d = os.path.dirname(n)
            while d: dirs.add(d); d = os.path.dirname(d)
            try: os.remove(os.path.join(root, n))
            except OSError: pass
        for d in sorted(dirs, key=len, reverse=True) + ['']:
            try: os.rmdir(os.path.join(root, d))
            except OSError: pass
        del installed[app]
        json.dump(installed, open(installed_file, 'w'))
        sys.exit(0)
    assert args[0] == 'sync-saves', args
    app = args[1]
    flags = set(args[2:])
    config = os.environ['LEGENDARY_CONFIG_PATH']
    home = os.path.dirname(config)
    cloud = os.path.join(home, 'fake-cloud')
    def log(name, level, msg):
        if level == 'DEBUG' and not debug: return
        print(f'[{name}] {level}: {msg}', flush=True)
    def flag(n): return os.path.exists(os.path.join(home, n))

    running = os.path.join(home, 'fake-running')
    if os.path.exists(running): open(os.path.join(home, 'fake-overlap'), 'w').write('yes')
    open(running, 'w').write('1')
    try:
        if flag('fake-slow'): time.sleep(0.5)
        installed_file = os.path.join(config, 'installed.json')
        installed = json.load(open(installed_file))
        igame = installed[app]
        try: index = json.load(open(os.path.join(cloud, 'index.json')))
        except Exception: index = []
        latest = sorted(index, key=lambda s: s['uploaded'])[-1] if index else None
        log('cli', 'INFO', f'Got {1 if latest else 0} remote save game(s)')
        log('cli', 'INFO', f'Checking "Game" ({app})')
        if not igame.get('save_path'):
            rel = open(os.path.join(home, 'fake-save-path')).read().strip()
            path = os.path.join(os.environ['WINEPREFIX'], rel)
            log('cli', 'INFO', f'Computed save path: "{path}"')
            os.makedirs(path, exist_ok=True)
            igame['save_path'] = path
            json.dump(installed, open(installed_file, 'w'))
        save_path = igame['save_path']

        newest = 0
        for d, _, fs in os.walk(save_path):
            for f in fs: newest = max(newest, os.stat(os.path.join(d, f)).st_mtime)
        dt_l = datetime.fromtimestamp(newest, timezone.utc) if newest else None
        dt_r = datetime.strptime(latest['name'], '%Y.%m.%d-%H.%M.%S.manifest').replace(tzinfo=timezone.utc) if latest else None
        if not newest and not latest:
            log('cli', 'INFO', 'No cloud or local savegame found.'); sys.exit(0)
        if dt_l and dt_r: log('Core', 'DEBUG', f'Local save date: {dt_l}, Remote save date: {dt_r}')
        if dt_l and dt_r and abs((dt_l - dt_r).total_seconds()) < 60: state = 'same'
        elif not dt_r or (dt_l and dt_l > dt_r): state = 'local'
        else: state = 'remote'
        force_up, force_down = '--force-upload' in flags, '--force-download' in flags
        if state == 'same' and not (force_up or force_down):
            log('cli', 'INFO', 'Save game for "Game" is up to date, skipping...'); sys.exit(0)
        def fmt(d): return d.strftime('%Y-%m-%d %H:%M:%S') if d else 'N/A'
        if (state == 'remote' and not force_up) or force_down:
            if state == 'remote':
                log('cli', 'INFO', 'Cloud save for "Game" is newer:')
                log('cli', 'INFO', f'- Cloud save date: {fmt(dt_r)}')
                log('cli', 'INFO', f'- Local save date: {fmt(dt_l)}')
            if '--skip-download' in flags:
                log('cli', 'INFO', 'Save game downloading is disabled, skipping...'); sys.exit(0)
            log('cli', 'INFO', 'Downloading remote savegame...')
            log('Core', 'INFO', 'Deleting old save files...')
            for d, _, fs in os.walk(save_path):
                for f in fs: os.remove(os.path.join(d, f))
            if flag('fake-fail-download'):
                log('Core', 'ERROR', 'Download failed, status code: 500')
            else:
                src = os.path.join(cloud, latest['name'])
                for d, _, fs in os.walk(src):
                    for f in fs:
                        rel = os.path.relpath(os.path.join(d, f), src)
                        dst = os.path.join(save_path, rel)
                        os.makedirs(os.path.dirname(dst), exist_ok=True)
                        shutil.copyfile(os.path.join(d, f), dst)
                        os.utime(dst, (dt_r.timestamp(), dt_r.timestamp()))
            log('Core', 'INFO', 'Successfully completed savegame download.')
        else:
            if state == 'local':
                log('cli', 'INFO', 'Local save for "Game" is newer')
                log('cli', 'INFO', f'- Cloud save date: {fmt(dt_r)}')
                log('cli', 'INFO', f'- Local save date: {fmt(dt_l)}')
            if '--skip-upload' in flags:
                log('cli', 'INFO', 'Save game uploading is disabled, skipping...'); sys.exit(0)
            log('cli', 'INFO', 'Uploading local savegame...')
            log('Core', 'INFO', 'Starting upload...')
            if not flag('fake-fail-upload'):
                name = dt_l.strftime('%Y.%m.%d-%H.%M.%S.manifest')
                dst = os.path.join(cloud, name)
                shutil.copytree(save_path, dst, dirs_exist_ok=True)
                index.append({'name': name, 'uploaded': time.time() + len(index)})
                json.dump(index, open(os.path.join(cloud, 'index.json'), 'w'))
            log('Core', 'INFO', 'Finished uploading savegame.')
    finally:
        os.remove(running)
    """#
}
