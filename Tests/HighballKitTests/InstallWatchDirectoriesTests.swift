import XCTest
@testable import HighballKit

final class InstallWatchDirectoriesTests: XCTestCase {
    func testOnlyExclusiveSteamPathsSkipTheFullRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).resolvingSymlinksInPath()
        let steam = root.appending(path: "steamapps"), shared = root.appending(path: "shared")
        let games = root.appending(path: "Games"), alias = root.appending(path: "mac-steamapps")
        for directory in [steam, shared, games] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: shared)

        let watch = InstallWatchDirectories(windowsSteam: [steam, shared], other: [games, alias])
        XCTAssertEqual(Set(watch.directories.map(\.path)), [steam.path, shared.path, games.path])
        XCTAssertTrue(watch.affectsOnlyWindowsSteam([steam.path]))
        XCTAssertFalse(watch.affectsOnlyWindowsSteam([shared.path]))
        XCTAssertFalse(watch.affectsOnlyWindowsSteam([games.path]))
        XCTAssertFalse(watch.affectsOnlyWindowsSteam([steam.path, games.path]))
        XCTAssertFalse(watch.affectsOnlyWindowsSteam([root.path]))
        XCTAssertFalse(watch.affectsOnlyWindowsSteam([]))
    }
}
