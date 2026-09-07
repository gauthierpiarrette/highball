import XCTest
@testable import HighballKit

/// A row must be found for a copy from any store (#63: an Epic copy of Guardians of the Galaxy
/// matched nothing, so Play never asked for D3DMetal and DXMT refused the DirectX 12 game), and
/// an Epic install whose folder is gone must not show as installed.
final class GameDBMatchTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "hb-gamedb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        {"id": "marvels-guardians-of-the-galaxy", "title": "Marvel's Guardians of the Galaxy™", "steam_appid": 1088850,
         "epic_app_name": "63a665088eb1480298f1e57943b225d8", "status": "community", "renderer": "d3dmetal"}
        """.write(to: dir.appending(path: "gotg.json"), atomically: true, encoding: .utf8)
        try """
        {"id": "epic-only", "title": "Epic Only Game", "status": "community", "renderer": "dxmt"}
        """.write(to: dir.appending(path: "epic-only.json"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func item(source: LibrarySource, title: String, steam: Int? = nil, epic: String? = nil) -> HighballKit.LibraryItem {
        HighballKit.LibraryItem(source: source, id: "t:\(title)", title: title, bottleName: "Games", installed: true, steamAppID: steam, epicAppName: epic)
    }

    func testSteamIDStillWinsAndRowsWithoutOneAreIndexed() {
        let db = GameDB(directories: [dir])
        XCTAssertEqual(db[1088850]?.id, "marvels-guardians-of-the-galaxy")
        XCTAssertEqual(db.entry(for: item(source: .steam, title: "anything", steam: 1088850))?.id, "marvels-guardians-of-the-galaxy")
        XCTAssertEqual(db.byTitle.count, 2, "a row with no Steam id is still a row")
    }

    func testEpicCopyMatchesByAppNameThenByTitle() {
        let db = GameDB(directories: [dir])
        XCTAssertEqual(db.entry(for: item(source: .epic, title: "Whatever Epic Calls It", epic: "63a665088eb1480298f1e57943b225d8"))?.id,
                       "marvels-guardians-of-the-galaxy", "the app name is exact")
        XCTAssertEqual(db.entry(for: item(source: .epic, title: "Marvels Guardians Of The Galaxy", epic: "unknown"))?.id,
                       "marvels-guardians-of-the-galaxy", "punctuation and case do not separate the same title")
        XCTAssertEqual(db.entry(for: item(source: .epic, title: "Epic Only Game", epic: "x"))?.renderer, .dxmt)
        XCTAssertNil(db.entry(for: item(source: .pin, title: "Notepad++")), "a program the database does not know")
        XCTAssertNil(db.entry(for: item(source: .epic, title: "Guardians of the Galaxy", epic: "y")), "exact after normalizing, never fuzzy")
    }

    func testNormalizedTitle() {
        XCTAssertEqual(GameDB.normalizedTitle("Marvel's Guardians of the Galaxy™"), "marvels guardians of the galaxy")
        XCTAssertEqual(GameDB.normalizedTitle("  Portal   2 "), "portal 2")
        XCTAssertEqual(GameDB.normalizedTitle("Marvel’s Guardians of the Galaxy"), GameDB.normalizedTitle("Marvel's Guardians of the Galaxy"), "straight and curly apostrophes agree")
    }

    func testInstallMapKeepsOnlyFoldersStillOnDisk() throws {
        let present = dir.appending(path: "Games/Present")
        try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
        let games = [
            EpicStore.InstalledGame(app_name: "present", install_path: present.path),
            EpicStore.InstalledGame(app_name: "gone", install_path: dir.appending(path: "Games/Gone").path),
            EpicStore.InstalledGame(app_name: "pathless", install_path: nil),
        ]
        XCTAssertEqual(EpicStore.installMap(games), ["present": present.path])
    }
}
