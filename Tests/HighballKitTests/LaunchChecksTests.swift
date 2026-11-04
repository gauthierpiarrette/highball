import XCTest
@testable import HighballKit

/// The checks a launch makes before the program starts, and the tweak removal next to them.
final class LaunchChecksTests: XCTestCase {

    /// highball#396: Steam warned it would stop running on Windows 7 in an environment whose setting
    /// said Windows 11. The prefix's own version is what Wine reports, read from its registry files.
    func testPrefixWindowsVersionComesFromTheRegistryFiles() {
        func system(_ build: String) -> String {
            "WINE REGISTRY Version 2\n\n[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion] 1788462370\n\"CurrentBuild\"=\"\(build)\"\n\"CurrentVersion\"=\"6.3\"\n"
        }
        XCTAssertEqual(WineRunner.prefixWindowsVersion(userReg: "", systemReg: system("7601")), "win7", "what winetricks win7 leaves")
        XCTAssertEqual(WineRunner.prefixWindowsVersion(userReg: "", systemReg: system("19045")), "win10")
        XCTAssertEqual(WineRunner.prefixWindowsVersion(userReg: "", systemReg: system("22000")), "win11")
        XCTAssertEqual(WineRunner.prefixWindowsVersion(userReg: "", systemReg: system("9600")), "win81")
        XCTAssertNil(WineRunner.prefixWindowsVersion(userReg: "", systemReg: ""), "nothing to read, nothing to change")
        // The per-user value wins in Wine, so it wins here.
        let user = "WINE REGISTRY Version 2\n\n[Software\\\\Wine] 1788462370\n\"Version\"=\"win7\"\n\n[Software\\\\Wine\\\\Direct3D] 1788462370\n\"Version\"=\"win11\"\n"
        XCTAssertEqual(WineRunner.prefixWindowsVersion(userReg: user, systemReg: system("22000")), "win7")
        XCTAssertEqual(WineRunner.prefixWindowsVersion(userReg: "[Software\\\\Wine\\\\Direct3D] 1\n\"Version\"=\"win7\"\n", systemReg: system("22000")), "win11",
                       "a value of the same name under another key is not the version")
    }

    /// highball#371: the log could not show whether DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN was set.
    func testTheHeaderShowsRendererAndControllerSwitchesOnly() {
        let env = ["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN": "1", "SDL_JOYSTICK_MFI": "0", "HOME": "/Users/someone",
                   "STEAM_TOKEN": "secret", "MVK_CONFIG_USE_MTLHEAP": "0", "WINE_NO_DELAYED_FORK": "1",
                   "D3DM_LONG": String(repeating: "x", count: 300)]
        XCTAssertEqual(WineRunner.headerSwitchLines(env),
                       "# DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN=1\n# MVK_CONFIG_USE_MTLHEAP=0\n# SDL_JOYSTICK_MFI=0\n# WINE_NO_DELAYED_FORK=1\n")
    }

    /// highball#420: an Epic game's launch printed its exchange code and account into a public issue.
    func testTheHeaderKeepsSecretArgumentsOut() {
        let args = ["C:\\Games\\installer.exe", "-AUTH_LOGIN=unused", "-AUTH_PASSWORD=b591ee791c13", "-AUTH_TYPE=exchangecode",
                    "-epicapp=d91f8774", "-epicusername=Someone", "-epicuserid=0123abcd", "-applaunch", "620"]
        XCTAssertEqual(WineRunner.redactedForReport(args),
                       ["C:\\Games\\installer.exe", "-AUTH_LOGIN=unused", "-AUTH_PASSWORD=[redacted]", "-AUTH_TYPE=exchangecode",
                        "-epicapp=d91f8774", "-epicusername=[redacted]", "-epicuserid=[redacted]", "-applaunch", "620"])
    }

    /// highball#416: a client a game's Play started under D3DMetal showed a black window on Show Steam.
    func testSteamWindowRestartsOnlyFromD3DMetal() {
        let engine = "/Users/x/Library/Application Support/Highball/engines/x64-crossover26.3-r27"
        let d3dmetal = ["WINEDLLPATH_PREPEND": "\(engine)/renderers/d3dmetal-tsshim/wine:\(engine)/frameworks/renderer/d3dmetal/wine:\(engine)/renderers/dxmt/wine"]
        let dxmt = ["WINEDLLPATH_PREPEND": "\(engine)/renderers/dxmt/wine:\(engine)/frameworks/renderer/d9vk/wine"]
        let dxvk = ["WINEDLLPATH_PREPEND": "\(engine)/frameworks/renderer/d9vk/wine:\(engine)/frameworks/renderer/dxvk/wine"]
        XCTAssertTrue(SteamRestart.windowNeedsRestart(live: d3dmetal, window: .dxmt))
        XCTAssertFalse(SteamRestart.windowNeedsRestart(live: dxmt, window: .dxmt), "already drawing")
        XCTAssertFalse(SteamRestart.windowNeedsRestart(live: dxvk, window: .dxmt), "not the black case")
        XCTAssertFalse(SteamRestart.windowNeedsRestart(live: d3dmetal, window: .d3dmetal), "the player chose D3DMetal for the window")
    }

