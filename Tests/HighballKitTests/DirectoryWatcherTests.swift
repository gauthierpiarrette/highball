import XCTest
@testable import HighballKit

final class DirectoryWatcherTests: XCTestCase {
    func testNewEntryReportsOnceAfterTheQuietPeriod() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = dir.appending(path: "second-store")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let changed = expectation(description: "change reported")
        changed.assertForOverFulfill = true
        let watcher = DirectoryWatcher(quiet: 0.3) { paths in
            XCTAssertEqual(paths, [dir.path, other.path])
            changed.fulfill()
        }
        watcher.watch([dir, other])
        XCTAssertEqual(watcher.watched, [dir.path, other.path])
        // Two writes inside one quiet period: one report.
        FileManager.default.createFile(atPath: dir.appending(path: "appmanifest_1.acf").path, contents: Data("a".utf8))
        FileManager.default.createFile(atPath: other.appending(path: "game.info").path, contents: Data("b".utf8))
        wait(for: [changed], timeout: 5)
        withExtendedLifetime(watcher) {}
    }

    func testMissingDirectoryIsSkippedAndDroppedDirectoriesAreReleased() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = DirectoryWatcher(quiet: 0.1) { _ in }
        watcher.watch([dir, dir.appending(path: "missing")])
        XCTAssertEqual(watcher.watched, [dir.path])
        watcher.watch([])
        XCTAssertTrue(watcher.watched.isEmpty)
    }

    /// Steam's install folder can appear only after the app started. Keep watching for it.
    func testDirectoryCreatedAfterTheFirstWatchIsArmedAutomatically() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let steamapps = root.appending(path: "steamapps")
        var onReport: () -> Void = {}
        let watcher = DirectoryWatcher(quiet: 0.2) { paths in
            XCTAssertEqual(paths, [steamapps.path])
            onReport()
        }
        watcher.watch([steamapps])
        XCTAssertTrue(watcher.watched.isEmpty)
        let created = expectation(description: "missing target appeared")
        onReport = { created.fulfill() }
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        wait(for: [created], timeout: 5)
        XCTAssertEqual(watcher.watched, [steamapps.path])
        let changed = expectation(description: "change reported after arming")
        onReport = { changed.fulfill() }
        FileManager.default.createFile(atPath: steamapps.appending(path: "appmanifest_400.acf").path, contents: Data("x".utf8))
        wait(for: [changed], timeout: 5)
        withExtendedLifetime(watcher) {}
    }

    /// A watched directory that is deleted and recreated (Steam's first update rebuilds folders)
    /// leaves a source on the old inode where nothing happens again. Reopen it when it returns.
    func testReplacedDirectoryIsReopened() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")
        let dir = root.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var onReport: () -> Void = {}
        let watcher = DirectoryWatcher(quiet: 0.2) { paths in
            XCTAssertEqual(paths, [dir.path])
            onReport()
        }
        watcher.watch([dir])
        // The delete is reported on its own; wait it out so it cannot coalesce with the next write.
        let deleted = expectation(description: "delete reported")
        onReport = { deleted.fulfill() }
        try FileManager.default.removeItem(at: dir)
        wait(for: [deleted], timeout: 5)
        let recreated = expectation(description: "recreation reported")
        onReport = { recreated.fulfill() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        wait(for: [recreated], timeout: 5)
        let written = expectation(description: "write on the recreated directory reported")
        onReport = { written.fulfill() }
        FileManager.default.createFile(atPath: dir.appending(path: "appmanifest_620.acf").path, contents: Data("y".utf8))
        wait(for: [written], timeout: 5)                      // only if the new inode is watched
        withExtendedLifetime(watcher) {}
    }
}
