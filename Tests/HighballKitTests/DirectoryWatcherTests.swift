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
}
