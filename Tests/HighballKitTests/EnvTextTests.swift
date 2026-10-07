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

    func testDllOverrideLookalikesAmongVariables() {
        // Lowercase name plus an override order reads as a DLL override, whatever the box (highball#202, #203).
        let env = ["winhttp": "n,b", "mfplat": "", "MVK_SHADOW_IMPORT": "1", "DXMT_METAL_HUD": "", "d3d11": "native", "path": "C:\\x"]
        XCTAssertEqual(EnvText.dllOverrideLookalikes(in: env).map { "\($0.key)=\($0.value)" }, ["d3d11=native", "mfplat=", "winhttp=n,b"])
        XCTAssertEqual(EnvText.dllOverrideLookalikes(in: ["WINEDEBUG": "-all"]).count, 0)
    }

    func testAdoptingLookalikesMovesThemIntoTheDllOverridesField() {
        var s = BottleSettings(name: "t", engineID: "e")
        s.dllOverrides = "version=n,b"
        s.environment = ["winhttp": "n,b", "MVK_SHADOW_IMPORT": "1", "version": "n,b"]
        XCTAssertEqual(s.adoptDllOverrideLookalikes(), ["version=n,b", "winhttp=n,b"])
        XCTAssertEqual(s.dllOverrides, "version=n,b;winhttp=n,b")
        XCTAssertEqual(s.environment, ["MVK_SHADOW_IMPORT": "1"])
        XCTAssertEqual(s.adoptDllOverrideLookalikes(), [])
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

    /// Opening Steam's window after a game crashed handed the request to the running client and
    /// left a newer, empty log; the game's page must still open the log with the crash in it.
    func testTheLastLaunchLogSkipsAnEmptyHandOver() {
        let play = "2026-10-07T181512Z-Games-steam.exe.log", open = "2026-10-07T181930Z-Games-steam.exe.log"
        let older = "2026-10-06T100000Z-Games-steam.exe.log", sameSecond = "2026-10-07T181930Z-Games-steam.exe-2.log"
        let names = [older, play, open, "2026-10-07T182000Z-Games-reg.exe.log"]
        XCTAssertEqual(LaunchLogs.newestWithOutput(names: names, bottle: "Games", executable: "steam.exe") { $0 != open }, play)
        XCTAssertEqual(LaunchLogs.newestWithOutput(names: names + [sameSecond], bottle: "Games", executable: "steam.exe") { $0 != open }, sameSecond,
                       "a later launch in the same second that has output is the newest")
        XCTAssertEqual(LaunchLogs.newestWithOutput(names: names, bottle: "Games", executable: "steam.exe") { _ in false }, open,
                       "when no log has output, the newest as before")
        XCTAssertNil(LaunchLogs.newestWithOutput(names: names, bottle: "Gaming", executable: "steam.exe") { _ in true })
    }

    func testALogOfHeaderAndExitLineOnlyHasNoOutput() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hb-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let header = """
        # gin x64-sikarugir10.0_6-r21 bottle=Games renderer=d3dmetal
        # wine /Users/x/Library/Application Support/Highball/bottles/Games/drive_c/Program Files (x86)/Steam/steam.exe steam://open/main
        # sync=msync winver=win11 dpi=96 dxvkAsync=false frameGen=off
        # audio out=48000 Hz
        #   dxvk.enableAsync = False

        """
        let handOver = dir.appending(path: "a.log"), crash = dir.appending(path: "b.log"), empty = dir.appending(path: "c.log")
        try (header + "# exit=0 after 0s\n").write(to: handOver, atomically: true, encoding: .utf8)
        try (header + "0124:err:seh:NtRaiseException Unhandled exception code c0000005\n# exit=0 after 61s\n").write(to: crash, atomically: true, encoding: .utf8)
        try "".write(to: empty, atomically: true, encoding: .utf8)
        XCTAssertFalse(LaunchLogs.hasOutput(handOver))
        XCTAssertTrue(LaunchLogs.hasOutput(crash))
        XCTAssertFalse(LaunchLogs.hasOutput(empty))
        XCTAssertFalse(LaunchLogs.hasOutput(dir.appending(path: "missing.log")))
    }
}
