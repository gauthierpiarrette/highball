import XCTest
@testable import HighballKit

/// No sync replaces or deletes a save without backing it up first (GOGSaves backups).
final class GOGSaveSafetyTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appending(path: "saves-\(UUID().uuidString)") }
    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: "Game/saves/locked").path)
        try? FileManager.default.removeItem(at: root)
    }

    private func fixture(install: String = "Game") throws -> (GOGSaves, GOGStore.InstalledGame, GOGSaves.Location, URL) {
        let saves = GOGSaves(store: GOGStore(paths: HighballPaths(home: root.appending(path: "home"))))
        let folder = root.appending(path: "\(install)/saves")
        try FileManager.default.createDirectory(at: folder.appending(path: "slot1"), withIntermediateDirectories: true)
        try Data("progress".utf8).write(to: folder.appending(path: "slot1/save.dat"))
        let game = GOGStore.InstalledGame(id: "1", title: "Game", folder: root.appending(path: install), buildID: nil, clientID: nil, dlcIDs: [], tasks: [])
        return (saves, game, GOGSaves.Location(name: "saves", template: "<?INSTALL?>/saves"), folder)
    }

    /// The backup happens before gogdl runs: gogdl isn't installed here, and the backup is still made.
    func testADownloadCopiesTheSavesBeforeAnythingRuns() throws {
        let (saves, game, location, folder) = try fixture()
        guard case .failed = saves.sync(game, location: location, folder: folder, direction: .download) else { return XCTFail("gogdl is absent here") }
        let copy = try XCTUnwrap(saves.backups(in: saves.backupsFolder(game, location)).first)
        XCTAssertEqual(try String(contentsOf: copy.appending(path: "slot1/save.dat"), encoding: .utf8), "progress")
    }

    func testAnUnchangedFolderIsNotCopiedTwice() throws {
        let (saves, game, location, folder) = try fixture()
        let first = try XCTUnwrap(try saves.backUpLocal(game, location: location, folder: folder))
        XCTAssertEqual(try saves.backUpLocal(game, location: location, folder: folder)?.lastPathComponent, first.lastPathComponent)
        try Data("more".utf8).write(to: folder.appending(path: "slot1/save.dat"))
        XCTAssertNotEqual(try saves.backUpLocal(game, location: location, folder: folder)?.lastPathComponent, first.lastPathComponent)
    }

    /// Pruning goes by creation date, not name, and never removes the backup just made, even when
    /// a clock that was once ahead left backups named after today.
    func testPruningKeepsTheNewestTenAndNeverTheCopyJustMade() throws {
        let (saves, game, location, folder) = try fixture()
        let dir = saves.backupsFolder(game, location)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<12 {
            let old = dir.appending(path: "9999-01-\(String(format: "%02d", i + 1))-mac")
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(86_400 * Double(i + 1))], ofItemAtPath: old.path)
        }
        let copy = try XCTUnwrap(try saves.backUpLocal(game, location: location, folder: folder))
        let kept = saves.backups(in: dir)
        XCTAssertEqual(kept.count, 10)
        XCTAssertTrue(kept.map(\.lastPathComponent).contains(copy.lastPathComponent))
    }

    func testAFailedCopyLeavesNothingBehindAndStopsTheSync() throws {
        let (saves, game, location, folder) = try fixture()
        let locked = folder.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appending(path: "f"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        guard case let .failed(why) = saves.sync(game, location: location, folder: folder, direction: .download) else { return XCTFail() }
        XCTAssertTrue(why.contains("backed up"))
        let dir = saves.backupsFolder(game, location)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [], [], "no half copy, no .partial")
    }

    /// gogdl lists and deletes hidden files too, so they are backed up like any save.
    func testHiddenFilesCount() throws {
        let folder = root.appending(path: "Hidden")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: ".save"))
        XCTAssertEqual(try GOGSaves.files(in: folder).map(\.lastPathComponent), [".save"])
    }

    /// gogdl walks into a linked folder and writes through a linked file, so the copy holds what
    /// they point at, not the links; a link to nothing holds nothing to keep.
    func testACopyHoldsWhatLinksPointAt() throws {
        let (saves, game, location, folder) = try fixture()
        let elsewhere = root.appending(path: "Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere.appending(path: "profile"), withIntermediateDirectories: true)
        try Data("linked file".utf8).write(to: elsewhere.appending(path: "one.dat"))
        try Data("in a linked folder".utf8).write(to: elsewhere.appending(path: "profile/two.dat"))
        let fm = FileManager.default
        try fm.createSymbolicLink(at: folder.appending(path: "one.dat"), withDestinationURL: elsewhere.appending(path: "one.dat"))
        try fm.createSymbolicLink(at: folder.appending(path: "profile"), withDestinationURL: elsewhere.appending(path: "profile"))
        try fm.createSymbolicLink(at: folder.appending(path: "gone.dat"), withDestinationURL: elsewhere.appending(path: "nothing"))
        try fm.createSymbolicLink(at: folder.appending(path: "slot1/loop"), withDestinationURL: folder)
        let copy = try XCTUnwrap(try saves.backUpLocal(game, location: location, folder: folder))
        XCTAssertEqual(try String(contentsOf: copy.appending(path: "one.dat"), encoding: .utf8), "linked file")
        XCTAssertEqual(try String(contentsOf: copy.appending(path: "profile/two.dat"), encoding: .utf8), "in a linked folder")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: copy.appending(path: "one.dat").path), "a file, not a link")
        XCTAssertFalse(fm.fileExists(atPath: copy.appending(path: "gone.dat").path))
        XCTAssertEqual(try String(contentsOf: copy.appending(path: "slot1/save.dat"), encoding: .utf8), "progress", "a loop is walked once")
    }

    func testTwoInstallsKeepTheirOwnBackups() throws {
        let (saves, a, location, _) = try fixture(install: "A")
        let (_, b, _, _) = try fixture(install: "B")
        XCTAssertNotEqual(saves.backupsFolder(a, location), saves.backupsFolder(b, location))
        XCTAssertEqual(saves.backupsFolder(a, location), saves.backupsFolder(a, location))
    }

    /// gogdl exits 0 when a file fails to download; its log line is what fails the sync.
    func testAFileGogdlFailedToFetchFailsTheCopy() {
        XCTAssertTrue(GOGSaves.isFailure("[SAVES] ERROR: Downloading file failed"))
        XCTAssertFalse(GOGSaves.isFailure("[SAVES] INFO: Files in cloud: 3"))
    }

    /// Every upload backs up GOG's cloud first: with gogdl absent here, that backup is what fails.
    func testAnUploadBacksUpTheCloudFirst() throws {
        let (saves, game, location, folder) = try fixture()
        guard case let .failed(why) = saves.sync(game, location: location, folder: folder, direction: .upload) else { return XCTFail() }
        XCTAssertTrue(why.contains("backed up"))
    }

    /// Backing up a years-old save folder dates the backup now, so pruning still keeps the newest.
    func testACopyOfAnOldFolderIsDatedNow() throws {
        let (saves, game, location, folder) = try fixture()
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: folder.path)
        let copy = try XCTUnwrap(try saves.backUpLocal(game, location: location, folder: folder))
        let made = try XCTUnwrap(try copy.resourceValues(forKeys: [.creationDateKey]).creationDate)
        XCTAssertLessThan(abs(made.timeIntervalSinceNow), 60)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.appending(path: ".highball-backup").path), "nothing of Highball's inside the copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: GOGSaves.fingerprintFile(of: copy).path))
    }

    func testARefusalMovesNothing() {
        XCTAssertTrue(GOGSaves.isRefusal("[SAVES] WARNING: Refused to download files, newer files locally"))
        XCTAssertFalse(GOGSaves.isRefusal("[SAVES] INFO: Done"))
    }

    private func oldBackup(_ name: String, in dir: URL, daysAgo: Double) throws -> URL {
        let url = dir.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-86_400 * daysAgo)], ofItemAtPath: url.path)
        return url
    }

    /// Mac and cloud backups are pruned separately, and kept ones never.
    func testPruningIsPerKindAndSparesKeptBackups() throws {
        let (saves, game, location, folder) = try fixture()
        let dir = saves.backupsFolder(game, location)
        for i in 0..<12 { _ = try oldBackup("2020-01-\(String(format: "%02d", i + 1))T000000Z-cloud", in: dir, daysAgo: Double(30 + i)) }
        for i in 0..<3 { _ = try oldBackup("2019-01-0\(i + 1)T000000Z-mac-kept", in: dir, daysAgo: Double(400 + i)) }
        for i in 0..<12 {
            try Data("progress \(i)".utf8).write(to: folder.appending(path: "slot1/save.dat"))
            try saves.backUpLocal(game, location: location, folder: folder)
        }
        let all = saves.backups(in: dir)
        XCTAssertEqual(all.filter { GOGSaves.kind(of: $0) == .mac && !GOGSaves.isKept($0) }.count, 10)
        XCTAssertEqual(all.filter { GOGSaves.kind(of: $0) == .cloud }.count, 12, "cloud backups untouched by Mac ones")
        XCTAssertEqual(all.filter(GOGSaves.isKept).count, 3)
    }

    /// A kept backup of unchanged saves turns the matching backup into a kept one.
    func testAKeptBackupOfUnchangedSavesKeepsTheLastOne() throws {
        let (saves, game, location, folder) = try fixture()
        let first = try XCTUnwrap(try saves.backUpLocal(game, location: location, folder: folder))
        let kept = try XCTUnwrap(try saves.backUpLocal(game, location: location, folder: folder, kept: true))
        XCTAssertTrue(GOGSaves.isKept(kept))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(saves.backups(in: saves.backupsFolder(game, location)).count, 1)
    }

    /// The fingerprint tells apart folders that only differ in names.
    func testTheFingerprintCountsNames() throws {
        let a = root.appending(path: "A"), b = root.appending(path: "B")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for (folder, name) in [(a, "one.sav"), (b, "two.sav")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appending(path: name))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folder.appending(path: name).path)
        }
        XCTAssertNotEqual(GOGSaves.fingerprint(a), GOGSaves.fingerprint(b))
    }

    /// A backup a crash left half-filled is cleared at the next backup once it is an hour old.
    func testStalePartialBackupsAreCleared() throws {
        let (saves, game, location, folder) = try fixture()
        let dir = saves.backupsFolder(game, location)
        let stale = try oldBackup("2020-01-01T000000Z-mac.partial", in: dir, daysAgo: 1)
        let fresh = try oldBackup("2020-01-02T000000Z-mac.partial", in: dir, daysAgo: 0)
        try saves.backUpLocal(game, location: location, folder: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "maybe still being filled")
    }

    /// gogdl reads GOG's dates with Python's fromisoformat, then astimezone().
    func testCloudDatesAreReadAsPythonReadsThem() throws {
        XCTAssertEqual(GOGSaves.date(iso: "2024-05-01T10:00:00+00:00")?.timeIntervalSince1970, 1_714_557_600)
        XCTAssertEqual(GOGSaves.date(iso: "2024-05-01T10:00:00Z")?.timeIntervalSince1970, 1_714_557_600)
        XCTAssertEqual(GOGSaves.date(iso: "2024-05-01T19:00:00+09:00")?.timeIntervalSince1970, 1_714_557_600)
        XCTAssertEqual(GOGSaves.date(iso: "2024-05-01T05:00:00-0500")?.timeIntervalSince1970, 1_714_557_600)
        XCTAssertEqual(GOGSaves.date(iso: "2024-05-01 10:00+00:00")?.timeIntervalSince1970, 1_714_557_600)
        XCTAssertEqual(GOGSaves.date(iso: "2024-05-01T10:00:00.5+00:00")?.timeIntervalSince1970 ?? 0, 1_714_557_600.5, accuracy: 0.0001)
        XCTAssertEqual(GOGSaves.date(iso: "2024-05-01T10:00:00.123456+00:00")?.timeIntervalSince1970 ?? 0, 1_714_557_600.123456, accuracy: 0.000001)
        var local = DateComponents(year: 2024, month: 5, day: 1, hour: 10)
        local.timeZone = .current
        XCTAssertEqual(GOGSaves.date(iso: "2024-05-01T10:00:00"), Calendar(identifier: .gregorian).date(from: local), "no offset: local time")
        XCTAssertNil(GOGSaves.date(iso: "yesterday"))
    }

    /// What an uninstall backs up, leaves alone, or needs the player's go-ahead for.
    func testUninstallPlan() throws {
        let game = GOGStore.InstalledGame(id: "1", title: "Game", folder: root.appending(path: "drive_c/Games/Game"), buildID: nil, clientID: nil, dlcIDs: [], tasks: [])
        let driveC = root.appending(path: "drive_c")
        func plan(_ templates: [String]) -> GOGSaves.UninstallPlan {
            GOGSaves.uninstallPlan(templates.enumerated().map { GOGSaves.Location(name: "l\($0.offset)", template: $0.element) },
                                   game: game, driveC: driveC, userName: "player")
        }
        let inside = plan(["<?INSTALL?>/saves"])
        XCTAssertEqual(inside.backUp.map(\.folder.lastPathComponent), ["saves"])
        XCTAssertTrue(inside.cannotBackUp.isEmpty)
        XCTAssertTrue(plan(["<?SAVED_GAMES?>/Studio/Game", "<?DOCUMENTS?>/%USERNAME%", "<?MAC_LIBRARY?>/x"]).backUp.isEmpty, "outside the game's folder: left alone")
        let partly = plan(["<?INSTALL?>/saves/%USERNAME%"])
        XCTAssertEqual(partly.backUp.map { $0.folder.path }, [game.folder.appending(path: "saves").path], "up to the part Highball can't resolve")
        XCTAssertEqual(plan(["<?INSTALL?>", "<?INSTALL?>/", "<?INSTALL?>/%SAVES%", "<?INSTALL?>/../Other"]).cannotBackUp.count, 4)
        XCTAssertEqual(plan(["<?INSTALL?>\\Save Data"]).backUp.map(\.folder.lastPathComponent), ["Save Data"])
    }

    private func write(_ text: String, to url: URL, dated date: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }

    /// What the game wrote in its folder is what changed after Highball first set it up there and
    /// not while an update ran: a save from before the last update still counts, the patch's
    /// files don't, nor what the installer put down or the locations backed up on their own.
    /// Never set up here: nothing to tell apart, so nothing is copied.
    func testTheGameFolderCopyHoldsWhatTheGameWrote() throws {
        let saves = GOGSaves(store: GOGStore(paths: HighballPaths(home: root.appending(path: "home"))))
        let driveC = root.appending(path: "drive_c")
        let game = GOGStore.InstalledGame(id: "7", title: "Game", folder: driveC.appending(path: "GOG Games/Game"), buildID: "b1", clientID: nil, dlcIDs: [], tasks: [])
        let now = Date()
        try write("exe", to: game.folder.appending(path: "game.exe"), dated: now.addingTimeInterval(-7200))
        XCTAssertNil(try saves.backUpGameFolder(game, driveC: driveC), "never set up through Highball")
        GOGStore.markSetupDone(for: game, driveC: driveC)
        let setUp = try XCTUnwrap(GOGStore.history(for: game, driveC: driveC).firstSetup)
        GOGStore.recordUpdate(for: game, driveC: driveC, start: setUp.addingTimeInterval(1200), end: setUp.addingTimeInterval(2400))
        GOGStore.markSetupDone(for: game, driveC: driveC)   // the update's setup keeps the first date
        XCTAssertEqual(GOGStore.history(for: game, driveC: driveC).firstSetup, setUp)
        try write("before the update", to: game.folder.appending(path: "SAVES/slot1.sav"), dated: setUp.addingTimeInterval(600))
        try write("patch", to: game.folder.appending(path: "data/patch.pak"), dated: setUp.addingTimeInterval(1800))
        try write("after it", to: game.folder.appending(path: "SAVES/slot2.sav"), dated: setUp.addingTimeInterval(3000))
        try write("cloud", to: game.folder.appending(path: "cloud/a.sav"), dated: setUp.addingTimeInterval(600))
        let copy = try XCTUnwrap(try saves.backUpGameFolder(game, driveC: driveC, skipping: [game.folder.appending(path: "cloud")]))
        XCTAssertEqual(try GOGSaves.files(in: copy).map { GOGSaves.relativePath(of: $0, in: copy) }, ["SAVES/slot1.sav", "SAVES/slot2.sav"])
        XCTAssertTrue(GOGSaves.isKept(copy))
        XCTAssertEqual(GOGSaves.contents(of: copy).files, 2)
        XCTAssertEqual(GOGSaves.contents(of: copy).bytes, 25)
    }

    /// An install set up before the history was kept counts from its setup marker's date.
    func testAnInstallWithNoHistoryCountsFromItsMarker() throws {
        let driveC = root.appending(path: "drive_c")
        let game = GOGStore.InstalledGame(id: "7", title: "Game", folder: driveC.appending(path: "Game"), buildID: "b1", clientID: nil, dlcIDs: [], tasks: [])
        let marked = Date(timeIntervalSince1970: 1_700_000_000)
        try write("b1", to: GOGStore.setupMarker(for: game, driveC: driveC), dated: marked)
        let history = GOGStore.history(for: game, driveC: driveC)
        XCTAssertEqual(history.firstSetup, marked)
        XCTAssertTrue(history.isGameWritten(marked.addingTimeInterval(1)))
        XCTAssertFalse(history.isGameWritten(marked.addingTimeInterval(-1)))
        GOGStore.markSetupDone(for: game, driveC: driveC)
        XCTAssertEqual(GOGStore.history(for: game, driveC: driveC).firstSetup, marked, "the marker's old date, read before it is rewritten")
    }

    /// Deleting saves with the game removes the folders GOG names elsewhere, and never a whole or
    /// shared folder, Highball's save-backups (even through a link), or one holding the game.
    func testDeletingSavesLeavesSharedFoldersAndBackupsAlone() throws {
        let home = root.appending(path: "home")
        let saves = GOGSaves(store: GOGStore(paths: HighballPaths(home: home)))
        let driveC = root.appending(path: "drive_c")
        let user = driveC.appending(path: "users/player")
        let game = GOGStore.InstalledGame(id: "7", title: "Game", folder: user.appending(path: "AppData/Local/Games/Game"), buildID: nil, clientID: nil, dlcIDs: [], tasks: [])
        try write("exe", to: game.folder.appending(path: "game.exe"))
        try write("own", to: user.appending(path: "Saved Games/Studio/Game/slot.sav"))
        try write("other game", to: user.appending(path: "Saved Games/Other/slot.sav"))
        try write("kept", to: saves.backupsDir.appending(path: "7-saves-1/2026-mac-kept/slot.sav"))
        try FileManager.default.createDirectory(at: user.appending(path: "AppData/Roaming"), withIntermediateDirectories: true)
        // The environment's Documents is the Mac's own, here `home`, as UserFolders links it.
        try FileManager.default.createSymbolicLink(at: user.appending(path: "Documents"), withDestinationURL: home)
        try write("mac", to: home.appending(path: "My Games/Game/slot.sav"))
        let templates = ["<?SAVED_GAMES?>/Studio/Game", "<?SAVED_GAMES?>", "<?DOCUMENTS?>/save-backups", "<?DOCUMENTS?>",
                         "<?APPLICATION_DATA_LOCAL?>/Games", "<?SAVED_GAMES?>/../Saved Games/Other", "<?INSTALL?>/saves",
                         "<?DOCUMENTS?>/My Games/Game"]
        let plan = GOGSaves.uninstallPlan(templates.enumerated().map { GOGSaves.Location(name: "l\($0.offset)", template: $0.element) },
                                          game: game, driveC: driveC, userName: "player")
        let (removed, leftAlone) = saves.removeSaves(plan, game: game, driveC: driveC)
        XCTAssertEqual(removed.map(\.lastPathComponent), ["Game"])
        XCTAssertEqual(leftAlone.map(\.lastPathComponent), ["save-backups", "Games", "Game"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appending(path: "My Games/Game/slot.sav").path), "the Mac's Documents, through the link")
        XCTAssertFalse(FileManager.default.fileExists(atPath: user.appending(path: "Saved Games/Studio/Game").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.appending(path: "Saved Games/Other/slot.sav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saves.backupsDir.appending(path: "7-saves-1/2026-mac-kept/slot.sav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.folder.appending(path: "game.exe").path))
    }

    /// Kept saves go back where they came from in a new install: a named location to its folder,
    /// the game-folder copy by its paths. What is there already is copied first, the install is
    /// asked once, and copies of the game still in other environments are never asked.
    func testPuttingSavesBackPlacesThemInTheNewInstall() throws {
        let saves = GOGSaves(store: GOGStore(paths: HighballPaths(home: root.appending(path: "home"))))
        func install(_ path: String) -> GOGStore.InstalledGame {
            GOGStore.InstalledGame(id: "7", title: "Game", folder: root.appending(path: path), buildID: nil, clientID: nil, dlcIDs: [], tasks: [])
        }
        let old = install("A/Game"), new = install("B/Game"), elsewhere = install("C/Game")
        let location = GOGSaves.Location(name: "saves", template: "<?INSTALL?>/saves")
        try write("cloud slot", to: old.folder.appending(path: "saves/slot.sav"))
        try write("local slot", to: old.folder.appending(path: "Profiles/p1.sav"))
        let named = try XCTUnwrap(try saves.backUpLocal(old, location: location, folder: old.folder.appending(path: "saves"), kept: true))
        let written = try XCTUnwrap(try saves.backUpLocal(old, location: GOGSaves.gameFolder, folder: old.folder, kept: true,
                                                          only: [old.folder.appending(path: "Profiles/p1.sav")]))
        saves.keep([(location.name, old.folder.appending(path: "saves"), named), (GOGSaves.gameFolder.name, old.folder, written)],
                   of: old, otherInstalls: [elsewhere.folder])
        XCTAssertNil(GOGSaves.toOffer(saves.keptSaves()[elsewhere.id], to: elsewhere))
        try write("fresh", to: new.folder.appending(path: "saves/slot.sav"))
        let kept = try XCTUnwrap(GOGSaves.toOffer(saves.keptSaves()[new.id], to: new))
        XCTAssertEqual(try saves.putBack(kept, into: new), 2)
        XCTAssertEqual(try String(contentsOf: new.folder.appending(path: "saves/slot.sav"), encoding: .utf8), "cloud slot")
        XCTAssertEqual(try String(contentsOf: new.folder.appending(path: "Profiles/p1.sav"), encoding: .utf8), "local slot")
        let before = try XCTUnwrap(saves.backups(in: saves.backupsFolder(new, location)).first)
        XCTAssertEqual(try String(contentsOf: before.appending(path: "slot.sav"), encoding: .utf8), "fresh", "what was there is copied first")
        saves.markAsked(new)
        XCTAssertNil(GOGSaves.toOffer(saves.keptSaves()[new.id], to: new), "asked once")
    }

    /// The latest uninstall's backups replace an earlier one's: a location it had nothing for
    /// never brings back an older copy, and an uninstall that kept nothing offers nothing.
    func testOnlyTheLatestUninstallsBackupsAreOffered() throws {
        let saves = GOGSaves(store: GOGStore(paths: HighballPaths(home: root.appending(path: "home"))))
        let game = GOGStore.InstalledGame(id: "7", title: "Game", folder: root.appending(path: "A/Game"), buildID: nil, clientID: nil, dlcIDs: [], tasks: [])
        let old = root.appending(path: "backups/old"), new = root.appending(path: "backups/new")
        saves.keep([("saves", game.folder.appending(path: "saves"), old), (GOGSaves.gameFolder.name, game.folder, old)], of: game, otherInstalls: [])
        saves.keep([(GOGSaves.gameFolder.name, game.folder, new)], of: game, otherInstalls: [])
        XCTAssertEqual(GOGSaves.toOffer(saves.keptSaves()[game.id], to: game)?.entries.map(\.name), [GOGSaves.gameFolder.name])
        XCTAssertEqual(GOGSaves.toOffer(saves.keptSaves()[game.id], to: game)?.entries.map(\.backup), [new])
        saves.keep([], of: game, otherInstalls: [])
        XCTAssertNil(GOGSaves.toOffer(saves.keptSaves()[game.id], to: game))
    }
}
