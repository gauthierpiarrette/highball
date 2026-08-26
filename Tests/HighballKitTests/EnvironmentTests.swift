import XCTest
@testable import HighballKit

/// The launch environment is where most field bugs lived (Steam's CEF hang, DLL
/// overrides, renderer overlays). These tests pin its composition rules.
final class EnvironmentTests: XCTestCase {

    private func fixtures() throws -> (engine: InstalledEngine, bottle: Bottle) {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spike/engine-manifest.json")
        let manifest = try EngineManifest.load(from: manifestURL)
        let root = FileManager.default.temporaryDirectory.appending(path: "hb-test-engine-\(UUID().uuidString)")
        let engine = InstalledEngine(manifest: manifest, root: root)
        let bottle = Bottle(url: URL(fileURLWithPath: "/tmp/hb-test-bottle"),
                            settings: BottleSettings(name: "t", engineID: manifest.id))
        return (engine, bottle)
    }

    // Steam's CEF webhelper hangs under msync/esync on Wine 10. sync=none must write
    // explicit zeros, not merely omit the variables.
    func testSyncNoneWritesExplicitZeros() throws {
        var (engine, bottle) = try fixtures()
        bottle.settings.sync = .none
        let env = try bottle.environment(engine: engine, renderer: .wined3d)
        XCTAssertEqual(env["WINEMSYNC"], "0")
        XCTAssertEqual(env["WINEESYNC"], "0")
    }

    func testSyncModes() throws {
        var (engine, bottle) = try fixtures()
        bottle.settings.sync = .msync
        var env = try bottle.environment(engine: engine, renderer: .wined3d)
        XCTAssertEqual(env["WINEMSYNC"], "1")
        XCTAssertEqual(env["WINEESYNC"], "0")
        bottle.settings.sync = .esync
        env = try bottle.environment(engine: engine, renderer: .wined3d)
        XCTAssertEqual(env["WINEESYNC"], "1")
        XCTAssertEqual(env["WINEMSYNC"], "0")
    }

    func testPrefixAndDebugAlwaysSet() throws {
        let (engine, bottle) = try fixtures()
        let env = try bottle.environment(engine: engine, renderer: .wined3d)
        XCTAssertEqual(env["WINEPREFIX"], "/tmp/hb-test-bottle")
        XCTAssertEqual(env["WINEDEBUG"], "fixme-all")
    }

    // Bottle-level DLL overrides (the #17 feature) reach WINEDLLOVERRIDES, and compose
    // with an override the user also set via the env editor, joined by ";".
    func testDllOverridesCompose() throws {
        var (engine, bottle) = try fixtures()
        bottle.settings.dllOverrides = "version=n,b"
        var env = try bottle.environment(engine: engine, renderer: .wined3d)
        XCTAssertEqual(env["WINEDLLOVERRIDES"], "version=n,b")

        bottle.settings.environment["WINEDLLOVERRIDES+"] = "libglesv2=d"
        env = try bottle.environment(engine: engine, renderer: .wined3d)
        let v = env["WINEDLLOVERRIDES"] ?? ""
        XCTAssertTrue(v.contains("version=n,b") && v.contains("libglesv2=d"), "got \(v)")
        XCTAssertTrue(v.contains(";"), "WINEDLLOVERRIDES parts must be ';'-joined, got \(v)")
    }

    // extra (per-pin environment from the program settings sheet) wins over bottle env.
    func testExtraEnvironmentWins() throws {
        var (engine, bottle) = try fixtures()
        bottle.settings.environment["MY_FLAG"] = "bottle"
        let env = try bottle.environment(engine: engine, renderer: .wined3d, extra: ["MY_FLAG": "pin"])
        XCTAssertEqual(env["MY_FLAG"], "pin")
    }

    func testTogglesAndFpsCap() throws {
        var (engine, bottle) = try fixtures()
        bottle.settings.metalHUD = true
        bottle.settings.advertiseAVX = true
        bottle.settings.fpsCap = 60
        var env = try bottle.environment(engine: engine, renderer: .wined3d)
        XCTAssertEqual(env["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(env["ROSETTA_ADVERTISE_AVX"], "1")
        XCTAssertNil(env["DXVK_FRAME_RATE"], "wined3d has no fps cap channel")

        // DXVK renderer needs its overlay dir on disk for environment() to succeed.
        let dxvkWine = engine.renderersDir.appending(path: "dxvk/wine")
        try FileManager.default.createDirectory(at: dxvkWine, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: engine.root) }
        env = try bottle.environment(engine: engine, renderer: .dxvk)
        XCTAssertEqual(env["DXVK_FRAME_RATE"], "60")
        XCTAssertEqual(env["DXVK_ASYNC"], "1", "dxvkAsync defaults on")
        XCTAssertEqual(env["WINEDLLPATH_PREPEND"], dxvkWine.path)
    }

    // A renderer whose overlay is missing must throw, not silently fall back.
    func testMissingRendererThrows() throws {
        let (engine, bottle) = try fixtures()
        XCTAssertThrowsError(try bottle.environment(engine: engine, renderer: .dxmt))
    }
}
