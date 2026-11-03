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
}
