import XCTest
@testable import HighballKit

/// An uninstall removes the files the install put there and leaves what the player added (highball#652).
final class GOGUninstallFilesTests: XCTestCase {
    var dir: URL!
    var game: URL { dir.appending(path: "drive_c/GOG Games/Gunslugs", directoryHint: .isDirectory) }
    let fm = FileManager.default

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appending(path: "gog-uninstall-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: dir) }

    func write(_ path: String, in folder: URL? = nil, modified: Date? = nil) throws {
        let url = (folder ?? game).appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(path.utf8).write(to: url)
        if let modified { try fm.setAttributes([.modificationDate: modified, .creationDate: modified], ofItemAtPath: url.path) }
    }

    func exists(_ path: String) -> Bool { fm.fileExists(atPath: game.appending(path: path).path) }

    func testUninstallRemovesTheInstallsFilesAndKeepsThePlayers() throws {
        try write("Gunslugs.exe"); try write("data/levels/1.dat"); try write("data/sound/a.ogg")
        try write("goggame-1234.info"); try write(".highball-gogdl-manifest")
        GOGStore.recordInstallFiles(in: game, downloadStarted: Date())
        // After the install: a patched DLL from a zip keeps its 2001 date, an app bundle copied by
        // Finder keeps its own, and the game writes a config.
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try write("patch/d3d9.dll", modified: old)
        try write("Fallout CE.app/Contents/MacOS/fallout-ce", modified: old)
        try write("data/levels/user.cfg")
        try write("data/sound/.DS_Store")

        let left = try XCTUnwrap(GOGStore.removeInstallFiles(in: game))
        XCTAssertFalse(exists("Gunslugs.exe")); XCTAssertFalse(exists("data/levels/1.dat"))
        XCTAssertFalse(exists("goggame-1234.info")); XCTAssertFalse(exists(".highball-gogdl-manifest"))
        XCTAssertFalse(exists(".highball-install-files"))
        XCTAssertFalse(exists("data/sound"), "a folder left with only Finder's .DS_Store goes")
        XCTAssertTrue(exists("patch/d3d9.dll")); XCTAssertTrue(exists("Fallout CE.app/Contents/MacOS/fallout-ce"))
        XCTAssertTrue(exists("data/levels/user.cfg"))
        XCTAssertEqual(Set(left.map(\.lastPathComponent)), ["d3d9.dll", "fallout-ce", "user.cfg"])
        XCTAssertEqual(GOGStore.installFiles(game), nil)
    }

    func testAFolderWithNothingAddedIsRemovedWhole() throws {
        try write("Gunslugs.exe"); try write("data/1.dat"); try write("goggame-1234.info")
        GOGStore.recordInstallFiles(in: game, downloadStarted: Date())
        XCTAssertEqual(GOGStore.removeInstallFiles(in: game), [])
        XCTAssertFalse(fm.fileExists(atPath: game.path))
    }

    func testWithoutAListNothingIsTouched() throws {
        try write("Gunslugs.exe")
        XCTAssertNil(GOGStore.removeInstallFiles(in: game))
        XCTAssertTrue(exists("Gunslugs.exe"))
    }

    func testAReinstallDoesNotClaimWhatTheLastUninstallLeft() throws {
        try write("Gunslugs.exe"); try write("goggame-1234.info")
        GOGStore.recordInstallFiles(in: game, downloadStarted: Date())
        try write("mods/big.pak"); try write("notes.txt")
        _ = GOGStore.removeInstallFiles(in: game)
        XCTAssertTrue(exists(".highball-left-files"))
        // A later download into the same folder rewrites notes.txt (the game ships one too) but not the mod.
        let later = Date().addingTimeInterval(60)
        try write("Gunslugs.exe"); try write("goggame-1234.info")
        try fm.setAttributes([.modificationDate: later.addingTimeInterval(5)], ofItemAtPath: game.appending(path: "notes.txt").path)
        GOGStore.recordInstallFiles(in: game, downloadStarted: later)
        XCTAssertEqual(Set(try XCTUnwrap(GOGStore.installFiles(game))), ["Gunslugs.exe", "goggame-1234.info", "notes.txt"])
        XCTAssertFalse(exists(".highball-left-files"))
        _ = GOGStore.removeInstallFiles(in: game)
        XCTAssertTrue(exists("mods/big.pak")); XCTAssertFalse(exists("notes.txt"))
    }

    func testAnUpdateAddsWhatItChangedAndStartsNoList() throws {
        try write("Gunslugs.exe")
        let later = Date().addingTimeInterval(60)
        GOGStore.recordUpdatedFiles(in: game, updateStarted: later)
        XCTAssertNil(GOGStore.installFiles(game), "an install from before the lists keeps none")

        GOGStore.recordInstallFiles(in: game, downloadStarted: Date())
        try write("added-by-player.txt")
        try write("data/new-in-patch.dat", modified: later.addingTimeInterval(5))
        GOGStore.recordUpdatedFiles(in: game, updateStarted: later)
        XCTAssertEqual(Set(try XCTUnwrap(GOGStore.installFiles(game))), ["Gunslugs.exe", "data/new-in-patch.dat"])
    }

    func testNothingOutsideTheFolderIsRemoved() throws {
        let outside = dir.appending(path: "outside", directoryHint: .isDirectory)
        try write("keep.txt", in: outside)
        try write("Gunslugs.exe")
        try fm.createSymbolicLink(at: game.appending(path: "linked"), withDestinationURL: outside)
        GOGStore.recordInstallFiles(in: game, downloadStarted: Date())
        // A list that names a file behind the link or above the folder, as a damaged one could.
        let record = GOGStore.installFilesRecord(game)
        try Data("Gunslugs.exe\nlinked/keep.txt\n../outside/keep.txt\nlinked\n".utf8).write(to: record)
        _ = GOGStore.removeInstallFiles(in: game)
        XCTAssertTrue(fm.fileExists(atPath: outside.appending(path: "keep.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: game.path), "the link itself was the install's and went")
    }
}
