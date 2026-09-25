import XCTest
@testable import HighballKit

/// A game recipe's environment step belongs to that game, not to the bottle (highball#198: the
/// Sims recipe's MVK_SHADOW_IMPORT=1, applied bottle-wide, broke DXVK's Direct3D 9 for every
/// other game on the Wine 11 engines). Launchers and tweaks keep the bottle-wide scope.
final class RecipeScopeTests: XCTestCase {

    private func recipe(_ json: String) throws -> Recipe {
        try JSONDecoder.highball.decode(Recipe.self, from: Data(json.utf8))
    }

    private func fixtures() throws -> (engine: InstalledEngine, bottle: Bottle) {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spike/engine-manifest.json")
        let manifest = try EngineManifest.load(from: manifestURL)
        let root = FileManager.default.temporaryDirectory.appending(path: "hb-scope-engine-\(UUID().uuidString)")
        let dir = FileManager.default.temporaryDirectory.appending(path: "hb-scope-bottle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bottle = Bottle(url: dir, settings: BottleSettings(name: "t", engineID: manifest.id))
        return (InstalledEngine(manifest: manifest, root: root), bottle)
    }

    private let sims = """
    {"id": "the-sims-legacy-collection", "kind": "game", "title": "The Sims", "requires": ["steam"],
     "renderer": null, "steps": [{"type": "environment", "name": "MVK_SHADOW_IMPORT", "value": "1"}],
     "knownIssues": [], "lastVerified": null}
    """
    private let launcher = """
    {"id": "ea-app", "kind": "launcher", "title": "EA app", "requires": [],
     "renderer": null, "steps": [{"type": "environment", "name": "DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN", "value": "1"}],
     "knownIssues": [], "lastVerified": null}
    """

    func testGameRecipeVariableIsScopedToTheGame() async throws {
        let (engine, bottle) = try fixtures()
        var runner = RecipeRunner(engine: engine, bottle: bottle)
        _ = try await runner.apply(try recipe(sims))
        XCTAssertEqual(runner.bottle.settings.gameEnvironment["the-sims-legacy-collection"], ["MVK_SHADOW_IMPORT": "1"])
        XCTAssertNil(runner.bottle.settings.environment["MVK_SHADOW_IMPORT"], "must not reach every program in the bottle")
        // The launch for that game carries it; a launch for anything else does not.
        XCTAssertEqual(runner.bottle.settings.environment(forGame: "the-sims-legacy-collection")["MVK_SHADOW_IMPORT"], "1")
        XCTAssertEqual(runner.bottle.settings.environment(forGame: "five-nights-at-freddys"), [:])
        XCTAssertEqual(runner.bottle.settings.environment(forGame: nil), [:])
        let saved = try JSONDecoder.highball.decode(BottleSettings.self, from: Data(contentsOf: bottle.url.appending(path: "bottle.json")))
        XCTAssertEqual(saved.gameEnvironment["the-sims-legacy-collection"]?["MVK_SHADOW_IMPORT"], "1", "survives a save and load")
    }

    func testLauncherRecipeVariableStaysBottleWide() async throws {
        let (engine, bottle) = try fixtures()
        var runner = RecipeRunner(engine: engine, bottle: bottle)
        _ = try await runner.apply(try recipe(launcher))
        XCTAssertEqual(runner.bottle.settings.environment["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN"], "1")
        XCTAssertTrue(runner.bottle.settings.gameEnvironment.isEmpty)
    }

    func testLaunchEnvironmentMergesTheGamesVariablesLast() throws {
        var (engine, bottle) = try fixtures()
        bottle.settings.gameEnvironment["the-sims-legacy-collection"] = ["MVK_SHADOW_IMPORT": "1"]
        let sims = try bottle.environment(engine: engine, renderer: .wined3d, extra: bottle.settings.environment(forGame: "the-sims-legacy-collection"))
        XCTAssertEqual(sims["MVK_SHADOW_IMPORT"], "1")
        let other = try bottle.environment(engine: engine, renderer: .wined3d, extra: bottle.settings.environment(forGame: "five-nights-at-freddys"))
        XCTAssertNil(other["MVK_SHADOW_IMPORT"])
    }

    func testLeakedVariableMovesToTheGameOnce() throws {
        var settings = BottleSettings(name: "t", engineID: "e")
        settings.environment = ["MVK_SHADOW_IMPORT": "1", "MY_OWN": "x"]
        settings.recipes = ["the-sims-legacy-collection"]
        let r = try recipe(sims)
        XCTAssertEqual(Recipe.scopeLeakedEnvironment(of: r, in: &settings), ["MVK_SHADOW_IMPORT"])
        XCTAssertEqual(settings.environment, ["MY_OWN": "x"])
        XCTAssertEqual(settings.gameEnvironment["the-sims-legacy-collection"], ["MVK_SHADOW_IMPORT": "1"])
        XCTAssertEqual(Recipe.scopeLeakedEnvironment(of: r, in: &settings), [], "nothing left to move")
        // A value the owner changed by hand is not the recipe's and stays where they put it.
        var edited = BottleSettings(name: "t", engineID: "e")
        edited.environment = ["MVK_SHADOW_IMPORT": "0"]
        XCTAssertEqual(Recipe.scopeLeakedEnvironment(of: r, in: &edited), [])
        XCTAssertEqual(edited.environment["MVK_SHADOW_IMPORT"], "0")
        // A launcher's variable never moves.
        var l = BottleSettings(name: "t", engineID: "e")
        l.environment = ["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN": "1"]
        XCTAssertEqual(Recipe.scopeLeakedEnvironment(of: try recipe(launcher), in: &l), [])
    }

    func testSteamRestartsWhenTheClientCarriesAnotherGamesVariable() {
        var settings = BottleSettings(name: "t", engineID: "e")
        settings.gameEnvironment["the-sims-legacy-collection"] = ["MVK_SHADOW_IMPORT": "1"]
        XCTAssertEqual(settings.customEnvironmentKeys, ["MVK_SHADOW_IMPORT"])
        let base = ["WINEDLLPATH_PREPEND": "/r/dxvk/wine", "WINEMSYNC": "1", "WINEESYNC": "0"]
        // The client was started for the Sims; the next game does not set the variable.
        let live = base.merging(["MVK_SHADOW_IMPORT": "1"]) { $1 }
        let why = SteamRestart.reason(live: live, wanted: base, wantedRenderer: "dxvk", custom: settings.customEnvironmentKeys)
        XCTAssertEqual(why, "it runs with MVK_SHADOW_IMPORT=1 and the game does not set it")
        // The other way round: a client started for another game, and now the Sims want it.
        let wanted = base.merging(["MVK_SHADOW_IMPORT": "1"]) { $1 }
        XCTAssertEqual(SteamRestart.reason(live: base, wanted: wanted, wantedRenderer: "dxvk", custom: settings.customEnvironmentKeys + ["MVK_SHADOW_IMPORT"]), // named twice, reported once
                       "it runs without MVK_SHADOW_IMPORT=1")
        // Same variables both sides: nothing to restart for.
        XCTAssertNil(SteamRestart.reason(live: live, wanted: wanted, wantedRenderer: "dxvk", custom: settings.customEnvironmentKeys))
    }
}
