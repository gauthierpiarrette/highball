import XCTest
@testable import HighballKit

/// What an Epic uninstall does with the game's saves (EpicSaves, uninstalling): which files are
/// kept, what Delete save data too may delete, and putting kept saves back into a new install.
final class EpicUninstallSavesTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appending(path: "home") }
    private var config: URL { home.appending(path: "legendary") }
    private var prefix: URL { root.appending(path: "Env") }
    private var driveC: URL { prefix.appending(path: "drive_c") }
    private var install: URL { driveC.appending(path: "Games/Game") }
    private var user: URL { driveC.appending(path: "users/player") }
    private var folder: URL { user.appending(path: "AppData/Local/Game/Saved") }
    private var userHome: URL { root.appending(path: "user") }
    private let app = "Game"
    private var saves: EpicSaves { EpicSaves(store: EpicStore(paths: HighballPaths(home: home))) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "epic-uninstall-\(UUID().uuidString)")
        for dir in [config.appending(path: "metadata"), install, userHome, user] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try catalog(include: nil)
    }
    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func catalog(include: String?) throws {
        var attributes: [String: Any] = ["CloudSaveFolder": ["type": "STRING", "value": "{AppData}/Game/Saved"]]
        if let include { attributes["CloudIncludeList"] = ["type": "STRING", "value": include] }
        let obj: [String: Any] = ["app_name": app, "metadata": ["customAttributes": attributes]]
        try JSONSerialization.data(withJSONObject: obj).write(to: config.appending(path: "metadata/\(app).json"))
    }
    private func installed(savePath: URL?) throws {
        let game: [String: Any] = ["app_name": app, "install_path": install.path, "save_path": savePath?.path ?? NSNull()]
        try JSONSerialization.data(withJSONObject: [app: game]).write(to: config.appending(path: "installed.json"))
    }
    private func write(_ text: String, to url: URL, dated date: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }
    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func relative(_ backup: URL) -> [String] { SaveBackups.files(in: backup).map { SaveBackups.relativePath($0, in: backup) } }

    /// The first install that finishes starts the history; one that failed before it doesn't, and
    /// every run after it (an update, a repair, a failed one) is legendary's window.
    /// The Cloud saves setting says when this install's saves were last in step; a download's
    /// marker alone is no sync.
    func testLastSyncedReadsThisInstallsRecord() throws {
        let install = root.appending(path: "Game"), other = root.appending(path: "Other")
        XCTAssertNil(saves.lastSynced("Garlic", install: install))
        let when = Date(timeIntervalSince1970: 1793000000)
        let records: [String: EpicSaves.Record] = [EpicSaves.key(app: "Garlic", install: install): .init(synced: when),
                                                   EpicSaves.key(app: "Garlic", install: other): .init(synced: .distantPast)]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: saves.recordsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(records).write(to: saves.recordsFile)
        XCTAssertEqual(saves.lastSynced("Garlic", install: install), when)
        XCTAssertNil(saves.lastSynced("Garlic", install: other), "a marker, not a sync")
    }

    func testTheHistoryStartsAtTheFirstFinishedInstall() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        EpicSaves.recordInstall(app: app, driveC: driveC, start: t, end: t.addingTimeInterval(60), finished: false)
        XCTAssertNil(EpicSaves.history(app: app, driveC: driveC).firstSetup)
        EpicSaves.recordInstall(app: app, driveC: driveC, start: t.addingTimeInterval(100), end: t.addingTimeInterval(200), finished: true)
        EpicSaves.recordInstall(app: app, driveC: driveC, start: t.addingTimeInterval(1000), end: t.addingTimeInterval(1100), finished: false)
        let history = EpicSaves.history(app: app, driveC: driveC)
        XCTAssertEqual(history.firstSetup, t.addingTimeInterval(200))
        XCTAssertEqual(history.updates, [.init(start: t.addingTimeInterval(1000), end: t.addingTimeInterval(1100))])
        let other = root.appending(path: "Other/drive_c")
        EpicSaves.moveHistory(app: app, from: driveC, to: other)
        XCTAssertEqual(EpicSaves.history(app: app, driveC: other), history, "moves with the game")
        XCTAssertNil(EpicSaves.history(app: app, driveC: driveC).firstSetup)
    }

    /// Keep copies the save folder (the files the include list picks) and what the game wrote in
    /// its folder outside legendary's runs, leaving out a save folder inside it. Never installed
    /// through Highball: no install-folder copy.
    func testKeepCopiesTheSaveFolderAndWhatTheGameWrote() throws {
        try catalog(include: "*.sav")
        let now = Date()
        try write("exe", to: install.appending(path: "Game.exe"), dated: now.addingTimeInterval(-7200))
        try write("profile", to: install.appending(path: "Profiles/p1.ini"), dated: now.addingTimeInterval(-600))
        try write("save", to: folder.appending(path: "slot1.sav"))
        try write("cache", to: folder.appending(path: "shader.cache"))
        var kept = try saves.backUpForUninstall(app, install: install, prefix: prefix, saveFolder: folder)
        XCTAssertEqual(kept.map(\.name), [EpicSaves.savesName], "no history: the save folder only")
        XCTAssertEqual(relative(kept[0].backup), ["slot1.sav"])
        XCTAssertTrue(SaveBackups.isKept(kept[0].backup))
        XCTAssertEqual(kept[0].place, .environment)
        XCTAssertEqual(kept[0].path, "drive_c/users/player/AppData/Local/Game/Saved")

        let installed = now.addingTimeInterval(-3600)
        EpicSaves.recordInstall(app: app, driveC: driveC, start: installed.addingTimeInterval(-60), end: installed, finished: true)
        EpicSaves.recordInstall(app: app, driveC: driveC, start: now.addingTimeInterval(-1900), end: now.addingTimeInterval(-1700), finished: true)
        try write("patch", to: install.appending(path: "Data/patch.pak"), dated: now.addingTimeInterval(-1800))
        try write("inside", to: install.appending(path: "Saved/slot2.sav"), dated: now.addingTimeInterval(-60))
        kept = try saves.backUpForUninstall(app, install: install, prefix: prefix, saveFolder: install.appending(path: "Saved"))
        XCTAssertEqual(kept.map(\.name), [EpicSaves.savesName, EpicSaves.gameFolderName])
        XCTAssertEqual(kept[0].place, .game)
        XCTAssertEqual(kept[0].path, "Saved")
        XCTAssertEqual(relative(kept[1].backup), ["Profiles/p1.ini"], "not the installer's, the patch's or the save folder's")
        XCTAssertTrue(SaveBackups.isKept(kept[1].backup))
    }

    /// A save folder that can't be read stops the removal.
    /// legendary leaves the game's folder when it holds files it didn't install, and a reinstall
    /// there fails: once the record is gone the folder goes, but never a shared one.
    func testTheLeftoverFolderGoesButNeverASharedOne() throws {
        let prefix = FileManager.default.temporaryDirectory.appending(path: "leftover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: prefix) }
        let driveC = prefix.appending(path: "drive_c")
        let games = driveC.appending(path: "Program Files/Epic Games")
        let game = games.appending(path: "Game"), other = games.appending(path: "Other")
        for folder in [game, other, driveC.appending(path: "users/someone/Game")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appending(path: "save.dat"))
        }
        let saves = EpicSaves(store: EpicStore(paths: HighballPaths(home: prefix.appending(path: "home"))))
        XCTAssertFalse(saves.removeLeftover(games, prefix: prefix, stillInstalled: [other]), "holds a game still installed")
        XCTAssertFalse(saves.removeLeftover(driveC.appending(path: "Program Files"), prefix: prefix, stillInstalled: []), "a folder every game shares")
        XCTAssertFalse(saves.removeLeftover(driveC.appending(path: "users/someone/Game"), prefix: prefix, stillInstalled: []), "a user folder")
        XCTAssertTrue(saves.removeLeftover(game, prefix: prefix, stillInstalled: [other]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appending(path: "save.dat").path))
    }

    func testAFailedCopyThrows() throws {
        try write("save", to: folder.appending(path: "Sub/slot1.sav"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.appending(path: "Sub").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appending(path: "Sub").path) }
        XCTAssertThrowsError(try saves.backUpForUninstall(app, install: install, prefix: prefix, saveFolder: folder))
    }

    /// The folder an uninstall deals with is the one legendary stored, inside the environment, and
    /// not one sync refuses for holding more than this game's saves.
    func testTheUninstallSaveFolderIsOneSyncWouldUse() throws {
        XCTAssertNil(saves.uninstallSaveFolder(app, install: install, prefix: prefix, resolve: false, home: userHome))
        try installed(savePath: folder)
        XCTAssertEqual(saves.uninstallSaveFolder(app, install: install, prefix: prefix, resolve: false, home: userHome)?.path, folder.path)
        try installed(savePath: user.appending(path: "Documents"))
        XCTAssertNil(saves.uninstallSaveFolder(app, install: install, prefix: prefix, resolve: false, home: userHome), "holds more than the game's saves")
        try installed(savePath: root.appending(path: "Elsewhere/drive_c/users/player/AppData/Local/Game/Saved"))
        XCTAssertNil(saves.uninstallSaveFolder(app, install: install, prefix: prefix, resolve: false, home: userHome), "another environment's")
    }

    /// Delete save data too removes a save folder inside the environment's drive_c, only the files
    /// the include list picks when there is one, and never one that is the Mac's through a link,
    /// Highball's save-backups or the install folder.
    func testDeletingSavesStaysInsideTheEnvironment() throws {
        try write("save", to: folder.appending(path: "slot1.sav"))
        XCTAssertTrue(saves.removeSaves(app, folder: folder, install: install, prefix: prefix))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))

        try catalog(include: "*.sav")
        try write("save", to: folder.appending(path: "slot1.sav"))
        try write("other", to: folder.appending(path: "settings.ini"))
        XCTAssertTrue(saves.removeSaves(app, folder: folder, install: install, prefix: prefix))
        XCTAssertEqual(SaveBackups.files(in: folder).map(\.lastPathComponent), ["settings.ini"])

        let mac = userHome.appending(path: "Documents")
        try write("mac", to: mac.appending(path: "My Games/Game/slot.sav"))
        try FileManager.default.createSymbolicLink(at: user.appending(path: "Documents"), withDestinationURL: mac)
        let linked = user.appending(path: "Documents/My Games/Game")
        XCTAssertFalse(saves.removeSaves(app, folder: linked, install: install, prefix: prefix))
        XCTAssertNotNil(read(mac.appending(path: "My Games/Game/slot.sav")))

        try write("kept", to: saves.backups.root.appending(path: "epic-Game-1/2026-mac-kept/slot.sav"))
        try FileManager.default.createSymbolicLink(at: user.appending(path: "Backups"), withDestinationURL: saves.backups.root)
        XCTAssertFalse(saves.removeSaves(app, folder: user.appending(path: "Backups"), install: install, prefix: prefix))
        XCTAssertFalse(saves.removeSaves(app, folder: driveC.appending(path: "Games"), install: install, prefix: prefix), "holds the game")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saves.backups.root.appending(path: "epic-Game-1/2026-mac-kept/slot.sav").path))
    }

    /// Kept saves go back where they were in a new install, in another environment too: the save
    /// folder by its place in the environment, the game-folder copy by its paths, dated now. What
    /// is there already is copied first, the install is asked once, and only the latest
    /// uninstall's backups are offered.
    func testPuttingSavesBackPlacesThemInTheNewInstall() throws {
        let now = Date()
        EpicSaves.recordInstall(app: app, driveC: driveC, start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600), finished: true)
        try write("cloud slot", to: folder.appending(path: "slot1.sav"))
        try write("profile", to: install.appending(path: "Profiles/p1.ini"), dated: now.addingTimeInterval(-60))
        let kept = try saves.backUpForUninstall(app, install: install, prefix: prefix, saveFolder: folder)
        XCTAssertEqual(kept.count, 2)
        saves.keep(kept, of: app)

        let newPrefix = root.appending(path: "Env2")
        let newInstall = newPrefix.appending(path: "drive_c/Games/Game")
        let newFolder = newPrefix.appending(path: "drive_c/users/player/AppData/Local/Game/Saved")
        try write("fresh", to: newFolder.appending(path: "slot1.sav"))
        let offer = try XCTUnwrap(KeptSavesFile.toOffer(saves.keptSaves()[app], install: newInstall))
        XCTAssertEqual(try saves.putBack(offer, app: app, install: newInstall, prefix: newPrefix), 2)
        XCTAssertEqual(read(newFolder.appending(path: "slot1.sav")), "cloud slot")
        XCTAssertEqual(read(newInstall.appending(path: "Profiles/p1.ini")), "profile")
        let dated = try XCTUnwrap(try newInstall.appending(path: "Profiles/p1.ini").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        XCTAssertGreaterThan(dated, now.addingTimeInterval(-5), "counts as the game's at the next uninstall")
        let before = try XCTUnwrap(saves.backups.backups(in: saves.backupFolder(app, EpicSaves.savesName, install: newInstall)).first)
        XCTAssertEqual(read(before.appending(path: "slot1.sav")), "fresh", "what was there is copied first")
        XCTAssertTrue(SaveBackups.isKept(before))
        saves.markAsked(app, install: newInstall)
        XCTAssertNil(KeptSavesFile.toOffer(saves.keptSaves()[app], install: newInstall), "asked once")
        XCTAssertNotNil(KeptSavesFile.toOffer(saves.keptSaves()[app], install: install))

        saves.keep([kept[1]], of: app)
        XCTAssertEqual(KeptSavesFile.toOffer(saves.keptSaves()[app], install: newInstall)?.entries.map(\.name), [EpicSaves.gameFolderName], "the latest uninstall only")
        saves.keep([], of: app)
        XCTAssertNil(KeptSavesFile.toOffer(saves.keptSaves()[app], install: newInstall))
    }

    /// GOG's kept-saves.json from before entries had a place still reads, each under the game's
    /// folder.
    func testAnEntryWithNoPlaceIsUnderTheGamesFolder() throws {
        let json = #"{"date":0,"entries":[{"name":"saves","path":"SAVES","backup":"file:///tmp/b"}],"asked":[]}"#
        let kept = try JSONDecoder().decode(KeptSaves.self, from: Data(json.utf8))
        XCTAssertEqual(kept.entries[0].folder(install: install, environment: prefix), install.appending(path: "SAVES"))
    }

    /// The removal message says what each answer does to the saves.
    func testTheEpicMessageSaysWhatEachAnswerDoesToTheSaves() {
        let text = Uninstall.confirmation(route: .epic(appName: app), sizeOnDisk: 0)
        XCTAssertTrue(text.contains("Keep save data first copies"), text)
        XCTAssertTrue(text.contains("Delete save data too copies nothing"), text)
        XCTAssertTrue(text.contains("Epic's cloud stay there either way"), text)
    }
}
