import XCTest
@testable import HighballKit

/// A recipe that names an engine (the EA app needs the Wine 11 tree, #60) is offered that engine
/// only when the environment's Wine build differs. A wrong answer either downloads 440 MB for
/// nothing or lets the installer fail the way #60 did.
final class RecipeEngineTests: XCTestCase {
    private func manifest(id: String, wine: String) throws -> EngineManifest {
        let json = """
        {"id": "\(id)", "displayName": "Wine 11.0 (test tree) + DXMT", "arch": "x86_64", "minMacOS": "14.0",
         "components": {"wine": {"kind": "engine", "url": "https://example.invalid/\(wine).tar.gz", "sha256": "\(wine)", "size": 1000}}}
        """
        return try JSONDecoder().decode(EngineManifest.self, from: Data(json.utf8))
    }

    private func recipe(engine: String?) throws -> Recipe {
        let field = engine.map { ", \"engine\": \"\($0)\"" } ?? ""
        let json = "{\"id\": \"ea-app\", \"kind\": \"launcher\", \"title\": \"EA app\", \"steps\": []\(field)}"
        return try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
    }

    func testRecipeDecodesTheEngineItNeeds() throws {
        XCTAssertEqual(try recipe(engine: "x64-crossover26.3-r4").engine, "x64-crossover26.3-r4")
        XCTAssertNil(try recipe(engine: nil).engine)
    }

    func testOfferedOnlyWhenTheWineBuildDiffers() throws {
        let wine10 = try manifest(id: "x64-sikarugir10.0_6-r2", wine: "aaa")
        let wine11 = try manifest(id: "x64-crossover26.3-r4", wine: "bbb")
        let wine11Later = try manifest(id: "x64-crossover26.3-r5", wine: "bbb")
        let r = try recipe(engine: "x64-crossover26.3-r4")
        XCTAssertEqual(r.engineToOffer(current: wine10, known: [wine10, wine11])?.id, "x64-crossover26.3-r4")
        XCTAssertNil(r.engineToOffer(current: wine11, known: [wine10, wine11]), "already on it")
        XCTAssertNil(r.engineToOffer(current: wine11Later, known: [wine10, wine11]), "a later build of the same Wine counts")
        XCTAssertNil(r.engineToOffer(current: wine10, known: [wine10]), "an engine the app does not know is never offered")
        XCTAssertNil(try recipe(engine: nil).engineToOffer(current: wine10, known: [wine10, wine11]))
    }

    func testTheShippedWine11ManifestIsOfferedByTheEARecipeOnTheDefaultEngine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let def = try EngineManifest.load(from: root.appending(path: "spike/engine-manifest.json"))
        let wine11 = try EngineManifest.load(from: root.appending(path: "spike/engines/x64-crossover26.3-r4.json"))
        XCTAssertNil(wine11.acceptedLicenses, "a shipped manifest records no acceptance")
        XCTAssertTrue(EngineManifest.needsPrefixRefresh(from: def, to: wine11), "different Wine builds")
        let r = try recipe(engine: wine11.id)
        XCTAssertEqual(r.engineToOffer(current: def, known: [def, wine11])?.id, wine11.id)
        XCTAssertNotNil(wine11.components["d3dmetal-tsshim"], "the timestamp shim rides along on every engine with D3DMetal")
    }

    func testFreeBottleName() {
        XCTAssertEqual(BottleStore.freeName("EA app", taken: []), "EA app")
        XCTAssertEqual(BottleStore.freeName("EA app", taken: ["EA app"]), "EA app 2")
        XCTAssertEqual(BottleStore.freeName("EA app", taken: ["EA app", "EA app 2"]), "EA app 3")
    }
}
