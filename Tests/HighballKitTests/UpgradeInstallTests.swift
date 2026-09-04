import XCTest
@testable import HighballKit

/// The upgrade contract (issue #21, 0.8.0): a build must see the install the previous build
/// left behind. An environment that is not the default name, holding an installed Steam game,
/// written in the on-disk shape of the previous release, has to list as a real (not damaged)
/// environment, its game has to be found, and the library has to show it. Every first-run
/// script wipes the home, so this is the one place the *existing user* is the subject.
final class UpgradeInstallTests: XCTestCase {
    private var home: URL!
    private var paths: HighballPaths!

    override func setUp() {
        home = FileManager.default.temporaryDirectory.appending(path: "hb-upgrade-\(UUID().uuidString)")
        paths = HighballPaths(home: home)
        try? FileManager.default.createDirectory(at: paths.bottles, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    /// The exact shape 0.8.0 writes for a bottle (every key it emits), frozen. If a decoder
    /// change ever refuses this, every 0.8 user's environment turns "damaged" on update.
    static let bottleJSON_0_8 = """
    {
      "advertiseAVX" : false,
      "commandIsControl" : true,
      "commandIsControlSynced" : true,
      "created" : "2026-08-23T16:45:00Z",
      "dllOverrides" : "",
      "dpiScale" : 96,
      "dxvkAppConfig" : {},
      "dxvkAsync" : false,
      "engineID" : "x64-sikarugir10.0_6-r1",
      "environment" : {},
      "formatVersion" : 3,
      "fpsCap" : 0,
      "metalHUD" : false,
      "name" : "CS",
      "pins" : [],
      "recipes" : ["steam"],
      "renderer" : "dxmt",
      "rendererExplicit" : false,
      "sync" : "msync",
      "windowsVersion" : "win10"
    }
    """

    /// A 0.7-era install: `gin.json`, format 1, only the keys that version wrote.
    static let ginJSON_0_7 = """
    {"formatVersion":1,"name":"CS","engineID":"x64-sikarugir10.0_6-r0","renderer":"dxmt","recipes":["steam"]}
    """

    private func seed(name: String, settingsFile: String, json: String, appid: Int = 240,
                      game: String = "Counter-Strike: Source") throws -> URL {
        let bottle = paths.bottles.appending(path: name)
        let steam = bottle.appending(path: "drive_c/Program Files (x86)/Steam")
        let steamapps = steam.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: steamapps.appending(path: "common/\(game)"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bottle.appending(path: "drive_c/windows"), withIntermediateDirectories: true)
        try Data().write(to: steam.appending(path: "steam.exe"))
        try json.write(to: bottle.appending(path: settingsFile), atomically: true, encoding: .utf8)
        let acf = """
        "AppState"
        {
        \t"appid"\t\t"\(appid)"
        \t"name"\t\t"\(game)"
        \t"installdir"\t\t"\(game)"
        \t"StateFlags"\t\t"4"
        \t"SizeOnDisk"\t\t"5000000000"
        }
        """
        try acf.write(to: steamapps.appending(path: "appmanifest_\(appid).acf"), atomically: true, encoding: .utf8)
        return bottle
    }

    private func assertSeen(_ file: StaticString = #filePath, line: UInt = #line) throws {
        let store = BottleStore(paths: paths)
        let bottles = try store.list()
        XCTAssertEqual(bottles.map(\.name), ["CS"], "the environment lists under its own name", file: file, line: line)
        XCTAssertTrue(try store.damaged().isEmpty, "and is not reported as damaged", file: file, line: line)
        guard let cs = bottles.first else { return }
        let games = SteamLibrary.games(in: cs)
        XCTAssertEqual(games.map(\.appid), [240], "its installed game is found", file: file, line: line)
        XCTAssertTrue(games.first?.isReady == true, file: file, line: line)
        let items = LibraryIndex.build(bottles: bottles, steamByBottle: ["CS": games], epicOwned: [], epicInstalls: [:])
        XCTAssertEqual(items.count, 1, "and the library shows it", file: file, line: line)
        XCTAssertEqual(items.first?.title, "Counter-Strike: Source", file: file, line: line)
        XCTAssertTrue(items.first?.installed == true, file: file, line: line)
    }

    func testAn08InstallIsStillSeen() throws {
        _ = try seed(name: "CS", settingsFile: "bottle.json", json: Self.bottleJSON_0_8)
        try assertSeen()
    }

    func testA07InstallIsStillSeen() throws {
        _ = try seed(name: "CS", settingsFile: "gin.json", json: Self.ginJSON_0_7)
        try assertSeen()
    }

    /// What this build writes today must read back tomorrow: a round trip through the real
    /// encoder, so a new field with no default cannot slip in unnoticed.
    func testTodaysEncoderOutputReadsBack() throws {
        let settings = BottleSettings(name: "CS", engineID: "x64-sikarugir10.0_6-r1")
        let data = try JSONEncoder.highball.encode(settings)
        let bottle = try seed(name: "CS", settingsFile: "bottle.json", json: String(decoding: data, as: UTF8.self))
        XCTAssertNoThrow(try Bottle.load(bottle))
        try assertSeen()
    }

    /// The failure mode from the field: a settings file that cannot be read must surface as a
    /// damaged environment, never silently vanish (the library then points at Troubleshooting
    /// instead of telling the user to prepare a new environment).
    func testAnUnreadableSettingsFileIsReportedNotHidden() throws {
        _ = try seed(name: "CS", settingsFile: "bottle.json", json: "{ not json")
        let store = BottleStore(paths: paths)
        XCTAssertTrue(try store.list().isEmpty)
        let damaged = try store.damaged()
        XCTAssertEqual(damaged.map(\.name), ["CS"])
        XCTAssertTrue(damaged.first?.reason.contains("bottle.json") == true, "names the settings file: \(damaged.first?.reason ?? "")")
    }
}
