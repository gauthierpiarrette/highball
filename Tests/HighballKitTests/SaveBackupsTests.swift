import XCTest
@testable import HighballKit

/// The backups shared by GOG and Epic syncs (SaveBackups) beyond what GOGSaveSafetyTests covers.
final class SaveBackupsTests: XCTestCase {
    /// A pinned backup (a download's, until it is done or undone) outlives any number of newer
    /// backups of its kind.
    func testAPinnedBackupIsNeverPruned() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pinned-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let backups = SaveBackups(root: root.appending(path: "backups"))
        let folder = root.appending(path: "saves"), dir = backups.folder("game", install: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("0".utf8).write(to: folder.appending(path: "slot"))
        let pinned = try XCTUnwrap(try backups.backUpLocal(folder, into: dir))
        try SaveBackups.pin(pinned)
        for i in 1...12 {
            try Data("\(i)".utf8).write(to: folder.appending(path: "slot"))
            try backups.backUpLocal(folder, into: dir)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinned.path))
        XCTAssertEqual(backups.backups(in: dir).count, 11, "ten rotating, plus the pinned one")
        SaveBackups.unpin(pinned)
        try Data("13".utf8).write(to: folder.appending(path: "slot"))
        try backups.backUpLocal(folder, into: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pinned.path), "pruned like the others once unpinned")
    }
    func testManualSaveCopyKeepsTheGameFilesAndLeavesTheOriginalAlone() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "save-copy-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = root.appending(path: "prefix/drive_c/users/player/AppData/Roaming/DarkSoulsIII")
        let profile = source.appending(path: "profile", directoryHint: .isDirectory)
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let slot = profile.appending(path: "DS30000.sl2")
        try Data("first".utf8).write(to: slot)
        let backups = SaveBackups(root: root.appending(path: "backups", directoryHint: .isDirectory))
        let first = try XCTUnwrap(try backups.copyGameSaves(from: source, title: "Dark Souls III"))
        XCTAssertTrue(SaveBackups.isKept(first))
        XCTAssertEqual(try Data(contentsOf: first.appending(path: "profile/DS30000.sl2")), Data("first".utf8))
        try Data("second".utf8).write(to: slot)
        let second = try XCTUnwrap(try backups.copyGameSaves(from: source, title: "Dark Souls III"))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: second.appending(path: "profile/DS30000.sl2")), Data("second".utf8))
        XCTAssertEqual(try Data(contentsOf: slot), Data("second".utf8))
        try fm.createSymbolicLink(at: source.appending(path: "outside"), withDestinationURL: root)
        XCTAssertThrowsError(try backups.copyGameSaves(from: source, title: "Dark Souls III"))
        XCTAssertEqual(backups.backups(in: first.deletingLastPathComponent()).count, 2)
        XCTAssertThrowsError(try backups.copyGameSaves(from: root, title: "Too broad"))
    }
}
