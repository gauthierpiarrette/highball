import XCTest
@testable import HighballKit

final class SteamRestartTests: XCTestCase {
    private let dxvk = ["WINEDLLPATH_PREPEND": "/e/dxvk/wine", "WINEMSYNC": "1", "WINEESYNC": "0"]

    func testSameEnvironmentNeedsNoRestart() {
        XCTAssertNil(SteamRestart.reason(live: dxvk, wanted: dxvk, wantedRenderer: "dxvk"))
    }

    func testRendererOverlayDifferenceNamesTheRenderer() {
        var live = dxvk; live["WINEDLLPATH_PREPEND"] = "/e/dxmt/wine"
        let why = SteamRestart.reason(live: live, wanted: dxvk, wantedRenderer: "dxvk")
        XCTAssertEqual(why, "it runs with a different renderer than dxvk")
    }

    func testWined3dClientVersusOverlayLaunchIsARendererDifference() {
        var live = dxvk; live["WINEDLLPATH_PREPEND"] = nil
        XCTAssertNotNil(SteamRestart.reason(live: live, wanted: dxvk, wantedRenderer: "dxvk"))
        XCTAssertNil(SteamRestart.reason(live: live, wanted: live, wantedRenderer: "wined3d"))
    }

    func testSyncDifferenceNamesBothModes() {
        var live = dxvk; live["WINEMSYNC"] = "0"
        let why = SteamRestart.reason(live: live, wanted: dxvk, wantedRenderer: "dxvk")
        XCTAssertEqual(why, "it runs with sync none and the game wants msync")
    }

    func testBothDifferencesAreListed() {
        let live = ["WINEDLLPATH_PREPEND": "/e/dxmt/wine", "WINEMSYNC": "0", "WINEESYNC": "0"]
        let why = SteamRestart.reason(live: live, wanted: dxvk, wantedRenderer: "dxvk") ?? ""
        XCTAssertTrue(why.contains("renderer") && why.contains("sync none"), why)
    }

    func testUnrelatedVariablesAreIgnored() {
        var live = dxvk; live["DXVK_LOG_PATH"] = "C:\\other"; live["STEAM_COMPAT"] = "1"
        XCTAssertNil(SteamRestart.reason(live: live, wanted: dxvk, wantedRenderer: "dxvk"))
    }

    func testAVXToggleFlippedWhileTheClientRunsRestartsIt() {
        var wanted = dxvk; wanted["ROSETTA_ADVERTISE_AVX"] = "1"
        XCTAssertEqual(SteamRestart.reason(live: dxvk, wanted: wanted, wantedRenderer: "dxvk"),
                       "it runs with AVX advertised off and the game wants it on")
        XCTAssertEqual(SteamRestart.reason(live: wanted, wanted: dxvk, wantedRenderer: "dxvk"),
                       "it runs with AVX advertised on and the game wants it off")
        XCTAssertNil(SteamRestart.reason(live: wanted, wanted: wanted, wantedRenderer: "dxvk"))
    }

    func testMetalHUDToggleFlippedWhileTheClientRunsRestartsIt() {
        var wanted = dxvk; wanted["MTL_HUD_ENABLED"] = "1"
        XCTAssertEqual(SteamRestart.reason(live: dxvk, wanted: wanted, wantedRenderer: "dxvk"),
                       "it runs with the Metal HUD off and the game wants it on")
    }

    func testGLContextSwitchMissingFromAnOlderClientRestartsIt() {
        // 0.9.24 sets CX_FWD_COMPAT_GL_CTX on every launch; a client started by 0.9.23 lacks it.
        var wanted = dxvk; wanted["CX_FWD_COMPAT_GL_CTX"] = "1"
        XCTAssertEqual(SteamRestart.reason(live: dxvk, wanted: wanted, wantedRenderer: "dxvk"),
                       "it runs with forward-compatible OpenGL contexts off and the game wants it on")
    }

    func testCustomVariablesTheEnvironmentSetsRestartTheClientWhenTheyDiffer() {
        var wanted = dxvk; wanted["MVK_SHADOW_IMPORT"] = "1"
        XCTAssertEqual(SteamRestart.reason(live: dxvk, wanted: wanted, wantedRenderer: "dxvk", custom: ["MVK_SHADOW_IMPORT"]),
                       "it runs without MVK_SHADOW_IMPORT=1")
        var live = dxvk; live["MVK_SHADOW_IMPORT"] = "0"
        XCTAssertEqual(SteamRestart.reason(live: live, wanted: wanted, wantedRenderer: "dxvk", custom: ["MVK_SHADOW_IMPORT"]),
                       "it runs with MVK_SHADOW_IMPORT=0 and the game wants 1")
        XCTAssertNil(SteamRestart.reason(live: wanted, wanted: wanted, wantedRenderer: "dxvk", custom: ["MVK_SHADOW_IMPORT"]))
        // Not listed as custom: still per-launch noise.
        XCTAssertNil(SteamRestart.reason(live: dxvk, wanted: wanted, wantedRenderer: "dxvk"))
    }

    func testOnlyTheClientsOwnProcessesCountAsTheClient() {
        XCTAssertTrue(SteamRestart.isClientProcess(argv0: "C:\\Program Files (x86)\\Steam\\steam.exe"))
        XCTAssertTrue(SteamRestart.isClientProcess(argv0: "C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win7x64\\steamwebhelper.exe"))
        XCTAssertTrue(SteamRestart.isClientProcess(argv0: "/b/drive_c/Program Files (x86)/Steam/GameOverlayUI.exe"))
        XCTAssertFalse(SteamRestart.isClientProcess(argv0: "C:\\Program Files (x86)\\Steam\\steamapps\\common\\PEAK\\PEAK.exe"), "a game the client started")
        XCTAssertFalse(SteamRestart.isClientProcess(argv0: "C:\\Games\\Tool\\steam_helper_for_mods.exe"), "a name that merely contains steam")
        XCTAssertFalse(SteamRestart.isClientProcess(argv0: ""))
    }

    func testRendererNameComesFromTheOverlayPath() {
        let base = "/e/x64-crossover26.3-r8/frameworks/renderer"
        XCTAssertEqual(SteamRestart.rendererName(ofLive: ["WINEDLLPATH_PREPEND": "/e/x/renderers/d3dmetal-tsshim/wine:\(base)/d3dmetal/wine:\(base)/d9vk/wine"]), "d3dmetal")
        XCTAssertEqual(SteamRestart.rendererName(ofLive: ["WINEDLLPATH_PREPEND": "\(base)/d9vk/wine:\(base)/dxmt/wine"]), "dxmt")
        XCTAssertEqual(SteamRestart.rendererName(ofLive: ["WINEDLLPATH_PREPEND": "\(base)/d9vk/wine:\(base)/dxvk/wine"]), "dxvk")
        XCTAssertEqual(SteamRestart.rendererName(ofLive: ["WINEDLLPATH_PREPEND": "/e/x/renderers/dxmt/wine:\(base)/d9vk/wine"]), "dxmt")
        XCTAssertEqual(SteamRestart.rendererName(ofLive: [:]), "wined3d")
    }
}
