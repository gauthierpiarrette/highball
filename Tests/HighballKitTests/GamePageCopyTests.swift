import XCTest
@testable import HighballKit

final class GamePageCopyTests: XCTestCase {
    private func entry(_ json: String) throws -> GameDBEntry {
        try JSONDecoder().decode(GameDBEntry.self, from: Data(json.utf8))
    }
    private let today = Date(timeIntervalSince1970: 1_788_480_000)   // 2026-09-04 UTC-ish

    func testVerifiedOnAnotherChipNamesTheGap() throws {
        let e = try entry(#"{"id":"x","title":"X","steam_appid":1,"status":"verified-local","lastVerified":"2026-08-23","verified":{"chip":"Apple M4 Pro","macos":"26","fps":"60 to 82"}}"#)
        let v = GamePageCopy.verdict(e, myChip: "Apple M1 Pro", today: today)
        XCTAssertEqual(v.headline, "Verified on an M4 Pro.")
        XCTAssertEqual(v.detail, "60 to 82 frames per second on macOS 26, last confirmed 12 days ago. Your Mac is an M1 Pro.")
    }

    func testVerifiedOnTheSameChipSaysSo() throws {
        let e = try entry(#"{"id":"x","title":"X","steam_appid":1,"status":"verified-local","lastVerified":"2026-09-04","verified":{"chip":"Apple M1 Pro","macos":"26.6.2","fps":"about 70"}}"#)
        let v = GamePageCopy.verdict(e, myChip: "Apple M1 Pro", today: today)
        XCTAssertEqual(v.headline, "Verified on an M1 Pro, the same chip as yours.")
        XCTAssertEqual(v.detail, "About 70 frames per second on macOS 26.6.2, last confirmed today.")
    }

    func testVerifiedWithoutStructuredFactsStaysHonest() throws {
        let e = try entry(#"{"id":"x","title":"X","steam_appid":1,"status":"verified-local","lastVerified":"2026-05-01"}"#)
        let v = GamePageCopy.verdict(e, myChip: "Apple M1 Pro", today: today)
        XCTAssertEqual(v.headline, "Verified on this project's own Mac.")
        XCTAssertEqual(v.detail, "Last confirmed on 2026-05-01.")
    }

    func testNoRowIsAnInvitation() {
        let v = GamePageCopy.verdict(nil, myChip: "Apple M2", today: today)
        XCTAssertEqual(v.headline, "Nobody has tested this on an M2 yet.")
    }

    func testBlockedNamesTheAntiCheat() throws {
        let e = try entry(#"{"id":"x","title":"X","steam_appid":1,"status":"blocked-anticheat","anticheat":{"names":["Vanguard"],"macVerdict":"blocked","note":"kernel driver"}}"#)
        XCTAssertEqual(GamePageCopy.verdict(e, myChip: "Apple M1", today: today).headline, "Can't run: Vanguard.")
    }

    func testWillDoListsRendererArgsAndRecipeSteps() throws {
        let e = try entry(#"{"id":"x","title":"X","steam_appid":1,"status":"verified-local","renderer":"dxmt","launchArgs":["-windowed"]}"#)
        let recipe = Recipe(id: "x", kind: .game, title: "X fix", steps: [
            .winetricks(verbs: ["vcrun2022"], slow: "about a minute"),
            .environment(name: "MVK_SHADOW_IMPORT", value: "1"),
            .note("Alt-tab twice if the window stays black"),
        ])
        let items = GamePageCopy.willDo(e, recipe: recipe, applied: false, bottleRenderer: .dxvk, osMajor: 26)
        XCTAssertEqual(items.map(\.text), [
            "Use DXMT (DirectX 11 on Metal) for this game, the way it was verified, instead of the environment's DXVK (Vulkan on Metal)",
            "Start it with -windowed",
            "Install vcrun2022",
            "Set MVK_SHADOW_IMPORT for this game",
            "Alt-tab twice if the window stays black",
        ])
        XCTAssertEqual(items[2].cost, "about a minute")
        let done = GamePageCopy.willDo(e, recipe: recipe, applied: true, bottleRenderer: .dxmt, osMajor: 26)
        XCTAssertEqual(done[0].text, "Use DXMT (DirectX 11 on Metal), the way it was verified")
        XCTAssertTrue(done[2].done); XCTAssertNil(done[2].cost)
    }
}

extension GamePageCopyTests {
    func testD3DMetalAskConsequenceComesFromTheRow() throws {
        let only = try entry(#"{"id":"x","title":"X","steam_appid":1,"status":"verified-local","renderer":"d3dmetal"}"#)
        XCTAssertTrue(GamePageCopy.d3dMetalAsk(title: "X", entry: only).contains("no other graphics mode"))
        XCTAssertNil(GamePageCopy.otherWorkingRenderer(only))
        let alt = try entry(#"{"id":"x","title":"X","steam_appid":1,"status":"verified-local","renderer":"d3dmetal","rendererResults":{"dxvk":{"verdict":"works","detail":"slower"}}}"#)
        XCTAssertTrue(GamePageCopy.d3dMetalAsk(title: "X", entry: alt).contains("but slower"))
        XCTAssertEqual(GamePageCopy.otherWorkingRenderer(alt), .dxvk)
        let e = try entry(#"{"id":"x","title":"X","steam_appid":1,"status":"verified-local","renderer":"dxmt"}"#)
        XCTAssertEqual(GamePageCopy.willDo(e, recipe: nil, applied: false, bottleRenderer: .dxvk, explicit: true, osMajor: 26).first?.text,
                       "Use DXVK (Vulkan on Metal), the environment's setting (set by you)")
    }
}
