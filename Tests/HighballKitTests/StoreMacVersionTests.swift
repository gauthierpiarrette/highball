import XCTest
@testable import HighballKit

/// GOG's and Epic's catalogs list a game's Mac release beside the Windows one, which the same
/// purchase includes: the tile's Apple logo and the game page's Mac section come from that.
final class StoreMacVersionTests: XCTestCase {
    func testGOGReleaseListingMacOSIsMarked() throws {
        let json = """
        {"type":"game","title":{"*":"Jill of the Jungle"},"game":{"releases":[]},
         "supported_operating_systems":[{"slug":"windows","name":"Windows"},{"slug":"osx","name":"macOS"}]}
        """
        XCTAssertEqual(try XCTUnwrap(GOGStore.parseRelease(id: "1", data: Data(json.utf8))).listsMac, true)
        let windowsOnly = #"{"type":"game","title":{"*":"Control"},"game":{},"supported_operating_systems":[{"slug":"windows"}]}"#
        XCTAssertEqual(try XCTUnwrap(GOGStore.parseRelease(id: "2", data: Data(windowsOnly.utf8))).listsMac, false)
    }

    /// An entry cached before the systems were read decodes with nil, which looks it up again.
    func testGOGCacheFromBeforeReadsAsUnknown() throws {
        let old = #"{"id":"1","title":"Old"}"#
        XCTAssertNil(try JSONDecoder().decode(GOGStore.Game.self, from: Data(old.utf8)).listsMac)
    }

    func testEpicCatalogItemListingMacIsMarked() throws {
        let json = """
        [{"app_name":"Garlic","app_title":"Enter the Gungeon",
          "metadata":{"releaseInfo":[{"appId":"Garlic","platform":["Mac","Win32","Windows"]}]}},
         {"app_name":"Duck","app_title":"Cardpocalypse","metadata":{"releaseInfo":[{"platform":["Windows"]}]}},
         {"app_name":"Bare","app_title":"No metadata"}]
        """
        let games = try JSONDecoder().decode([EpicStore.Game].self, from: Data(json.utf8))
        XCTAssertEqual(games.map(\.listsMac), [true, false, false])
        let cloud = #"[{"app_name":"A","app_title":"A","metadata":{"customAttributes":{"CloudSaveFolder":{"type":"STRING","value":"{AppData}/A/Saved"}}}}]"#
        XCTAssertEqual(try JSONDecoder().decode([EpicStore.Game].self, from: Data(cloud.utf8)).map(\.cloudSaves), [true])
        XCTAssertEqual(games.map(\.cloudSaves), [false, false, false])
    }

    func testLibraryCarriesTheListingToGOGAndEpicTiles() {
        let items = LibraryIndex.build(
            bottles: [], steamByBottle: [:],
            epicOwned: [EpicStore.Game(app_name: "Garlic", app_title: "Enter the Gungeon", listsMac: true),
                        EpicStore.Game(app_name: "Duck", app_title: "Cardpocalypse")],
            epicInstalls: [:],
            gogGames: [GOGStore.Game(id: "1", title: "Jill of the Jungle", listsMac: true)])
        let listed = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.macListed) })
        XCTAssertEqual(listed["epic:Garlic"], true)
        XCTAssertEqual(listed["epic:Duck"], false)
        XCTAssertEqual(listed["gog:1"], true)
    }
}

