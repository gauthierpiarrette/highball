import XCTest
@testable import HighballKit

/// Issue #61: a bottle set to D3DMetal on an engine that carries the files but has no licence
/// accepted for them died at launch with "missing: d3dmetal renderer … (optional component not
/// installed?)", the message was wrong, and nothing offered a way out short of a new bottle.
/// A renderer the engine cannot run must be reported for what it is, a bottle-level setting
/// must degrade to a mode that runs, and a recipe must not install such a setting.
final class RendererAvailabilityTests: EnglishCopyTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "hb-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func manifest() throws -> EngineManifest {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spike/engine-manifest.json")
        return try EngineManifest.load(from: url)
    }

    /// An engine like the shipped one: the runtime template carries every renderer, D3DMetal
    /// included; `accepted` decides whether the licence is on record.
    private func engine(ships: [String] = ["dxmt", "dxvk", "d9vk", "d3dmetal"], accepted: Bool) throws -> InstalledEngine {
        var m = try manifest()
        m.acceptedLicenses = accepted ? [EngineManifest.gatedRenderers["d3dmetal"]!] : nil
        // Each engine gets its own root: one test builds several, and files from a full engine
        // must not leak into the one that is meant to lack a renderer.
        let engineRoot = root.appending(path: UUID().uuidString)
        for name in ships {
            try FileManager.default.createDirectory(at: engineRoot.appending(path: "frameworks/renderer/\(name)/wine"), withIntermediateDirectories: true)
        }
        return InstalledEngine(manifest: m, root: engineRoot)
    }

    private func bottle(renderer: Renderer, explicit: Bool = false) -> Bottle {
        var b = Bottle(url: URL(fileURLWithPath: "/tmp/hb-test-bottle-61"), settings: BottleSettings(name: "t", engineID: "e"))
        b.settings.renderer = renderer
        b.settings.rendererExplicit = explicit
        return b
    }

    // MARK: A new environment's mode

    func testANewEnvironmentStartsOnTheFirstModeItsEngineRuns() throws {
        XCTAssertEqual(Renderer.defaultMode(for: try engine(accepted: false)), .dxmt, "every Intel engine keeps DXMT")
        XCTAssertEqual(Renderer.defaultMode(for: try engine(ships: ["dxvk", "vkd3d"], accepted: false)), .dxvk,
                       "no DXMT (the arm64 line): DXVK, not a DXMT setting that degrades at every launch")
        XCTAssertEqual(Renderer.defaultMode(for: try engine(ships: [], accepted: false)), .wined3d)
    }

    // MARK: Direct3D 12-only programs (highball#139)

    func testADirect3D12OnlyProgramGetsAModeThatHasIt() throws {
        let full = try engine(accepted: true)
        XCTAssertEqual(Renderer.forDirect3D12Only(chosen: .dxmt, engine: full), .d3dmetal)
        XCTAssertEqual(Renderer.forDirect3D12Only(chosen: .dxvk, engine: full), .d3dmetal)
        XCTAssertEqual(Renderer.forDirect3D12Only(chosen: .wined3d, engine: full), .d3dmetal)
        XCTAssertEqual(Renderer.forDirect3D12Only(chosen: .d3dmetal, engine: full), .d3dmetal, "already serves it")
        XCTAssertEqual(Renderer.forDirect3D12Only(chosen: .vkd3d, engine: full), .vkd3d, "already serves it")
        // The licence still to accept is the caller's ask, not a reason to pick something else.
        XCTAssertEqual(Renderer.forDirect3D12Only(chosen: .dxmt, engine: try engine(accepted: false)), .d3dmetal)
        // No D3DMetal at all: vkd3d when the engine carries it, else the choice stands and the
        // launch fails the way it did.
        XCTAssertEqual(Renderer.forDirect3D12Only(chosen: .dxmt, engine: try engine(ships: ["dxmt", "dxvk", "d9vk", "vkd3d"], accepted: true)), .vkd3d)
        XCTAssertEqual(Renderer.forDirect3D12Only(chosen: .dxmt, engine: try engine(ships: ["dxmt", "dxvk", "d9vk"], accepted: true)), .dxmt)
    }

    /// Forza Horizon 6 imports Direct3D 12 and no other graphics API, its row says D3DMetal, and on
    /// an environment set to DXMT by hand Play launched it on DXMT, where it stalled (0.10.9 release
    /// pass, M4, 2026-10-06). The environment's explicit mode stands for every game it can run.
    func testAnExplicitEnvironmentModeGivesWayOnlyToAProgramItCannotRun() throws {
        let full = try engine(accepted: true)
        func takeOver(chosen: Renderer = .dxmt, requested: Renderer? = nil, gameOverride: Renderer? = nil, row: Renderer?,
                      explicit: Bool, nativeVulkan: Bool = false, needs12: Bool, engine: InstalledEngine? = nil) -> Renderer? {
            Renderer.direct3D12TakeOver(chosen: chosen, requested: requested, gameOverride: gameOverride, row: row,
                                        environmentExplicit: explicit, nativeVulkan: nativeVulkan, engine: engine ?? full,
                                        programNeedsDirect3D12: { needs12 })
        }
        // The case of the pass: explicit DXMT, the row's D3DMetal, a Direct3D 12-only program.
        XCTAssertEqual(takeOver(row: .d3dmetal, explicit: true, needs12: true), .d3dmetal)
        // The row's own Direct3D 12 mode is preferred over the generic choice.
        XCTAssertEqual(takeOver(row: .vkd3d, explicit: true, needs12: true, engine: try engine(ships: ["dxmt", "dxvk", "d9vk", "d3dmetal", "vkd3d"], accepted: true)), .vkd3d)
        // A row without Direct3D 12 does not stop the switch when the environment overrode it.
        XCTAssertEqual(takeOver(row: .dxvk, explicit: true, needs12: true), .d3dmetal)
        // A program with another graphics path keeps the environment's explicit mode: the promise stands.
        XCTAssertNil(takeOver(row: .d3dmetal, explicit: true, needs12: false))
        // Without a row the switch was already made for an explicit environment (highball#139).
        XCTAssertEqual(takeOver(row: nil, explicit: true, needs12: true), .d3dmetal)
        XCTAssertEqual(takeOver(row: nil, explicit: false, needs12: true), .d3dmetal)
        // A row that chose (environment on Automatic) stands, whatever it says.
        XCTAssertNil(takeOver(row: .dxvk, explicit: false, needs12: true))
        // A choice for this game alone always stands, and so does a native Vulkan title.
        XCTAssertNil(takeOver(requested: .dxmt, row: .d3dmetal, explicit: true, needs12: true))
        XCTAssertNil(takeOver(gameOverride: .dxmt, row: .d3dmetal, explicit: true, needs12: true))
        XCTAssertNil(takeOver(row: .d3dmetal, explicit: true, nativeVulkan: true, needs12: true))
        // A chosen mode with Direct3D 12 never switches.
        XCTAssertNil(takeOver(chosen: .d3dmetal, row: .d3dmetal, explicit: true, needs12: true))
        // An engine with no Direct3D 12 mode at all: nothing to switch to, the launch fails as before.
        XCTAssertNil(takeOver(row: .d3dmetal, explicit: true, needs12: true, engine: try engine(ships: ["dxmt", "dxvk", "d9vk"], accepted: true)))
        // The import check is the expensive part: it is not asked when something else decides.
        var asked = false
        _ = Renderer.direct3D12TakeOver(chosen: .dxmt, requested: nil, gameOverride: .dxmt, row: .d3dmetal, environmentExplicit: true,
                                        nativeVulkan: false, engine: full, programNeedsDirect3D12: { asked = true; return true })
        XCTAssertFalse(asked, "a per-game choice decides without reading the program")
    }

    // MARK: Availability

    func testAvailabilityTellsLicenceFromAbsence() throws {
        let unaccepted = try engine(accepted: false)
        XCTAssertEqual(Renderer.d3dmetal.availability(in: unaccepted), .needsLicence("apple-gptk-license-2023-08-17"))
        XCTAssertEqual(Renderer.dxmt.availability(in: unaccepted), .available)
        XCTAssertEqual(Renderer.wined3d.availability(in: unaccepted), .available, "Wine's own D3D is always there")
        let accepted = try engine(accepted: true)
        XCTAssertEqual(Renderer.d3dmetal.availability(in: accepted), .available)
        let without = try engine(ships: ["dxmt", "dxvk", "d9vk"], accepted: true)
        XCTAssertEqual(Renderer.d3dmetal.availability(in: without), .notShipped, "an accepted licence does not conjure files")
    }

    func testReasonsNameTheActionNotAMissingComponent() throws {
        let why = Renderer.d3dmetal.unavailableReason(in: try engine(accepted: false))!
        XCTAssertTrue(why.contains("licence"), why)
        XCTAssertTrue(why.contains("Review licence") || why.contains("accept"), why)
        XCTAssertFalse(why.contains("not installed"), "the files are there; saying otherwise sent #61 to reinstalling")
        let none = Renderer.d3dmetal.unavailableReason(in: try engine(ships: ["dxmt"], accepted: true))!
        XCTAssertTrue(none.contains("engine"), none)
        XCTAssertNil(Renderer.dxmt.unavailableReason(in: try engine(accepted: false)))
    }

    func testFallbackPrefersTheDefaultThenVulkanThenWine() throws {
        XCTAssertEqual(Renderer.fallback(for: .d3dmetal, in: try engine(accepted: false)), .dxmt)
        XCTAssertEqual(Renderer.fallback(for: .d3dmetal, in: try engine(ships: ["dxvk", "d9vk"], accepted: false)), .dxvk)
        XCTAssertEqual(Renderer.fallback(for: .d3dmetal, in: try engine(ships: [], accepted: false)), .wined3d)
        XCTAssertEqual(Renderer.fallback(for: .dxmt, in: try engine(ships: ["dxvk", "d9vk"], accepted: false)), .dxvk, "never the mode that failed")
    }

    // MARK: A launch

    func testBottleSettingDegradesWithANoteAndAnExplicitRequestRefuses() throws {
        let e = try engine(accepted: false)
        let b = bottle(renderer: .d3dmetal)
        let (r, note) = try b.effectiveRenderer(requested: nil, engine: e)
        XCTAssertEqual(r, .dxmt)
        XCTAssertNotNil(note)
        XCTAssertTrue(note!.contains("DXMT") || note!.contains("dxmt"), note!)
        XCTAssertThrowsError(try b.effectiveRenderer(requested: .d3dmetal, engine: e)) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("licence"), text)
            XCTAssertFalse(text.contains("not installed"), text)
        }
        let fine = try b.effectiveRenderer(requested: nil, engine: try engine(accepted: true))
        XCTAssertEqual(fine.renderer, .d3dmetal)
        XCTAssertNil(fine.note)
    }

    /// A game's recipe asks for athei's x87sidecar with HB_X87SIDECAR=1 (highball#165), and the
    /// launch gets ROSETTA_X87_PATH only where the engine ships the sidecar.
    func testTheX87SidecarIsSetOnlyForAGameThatAsksAndAnEngineThatShipsIt() throws {
        let e = try engine(accepted: false)
        var asks = bottle(renderer: .dxmt)
        asks.settings.environment = ["HB_X87SIDECAR": "1"]
        XCTAssertNil(try asks.environment(engine: e)["ROSETTA_X87_PATH"], "no sidecar in this engine")
        let tool = e.root.appending(path: "x87sidecar/x87sidecar")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tool.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(try asks.environment(engine: e)["ROSETTA_X87_PATH"], tool.path)
        XCTAssertNil(try bottle(renderer: .dxmt).environment(engine: e)["ROSETTA_X87_PATH"], "a game that doesn't ask")
        var stale = bottle(renderer: .dxmt)
        stale.settings.environment = ["ROSETTA_X87_PATH": "/somewhere/else"]
        XCTAssertNil(try stale.environment(engine: e)["ROSETTA_X87_PATH"], "only the switch sets it")
    }

    func testEnvironmentFollowsTheDegradedRendererInsteadOfThrowing() throws {
        let e = try engine(accepted: false)
        let env = try bottle(renderer: .d3dmetal).environment(engine: e)
        XCTAssertNil(env["CX_D3DMETALPATH"], "no D3DMetal variables when it is not running")
        XCTAssertTrue(env["WINEDLLPATH_PREPEND"]?.contains("/dxmt/") == true, "the fallback's overlay is on the path")
        XCTAssertThrowsError(try bottle(renderer: .dxmt).environment(engine: e, renderer: .d3dmetal), "an explicit request stays strict")
    }

    // MARK: D3DMetal timestamp shim (#63)

    func testTimestampShimGoesInFrontOfD3DMetalWithTheRealFilesBesideIt() throws {
        let e = try engine(accepted: true)
        let fm = FileManager.default
        let real = e.root.appending(path: "frameworks/renderer/d3dmetal/wine")
        try fm.createDirectory(at: real.appending(path: "x86_64-windows"), withIntermediateDirectories: true)
        try fm.createDirectory(at: real.appending(path: "x86_64-unix"), withIntermediateDirectories: true)
        try SyntheticPE.make(exportName: "d3d12.dll").write(to: real.appending(path: "x86_64-windows/d3d12.dll"))
        try Data("so".utf8).write(to: real.appending(path: "x86_64-unix/d3d12.so"))
        let shim = e.root.appending(path: "renderers/d3dmetal-tsshim/wine")
        try fm.createDirectory(at: shim.appending(path: "x86_64-windows"), withIntermediateDirectories: true)
        try fm.createDirectory(at: shim.appending(path: "x86_64-unix"), withIntermediateDirectories: true)
        try Data("shim".utf8).write(to: shim.appending(path: "x86_64-windows/d3d12.dll"))
        // The 0.9.0 layout, which Wine 11 resolved back to the shim: it must go.
        try Data("old".utf8).write(to: shim.appending(path: "x86_64-windows/d3d12_d3dmetal.dll"))
        try fm.createSymbolicLink(at: shim.appending(path: "x86_64-unix/d3d12_d3dmetal.so"), withDestinationURL: real.appending(path: "x86_64-unix/d3d12.so"))

        let env = try bottle(renderer: .d3dmetal).environment(engine: e)
        XCTAssertTrue(env["WINEDLLPATH_PREPEND"]?.hasPrefix(shim.path) == true, "the shim overlay comes first: \(env["WINEDLLPATH_PREPEND"] ?? "")")
        XCTAssertTrue(env["WINEDLLPATH_PREPEND"]?.contains("/d3dmetal/wine") == true, "D3DMetal itself stays on the path")
        let copy = shim.appending(path: "x86_64-windows/apd12.dll")
        XCTAssertEqual(PEExportName.read(try Data(contentsOf: copy)), "apd12.dll",
                       "the real PE sits beside the shim under a name of its own, inside and out")
        XCTAssertEqual(try Data(contentsOf: copy).count, SyntheticPE.make(exportName: "d3d12.dll").count, "same bytes otherwise")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: shim.appending(path: "x86_64-unix/apd12.so").path),
                       real.appending(path: "x86_64-unix/d3d12.so").path, "and its Mach-O half is a link, not a copy")
        XCTAssertEqual(env["HB_D3D12_REAL"], "Z:" + shim.path.replacingOccurrences(of: "/", with: "\\") + "\\x86_64-windows\\apd12.dll",
                       "the shim gets the real one's Windows path")
        XCTAssertFalse(fm.fileExists(atPath: shim.appending(path: "x86_64-windows/d3d12_d3dmetal.dll").path), "the colliding layout is removed")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: shim.appending(path: "x86_64-unix/d3d12_d3dmetal.so").path))
        let stamp = try fm.attributesOfItem(atPath: copy.path)[.modificationDate] as? Date
        _ = try bottle(renderer: .d3dmetal).environment(engine: e)   // a second launch changes nothing
        XCTAssertEqual(try fm.attributesOfItem(atPath: copy.path)[.modificationDate] as? Date, stamp, "the copy is not rewritten every launch")

        let plain = try engine(accepted: true)
        let env2 = try bottle(renderer: .d3dmetal).environment(engine: plain)
        XCTAssertFalse(env2["WINEDLLPATH_PREPEND"]?.contains("tsshim") == true, "no shim shipped, no shim on the path")
        XCTAssertNil(env2["HB_D3D12_REAL"])
    }

    // MARK: DirectX 12 through Vulkan

    /// The vkd3d-proton route (#63): its overlay carries DXGI, D3D11 and D3D12 together, native
    /// first, and the switches that let both libraries start on MoltenVK. Absent from an engine
    /// that lacks the overlay, and never a general fallback.
    func testVkd3dEnvironmentAndAvailability() throws {
        let e = try engine(ships: ["dxmt", "dxvk", "d9vk", "vkd3d"], accepted: false)
        XCTAssertEqual(Renderer.vkd3d.availability(in: e), .available)
        let env = try Renderer.vkd3d.environment(engine: e)
        XCTAssertTrue(env["WINEDLLPATH_PREPEND"]!.contains("/vkd3d/wine"), "the overlay leads the search path")
        XCTAssertTrue(env["WINEDLLPATH_PREPEND"]!.contains("/d9vk/wine"), "D3D9 still comes from DXVK")
        XCTAssertEqual(env["WINEDLLOVERRIDES+"], "dxgi,d3d11,d3d10core,d3d12,d3d12core=n,b")
        XCTAssertEqual(env["VKD3D_FEATURE_LEVEL"], "12_0")
        XCTAssertEqual(env["VKD3D_SHADER_MODEL"], "6_6")
        XCTAssertEqual(env["VKD3D_RELAX_DEVICE_CAPS"], "1")
        XCTAssertEqual(env["DXVK_RELAX_FEATURES"], "1")
        XCTAssertEqual(env["VKD3D_SHADER_CACHE_PATH"], "C:\\highball\\cache\\vkd3d\\" + e.manifest.vkd3dCacheKey,
                       "B2: the pipeline cache lives in the prefix, one folder per engine build")
        let without = try engine(ships: ["dxmt", "dxvk", "d9vk"], accepted: false)
        XCTAssertEqual(Renderer.vkd3d.availability(in: without), .notShipped)
        XCTAssertThrowsError(try Renderer.vkd3d.environment(engine: without))
        XCTAssertEqual(Renderer.fallback(for: .vkd3d, in: e), .dxmt, "a bottle set to it degrades to the default, never to another DirectX 12 route")
        XCTAssertFalse(Renderer.fallbackOrder.contains(.vkd3d), "never a fallback for other modes")
    }

    /// A variable the bottle carries, from a recipe or the player, outranks the route's declared
    /// defaults: Microsoft Flight Simulator 2024 asks for Shader Model 6.7 and its recipe says so,
    /// and the first launch through the app had it replaced by the route's 6_6 (2026-10-15).
    func testBottleVariablesOutrankTheRouteDefaults() throws {
        let e = try engine(ships: ["dxmt", "dxvk", "d9vk", "vkd3d"], accepted: false)
        var b = bottle(renderer: .vkd3d, explicit: true)
        b.settings.environment["VKD3D_SHADER_MODEL"] = "6_7"
        b.settings.environment["VKD3D_FEATURE_LEVEL"] = "12_1"
        let env = try b.environment(engine: e)
        XCTAssertEqual(env["VKD3D_SHADER_MODEL"], "6_7")
        XCTAssertEqual(env["VKD3D_FEATURE_LEVEL"], "12_1")
        XCTAssertEqual(env["VKD3D_RELAX_DEVICE_CAPS"], "1", "the route's other defaults still apply")
        XCTAssertTrue(env["WINEDLLOVERRIDES"]!.contains("d3d12core=n,b"), "the composed entries still compose")
        XCTAssertTrue(env["WINEDLLPATH_PREPEND"]!.contains("/vkd3d/wine"))
    }

    /// B2: a pipeline cache compiled by one MoltenVK build and read by another gave wrong or hung
    /// pipelines on the arm64 line. The key follows every component's checksum, so a rebuilt
    /// component (same version, new patch) starts a new cache, and nothing else moves it.
    func testVkd3dCacheKeyFollowsTheComponentsBuild() throws {
        let m = try manifest()
        XCTAssertEqual(m.vkd3dCacheKey, try manifest().vkd3dCacheKey, "stable for one build")
        XCTAssertTrue(m.vkd3dCacheKey.hasPrefix(m.id + "-"))
        XCTAssertEqual(m.vkd3dCacheKey.count, m.id.count + 9)
        var rebuilt = m
        let name = m.components.keys.sorted().last!
        rebuilt.components[name]!.sha256 = String(repeating: "0", count: 64)
        XCTAssertNotEqual(rebuilt.vkd3dCacheKey, m.vkd3dCacheKey, "a rebuilt component starts a new cache")
        var renamed = m
        renamed.displayName = "Something else"
        renamed.notes = ["a note"]
        XCTAssertEqual(renamed.vkd3dCacheKey, m.vkd3dCacheKey, "only the binaries count")
    }

    func testALaunchMakesItsCacheFolderAndDropsOtherBuildsCaches() throws {
        let fm = FileManager.default
        let b = Bottle(url: root.appending(path: "bottle"), settings: BottleSettings(name: "t", engineID: "e"))
        let stale = b.vkd3dCacheRoot.appending(path: "old-engine-12345678")
        try fm.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stale.appending(path: "vkd3d-proton.cache"))
        b.prepareVkd3dCache(environment: ["VKD3D_SHADER_CACHE_PATH": "C:\\highball\\cache\\vkd3d\\new-engine-abcdef01"])
        XCTAssertTrue(fm.fileExists(atPath: b.vkd3dCacheRoot.appending(path: "new-engine-abcdef01").path))
        XCTAssertFalse(fm.fileExists(atPath: stale.path), "another build's cache is removed")

        let kept = b.vkd3dCacheRoot.appending(path: "new-engine-abcdef01/vkd3d-proton.cache")
        try Data("y".utf8).write(to: kept)
        b.prepareVkd3dCache(environment: ["VKD3D_SHADER_CACHE_PATH": "C:\\highball\\cache\\vkd3d\\new-engine-abcdef01"])
        XCTAssertTrue(fm.fileExists(atPath: kept.path), "the current build's cache survives the next launch")

        b.prepareVkd3dCache(environment: ["VKD3D_SHADER_CACHE_PATH": "C:\\games\\cache"])
        b.prepareVkd3dCache(environment: [:])
        XCTAssertTrue(fm.fileExists(atPath: kept.path), "a path a recipe set elsewhere, or none, touches nothing")
    }

    func testSuggestionOffersTheOtherDirectX12RouteAfterAppleFails() {
        XCTAssertEqual(Renderer.suggestion(after: .d3dmetal, vkd3dAvailable: true), .vkd3d)
        XCTAssertEqual(Renderer.suggestion(after: .d3dmetal, vkd3dAvailable: false), .dxvk)
        XCTAssertEqual(Renderer.suggestion(after: .vkd3d), .dxvk)
        XCTAssertEqual(Renderer.suggestion(after: .dxmt, d3dmetalAvailable: false, vkd3dAvailable: true), .vkd3d, "no licence, but the other DirectX 12 route exists")
    }

    // MARK: The ask

    func testAskCopySaysWhereTheSettingCameFromWhenNoRowNeedsIt() {
        let fromEnvironment = GamePageCopy.d3dMetalAsk(title: "Deliver At All Costs Demo", entry: nil)
        XCTAssertTrue(fromEnvironment.contains("environment"), fromEnvironment)
        XCTAssertTrue(fromEnvironment.contains("DXMT"), "the way out is named")
        XCTAssertFalse(fromEnvironment.contains("nothing else to try"), "that sentence belongs to rows with no working alternative")
    }

    // MARK: A recipe

    func testRecipeDoesNotSetAModeTheEngineCannotRun() {
        let settings = BottleSettings(name: "t", engineID: "e")
        XCTAssertEqual(RecipeRunner.rendererToApply(recipeRenderer: .d3dmetal, settings: settings, available: true), .d3dmetal)
        XCTAssertNil(RecipeRunner.rendererToApply(recipeRenderer: .d3dmetal, settings: settings, available: false), "#61: the recipe's mode must not outlive what the engine can do")
        var explicit = settings; explicit.renderer = .dxvk; explicit.rendererExplicit = true
        XCTAssertNil(RecipeRunner.rendererToApply(recipeRenderer: .d3dmetal, settings: explicit, available: true), "#29 still holds")
    }
}
