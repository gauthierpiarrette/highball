import XCTest
@testable import HighballKit

final class EnvTextTests: XCTestCase {
    func testValidLinesAreKeptAndTheRestNamed() {
        let p = EnvText.parse("MVK_SHADOW_IMPORT=1\nFOO=bar baz\nnot a pair\n\n=novalue\n  SPACED = x ")
        XCTAssertEqual(p.environment, ["MVK_SHADOW_IMPORT": "1", "FOO": "bar baz", "SPACED": " x"])
        XCTAssertEqual(p.ignored, ["not a pair", "=novalue"])
    }

    func testEmptyValueIsAllowed() {
        // An empty value is a way to blank a variable the engine sets.
        XCTAssertEqual(EnvText.parse("DXMT_METAL_HUD=").environment, ["DXMT_METAL_HUD": ""])
    }

    func testRoundTrip() {
        let env = ["B": "2", "A": "1"]
        XCTAssertEqual(EnvText.text(for: env), "A=1\nB=2")
        XCTAssertEqual(EnvText.parse(EnvText.text(for: env)).environment, env)
    }

    func testDllOverridesIgnoredNamesTheBadEntries() {
        XCTAssertEqual(WineRunner.dllOverridesIgnored("d3d9=n,b;version;winmm=x;  ;dxgi=b"), ["version", "winmm=x"])
        XCTAssertEqual(WineRunner.dllOverridesIgnored(""), [])
    }

    func testNewestLaunchLogByName() {
        let names = ["2026-09-11T154113Z-Gaming-steam.exe.log", "2026-09-11T153459Z-Gaming-steam.exe.log",
                     "2026-09-11T154110Z-Gaming-reg.exe.log", "2026-09-11T160000Z-cx-steam-steam.exe.log",
                     "2026-09-11T145016Z-rsmoke-Heaven.exe.log", "2026-09-11T145016Z-rsmoke-Heaven.exe-2.log", "sessions.jsonl"]
        XCTAssertEqual(LaunchLogs.newest(names: names, bottle: "Gaming", executable: "steam.exe"), "2026-09-11T154113Z-Gaming-steam.exe.log")
        XCTAssertEqual(LaunchLogs.newest(names: names, bottle: "cx-steam", executable: "steam.exe"), "2026-09-11T160000Z-cx-steam-steam.exe.log")
        XCTAssertEqual(LaunchLogs.newest(names: names, bottle: "rsmoke", executable: "Heaven.exe"), "2026-09-11T145016Z-rsmoke-Heaven.exe-2.log")
        XCTAssertNil(LaunchLogs.newest(names: names, bottle: "Gaming", executable: "acs.exe"))
        XCTAssertNil(LaunchLogs.newest(names: names, bottle: "steam", executable: "steam.exe"), "an environment name that is a suffix of another must not match")
    }
}
