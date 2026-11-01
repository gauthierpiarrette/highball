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
}
