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

    // Wine's menu builder must never run: it writes shortcuts onto the macOS Desktop for every
    // installer (three of them appeared during the CrossOver-tree engine's first tests). The
    // user's own overrides still append after it.
    func testMenuBuilderDisabledOnEveryRenderer() throws {
        let (engine, bottle) = try fixtures()
        let env = try bottle.environment(engine: engine, renderer: .wined3d)
        XCTAssertEqual(env["WINEDLLOVERRIDES"], "winemenubuilder.exe=d", "present with no bottle overrides at all")
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
        XCTAssertEqual(env["WINEDLLOVERRIDES"], "version=n,b;winemenubuilder.exe=d", "the bottle's overrides sit in front of Highball's own")

        bottle.settings.environment["WINEDLLOVERRIDES+"] = "libglesv2=d"
        env = try bottle.environment(engine: engine, renderer: .wined3d)
        let v = env["WINEDLLOVERRIDES"] ?? ""
        XCTAssertTrue(v.contains("version=n,b") && v.contains("libglesv2=d"), "got \(v)")
        XCTAssertTrue(v.contains(";"), "WINEDLLOVERRIDES parts must be ';'-joined, got \(v)")
    }

    // The registry mirror (issues #22/#25) parses only real override syntax: multi-name
    // entries fan out, ".dll" is stripped, and pasted Proton launch options never leak
    // garbage value names into HKCU\Software\Wine\DllOverrides.
    func testDllOverridesRegistryParse() {
        func flat(_ s: String) -> [String] { WineRunner.parseDllOverrides(s).map { "\($0.name)=\($0.order)" } }
        XCTAssertEqual(flat("version=n,b"), ["version=n,b"])
        XCTAssertEqual(flat("dxgi,D3D9.dll=n"), ["dxgi=n", "d3d9=n"])
        XCTAssertEqual(flat("winmm="), ["winmm="])              // empty = disabled
        XCTAssertEqual(flat("libglesv2=d"), ["libglesv2=d"])    // explicit disable
        XCTAssertEqual(flat("version=native,builtin;winmm=b"), ["version=native,builtin", "winmm=b"])
        XCTAssertEqual(flat(#"WINEDLLOVERRIDES="version=n,b" %command%"#), [])
        XCTAssertEqual(flat("just some words"), [])
        XCTAssertEqual(flat(""), [])
    }

    // The generated dxvk.conf: global line follows the bottle toggle, and the [csgo.exe]
    // section (issue #21: legacy CS:GO map-load freeze) must come AFTER it — later lines
    // win in DXVK's parser — carrying async off, the 32-bit memory cap, and the device id.
    func testDxvkConfigContent() {
        let on = Bottle.dxvkConfig(async: true)
        XCTAssertTrue(on.contains("dxvk.enableAsync = True"))
        let section = on.range(of: "[csgo.exe]")
        let global = on.range(of: "dxvk.enableAsync = True")
        XCTAssertNotNil(section); XCTAssertNotNil(global)
        XCTAssertTrue(global!.lowerBound < section!.lowerBound, "global line must precede the per-app section")
        let tail = String(on[section!.lowerBound...])
        XCTAssertTrue(tail.contains("dxvk.enableAsync = False"))
        XCTAssertTrue(tail.contains("d3d9.maxAvailableMemory = 2048"))
        XCTAssertTrue(tail.contains("d3d9.customDeviceId = 73BF"))

        let off = Bottle.dxvkConfig(async: false)
        XCTAssertTrue(off.contains("dxvk.enableAsync = False"))
        XCTAssertFalse(off.contains("dxvk.enableAsync = True"))
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

        // DXVK renderer needs BOTH overlay dirs on disk: d9vk (D3D9) and dxvk (D3D10/11).
        let d9vkWine = engine.renderersDir.appending(path: "d9vk/wine")
        let dxvkWine = engine.renderersDir.appending(path: "dxvk/wine")
        try FileManager.default.createDirectory(at: d9vkWine, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dxvkWine, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: engine.root) }
        env = try bottle.environment(engine: engine, renderer: .dxvk)
        XCTAssertEqual(env["DXVK_FRAME_RATE"], "60")
        // The async toggle travels via the generated conf, never DXVK_ASYNC: the async fork
        // reads `env == "1" || config.enableAsync`, so an env 1 would defeat the per-game
        // [csgo.exe] override that issue #21 requires.
        XCTAssertNil(env["DXVK_ASYNC"], "async must ride the conf, not the env")
        XCTAssertEqual(env["DXVK_CONFIG_FILE"], #"C:\highball\dxvk.conf"#)
        // d9vk must come first so DXVK's d3d9 wins the builtin search over wined3d (#21 CSM gate).
        XCTAssertEqual(env["WINEDLLPATH_PREPEND"], "\(d9vkWine.path):\(dxvkWine.path)")
    }

    // A renderer whose overlay is missing must throw, not silently fall back.
    func testMissingRendererThrows() throws {
        let (engine, bottle) = try fixtures()
        XCTAssertThrowsError(try bottle.environment(engine: engine, renderer: .dxmt))
    }

    // .dxvk with the dxvk overlay present but d9vk (its D3D9) missing must throw — never
    // silently regress D3D9 to builtin wined3d, which is exactly the #21 CSM-gate failure.
    func testDxvkRequiresD9vkOverlay() throws {
        let (engine, bottle) = try fixtures()
        try FileManager.default.createDirectory(at: engine.renderersDir.appending(path: "dxvk/wine"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: engine.root) }
        XCTAssertThrowsError(try bottle.environment(engine: engine, renderer: .dxvk),
                             "dxvk present but d9vk missing must throw, not fall back to wined3d")
    }
}
