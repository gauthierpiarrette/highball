import XCTest
@testable import HighballKit

/// Issue #61: a bottle set to D3DMetal on an engine that carries the files but has no licence
/// accepted for them died at launch with "missing: d3dmetal renderer … (optional component not
/// installed?)", the message was wrong, and nothing offered a way out short of a new bottle.
/// A renderer the engine cannot run must be reported for what it is, a bottle-level setting
/// must degrade to a mode that runs, and a recipe must not install such a setting.
final class RendererAvailabilityTests: XCTestCase {
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
        try Data("pe".utf8).write(to: real.appending(path: "x86_64-windows/d3d12.dll"))
        try Data("so".utf8).write(to: real.appending(path: "x86_64-unix/d3d12.so"))
        let shim = e.root.appending(path: "renderers/d3dmetal-tsshim/wine")
        try fm.createDirectory(at: shim.appending(path: "x86_64-windows"), withIntermediateDirectories: true)
        try Data("shim".utf8).write(to: shim.appending(path: "x86_64-windows/d3d12.dll"))

        let env = try bottle(renderer: .d3dmetal).environment(engine: e)
        XCTAssertTrue(env["WINEDLLPATH_PREPEND"]?.hasPrefix(shim.path) == true, "the shim overlay comes first: \(env["WINEDLLPATH_PREPEND"] ?? "")")
        XCTAssertTrue(env["WINEDLLPATH_PREPEND"]?.contains("/d3dmetal/wine") == true, "D3DMetal itself stays on the path")
        XCTAssertEqual(try String(contentsOf: shim.appending(path: "x86_64-windows/d3d12_d3dmetal.dll"), encoding: .utf8), "pe",
                       "the real PE sits beside the shim under a name of its own")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: shim.appending(path: "x86_64-unix/d3d12_d3dmetal.so").path),
                       real.appending(path: "x86_64-unix/d3d12.so").path, "and its Mach-O half is a link, not a copy")
        XCTAssertEqual(env["HB_D3D12_REAL"], "Z:" + shim.path.replacingOccurrences(of: "/", with: "\\") + "\\x86_64-windows\\d3d12_d3dmetal.dll",
                       "the shim gets the real one's Windows path")
        _ = try bottle(renderer: .d3dmetal).environment(engine: e)   // a second launch changes nothing

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
        let without = try engine(ships: ["dxmt", "dxvk", "d9vk"], accepted: false)
        XCTAssertEqual(Renderer.vkd3d.availability(in: without), .notShipped)
        XCTAssertThrowsError(try Renderer.vkd3d.environment(engine: without))
        XCTAssertEqual(Renderer.fallback(for: .vkd3d, in: e), .dxmt, "a bottle set to it degrades to the default, never to another DirectX 12 route")
        XCTAssertFalse(Renderer.fallbackOrder.contains(.vkd3d), "never a fallback for other modes")
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
