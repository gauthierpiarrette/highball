import XCTest
@testable import HighballKit

/// A recipe's file for a Steam game installed in another library (an external disk Steam knows
/// as D:) goes into the game's folder there. Before, it went into a folder of the same name on C
/// that the game never reads, so Portal 2 on an external disk kept HDR's freeze with its fix
/// applied, and CS:GO Legacy or RaceRoom launched without the d3d9.dll their recipes copy.
final class RecipeGameFolderTests: XCTestCase {
    private var tmp: URL!
    private let portal2 = "Program Files (x86)/Steam/steamapps/common/Portal 2/portal2/cfg/autoexec.cfg"

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appending(path: "hb-gamefolder-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func manifest(_ appid: Int, _ name: String, dir: String) -> String {
        "\"AppState\"\n{\n\t\"appid\"\t\t\"\(appid)\"\n\t\"name\"\t\t\"\(name)\"\n\t\"StateFlags\"\t\t\"4\"\n\t\"installdir\"\t\t\"\(dir)\"\n}\n"
    }

    /// An environment with Steam on C and a second library at D:\SteamLibrary.
    private func environment() throws -> (bottle: URL, driveC: URL, steam: URL, external: URL) {
        let bottle = tmp.appending(path: "bottle", directoryHint: .isDirectory)
        let steam = bottle.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let external = tmp.appending(path: "Disk/SteamLibrary", directoryHint: .isDirectory)
        try write("", to: steam.appending(path: "steam.exe"))
        let dosdevices = bottle.appending(path: "dosdevices", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dosdevices.appending(path: "c:").path, withDestinationPath: "../drive_c")
        try FileManager.default.createSymbolicLink(atPath: dosdevices.appending(path: "d:").path, withDestinationPath: tmp.appending(path: "Disk").path)
        try write("""
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"
        \t}
        \t"1"
        \t{
        \t\t"path"\t\t"D:\\\\SteamLibrary"
        \t}
        }
        """, to: steam.appending(path: "steamapps/libraryfolders.vdf"))
        try FileManager.default.createDirectory(at: external.appending(path: "steamapps"), withIntermediateDirectories: true)
        return (bottle, bottle.appending(path: "drive_c", directoryHint: .isDirectory), steam, external)
    }

    private func install(_ appid: Int, _ name: String, dir: String, in library: URL) throws {
        try write(manifest(appid, name, dir: dir), to: library.appending(path: "steamapps/appmanifest_\(appid).acf"))
        try write("", to: library.appending(path: "steamapps/common/\(dir)/game.exe"))
    }

    func testAFileForAGameOnAnotherLibraryGoesIntoItsFolder() throws {
        let env = try environment()
        try install(620, "Portal 2", dir: "Portal 2", in: env.external)
        let games = SteamLibrary.games(steamRoot: env.steam, bottleURL: env.bottle)
        let want = env.external.appending(path: "steamapps/common/Portal 2/portal2/cfg/autoexec.cfg").standardizedFileURL.path
        XCTAssertEqual(Recipe.target(of: portal2, driveC: env.driveC, steamGames: games).standardizedFileURL.path, want)
        // The old behaviour left a folder of that name on C for every game it missed; the
        // manifest still decides.
        try write("mat_hdr_level 0\n", to: env.driveC.appending(path: portal2))
        XCTAssertEqual(Recipe.target(of: portal2, driveC: env.driveC, steamGames: games).standardizedFileURL.path, want)
    }

    func testAGameInTheEnvironmentsOwnLibraryKeepsThePath() throws {
        let env = try environment()
        try install(620, "Portal 2", dir: "Portal 2", in: env.steam)
        let games = SteamLibrary.games(steamRoot: env.steam, bottleURL: env.bottle)
        XCTAssertEqual(games.map(\.appid), [620])
        XCTAssertEqual(Recipe.target(of: portal2, driveC: env.driveC, steamGames: games), env.driveC.appending(path: portal2))
    }

