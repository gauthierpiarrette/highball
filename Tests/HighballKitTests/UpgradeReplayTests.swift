import XCTest
@testable import HighballKit

/// Replays every home shape a released build wrote (Tests/Fixtures/homes/<version>, captured by
/// Scripts/snapshot-home.sh): the bottle settings still decode and list as real, the engine
/// manifest still loads, the library still shows the game. One fixture per release, forever.
final class UpgradeReplayTests: XCTestCase {
    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/homes")
    }

    func testEveryReleasedHomeShapeStillReads() throws {
        let fm = FileManager.default
        let versions = (try? fm.contentsOfDirectory(atPath: Self.fixturesDir.path))?.filter { !$0.hasPrefix(".") }.sorted() ?? []
        try XCTSkipIf(versions.isEmpty, "no snapshots yet: run Scripts/snapshot-home.sh <version>")
        for version in versions {
            let fixture = Self.fixturesDir.appending(path: version)
            let home = fm.temporaryDirectory.appending(path: "hb-replay-\(version)-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: home) }
            let paths = HighballPaths(home: home)
            // The bottle, with a Steam game inside, the way a real home has it.
            let bottle = paths.bottles.appending(path: "Games")
            let steam = bottle.appending(path: "drive_c/Program Files (x86)/Steam")
            try fm.createDirectory(at: steam.appending(path: "steamapps/common/Portal"), withIntermediateDirectories: true)
            try fm.createDirectory(at: bottle.appending(path: "drive_c/windows"), withIntermediateDirectories: true)
            try Data().write(to: steam.appending(path: "steam.exe"))
            try fm.copyItem(at: fixture.appending(path: "bottle/bottle.json"), to: bottle.appending(path: "bottle.json"))
            try """
            "AppState"\n{\n\t"appid"\t\t"400"\n\t"name"\t\t"Portal"\n\t"installdir"\t\t"Portal"\n\t"StateFlags"\t\t"4"\n\t"SizeOnDisk"\t\t"1000"\n}
            """.write(to: steam.appending(path: "steamapps/appmanifest_400.acf"), atomically: true, encoding: .utf8)
            // The engine's manifest as written by that build.
            let snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appending(path: "snapshot.json"))) as? [String: Any]
            let engineID = try XCTUnwrap(snapshot?["engine"] as? String)
            let engineDir = paths.engine(engineID)
            try fm.createDirectory(at: engineDir, withIntermediateDirectories: true)
            try fm.copyItem(at: fixture.appending(path: "engine/manifest.json"), to: engineDir.appending(path: "manifest.json"))
            if fm.fileExists(atPath: fixture.appending(path: "library.json").path) {
                try fm.copyItem(at: fixture.appending(path: "library.json"), to: home.appending(path: "library.json"))
            }

            let store = BottleStore(paths: paths)
            let bottles = try store.list()
            XCTAssertEqual(bottles.map(\.name), ["Games"], "\(version): the environment lists")
            XCTAssertTrue(try store.damaged().isEmpty, "\(version): and is not damaged")
            XCTAssertEqual(bottles.first?.settings.engineID, engineID, "\(version): on its engine")
            let engines = try EngineStore(paths: paths).installedEngines()
            XCTAssertEqual(engines.map(\.id), [engineID], "\(version): the engine manifest loads")
            let games = bottles.first.map { SteamLibrary.games(in: $0) } ?? []
            let items = LibraryIndex.build(bottles: bottles, steamByBottle: ["Games": games], epicOwned: [], epicInstalls: [:],
                                           plays: LibraryStore(paths: paths).load())
            XCTAssertEqual(items.first?.title, "Portal", "\(version): the library shows the game")
            XCTAssertNoThrow(LibraryStore(paths: paths).rendererOverrides(), "\(version): the library file reads")
            // And today's encoder still writes what that build can read back: a round trip.
            if var b = bottles.first { b.settings.renderer = b.settings.renderer; XCTAssertNoThrow(try b.save(), "\(version): settings save") }
            XCTAssertTrue(try store.damaged().isEmpty, "\(version): still not damaged after a save")
        }
    }
}
