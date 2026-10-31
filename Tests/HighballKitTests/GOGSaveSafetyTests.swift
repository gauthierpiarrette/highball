import XCTest
@testable import HighballKit

/// No sync replaces or deletes a save without a copy of it kept first (GOGSaves' backups).
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

    /// The copy comes before gogdl is asked: here gogdl is not even installed, and the copy is made.
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

    /// Kept by when they were made, never by name, and never the copy just made: a clock that was
    /// once ahead leaves copies dated later than today's.
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

    /// gogdl lists and deletes hidden files too, so they count as saves to keep.
    func testHiddenFilesCount() throws {
        let folder = root.appending(path: "Hidden")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: ".save"))
        XCTAssertEqual(GOGSaves.files(in: folder).map(\.lastPathComponent), [".save"])
    }

    func testTwoInstallsKeepTheirOwnBackups() throws {
        let (saves, a, location, _) = try fixture(install: "A")
        let (_, b, _, _) = try fixture(install: "B")
        XCTAssertNotEqual(saves.backupsFolder(a, location), saves.backupsFolder(b, location))
        XCTAssertEqual(saves.backupsFolder(a, location), saves.backupsFolder(a, location))
    }

    /// gogdl exits 0 when a file failed to come down; its log line fails the cloud copy instead.
    func testAFileGogdlFailedToFetchFailsTheCopy() {
        XCTAssertTrue(GOGSaves.isFailure("[SAVES] ERROR: Downloading file failed"))
        XCTAssertFalse(GOGSaves.isFailure("[SAVES] INFO: Files in cloud: 3"))
    }

    /// An upload copies GOG's cloud first unless the saves came down before the session: with
    /// gogdl absent here, the copy is what fails in the first case, and the sync in the second.
    func testAnUploadCopiesTheCloudFirstUnlessTheSavesCameDown() throws {
        let (saves, game, location, folder) = try fixture()
        guard case let .failed(first) = saves.sync(game, location: location, folder: folder, direction: .upload) else { return XCTFail() }
        XCTAssertTrue(first.contains("backed up"))
        guard case let .failed(second) = saves.sync(game, location: location, folder: folder, direction: .upload, cloudInStep: true) else { return XCTFail() }
        XCTAssertFalse(second.contains("backed up"))
    }

    /// A save folder years old: its copy is dated now, so the newest copies are still the ones kept.
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
}
