import XCTest
@testable import HighballKit

final class DirectoryWatcherTests: XCTestCase {
    func testNewEntryReportsOnceAfterTheQuietPeriod() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let changed = expectation(description: "change reported")
        changed.assertForOverFulfill = true
        let watcher = DirectoryWatcher(quiet: 0.3) { changed.fulfill() }
        watcher.watch([dir])
        XCTAssertEqual(watcher.watched, [dir.path])
        // Two writes inside one quiet period: one report.
        FileManager.default.createFile(atPath: dir.appending(path: "appmanifest_1.acf").path, contents: Data("a".utf8))
        FileManager.default.createFile(atPath: dir.appending(path: "appmanifest_2.acf").path, contents: Data("b".utf8))
        wait(for: [changed], timeout: 5)
        withExtendedLifetime(watcher) {}
    }

    func testMissingDirectoryIsSkippedAndDroppedDirectoriesAreReleased() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = DirectoryWatcher(quiet: 0.1) {}
        watcher.watch([dir, dir.appending(path: "missing")])
        XCTAssertEqual(watcher.watched, [dir.path])
        watcher.watch([])
        XCTAssertTrue(watcher.watched.isEmpty)
    }

    /// Steam's install folder appears after the app started (the Steam recipe ran from Get Started),
    /// so it is not there at the first watch; the next watch must arm it (issue found in the
    /// 2026-09-05 from-scratch run: an installed game did not appear until a relaunch).
    func testDirectoryCreatedAfterTheFirstWatchIsArmedByTheNextWatch() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let steamapps = root.appending(path: "steamapps")
        let changed = expectation(description: "change reported after arming")
        let watcher = DirectoryWatcher(quiet: 0.2) { changed.fulfill() }
        watcher.watch([steamapps])
        XCTAssertTrue(watcher.watched.isEmpty)
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        watcher.watch([steamapps])
        XCTAssertEqual(watcher.watched, [steamapps.path])
        FileManager.default.createFile(atPath: steamapps.appending(path: "appmanifest_400.acf").path, contents: Data("x".utf8))
        wait(for: [changed], timeout: 5)
        withExtendedLifetime(watcher) {}
    }

    /// A watched directory that is deleted and recreated (Steam's first update rebuilds folders)
    /// leaves a source on the old inode where nothing happens again; the next watch must reopen it.
    func testReplacedDirectoryIsReopened() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")
        let dir = root.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var onReport: () -> Void = {}
        let watcher = DirectoryWatcher(quiet: 0.2) { onReport() }
        watcher.watch([dir])
        // The delete is reported on its own; wait it out so it cannot coalesce with the next write.
        let deleted = expectation(description: "delete reported")
        onReport = { deleted.fulfill() }
        try FileManager.default.removeItem(at: dir)
        wait(for: [deleted], timeout: 5)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        watcher.watch([dir])                                  // must reopen on the new inode
        let written = expectation(description: "write on the recreated directory reported")
        onReport = { written.fulfill() }
        FileManager.default.createFile(atPath: dir.appending(path: "appmanifest_620.acf").path, contents: Data("y".utf8))
        wait(for: [written], timeout: 5)                      // only if the new inode is watched
        withExtendedLifetime(watcher) {}
    }
}
