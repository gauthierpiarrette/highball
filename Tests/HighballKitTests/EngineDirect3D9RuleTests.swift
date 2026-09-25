import XCTest
@testable import HighballKit

/// An engine can say Direct3D 9 belongs to Wine's own Direct3D in the automatic modes
/// (`EngineManifest.direct3D9 == "wined3d"`): on the Wine 11 tree DXVK's d3d9 is the slow path
/// (highball#198). The explicit DXVK mode keeps DXVK's d3d9, since there it is the point (#21).
final class EngineDirect3D9RuleTests: XCTestCase {

    private func engine(direct3D9: String?) throws -> InstalledEngine {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spike/engine-manifest.json")
        var manifest = try EngineManifest.load(from: manifestURL)
        manifest.direct3D9 = direct3D9
        let root = FileManager.default.temporaryDirectory.appending(path: "hb-d3d9-engine-\(UUID().uuidString)")
        for dir in ["d9vk/wine", "dxvk/wine", "dxmt/wine"] {
            try FileManager.default.createDirectory(at: root.appending(path: "renderers/\(dir)"), withIntermediateDirectories: true)
        }
        return InstalledEngine(manifest: manifest, root: root)
    }

    func testAutomaticModeLeavesDirect3D9ToWineOnAFlaggedEngine() throws {
        let flagged = try engine(direct3D9: "wined3d")
        defer { try? FileManager.default.removeItem(at: flagged.root) }
        let bottle = Bottle(url: URL(fileURLWithPath: "/tmp/hb-d3d9-bottle"), settings: BottleSettings(name: "t", engineID: flagged.id))
        let env = try bottle.environment(engine: flagged, renderer: .dxmt)
        XCTAssertFalse(env["WINEDLLPATH_PREPEND"]!.contains("d9vk"), "DXMT on a flagged engine must not attach DXVK's d3d9: \(env["WINEDLLPATH_PREPEND"]!)")
        XCTAssertTrue(env["WINEDLLPATH_PREPEND"]!.contains("dxmt/wine"))
        // The explicit DXVK mode is untouched: both overlays, d9vk first.
        let dxvk = try bottle.environment(engine: flagged, renderer: .dxvk)
        XCTAssertEqual(dxvk["WINEDLLPATH_PREPEND"], "\(flagged.renderersDir.appending(path: "d9vk/wine").path):\(flagged.renderersDir.appending(path: "dxvk/wine").path)")
    }

    func testAnUnflaggedEngineStillAttachesDXVKsDirect3D9() throws {
        let plain = try engine(direct3D9: nil)
        defer { try? FileManager.default.removeItem(at: plain.root) }
        XCTAssertFalse(plain.direct3D9UsesWined3d)
        let bottle = Bottle(url: URL(fileURLWithPath: "/tmp/hb-d3d9-bottle"), settings: BottleSettings(name: "t", engineID: plain.id))
        let env = try bottle.environment(engine: plain, renderer: .dxmt)
        XCTAssertTrue(env["WINEDLLPATH_PREPEND"]!.hasSuffix(plain.renderersDir.appending(path: "d9vk/wine").path), "d9vk appended after the backend as before")
    }

    func testInstalledManifestsAdoptTheFlagFromTheBundledOneOnce() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "hb-d3d9-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = HighballPaths(home: home)
        let store = EngineStore(paths: paths)
        // Two installed engines: r11 without the flag (installed before the rule), r9 unaffected.
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spike/engine-manifest.json")
        var base = try EngineManifest.load(from: manifestURL)
        base.direct3D9 = nil
        for id in ["x64-crossover26.3-r11", "x64-sikarugir10.0_6-r9"] {
            var m = base; m.id = id
            let dir = paths.engine(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try m.save(to: dir.appending(path: "manifest.json"))
        }
        var known = base; known.id = "x64-crossover26.3-r11"; known.direct3D9 = "wined3d"
        XCTAssertEqual(store.adoptKnownFacts(known: [known]), ["x64-crossover26.3-r11"])
        XCTAssertTrue(try store.engine("x64-crossover26.3-r11").direct3D9UsesWined3d)
        XCTAssertFalse(try store.engine("x64-sikarugir10.0_6-r9").direct3D9UsesWined3d)
        XCTAssertEqual(store.adoptKnownFacts(known: [known]), [], "a second pass changes nothing")
    }

    func testShippedWine11ManifestsCarryTheRule() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spike/engines")
        for id in ["x64-crossover26.3-r11", "x64-crossover26.3-r12"] {
            let m = try EngineManifest.load(from: dir.appending(path: "\(id).json"))
            XCTAssertEqual(m.direct3D9, "wined3d", id)
        }
        // The default engine (Wine 10) keeps DXVK's d3d9: FNAF runs at 76 fps on it.
        let def = try EngineManifest.load(from: dir.deletingLastPathComponent().appending(path: "engine-manifest.json"))
        XCTAssertNil(def.direct3D9)
    }
}
