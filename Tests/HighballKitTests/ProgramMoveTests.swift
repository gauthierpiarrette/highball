import XCTest
@testable import HighballKit

/// A program added by hand that lives outside its environment can move to another one
/// (highball#753). Its id carries the environment's name, so what library.json keeps for it moves
/// to the new id, and the game page and Mac app links find it again by its uuid.
final class ProgramMoveTests: XCTestCase {
    private var home: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "hb-pinmove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = LibraryStore(paths: HighballPaths(home: home))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func testOnlyAProgramOutsideTheEnvironmentCanMove() {
        XCTAssertTrue(Pin(name: "Game", path: "/Volumes/Games/Game/game.exe").isOutsideEnvironment)
        XCTAssertFalse(Pin(name: "Game", path: "Program Files/Game/game.exe").isOutsideEnvironment)
    }

    func testThePlayersChoicesFollowTheNewID() {
        let uuid = UUID().uuidString
        let old = "pin:Games:\(uuid)", new = "pin:Wine 11:\(uuid)"
        store.recordPlay(id: old, bottle: "Games", date: Date(timeIntervalSince1970: 1_800_000_000))
        store.setRendererOverride(.dxmt, for: old)
        store.setLaunchArguments(["-windowed"], for: old)
        store.setDisplay("DISPLAY-UUID", for: old)
        store.recordPlay(id: "steam:620", bottle: "Games")

        store.rekey(from: old, to: new, bottle: "Wine 11")

        let fresh = LibraryStore(paths: HighballPaths(home: home))
        XCTAssertNil(fresh.load()[old])
        XCTAssertEqual(fresh.load()[new]?.lastPlayedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(fresh.load()[new]?.bottle, "Wine 11")
        XCTAssertEqual(fresh.rendererOverrides(), [new: .dxmt])
        XCTAssertEqual(fresh.launchArguments(), [new: ["-windowed"]])
        XCTAssertEqual(fresh.displayChoices(), [new: "DISPLAY-UUID"])
        XCTAssertNotNil(fresh.load()["steam:620"], "other games keep theirs")
    }

    func testAChoiceTheNewIDHasStays() {
        let uuid = UUID().uuidString
        let old = "pin:Games:\(uuid)", new = "pin:Other:\(uuid)"
        store.setLaunchArguments(["-old"], for: old)
        store.setLaunchArguments(["-new"], for: new)
        store.rekey(from: old, to: new, bottle: "Other")
        XCTAssertEqual(store.launchArguments(), [new: ["-new"]])
    }

    func testAHiddenProgramStaysHiddenUnderItsNewID() {
        let uuid = UUID().uuidString
        store.setHidden(true, for: "pin:Games:\(uuid)")
        store.rekey(from: "pin:Games:\(uuid)", to: "pin:Other:\(uuid)", bottle: "Other")
        XCTAssertTrue(LibraryStore.isHidden("pin:Other:\(uuid)", in: store.hiddenIDs()))
    }

    func testThePageAndAMacAppFindTheProgramAfterItMoved() {
        let uuid = UUID()
        let before = LibraryItem(source: .pin, id: "pin:Games:\(uuid.uuidString)", title: "Game", bottleName: "Games", installed: true, pinID: uuid)
        let after = LibraryItem(source: .pin, id: "pin:Other:\(uuid.uuidString)", title: "Game", bottleName: "Other", installed: true, pinID: uuid)
        let steam = LibraryItem(source: .steam, id: "steam:620", title: "Portal 2", bottleName: "Games", installed: true)
        XCTAssertEqual(LibraryIndex.pinItem(withSameProgramAs: before, in: [steam, after])?.id, after.id)
        XCTAssertNil(LibraryIndex.pinItem(withSameProgramAs: steam, in: [steam, after]))
        XCTAssertEqual(LibraryIndex.pinItem(forLink: .pin(bottle: "Games", id: uuid), in: [steam, after])?.bottleName, "Other")
        XCTAssertNil(LibraryIndex.pinItem(forLink: .steam(appid: 620), in: [steam, after]))
    }
}