    /// highball#565: a DXMT environment whose game ran with D3DMetal (its own mode or its database
    /// row) left Steam on D3DMetal, and Show brought back "steamwebhelper is not responding".
    func testSteamWindowRestartsInADXMTEnvironment() {
        let engine = "/Users/x/Library/Application Support/Highball/engines/x64-sikarugir10.0_6-r28"
        let d3dmetal = ["WINEDLLPATH_PREPEND": "\(engine)/renderers/d3dmetal-tsshim/wine:\(engine)/frameworks/renderer/d3dmetal/wine"]
        let window = SteamRestart.windowMode(shortcut: nil, environment: .dxmt, dxmtRuns: true)
        XCTAssertEqual(window, .dxmt)
        XCTAssertTrue(SteamRestart.windowNeedsRestart(live: d3dmetal, window: window))
        XCTAssertEqual(SteamRestart.windowMode(shortcut: nil, environment: .d3dmetal, dxmtRuns: true), .dxmt)
        XCTAssertEqual(SteamRestart.windowMode(shortcut: nil, environment: .d3dmetal, dxmtRuns: false), .d3dmetal)
        XCTAssertEqual(SteamRestart.windowMode(shortcut: .dxvk, environment: .d3dmetal, dxmtRuns: true), .dxvk)
        XCTAssertFalse(SteamRestart.windowNeedsRestart(live: d3dmetal,
                                                       window: SteamRestart.windowMode(shortcut: .d3dmetal, environment: .dxmt, dxmtRuns: true)))
    }

    /// highball#241, #336: winetricks started its wine processes with the environment's msync while
    /// a Steam window, started with sync off, held the server, and each of them died at once.
    func testEveryWayIntoARunningPrefixTakesItsSyncMode() {
        let msync = ["WINEMSYNC": "1", "WINEESYNC": "0", "WINEPREFIX": "/p"]
        XCTAssertEqual(WineRunner.joining(msync, liveSync: SyncMode.none), ["WINEMSYNC": "0", "WINEESYNC": "0", "WINEPREFIX": "/p"])
        XCTAssertEqual(WineRunner.joining(msync, liveSync: .msync), msync, "same mode, nothing changes")
        XCTAssertEqual(WineRunner.joining(msync, liveSync: nil), msync, "no server running, the environment's own mode starts it")
        XCTAssertEqual(WineRunner.joining(["WINEMSYNC": "0", "WINEESYNC": "0"], liveSync: .esync), ["WINEMSYNC": "0", "WINEESYNC": "1"])
    }

    /// highball-db#493: a program set to Wine's own Direct3D on its page ran with the environment's D3DMetal.
    func testPlayGivesAProgramTheModeItChose() {
        let pin = Pin(name: "Velocity Ultra", path: "/Volumes/x/game.exe", renderer: .dxvk)
        XCTAssertEqual(pin.launching(with: .wined3d).renderer, .wined3d, "the page's mode wins for this launch")
        XCTAssertEqual(pin.launching(with: nil).renderer, .dxvk, "nothing chosen, the pin keeps its own")
        XCTAssertEqual(pin.launching(with: .wined3d).id, pin.id, "the same program")
        XCTAssertNil(Pin(name: "x", path: "x.exe").launching(with: nil).renderer, "and with none, the environment decides")
    }

    /// Forza Horizon 6 added by hand ran without its fix's graphics card variables and crashed (highball#486).
    func testAProgramCarriesItsGamesVariables() {
        let fix = ["D3DM_VENDOR_ID": "0x10de", "D3DM_DEVICE_ID": "0x2786"]
        let pin = Pin(name: "Forza Horizon 6", path: "/Users/x/Games/Forza Horizon 6/forzahorizon6.exe",
                      environment: ["D3DM_DEVICE_ID": "0x56a1", "MY_SETTING": "1"])
        let env = pin.environment(withGame: fix)
        XCTAssertEqual(env["D3DM_VENDOR_ID"], "0x10de", "the fix's variable reaches the launch")
        XCTAssertEqual(env["D3DM_DEVICE_ID"], "0x56a1", "the program's own setting wins over the fix")
        XCTAssertEqual(env["MY_SETTING"], "1")
        XCTAssertEqual(Pin(name: "x", path: "x.exe").environment(withGame: [:]), [:], "no game, nothing added")
    }

    /// A DualSense player had "Controllers through SDL" installed and no way back but regedit.
    func testRegistryOnlyTweaksCanBeRemoved() throws {
        let sdl = try JSONDecoder.highball.decode(Recipe.self, from: Data("""
        {"id": "controller-sdl", "kind": "tweak", "title": "Controllers through SDL", "steps": [
          {"type": "registry", "key": "HKLM\\\\System\\\\CurrentControlSet\\\\Services\\\\winebus", "name": "DisableHidraw", "valueType": "REG_DWORD", "data": "1"},
          {"type": "registry", "key": "HKLM\\\\System\\\\CurrentControlSet\\\\Services\\\\winebus", "name": "Enable SDL", "valueType": "REG_DWORD", "data": "1"},
          {"type": "note", "text": "Restart the environment."}]}
        """.utf8))
        XCTAssertTrue(sdl.isRemovable)
        XCTAssertEqual(sdl.registryValues.map(\.name), ["DisableHidraw", "Enable SDL"])
        let runtime = try JSONDecoder.highball.decode(Recipe.self, from: Data("""
        {"id": "xact", "kind": "tweak", "title": "XACT", "steps": [{"type": "winetricks", "verbs": ["xact"]},
          {"type": "registry", "key": "HKCU\\\\Software\\\\Wine\\\\DllOverrides", "name": "xaudio2_7", "valueType": "REG_SZ", "data": "native"}]}
        """.utf8))
        XCTAssertFalse(runtime.isRemovable, "a runtime that installed files can't be taken off by deleting values")
        let notesOnly = try JSONDecoder.highball.decode(Recipe.self, from: Data("""
        {"id": "n", "kind": "tweak", "title": "N", "steps": [{"type": "note", "text": "x"}]}
        """.utf8))
        XCTAssertFalse(notesOnly.isRemovable, "nothing to remove")
    }
}
