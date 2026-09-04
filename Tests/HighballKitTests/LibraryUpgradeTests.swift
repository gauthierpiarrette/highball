import XCTest
@testable import HighballKit

/// The 0.8 sidebar removal must never hide an existing user's games: the library is built from
/// every environment, whatever it is named (regression for issue #21's "can't see my bottle").
final class LibraryUpgradeTests: XCTestCase {
    private func bottle(_ name: String) -> Bottle {
        Bottle(url: URL(fileURLWithPath: "/tmp/\(name)"), settings: BottleSettings(name: name, engineID: "e"))
    }

    func testGamesFromAnyNamedEnvironmentAppear() {
        let cs = bottle("CS")   // an upgrader's environment, not the default "Games"
        let game = SteamGame(appid: 240, name: "Counter-Strike: Source", installdir: "cs", sizeOnDisk: 1, stateFlags: 4, lastPlayed: nil)
        let items = LibraryIndex.build(bottles: [cs], steamByBottle: ["CS": [game]], epicOwned: [], epicInstalls: [:])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Counter-Strike: Source")
        XCTAssertEqual(items.first?.bottleName, "CS")
        XCTAssertTrue(items.first?.installed == true)
    }

    func testTwoEnvironmentsBothContributeAndTheSameGameMerges() {
        let a = bottle("CS"), b = bottle("Modding")
        let g1 = SteamGame(appid: 730, name: "CS2", installdir: "cs2", sizeOnDisk: 1, stateFlags: 4, lastPlayed: nil)
        let g2 = SteamGame(appid: 620, name: "Portal 2", installdir: "p2", sizeOnDisk: 1, stateFlags: 4, lastPlayed: nil)
        let items = LibraryIndex.build(bottles: [a, b],
                                       steamByBottle: ["CS": [g1], "Modding": [g1, g2]],
                                       epicOwned: [], epicInstalls: [:])
        XCTAssertEqual(Set(items.map(\.title)), ["CS2", "Portal 2"])
        // The duplicated CS2 is one row that remembers the other environment.
        let cs2 = items.first { $0.title == "CS2" }
        XCTAssertFalse(cs2?.otherBottles.isEmpty ?? true)
    }
}