    func testAGameThatIsNotThereKeepsThePath() throws {
        let env = try environment()
        XCTAssertEqual(Recipe.target(of: portal2, driveC: env.driveC, steamGames: []), env.driveC.appending(path: portal2))
        // A manifest whose folder is gone (the disk holds the manifest of a deleted game).
        try write(manifest(620, "Portal 2", dir: "Portal 2"), to: env.external.appending(path: "steamapps/appmanifest_620.acf"))
        let games = SteamLibrary.games(steamRoot: env.steam, bottleURL: env.bottle)
        XCTAssertEqual(Recipe.target(of: portal2, driveC: env.driveC, steamGames: games), env.driveC.appending(path: portal2))
    }

    func testOtherPathsAreUntouched() throws {
        let env = try environment()
        try install(620, "Portal 2", dir: "Portal 2", in: env.external)
        let games = SteamLibrary.games(steamRoot: env.steam, bottleURL: env.bottle)
        for path in ["users/steamuser/Documents/My Games/x.ini",
                     "Program Files (x86)/Steam/steamapps/common/Portal 2",
                     "Program Files (x86)/Steam/steamapps/common/Portal 2/../../../../etc/x",
                     "Program Files (x86)/Steam/steamapps/common/../x/y"] {
            XCTAssertEqual(Recipe.target(of: path, driveC: env.driveC, steamGames: games), env.driveC.appending(path: path), path)
        }
    }

    func testTheFolderNameMatchesWhateverItsCase() throws {
        let env = try environment()
        try install(4465480, "Counter-Strike: Global Offensive", dir: "CSGO Legacy", in: env.external)
        let games = SteamLibrary.games(steamRoot: env.steam, bottleURL: env.bottle)
        let path = "Program Files (x86)/Steam/steamapps/common/csgo legacy/bin/d3d9.dll"
        XCTAssertEqual(Recipe.target(of: path, driveC: env.driveC, steamGames: games).standardizedFileURL.path,
                       env.external.appending(path: "steamapps/common/CSGO Legacy/bin/d3d9.dll").standardizedFileURL.path)
    }

    func testACopyInTheGamesFolderCountsAsPresent() throws {
        let env = try environment()
        try install(4465480, "Counter-Strike: Global Offensive", dir: "csgo legacy", in: env.external)
        let games = SteamLibrary.games(steamRoot: env.steam, bottleURL: env.bottle)
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data("""
        {"id": "csgo-legacy", "kind": "game", "title": "CS:GO", "steps": [
          {"type": "copy", "from": "engine/lib/wine/i386-windows/d3d9.dll", "to": "Program Files (x86)/Steam/steamapps/common/csgo legacy/bin/d3d9.dll", "asNative": true}]}
        """.utf8))
        XCTAssertFalse(recipe.artifactsPresent(driveC: env.driveC, steamGames: games), "not copied yet")
        try write("x", to: env.external.appending(path: "steamapps/common/csgo legacy/bin/d3d9.dll"))
        XCTAssertTrue(recipe.artifactsPresent(driveC: env.driveC, steamGames: games))
        XCTAssertFalse(recipe.artifactsPresent(driveC: env.driveC), "without the games, the path on C as before")
    }

    func testApplyWritesTheFileIntoTheGamesFolder() async throws {
        let env = try environment()
        try install(620, "Portal 2", dir: "Portal 2", in: env.external)
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spike/engine-manifest.json")
        let engineManifest = try EngineManifest.load(from: manifestURL)
        let engine = InstalledEngine(manifest: engineManifest, root: tmp.appending(path: "engine"))
        let bottle = Bottle(url: env.bottle, settings: BottleSettings(name: "t", engineID: engineManifest.id))
        let recipe = try JSONDecoder.highball.decode(Recipe.self, from: Data("""
        {"id": "portal-2", "kind": "game", "title": "Portal 2", "requires": ["steam"], "renderer": null,
         "steps": [{"type": "file", "path": "\(portal2)", "contents": "mat_hdr_level 2\\n"}],
         "knownIssues": [], "lastVerified": null}
        """.utf8))
        var runner = RecipeRunner(engine: engine, bottle: bottle)
        _ = try await runner.apply(recipe)
        let written = env.external.appending(path: "steamapps/common/Portal 2/portal2/cfg/autoexec.cfg")
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "mat_hdr_level 2\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.driveC.appending(path: "Program Files (x86)/Steam/steamapps/common/Portal 2").path),
                       "nothing written into a folder on C the game never reads")
        XCTAssertEqual(runner.bottle.settings.recipes, ["portal-2"])
    }
}
