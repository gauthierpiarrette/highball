import XCTest
@testable import HighballKit

/// The app notices a bottle.json written outside it (the CLI adding a program while the app is
/// open) without reacting to Wine, which writes its registry files in the same folder all the time.
final class BottleSettingsStampsTests: XCTestCase {
    private var home: URL!
    private var paths: HighballPaths!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "hb-stamps-\(UUID().uuidString)")
        paths = HighballPaths(home: home)
        try paths.ensure()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func bottle(_ name: String) throws -> Bottle {
        let url = paths.bottle(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let b = Bottle(url: url, settings: BottleSettings(name: name, engineID: "test-engine"))
        try b.save()
        return b
    }

    func testRewritingTheSettingsChangesTheStamp() throws {
        var b = try bottle("Games")
        let before = BottleStore.settingsStamps(of: [b])
        b.settings.pins.append(Pin(name: "Game", path: "/Games/Game/game.exe"))
        try BottleStore(paths: paths).update(b)
        XCTAssertNotEqual(BottleStore.settingsStamps(of: [b]), before)
    }

    func testWineWritingItsRegistryLeavesTheStampAlone() throws {
        let b = try bottle("Games")
        let before = BottleStore.settingsStamps(of: [b])
        try Data("REGEDIT4\n".utf8).write(to: b.url.appending(path: "system.reg"), options: .atomic)
        try Data("REGEDIT4\n".utf8).write(to: b.url.appending(path: "user.reg"))
        XCTAssertEqual(BottleStore.settingsStamps(of: [b]), before)
    }

    func testEachBottleHasItsOwnStamp() throws {
        let a = try bottle("A"), b = try bottle("B")
        XCTAssertEqual(Set(BottleStore.settingsStamps(of: [a, b]).keys), ["A", "B"])
    }

    func testABottleWithoutASettingsFileHasNoStamp() throws {
        let b = try bottle("Games")
        try FileManager.default.removeItem(at: b.settingsURL)
        XCTAssertEqual(BottleStore.settingsStamps(of: [b]), [:])
    }
}
