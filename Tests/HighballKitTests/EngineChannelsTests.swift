import XCTest
@testable import HighballKit

/// The gate in front of engine lines that ship hidden. A wrong answer here would either hand a
/// preview engine to every player or hide it from the people testing it.
final class EngineChannelsTests: XCTestCase {
    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func manifest(id: String, channel: String?, minMacOS: String = "26.5") throws -> EngineManifest {
        var json: [String: Any] = ["id": id, "displayName": id, "arch": "arm64", "minMacOS": minMacOS, "components": [String: Any]()]
        if let channel { json["channel"] = channel }
        return try JSONDecoder().decode(EngineManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testNoChannelIsForEveryone() {
        XCTAssertTrue(EngineChannels.visible(channel: nil, beta: false, preview: false))
    }

    func testBetaNeedsBetaBuildsOrThePreviewKey() {
        XCTAssertFalse(EngineChannels.visible(channel: "beta", beta: false, preview: false))
        XCTAssertTrue(EngineChannels.visible(channel: "beta", beta: true, preview: false))
        XCTAssertTrue(EngineChannels.visible(channel: "beta", beta: false, preview: true))
    }

    func testPreviewNeedsThePreviewKeyEvenWithBetaBuilds() {
        XCTAssertFalse(EngineChannels.visible(channel: "preview", beta: true, preview: false))
        XCTAssertTrue(EngineChannels.visible(channel: "preview", beta: false, preview: true))
    }

    func testAnUnknownChannelStaysHidden() {
        XCTAssertFalse(EngineChannels.visible(channel: "previw", beta: true, preview: false))
        XCTAssertTrue(EngineChannels.visible(channel: "previw", beta: false, preview: true))
    }

    func testARecipePinnedToAHiddenEngineIsHiddenAndOthersAreNot() throws {
        let bundled = [try manifest(id: "arm64-line-r1", channel: "preview"), try manifest(id: "x64-line-r9", channel: nil)]
        XCTAssertTrue(EngineChannels.hidesPin("arm64-line-r1", bundled: bundled, beta: true, preview: false))
        XCTAssertFalse(EngineChannels.hidesPin("arm64-line-r1", bundled: bundled, beta: false, preview: true))
        XCTAssertFalse(EngineChannels.hidesPin("x64-line-r9", bundled: bundled, beta: false, preview: false))
        XCTAssertFalse(EngineChannels.hidesPin(nil, bundled: bundled, beta: false, preview: false))
        // A pin no bundled manifest carries keeps its own answer (Play asks for a Highball update).
        XCTAssertFalse(EngineChannels.hidesPin("x64-line-r10", bundled: bundled, beta: false, preview: false))
    }

    func testAPreviewEngineTakenForAGameIsSeenAndNoOtherIs() throws {
        let line = try manifest(id: "arm64-line-r1", channel: "preview")
        let other = try manifest(id: "arm64-line-r2", channel: "preview")
        let betaLine = try manifest(id: "x64-beta-r1", channel: "beta")
        XCTAssertTrue(EngineChannels.visible(line, beta: false, preview: false, optedIn: ["arm64-line-r1"]))
        XCTAssertFalse(EngineChannels.visible(other, beta: false, preview: false, optedIn: ["arm64-line-r1"]))
        // An opt-in reaches preview engines only: a beta line stays with beta builds.
        XCTAssertFalse(EngineChannels.visible(betaLine, beta: false, preview: false, optedIn: ["x64-beta-r1"]))
        XCTAssertFalse(EngineChannels.hidesPin("arm64-line-r1", bundled: [line], beta: false, preview: false, optedIn: ["arm64-line-r1"]))
        XCTAssertTrue(EngineChannels.hidesPin("arm64-line-r1", bundled: [line], beta: false, preview: false, optedIn: []))
    }

    func testPlayOffersAHiddenPreviewPinAndNothingElse() throws {
        let bundled = [try manifest(id: "arm64-line-r1", channel: "preview"), try manifest(id: "x64-line-r9", channel: nil),
                       try manifest(id: "x64-beta-r1", channel: "beta")]
        XCTAssertEqual(EngineChannels.previewToOffer(pin: "arm64-line-r1", bundled: bundled, beta: false, preview: false, optedIn: [])?.id,
                       "arm64-line-r1")
        // Seen already (the key, or taken once for a game): the usual engine ask takes over.
        XCTAssertNil(EngineChannels.previewToOffer(pin: "arm64-line-r1", bundled: bundled, beta: false, preview: true, optedIn: []))
        XCTAssertNil(EngineChannels.previewToOffer(pin: "arm64-line-r1", bundled: bundled, beta: false, preview: false,
                                                   optedIn: ["arm64-line-r1"]))
        XCTAssertNil(EngineChannels.previewToOffer(pin: "x64-line-r9", bundled: bundled, beta: false, preview: false, optedIn: []))
        XCTAssertNil(EngineChannels.previewToOffer(pin: "x64-beta-r1", bundled: bundled, beta: false, preview: false, optedIn: []))
        XCTAssertNil(EngineChannels.previewToOffer(pin: "x64-line-r10", bundled: bundled, beta: false, preview: false, optedIn: []))
        XCTAssertNil(EngineChannels.previewToOffer(pin: nil, bundled: bundled, beta: false, preview: false, optedIn: []))
    }

    private func recipe(engine: String) throws -> Recipe {
        let json = "{\"id\": \"game\", \"kind\": \"game\", \"title\": \"Game\", \"steps\": [], \"engine\": \"\(engine)\"}"
        return try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
    }

    /// Forza Horizon 6's route moved from arm64-kk r1 to r2 (2026-11-01): an environment on the route is offered the new
    /// revision the way one on a pinned preview recipe is, and one on the recipe's other route is not.
    func testAnEnvironmentOnARouteIsOfferedItsNewerRevision() throws {
        let r1 = try manifest(id: "arm64-line-r1", channel: "preview")
        let r2 = try manifest(id: "arm64-line-r2", channel: "preview")
        let x64 = try manifest(id: "x64-line-r18", channel: nil)
        let json = #"""
        {"id":"game","kind":"game","title":"Game","renderer":"d3dmetal","engine":"x64-line-r18",
         "steps":[{"type":"environment","name":"OLD","value":"1"}],
         "previewRoute":{"engine":"arm64-line-r2","renderer":"vkd3d",
           "steps":[{"type":"environment","name":"NEW","value":"1"}]}}
        """#
        let game = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
        let route = game.routed(onEngine: r1.id)
        XCTAssertTrue(route.isPreviewRoute)
        XCTAssertFalse(route.isOptIn, "Play's move ask skips opt-in recipes")
        XCTAssertEqual(route.previewRevisionToOffer(current: r1, known: [r1, r2, x64], macOS: "27.0")?.id, "arm64-line-r2")
        XCTAssertNil(game.routed(onEngine: r2.id).previewRevisionToOffer(current: r2, known: [r1, r2, x64], macOS: "27.0"))
        XCTAssertNil(game.routed(onEngine: x64.id).previewRevisionToOffer(current: x64, known: [r1, r2, x64], macOS: "27.0"))
    }

    /// Microsoft Flight Simulator 2024 set up on r3 while its recipe now pins r5 (2026-10-19): the environment runs the
    /// line already, so Play offers the move rather than the preview ask or a launch on r3.
    func testAnEnvironmentOnAnEarlierPreviewRevisionIsOfferedThePinnedOne() throws {
        let r3 = try manifest(id: "arm64-line-r3", channel: "preview")
        let r5 = try manifest(id: "arm64-line-r5", channel: "preview")
        let otherLine = try manifest(id: "arm64-other-r5", channel: "preview")
        let x64 = try manifest(id: "x64-line-r21", channel: nil)
        let x64Later = try manifest(id: "x64-line-r24", channel: nil)
        XCTAssertTrue(EngineChannels.runsLine(current: r3, of: r5))
        XCTAssertFalse(EngineChannels.runsLine(current: r3, of: otherLine))
        XCTAssertFalse(EngineChannels.runsLine(current: x64, of: r5))

        let game = try recipe(engine: "arm64-line-r5")
        XCTAssertEqual(game.previewRevisionToOffer(current: r3, known: [r3, r5], macOS: "27.0")?.id, "arm64-line-r5")
        XCTAssertNil(game.previewRevisionToOffer(current: r5, known: [r3, r5], macOS: "27.0"), "already on it")
        XCTAssertNil(game.previewRevisionToOffer(current: r3, known: [r3], macOS: "27.0"), "a revision this install does not see")
        XCTAssertNil(game.previewRevisionToOffer(current: otherLine, known: [otherLine, r5], macOS: "27.0"), "another line")
        // The line decides, not the channel the installed copy of the current engine's manifest carries.
        let r3Installed = try manifest(id: "arm64-line-r3", channel: nil)
        XCTAssertTrue(EngineChannels.runsLine(current: r3Installed, of: r5))
        XCTAssertEqual(game.previewRevisionToOffer(current: r3Installed, known: [r3, r5], macOS: "27.0")?.id, "arm64-line-r5")
        // A Wine 10 or Wine 11 environment never moves on its own, whatever its recipe pins.
        XCTAssertNil(try recipe(engine: "x64-line-r24").previewRevisionToOffer(current: x64, known: [x64, x64Later], macOS: "27.0"))
    }

    /// The arm64 line needs macOS 26.5 and the D3DMetal 4 revisions macOS 27. On an older macOS Play says so before any
    /// question or download, instead of offering an engine that cannot start there (2026-10-19).
    func testARecipeWhoseEngineNeedsANewerMacOSSaysWhichOne() throws {
        let r5 = try manifest(id: "arm64-line-r5", channel: "preview", minMacOS: "26.5")
        let game = try recipe(engine: "arm64-line-r5")
        XCTAssertEqual(game.engineMacOSFloor(bundled: [r5], macOS: "26.4.1"), "26.5")
        XCTAssertEqual(game.engineMacOSFloor(bundled: [r5], macOS: "15.7"), "26.5")
        XCTAssertNil(game.engineMacOSFloor(bundled: [r5], macOS: "26.5"))
        XCTAssertNil(game.engineMacOSFloor(bundled: [r5], macOS: "27.0.0"))
        let d3dmetal4 = try manifest(id: "x64-line-r18", channel: nil, minMacOS: "27.0")
        let d3dmetal4Later = try manifest(id: "x64-line-r24", channel: nil, minMacOS: "27.0")
        XCTAssertEqual(try recipe(engine: "x64-line-r18").engineMacOSFloor(bundled: [d3dmetal4, d3dmetal4Later], macOS: "26.6"), "27.0")
        XCTAssertNil(try recipe(engine: "x64-line-r18").engineMacOSFloor(bundled: [d3dmetal4, d3dmetal4Later], macOS: "27.0"))
        // A later revision that runs here is enough.
        let r6 = try manifest(id: "arm64-line-r6", channel: "preview", minMacOS: "26.0")
        XCTAssertNil(game.engineMacOSFloor(bundled: [r5, r6], macOS: "26.4"))
        // A pin the app does not ship keeps its own answer (engineUnknown), and no pin needs nothing.
        XCTAssertNil(try recipe(engine: "arm64-line-r9").engineMacOSFloor(bundled: [r5], macOS: "15.0"))
    }

    func testEveryEngineThePlayersHaveTodayHasNoChannel() throws {
        let dir = repo.appending(path: "spike/engines")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" } + [repo.appending(path: "spike/engine-manifest.json")]
        for file in files {
            let m = try EngineManifest.load(from: file)
            if m.isNativeARM64 { continue }
            XCTAssertNil(m.channel, "\(m.id) is an Intel engine players already have; a channel would hide it from them")
        }
    }
}
