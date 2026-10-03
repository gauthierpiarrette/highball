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

    func testOfferedUnlessTheEnvironmentAlreadySatisfiesIt() throws {
        let wine10 = try manifest(id: "x64-sikarugir10.0_6-r2", wine: "aaa")
        let wine11 = try manifest(id: "x64-crossover26.3-r4", wine: "bbb")
        let wine11Later = try manifest(id: "x64-crossover26.3-r5", wine: "bbb")
        let r = try recipe(engine: "x64-crossover26.3-r4")
        XCTAssertEqual(r.engineToOffer(current: wine10, known: [wine10, wine11])?.id, "x64-crossover26.3-r4")
        XCTAssertNil(r.engineToOffer(current: wine11, known: [wine10, wine11]), "already on it")
        XCTAssertNil(r.engineToOffer(current: wine11Later, known: [wine10, wine11]), "a later revision of the same Wine counts")
        XCTAssertNil(r.engineToOffer(current: wine10, known: [wine10]), "an engine the app does not know is never offered")
        XCTAssertNil(try recipe(engine: nil).engineToOffer(current: wine10, known: [wine10, wine11]))
    }

    /// A recipe can reach the database before the Highball that ships its engine (The Last
    /// Flame's r11 pin landed while 0.9.32 was the stable, highball#99). Play then must say
    /// "update" rather than launch on the old engine as if the recipe had never asked, and must
    /// stay quiet when the environment is already on that engine, whoever installed it.
    func testAnEngineThisBuildDoesNotShipAsksForAnUpdate() throws {
        let wine10 = try manifest(id: "x64-sikarugir10.0_6-r5", wine: "aaa")
        let r10 = try manifest(id: "x64-crossover26.3-r10", wine: "bbb")
        let r11 = try manifest(id: "x64-crossover26.3-r11", wine: "ccc")
        let r = try recipe(engine: "x64-crossover26.3-r11")
        XCTAssertNil(r.engineToOffer(current: wine10, known: [wine10, r10]), "nothing to offer: the build has no r11")
        XCTAssertEqual(r.engineUnknown(current: wine10, known: [wine10, r10]), "x64-crossover26.3-r11")
        XCTAssertNil(r.engineUnknown(current: wine10, known: [wine10, r10, r11]), "the build ships it: the engine ask handles it")
        XCTAssertNil(r.engineUnknown(current: r11, known: [wine10, r10]), "already on it (a newer Highball installed it)")
        XCTAssertNil(try recipe(engine: nil).engineUnknown(current: wine10, known: [wine10]))
    }

    /// r6 and r7 are the same Wine as r5, and a bottle on r5 still needs them: r6 changes
    /// MoltenVK (Red Dead), r7 adds a builtin DLL (CS:GO). Same Wine never meant "has it".
    func testALaterRevisionOfTheSameWineIsOffered() throws {
        let r5 = try manifest(id: "x64-crossover26.3-r5", wine: "bbb")
        let r7 = try manifest(id: "x64-crossover26.3-r7", wine: "bbb")
        let r = try recipe(engine: "x64-crossover26.3-r7")
        XCTAssertEqual(r.engineToOffer(current: r5, known: [r5, r7])?.id, "x64-crossover26.3-r7")
        XCTAssertNil(r.engineToOffer(current: r7, known: [r5, r7]))
        XCTAssertEqual(EngineManifest.revision(of: "x64-crossover26.3-r7"), 7)
        XCTAssertNil(EngineManifest.revision(of: "x64-crossover26.3"))
        XCTAssertFalse(EngineManifest.needsPrefixRefresh(from: r5, to: r7), "same Wine, no component asks: the prefix stays")
    }

    /// Red Dead's recipe pins r7, the revision it was verified on. Highball 0.10.2 offered a new
    /// player on the default engine exactly r7, five revisions behind the Wine 11 engine it
    /// shipped, with the msync leak and without the x87 and LastError fixes, and a non-default
    /// engine never moves on its own (highball-db#272). The offer is the newest shipped revision
    /// that carries the pin, skipping one this Mac cannot run.
    func testTheNewestRevisionCarryingThePinIsOffered() throws {
        let wine10 = try manifest(id: "x64-sikarugir10.0_6-r17", wine: "aaa")
        let r7 = try manifest(id: "x64-crossover26.3-r7", wine: "bbb")
        let r12 = try manifest(id: "x64-crossover26.3-r12", wine: "ccc")
        let r13 = try manifest(id: "x64-crossover26.3-r13", wine: "ccc")
        let r = try recipe(engine: "x64-crossover26.3-r7")
        XCTAssertEqual(r.engineToOffer(current: wine10, known: [r13, wine10, r7, r12])?.id, r13.id)
        XCTAssertNil(r.engineToOffer(current: r7, known: [wine10, r7, r12, r13]), "already on the pin, it stays")
        XCTAssertEqual(r.engineToOffer(current: wine10, known: [wine10, r7])?.id, r7.id, "the pin itself when nothing newer ships")
        let tall = try JSONDecoder().decode(EngineManifest.self, from: Data("""
        {"id": "x64-crossover26.3-r14", "displayName": "t", "arch": "x86_64", "minMacOS": "28.0",
         "components": {"wine": {"kind": "engine", "url": "https://example.invalid/ccc.tar.gz", "sha256": "ccc", "size": 1000}}}
        """.utf8))
        XCTAssertEqual(r.engineToOffer(current: wine10, known: [wine10, r7, r13, tall], macOS: "27.0")?.id, r13.id, "a revision this Mac cannot run is skipped")
    }

    /// r12 rebuilt Wine with more patches than r11, and a bottle on r12 was offered r11 for The
    /// Last Flame's pin, a downgrade. A later revision of the line counts whatever its Wine
    /// digest, and an earlier bottle is still offered the pin.
    func testALaterRevisionThatRebuiltWineIsNotOfferedTheEarlierOne() throws {
        let r11 = try manifest(id: "x64-crossover26.3-r11", wine: "ccc")
        let r12 = try manifest(id: "x64-crossover26.3-r12", wine: "ddd")
        let r10 = try manifest(id: "x64-crossover26.3-r10", wine: "bbb")
        let wine10 = try manifest(id: "x64-sikarugir10.0_6-r13", wine: "aaa")
        let r = try recipe(engine: "x64-crossover26.3-r11")
        XCTAssertNil(r.engineToOffer(current: r12, known: [wine10, r10, r11, r12]), "r12 carries r11")
        XCTAssertEqual(r.engineToOffer(current: r10, known: [wine10, r10, r11, r12])?.id, r12.id, "the newest revision carrying the pin")
        XCTAssertEqual(r.engineToOffer(current: wine10, known: [wine10, r10, r11, r12])?.id, r12.id, "another line")
        XCTAssertNil(r.engineUnknown(current: r12, known: [wine10, r12]), "a build without r11 on a bottle past it asks for nothing")
        XCTAssertEqual(r.engineUnknown(current: r10, known: [wine10, r10]), r11.id)
        XCTAssertEqual(EngineManifest.line(of: "x64-sikarugir10.0_6-r14"), "x64-sikarugir10.0_6")
        XCTAssertNil(EngineManifest.line(of: "x64-crossover26.3"))
    }

    /// The Wine 10 tree has two lines under one id: the GPTK 4 revisions (r6, r14) add a
    /// D3DMetal component the default ones (r5, r13) lack. A default bottle at a higher
    /// revision must not pass for GPTK 4, while a GPTK 4 bottle carries everything the default has.
    func testALaterRevisionMustCarryEveryComponentOfThePin() throws {
        func engine(_ id: String, _ names: [String]) throws -> EngineManifest {
            let comps = names.map { "\"\($0)\": {\"kind\": \"renderer\", \"url\": \"https://example.invalid/\($0).tar.gz\", \"sha256\": \"\($0)\", \"size\": 1}" }
            let json = """
            {"id": "\(id)", "displayName": "Wine 10.0 (test)", "arch": "x86_64", "minMacOS": "14.0",
             "components": {"wine": {"kind": "engine", "url": "https://example.invalid/aaa.tar.gz", "sha256": "aaa", "size": 1000}\(comps.isEmpty ? "" : ", " + comps.joined(separator: ", "))}}
            """
            return try JSONDecoder().decode(EngineManifest.self, from: Data(json.utf8))
        }
        let def13 = try engine("x64-sikarugir10.0_6-r13", ["dxmt"])
        let gptk6 = try engine("x64-sikarugir10.0_6-r6", ["dxmt", "d3dmetal"])
        let gptk14 = try engine("x64-sikarugir10.0_6-r14", ["dxmt", "d3dmetal"])
        let def5 = try engine("x64-sikarugir10.0_6-r5", ["dxmt"])
        XCTAssertEqual(try recipe(engine: gptk6.id).engineToOffer(current: def13, known: [def5, gptk6, def13, gptk14])?.id, gptk14.id,
                       "the newest GPTK 4 revision, never the default line's higher number")
        XCTAssertNil(try recipe(engine: gptk6.id).engineToOffer(current: gptk14, known: [def5, gptk6, def13, gptk14]))
        XCTAssertNil(try recipe(engine: def5.id).engineToOffer(current: gptk14, known: [def5, gptk6, def13, gptk14]))
        XCTAssertNil(try recipe(engine: def5.id).engineToOffer(current: def13, known: [def5, gptk6, def13, gptk14]))
    }

    /// Every pin in the database checked against every engine this build ships: a bottle on a
    /// later revision of the pinned line is never offered an earlier one.
    func testNoShippedEngineIsOfferedAnEarlierRevisionOfItsOwnLine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appending(path: "spike/engines")
        var known = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try EngineManifest.load(from: $0) }
        known.append(try EngineManifest.load(from: root.appending(path: "spike/engine-manifest.json")))
        for current in known {
            for wanted in known where wanted.id != current.id {
                guard let offered = try recipe(engine: wanted.id).engineToOffer(current: current, known: known),
                      EngineManifest.line(of: offered.id) == EngineManifest.line(of: current.id),
                      Set(offered.components.keys).isSubset(of: current.components.keys) else { continue }
                XCTAssertGreaterThan(EngineManifest.revision(of: offered.id) ?? 0, EngineManifest.revision(of: current.id) ?? 0,
                                     "\(current.id) is offered the earlier \(offered.id)")
            }
        }
    }

    /// A component that adds a builtin DLL asks for the Windows setup to run again, so the
    /// bottle gets the DLL's placeholder in syswow64 (a game loading it by system path finds
    /// nothing otherwise). The same Wine build is no reason to skip that.
    func testAComponentCanAskForThePrefixRefresh() throws {
        let json = """
        {"id": "x64-crossover26.3-r7", "displayName": "Wine 11.0 (test)", "arch": "x86_64", "minMacOS": "14.0",
         "components": {"wine": {"kind": "engine", "url": "https://example.invalid/bbb.tar.gz", "sha256": "bbb", "size": 1000},
                        "nvapi-stub": {"kind": "runtime", "url": "https://example.invalid/stub.tar.gz", "sha256": "ccc", "size": 10, "refreshesPrefix": true}}}
        """
        let r7 = try JSONDecoder().decode(EngineManifest.self, from: Data(json.utf8))
        let r6 = try manifest(id: "x64-crossover26.3-r6", wine: "bbb")
        XCTAssertTrue(EngineManifest.needsPrefixRefresh(from: r6, to: r7))
        XCTAssertFalse(EngineManifest.needsPrefixRefresh(from: r7, to: r7), "the stub is already there")
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

    /// The EA recipe in the sibling database checkout names the bundled Wine 11 engine at the top
    /// level (a `lastVerified.engine` alone is provenance, not a requirement: that is exactly what
    /// let the first screen check install straight onto Wine 10).
    func testTheEARecipeInTheDatabaseNamesTheBundledWine11Engine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let recipeURL = root.deletingLastPathComponent().appending(path: "highball-db/recipes/launchers/ea-app.json")
        guard FileManager.default.fileExists(atPath: recipeURL.path) else { throw XCTSkip("no highball-db checkout beside the repo") }
        let ea = try Recipe.load(from: recipeURL)
        let def = try EngineManifest.load(from: root.appending(path: "spike/engine-manifest.json"))
        let wine11 = try EngineManifest.load(from: root.appending(path: "spike/engines/x64-crossover26.3-r4.json"))
        XCTAssertEqual(ea.engine, wine11.id)
        XCTAssertEqual(ea.engineToOffer(current: def, known: [def, wine11])?.id, wine11.id, "installing the EA app on the default engine offers Wine 11")
        XCTAssertNil(ea.engineToOffer(current: wine11, known: [def, wine11]))
    }

    func testFreeBottleName() {
        XCTAssertEqual(BottleStore.freeName("EA app", taken: []), "EA app")
        XCTAssertEqual(BottleStore.freeName("EA app", taken: ["EA app"]), "EA app 2")
        XCTAssertEqual(BottleStore.freeName("EA app", taken: ["EA app", "EA app 2"]), "EA app 3")
    }
}
