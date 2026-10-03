import XCTest
@testable import HighballKit

/// Names people give their games (NameStore): kept by item id in the home, a blank resets, and
/// the store's own title is never touched.
final class NameStoreTests: XCTestCase {
    private var home: URL!
    private var store: NameStore!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = NameStore(paths: HighballPaths(home: home))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func testNoFileMeansNoNames() {
        XCTAssertEqual(store.names(), [:])
        XCTAssertNil(store.name(for: "steam:620"))
    }

    func testANameIsKeptByItemIdAndSurvivesANewStore() throws {
        try store.setName("Portal Deux", for: "steam:620")
        XCTAssertEqual(store.name(for: "steam:620"), "Portal Deux")
        XCTAssertEqual(NameStore(paths: HighballPaths(home: home)).name(for: "steam:620"), "Portal Deux")
    }

    func testABlankNameResetsAndTheLastResetRemovesTheFile() throws {
        try store.setName("Portal Deux", for: "steam:620")
        try store.setName("   ", for: "steam:620")
        XCTAssertNil(store.name(for: "steam:620"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: "names.json").path))
    }

    func testSurroundingWhitespaceIsTrimmed() throws {
        try store.setName("  My Game \n", for: "pin:Games:00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(store.name(for: "pin:Games:00000000-0000-0000-0000-000000000001"), "My Game")
    }

    func testOtherNamesStayWhenOneIsReset() throws {
        try store.setName("A", for: "steam:1")
        try store.setName("B", for: "steam:2")
        try store.setName(nil, for: "steam:1")
        XCTAssertEqual(store.names(), ["steam:2": "B"])
    }
}
