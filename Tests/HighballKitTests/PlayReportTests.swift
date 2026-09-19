import XCTest
@testable import HighballKit

final class PlayReportTests: XCTestCase {
    func testFormFieldsArePrefilledById() throws {
        let url = PlayReport.url(title: "Counter-Strike 2", appid: 730, renderer: "dxmt", chip: "Apple M1 Pro",
                                 macos: "26.6.2", engine: "x64-sikarugir10.0_6-r1", minutes: 23, version: "0.9.6")
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.host, "github.com")
        XCTAssertEqual(comps.path, "/gauthierpiarrette/highball-db/issues/new")
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["template"], "report.yml")
        XCTAssertEqual(q["title"], "Counter-Strike 2")
        XCTAssertEqual(q["steam_appid"], "730")
        XCTAssertEqual(q["renderer"], "dxmt")
        XCTAssertEqual(q["chip"], "Apple M1 Pro")
        XCTAssertEqual(q["macos"], "26.6.2")
        XCTAssertEqual(q["engine"], "x64-sikarugir10.0_6-r1")
        XCTAssertEqual(q["notes"], "Played for 23 min through Highball.")
        XCTAssertEqual(q["version"], "0.9.6")
        XCTAssertNil(q["rating"], "the rating is the player's to give")
    }

    func testUnknownAppIDAndRendererAreLeftOut() throws {
        let url = PlayReport.url(title: "X", appid: nil, renderer: nil, chip: "c", macos: "m", engine: "e", minutes: 1)
        let names = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        XCTAssertFalse(names.contains("steam_appid"))
        XCTAssertFalse(names.contains("renderer"))
    }

    func testSettingsSummaryListsWhatWasChosen() {
        var s = BottleSettings(name: "Gaming", engineID: "e")
        XCTAssertEqual(PlayReport.settingsSummary(s), "mode dxmt, sync msync, Windows win10, scale 96 dpi",
                       "defaults say nothing about the run, so only the always-on line remains")
        s.fpsCap = 60; s.frameGen = 2; s.frameGenAdaptive = true; s.metalHUD = true
        s.environment = ["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN": "1"]
        s.dxvkAppConfig = ["csgo.exe": ["d3d9.customDeviceId": "73BF"]]
        s.recipes = ["steam"]
        let pin = Pin(name: "Skyrim", path: "x.exe", arguments: ["-dx11"], environment: ["A": "b"], renderer: .d3dmetal)
        let lines = PlayReport.settingsSummary(s, pin: pin).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["mode dxmt, sync msync, Windows win10, scale 96 dpi", "Metal HUD on", "frame cap 60",
                               "frame generation 2x, adaptive", "DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN=1",
                               "dxvk.conf [csgo.exe] d3d9.customDeviceId=73BF", "recipes steam",
                               "program mode d3dmetal", "program arguments -dx11", "program A=b"])
    }

    func testSettingsReachTheForm() throws {
        let url = PlayReport.url(title: "X", appid: nil, renderer: nil, chip: "c", macos: "m", engine: "e", minutes: 1,
                                 settings: "frame cap 60\nMetal HUD on")
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["settings"], "frame cap 60\nMetal HUD on")
        let bare = PlayReport.url(title: "X", appid: nil, renderer: nil, chip: "c", macos: "m", engine: "e", minutes: 1, settings: "")
        XCTAssertFalse(URLComponents(url: bare, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "settings" } ?? true)
    }

    func testSessionRecordWithoutRendererStillDecodes() throws {
        let old = Data(#"{"title":"T","bottle":"B","appid":1,"started":0,"ended":120,"reason":"ended"}"#.utf8)
        let r = try JSONDecoder().decode(SessionRecord.self, from: old)
        XCTAssertNil(r.renderer)
        XCTAssertEqual(r.seconds, 120)
    }
}
