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
}
