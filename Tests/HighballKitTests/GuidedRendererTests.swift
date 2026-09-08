import XCTest
@testable import HighballKit

/// Per-game graphics modes (the guided renderer trial, ux-plan item 1), the one resolution rule
/// for a launch, the native-Vulkan flag (#44), and the same-Wine engine auto-update (item 9).
final class GuidedRendererTests: XCTestCase {
    private var home: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "hb-guided-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func testOverridesPersistBesidePlaysAndSurviveOldFiles() throws {
        let store = LibraryStore(paths: HighballPaths(home: home))
        store.recordPlay(id: "steam:319510", bottle: "Games")
        XCTAssertEqual(store.rendererOverrides(), [:], "nothing chosen yet")
        store.setRendererOverride(.dxvk, for: "steam:319510")
        XCTAssertEqual(store.rendererOverrides(), ["steam:319510": .dxvk])
        XCTAssertNotNil(store.load()["steam:319510"], "setting a mode keeps the play record")
        store.setRendererOverride(nil, for: "steam:319510")
        XCTAssertEqual(store.rendererOverrides(), [:], "nil clears it")
        // A file from before overrides existed still loads.
        try #"{"formatVersion":1,"items":{"steam:400":{"lastPlayedAt":"2026-09-01T00:00:00Z","bottle":"Games"}}}"#
            .write(to: home.appending(path: "library.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(store.rendererOverrides(), [:])
        XCTAssertNotNil(store.load()["steam:400"])
    }

    func testPruneDropsOverridesOfGamesThatAreGone() {
        let store = LibraryStore(paths: HighballPaths(home: home))
        store.setRendererOverride(.wined3d, for: "steam:1")
        store.setRendererOverride(.dxmt, for: "steam:2")
        store.prune(validIDs: ["steam:2"])
        XCTAssertEqual(store.rendererOverrides(), ["steam:2": .dxmt])
    }

    func testTheResolutionRuleMostSpecificFirst() {
        XCTAssertEqual(Renderer.choose(requested: .dxmt, gameOverride: .dxvk, row: .d3dmetal, environmentExplicit: false, pin: .wined3d, environment: .dxvk), .dxmt, "the caller's choice wins")
        XCTAssertEqual(Renderer.choose(requested: nil, gameOverride: .dxvk, row: .d3dmetal, environmentExplicit: false, pin: nil, environment: .dxmt), .dxvk, "the game's own override beats the row")
        XCTAssertEqual(Renderer.choose(requested: nil, gameOverride: nil, row: .d3dmetal, environmentExplicit: false, pin: nil, environment: .dxmt), .d3dmetal, "the row applies")
        XCTAssertEqual(Renderer.choose(requested: nil, gameOverride: nil, row: .d3dmetal, environmentExplicit: true, pin: nil, environment: .dxmt), .dxmt, "an explicit environment choice silences the row")
        XCTAssertEqual(Renderer.choose(requested: nil, gameOverride: nil, row: nil, environmentExplicit: false, pin: .wined3d, environment: .dxmt), .wined3d, "a pinned program's own mode")
        XCTAssertEqual(Renderer.choose(requested: nil, gameOverride: .dxvk, row: .d3dmetal, environmentExplicit: false, pin: nil, environment: .dxmt, nativeVulkan: true), .dxmt, "a native-Vulkan title ignores rows and overrides")
    }

    func testNativeVulkanRowDecodesAndSpeaks() throws {
        let json = #"{"id":"sims","title":"The Sims Legacy Collection","steam_appid":3314060,"status":"verified-local","renderer":"dxvk","nativeVulkan":true}"#
        let entry = try JSONDecoder().decode(GameDBEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.nativeVulkan, true)
        let lines = GamePageCopy.willDo(entry, recipe: nil, applied: false, bottleRenderer: .dxmt)
        XCTAssertTrue(lines.first?.text.contains("draw with Vulkan directly") == true, "the page says the mode does not apply: \(lines.first?.text ?? "")")
        let plain = try JSONDecoder().decode(GameDBEntry.self, from: Data(#"{"id":"x","title":"X","status":"community"}"#.utf8))
        XCTAssertNil(plain.nativeVulkan)
        let chosen = GamePageCopy.willDo(plain, recipe: nil, applied: false, bottleRenderer: .dxmt, gameOverride: .dxvk)
        XCTAssertTrue(chosen.first?.text.contains("for this game (set by you)") == true, "a per-game choice is named as such: \(chosen.first?.text ?? "")")
    }

    func testSameWineUpdateMayApplyItselfAndADifferentWineMayNot() throws {
        func manifest(_ id: String, wine: String) throws -> EngineManifest {
            try JSONDecoder().decode(EngineManifest.self, from: Data("""
            {"id": "\(id)", "displayName": "x", "arch": "x86_64", "minMacOS": "14.0",
             "components": {"wine": {"kind": "engine", "url": "https://example.invalid/w.tar.gz", "sha256": "\(wine)"}}}
            """.utf8))
        }
        let r1 = try manifest("x64-sikarugir10.0_6-r1", wine: "same"), r2 = try manifest("x64-sikarugir10.0_6-r2", wine: "same")
        let wine11 = try manifest("x64-crossover26.3-r4", wine: "other")
        XCTAssertTrue(EngineStore.autoUpdateAllowed(from: r1, to: r2), "component-only update")
        XCTAssertFalse(EngineStore.autoUpdateAllowed(from: r1, to: wine11), "a different Wine waits for a click")
    }
}
