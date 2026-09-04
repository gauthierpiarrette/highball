import XCTest
@testable import HighballKit

/// Tripwires for bugs that shipped once and must not ship twice.
final class RegressionTests: XCTestCase {

    /// DXVK async was on for every game from 0.3.0, not because anyone chose it but because it
    /// was the default. It skips draws while a pipeline compiles, upstream refuses to ship it,
    /// and it measured no benefit here, so format 2 switches existing bottles off once.
    func testOldBottlesAreMigratedOffDxvkAsync() throws {
        let json = #"{"name":"b","engineID":"e","dxvkAsync":true,"formatVersion":1}"#
        let s = try JSONDecoder.highball.decode(BottleSettings.self, from: Data(json.utf8))
        XCTAssertFalse(s.dxvkAsync, "a bottle written before format 2 must be switched off")
        XCTAssertEqual(s.formatVersion, 3, "and stamped, so the migration never runs twice")
    }

    /// But a user who turns it back on afterwards keeps it: the stamp is what makes it one-shot.
    func testADeliberateDxvkAsyncChoiceSurvives() throws {
        let json = #"{"name":"b","engineID":"e","dxvkAsync":true,"formatVersion":2}"#
        let s = try JSONDecoder.highball.decode(BottleSettings.self, from: Data(json.utf8))
        XCTAssertTrue(s.dxvkAsync, "format 2 means the value was chosen, not inherited")
    }

    /// A fresh bottle is off, and the generated conf says so rather than staying silent — the
    /// explicit line is what keeps DXVK printing its "Effective configuration" block, the one
    /// artefact that survives a game started by a launcher Highball did not spawn (#21).
    func testNewBottlesDefaultAsyncOffAndSaySo() {
        XCTAssertFalse(BottleSettings(name: "b", engineID: "e").dxvkAsync)
        XCTAssertTrue(Bottle.dxvkConfig(async: false).contains("dxvk.enableAsync = False"))
    }

    // Issue #12: Windows-invalid characters in a bottle name break wineboot (exit 53).
    func testBottleNameValidation() {
        XCTAssertNil(BottleStore.nameProblem("games"))
        XCTAssertNil(BottleStore.nameProblem("My Bottle 2"))
        for bad in ["a:b", "a/b", #"a\b"#, "a?b", "a*b", "a<b", "a>b", "a|b", "a\"b"] {
            XCTAssertNotNil(BottleStore.nameProblem(bad), "'\(bad)' must be rejected")
        }
        XCTAssertNotNil(BottleStore.nameProblem(""))
        XCTAssertNotNil(BottleStore.nameProblem("   "))
        XCTAssertNotNil(BottleStore.nameProblem(".hidden"))
        XCTAssertNotNil(BottleStore.nameProblem("dot."))
        XCTAssertNotNil(BottleStore.nameProblem(String(repeating: "x", count: 65)))
    }

    // 0.7.1 shipped a GPU identity absent from Wine's table; Wine silently ignored it
    // ("Invalid GPU override") and bottles stayed on the fake-NVIDIA identity that
    // makes CS:GO-class games demand NVAPI and die. 0x1002:0x73bf is in Wine 10's table.
    func testGpuIdentityStaysTableValid() {
        let id = WineRunner.gpuIdentity
        XCTAssertEqual(id.vendor, 0x1002, "AMD vendor id — do not change without checking Wine's GPU table")
        XCTAssertEqual(id.device, 0x73bf, "must exist in Wine's wined3d GPU table (0x73df does NOT)")
        XCTAssertNotEqual(id.device, 0x73df, "0x73df is the known-bad pair Wine rejects")
        XCTAssertLessThanOrEqual(id.vendor, 0xffff, "registry override values above 0xffff are rejected")
        XCTAssertLessThanOrEqual(id.device, 0xffff)
    }

    // Legendary's list-installed JSON uses `title`, not `app_title` (which the owned-games
    // endpoint uses). Decoding with the wrong type broke the Epic library view in 0.7.0 dev.
    func testEpicInstalledGameDecode() throws {
        let json = #"[{"app_name":"Duck","title":"Cardpocalypse","version":"1.0"}]"#
        let games = try JSONDecoder().decode([EpicStore.InstalledGame].self, from: Data(json.utf8))
        XCTAssertEqual(games.first?.app_name, "Duck")
    }

    // Old bottles carry gin.json written by earlier versions without newer fields.
    // Decoding must fill defaults, never throw (an early 0.5.x crashed on this class).
    func testSettingsDecodeFromOldVersion() throws {
        let old = #"{"formatVersion":1,"name":"aged","engineID":"x64-test","renderer":"dxmt","windowsVersion":"win10","sync":"msync","metalHUD":false,"advertiseAVX":false,"pins":[{"id":"6B1F0D2A-0000-4000-8000-000000000001","name":"Steam","path":"Program Files (x86)/Steam/steam.exe"}],"environment":{},"recipes":[]}"#
        let s = try JSONDecoder.highball.decode(BottleSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.name, "aged")
        XCTAssertEqual(s.dpiScale, 96, "no dpi field on an old bottle must default to 96 (100%)")
        XCTAssertEqual(s.dllOverrides, "", "field added in 0.7.2 must default empty")
        XCTAssertEqual(s.fpsCap, 0)
        // That fixture predates formatVersion 2, so it exercises the migration below.
        XCTAssertEqual(s.dxvkAsync, false)
        XCTAssertEqual(s.pins.first?.arguments, [], "pin arguments default to empty")
        XCTAssertEqual(s.pins.first?.environment, [:])
        XCTAssertNil(s.pins.first?.renderer)
    }

    // The retinaMode on/off toggle became a dpiScale slider in 0.7.8. A bottle that had
    // retinaMode:true must migrate to 200% (LogPixels 192), not silently reset to 100%.
    func testRetinaModeMigratesToDpiScale() throws {
        let on = try JSONDecoder.highball.decode(BottleSettings.self,
            from: Data(#"{"name":"a","engineID":"e","retinaMode":true}"#.utf8))
        XCTAssertEqual(on.dpiScale, 192, "legacy retinaMode:true -> 200% (LogPixels 192)")
        let off = try JSONDecoder.highball.decode(BottleSettings.self,
            from: Data(#"{"name":"a","engineID":"e","retinaMode":false}"#.utf8))
        XCTAssertEqual(off.dpiScale, 96, "legacy retinaMode:false -> 100%")
        let explicit = try JSONDecoder.highball.decode(BottleSettings.self,
            from: Data(#"{"name":"a","engineID":"e","dpiScale":144,"retinaMode":true}"#.utf8))
        XCTAssertEqual(explicit.dpiScale, 144, "an explicit dpiScale wins over the legacy key")
    }

    // The DPI slider generalizes the old 96/192 pair: native Retina pixels only above 100%,
    // and values clamped to Wine's usable 96..240 range so a bad input can't write garbage.
    func testDpiRegistryMappingAndClamp() {
        XCTAssertEqual(WineRunner.dpiRegistry(for: 96).logPixels, 96)
        XCTAssertEqual(WineRunner.dpiRegistry(for: 96).retinaMode, "n", "100% stays 1x")
        XCTAssertEqual(WineRunner.dpiRegistry(for: 144).logPixels, 144)
        XCTAssertEqual(WineRunner.dpiRegistry(for: 144).retinaMode, "y", "above 100% switches to native pixels")
        XCTAssertEqual(WineRunner.dpiRegistry(for: 50).logPixels, 96, "below range clamps up to 96")
        XCTAssertEqual(WineRunner.dpiRegistry(for: 50).retinaMode, "n")
        XCTAssertEqual(WineRunner.dpiRegistry(for: 999).logPixels, 240, "above range clamps to 240")
        XCTAssertEqual(WineRunner.dpiRegistry(for: 999).retinaMode, "y")
    }

    // Cmd+V beeped instead of pasting in Steam: Wine's Mac driver leaves Command acting as Alt.
    // Mapping Command to Ctrl without also mapping Option to Alt leaves no way to send Alt at all
    // (winemac.drv warns about exactly that), so the four values must move together.
    // Mac Driver values are REG_SZ "y"/"n". Writing DWORD 1 reads as absent and the mapping
    // silently stays off — the first cut of this shipped that way.
    func testCommandKeyMappingMovesAsASet() throws {
        let on = WineRunner.keyboardRegistry(commandIsControl: true)
        XCTAssertEqual(on.count, 4)
        XCTAssertEqual(Set(on.map(\.name)),
                       ["LeftCommandIsCtrl", "RightCommandIsCtrl", "LeftOptionIsAlt", "RightOptionIsAlt"])
        XCTAssertTrue(on.allSatisfy { $0.data == "y" }, "Command→Ctrl is useless without Option→Alt")

        let off = WineRunner.keyboardRegistry(commandIsControl: false)
        XCTAssertTrue(off.allSatisfy { $0.data == "n" }, "off restores Wine's default mapping")
        XCTAssertEqual(Set(off.map(\.name)), Set(on.map(\.name)),
                       "turning it off must clear the same keys it set, not leave half behind")
    }

    // A bottle made before this setting existed decodes with commandIsControlSynced == nil, which
    // is what makes the first launch after updating apply the mapping instead of waiting for Repair.
    func testPreExistingBottleIsUnsyncedSoLaunchApplies() throws {
        let json = #"{"formatVersion":1,"name":"old","engineID":"e"}"#
        let s = try JSONDecoder().decode(BottleSettings.self, from: Data(json.utf8))
        XCTAssertTrue(s.commandIsControl, "the default carries into bottles that predate it")
        XCTAssertNil(s.commandIsControlSynced, "never mirrored → next launch applies it")
        XCTAssertNotEqual(s.commandIsControl, s.commandIsControlSynced,
                          "differing is the trigger syncKeyboardRegistry checks")
    }

    // New bottles get Mac-native copy/paste; the setting is what the registry write follows.
    func testCommandIsControlDefaultsOn() throws {
        let s = BottleSettings(name: "t", engineID: "e")
        XCTAssertTrue(s.commandIsControl, "Mac users expect ⌘C/⌘V to work in Windows apps")
    }

    // The exact bug from review: commandIsControl encoded but never decoded, so a bottle saved with
    // the mapping off came back on after every relaunch and the toggle could not be turned off.
    func testCommandIsControlOffSurvivesSaveAndLoad() throws {
        var s = BottleSettings(name: "rt", engineID: "eng")
        s.commandIsControl = false
        s.commandIsControlSynced = false
        let reloaded = try JSONDecoder.highball.decode(BottleSettings.self,
                                                       from: try JSONEncoder.highball.encode(s))
        XCTAssertFalse(reloaded.commandIsControl, "off must still be off after a reload")
        XCTAssertEqual(reloaded.commandIsControlSynced, false,
                       "synced must round-trip too, or every launch re-mirrors the registry")
    }

    // A settings field that isn't in the hand-written init(from:) encodes but never decodes,
    // so it silently reverts to its default on the next load. Generic on purpose: this is the
    // tripwire for the next setting anyone adds, not just for commandIsControl.
    func testEverySettingSurvivesSaveAndLoad() throws {
        var s = BottleSettings(name: "rt", engineID: "eng")
        s.renderer = .wined3d
        s.rendererExplicit = true
        s.windowsVersion = .win11
        s.sync = .esync
        s.metalHUD = true
        s.advertiseAVX = true
        s.dxvkAsync = false
        s.fpsCap = 60
        s.dpiScale = 192
        s.dllOverrides = "version=n,b"
        s.dllOverridesSynced = "version=n,b"
        s.dxvkAppConfig = ["a.exe": ["k": "v"]]
        s.commandIsControl = false
        s.commandIsControlSynced = false
        s.environment = ["K": "V"]
        s.pins = [Pin(name: "p", path: #"C:\g.exe"#)]
        s.recipes = ["r"]

        // Every value differs from its default, so a field the decoder forgot comes back as the
        // default and the two encodings diverge on exactly that key.
        let written = try JSONEncoder.highball.encode(s)
        let reloaded = try JSONDecoder.highball.decode(BottleSettings.self, from: written)
        XCTAssertEqual(String(data: written, encoding: .utf8),
                       String(data: try JSONEncoder.highball.encode(reloaded), encoding: .utf8),
                       "a settings field is missing its decodeIfPresent line in BottleSettings.init(from:)")
    }

    // Steam writes StateFlags 1026 while downloading; the game card must not offer Play.
    func testACFDownloadingNotReady() throws {
        let acf = """
        "AppState"
        {
        \t"appid"\t\t"730"
        \t"name"\t\t"Counter-Strike 2"
        \t"StateFlags"\t\t"1026"
        \t"installdir"\t\t"Counter-Strike Global Offensive"
        }
        """
        let tmp = FileManager.default.temporaryDirectory.appending(path: "appmanifest_730.acf")
        try acf.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let game = SteamLibrary.parseManifest(tmp)
        XCTAssertEqual(game?.appid, 730)
        XCTAssertEqual(game?.isReady, false)
    }

    // resolve() must accept both drive-letter cases (CLI users type c:\ freely).
    func testWindowsPathLowercaseDrive() {
        let b = Bottle(url: URL(fileURLWithPath: "/tmp/b"), settings: BottleSettings(name: "b", engineID: "e"))
        XCTAssertEqual(b.resolve(windowsPath: #"c:\windows\system32\cmd.exe"#).path,
                       "/tmp/b/drive_c/windows/system32/cmd.exe")
    }

    // "Run and add to Programs" on an exe outside the bottle used to store just the
    // filename, producing a pin that resolved to a nonexistent drive_c file. Pins now
    // store drive_c-relative paths inside the bottle and absolute paths outside it,
    // and resolve accordingly. Preinstalled-games flow (Reddit report, 2026-08-26).
    func testPinPathsInsideAndOutsideBottle() {
        let driveC = URL(fileURLWithPath: "/tmp/b/drive_c")
        let inside = URL(fileURLWithPath: "/tmp/b/drive_c/Games/Foo/foo.exe")
        let outside = URL(fileURLWithPath: "/Users/someone/Games/Bar/bar.exe")
        XCTAssertEqual(Pin.storagePath(for: inside, driveC: driveC), "Games/Foo/foo.exe")
        XCTAssertEqual(Pin.storagePath(for: outside, driveC: driveC), "/Users/someone/Games/Bar/bar.exe")
        XCTAssertEqual(Pin(name: "f", path: "Games/Foo/foo.exe").executableURL(driveC: driveC).path,
                       "/tmp/b/drive_c/Games/Foo/foo.exe")
        XCTAssertEqual(Pin(name: "b", path: "/Users/someone/Games/Bar/bar.exe").executableURL(driveC: driveC).path,
                       "/Users/someone/Games/Bar/bar.exe")
    }

    // Z:\ is Wine's window onto the unix root; resolving it must leave the bottle.
    func testWindowsPathZDrive() {
        let b = Bottle(url: URL(fileURLWithPath: "/tmp/b"), settings: BottleSettings(name: "b", engineID: "e"))
        XCTAssertEqual(b.resolve(windowsPath: #"Z:\Users\someone\Games\game.exe"#).path,
                       "/Users/someone/Games/game.exe")
        XCTAssertEqual(b.resolve(windowsPath: #"C:\Games\g.exe"#).path, "/tmp/b/drive_c/Games/g.exe")
    }

    // Pins round trip with everything the program settings sheet can write.
    func testPinFullRoundTrip() throws {
        var p = Pin(name: "Launcher", path: "Games/l.exe")
        p.arguments = ["-dx11", #"C:\a b\cfg"#]
        p.environment = ["WINE_SIMULATE_WRITECOPY": "1"]
        p.renderer = .dxvk
        let back = try JSONDecoder.highball.decode(Pin.self, from: JSONEncoder.highball.encode(p))
        XCTAssertEqual(back, p)
    }
}

extension RegressionTests {
    // Rosetta-cold services need more than upstream's 10 s SCM window (CW HACK 20218
    // uses 40 s). Shrinking this re-deadlocks the Rockstar installer and slows GOG's
    // and Battle.net's service starts.
    func testServiceTimeoutAtLeastCrossOvers() {
        XCTAssertGreaterThanOrEqual(WineRunner.servicesPipeTimeoutMs, 40000)
    }
}

extension RegressionTests {
    // The report button used to skip any log whose NAME looked like a launcher's, on the theory
    // that a game started through Steam writes its own log last (#22). For a game that can only
    // be started from the launcher's own UI — legacy CS:GO's CEG chooser — that is exactly
    // backwards: Wine gives the whole process tree one pipe, so the game's DXVK output lands in
    // the steam.exe log, and skipping it left a wineboot log with nothing in it. That is the
    // file issue #21's reporter sent, and it cost four rounds. Selection is now by content.
    /// Issue #21: the reporter sent a `-wineboot.log` twice, both times chosen by this picker,
    /// and each round cost days. A wineboot log is the prefix booting and ends before the game
    /// starts, so it can never show a game failing — but it matches a backend marker anyway,
    /// because wineboot creates a d3d adapter and Wine shouts `wined3d_adapter_create`.
    func testReportSkipsAPrefixBootLogWhenAnythingElseExists() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "hb-boot-\(UUID().uuidString)")
        let paths = HighballPaths(home: home)
        try paths.ensure()
        defer { try? FileManager.default.removeItem(at: home) }

        // Where legacy CS:GO's output actually lands: the launcher's log, written before the
        // Repair that follows a fix instruction — so the boot log is the newer of the two.
        let game = paths.logs.appending(path: "2026-08-29T210000Z-CS-steam.exe.log")
        try ["# gin E bottle=CS renderer=dxvk", "info:  DXVK-Kegworks: v1.10.4-async",
             "info:  Game: csgo.exe", "Initializing game data", "# exit=0 (ok) after 300s"]
            .joined(separator: "\n").write(to: game, atomically: true, encoding: .utf8)
        let boot = paths.logs.appending(path: "2026-08-29T211442Z-CS-wineboot.log")
        try ["# gin E bottle=CS renderer=dxvk", "# wine wineboot -u",
             "01b4:err:winediag:wined3d_adapter_create Using the Vulkan renderer for d3d10/11 applications.",
             "# exit=0 (ok) after 12s"]
            .joined(separator: "\n").write(to: boot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)],
                                              ofItemAtPath: game.path)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: boot.path)

        let body = BugReport.url(version: "0.7.17", paths: paths, samplingLiveGames: false).absoluteString.removingPercentEncoding ?? ""
        XCTAssertTrue(body.contains("DXVK-Kegworks"), "the game's own output must be attached")
        XCTAssertFalse(body.contains("wineboot -u"), "a prefix-boot log must never win over a real log")
    }

    /// But a bottle that has only ever booted still has something worth sending.
    func testReportStillAttachesABootLogWhenItIsTheOnlyOne() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "hb-boot1-\(UUID().uuidString)")
        let paths = HighballPaths(home: home)
        try paths.ensure()
        defer { try? FileManager.default.removeItem(at: home) }
        try ["# gin E bottle=CS renderer=dxvk", "# wine wineboot -u",
             "01b4:err:winediag:wined3d_adapter_create Using the Vulkan renderer",
             "# exit=53 (failed) after 12s"]
            .joined(separator: "\n")
            .write(to: paths.logs.appending(path: "2026-08-29T211442Z-CS-wineboot.log"),
                   atomically: true, encoding: .utf8)

        let body = BugReport.url(version: "0.7.17", paths: paths, samplingLiveGames: false).absoluteString.removingPercentEncoding ?? ""
        XCTAssertTrue(body.contains("wineboot -u"), "with nothing else on disk it is still the best evidence")
    }

    func testReportPicksTheLogThatNamesTheBackendEvenWhenItIsALaunchers() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hb-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let steamLog = dir.appending(path: "2026-08-28T111314Z-play-steam.exe.log")
        try """
        # gin x64-sikarugir10.0_6-r0 bottle=play renderer=dxvk
        # wine steam.exe -silent -applaunch 730
        info:  Game: csgo.exe
        info:  DXVK-Kegworks: v1.10.4-async
        info:  Found config file: C:\\highball\\dxvk.conf
        info:  Effective configuration:
        info:    d3d9.customVendorId = 1002
        info:    dxvk.enableAsync = False
        """.write(to: steamLog, atomically: true, encoding: .utf8)

        // Written LAST, so the old newest-non-launcher rule would have picked exactly this.
        let winebootLog = dir.appending(path: "2026-08-28T111500Z-play-wineboot.log")
        try """
        # gin x64-sikarugir10.0_6-r0 bottle=play renderer=wined3d
        # wine wineboot -u
        err:kerberos:kerberos_LsaApInitializePackage no Kerberos support, expect problems
        """.write(to: winebootLog, atomically: true, encoding: .utf8)
        // Make the wineboot log unambiguously the newest.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: winebootLog.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)],
                                              ofItemAtPath: steamLog.path)

        let found = BugReport.mostInformativeLog(in: [dir])
        XCTAssertEqual(found?.url.lastPathComponent, steamLog.lastPathComponent,
                       "must pick the log that actually recorded a graphics backend")
        let digest = BugReport.digest(found?.text ?? "")
        XCTAssertTrue(digest.contains("Game: csgo.exe"), "the banner naming the exe must survive")
        XCTAssertTrue(digest.contains("dxvk.enableAsync = False"), "the effective config block must survive")
    }

    // A blind suffix(30) is useless on a wine log: the end is MoltenVK warning spam while the
    // block that identifies the backend sits thousands of lines earlier (6547 of 8185 in #21).
    func testReportDigestKeepsTheBackendBlockBuriedMidLogAndCollapsesSpam() {
        var lines = ["# gin e bottle=b renderer=dxvk", "# wine steam.exe"]
        lines += (0..<3000).map { "info:  chatter \($0)" }
        lines += ["info:  Game: csgo.exe", "info:  Effective configuration:", "info:    dxvk.enableAsync = False"]
        lines += (0..<200).map { _ in "[mvk-warn] Metal does not support disabling primitive restart." }
        let digest = BugReport.digest(lines.joined(separator: "\n"))

        XCTAssertTrue(digest.contains("Game: csgo.exe"))
        XCTAssertTrue(digest.contains("dxvk.enableAsync = False"))
        XCTAssertTrue(digest.contains("# wine steam.exe"), "the launch header must survive")
        XCTAssertTrue(digest.contains("(x"), "identical repeated lines must collapse")
        XCTAssertLessThan(digest.count, BugReport.maxDigestCharacters + 1)
        XCTAssertFalse(digest.contains("chatter 1500"), "unremarkable middle must be dropped")
    }
}

extension RegressionTests {
    // The first cut of the digest capped itself with suffix(), which discards the FRONT — the
    // launch header, the backend banner and the effective-configuration block it exists to keep —
    // and preserves the MoltenVK tail spam, i.e. exactly the failure it was written to fix.
    // Measured on this machine's real logs: 15 of 411 crossed the cap and 14 lost their header.
    func testOversizedDigestKeepsTheHeadNotJustTheTail() {
        var lines = ["# gin ENGINE bottle=b renderer=dxvk", "# wine steam.exe -applaunch 730",
                     "info:  Game: csgo.exe", "info:  Effective configuration:",
                     "info:    dxvk.enableAsync = False"]
        // Distinct long error lines: the real shape that overflows the budget.
        lines += (0..<400).map { "0\($0 % 10)a\($0 % 10):err:module:import_dll Library FOO\($0).dll not found in \(String(repeating: "path/", count: 20))" }
        lines += (0..<60).map { "[mvk-warn] Metal does not support disabling primitive restart \($0)." }
        let digest = BugReport.digest(lines.joined(separator: "\n"))

        XCTAssertGreaterThan(lines.joined(separator: "\n").count, BugReport.maxDigestCharacters,
                             "fixture must actually overflow, or this test is vacuous")
        XCTAssertLessThanOrEqual(digest.count, BugReport.maxDigestCharacters + 200)
        XCTAssertTrue(digest.contains("# gin ENGINE bottle=b renderer=dxvk"), "launch header must survive truncation")
        XCTAssertTrue(digest.contains("Game: csgo.exe"), "backend banner must survive truncation")
        XCTAssertTrue(digest.contains("dxvk.enableAsync = False"), "effective config must survive truncation")
        XCTAssertTrue(digest.contains("digest lines dropped"), "truncation must be visible, never silent")
    }

    // No single line may be long enough to paste a launcher's auth token into a public issue,
    // and the user's home directory must not carry their account name there either.
    func testDigestClipsLongLinesAndRedactsHome() {
        let token = String(repeating: "eyJhbGciOiJIUzI1NiJ9.", count: 60)
        let digest = BugReport.digest("# wine x\nerr:  LogHttp: GET \(NSHomeDirectory())/x?auth=\(token)")
        XCTAssertFalse(digest.contains(token), "a long opaque value must be clipped")
        XCTAssertFalse(digest.contains(NSHomeDirectory()), "home path must be redacted to ~")
        XCTAssertTrue(digest.contains("~"))
    }

    // The digest cap is not a URL cap: percent-encoding a log several-folds it, and GitHub
    // answers a request URI over ~8 KB with 414 — the report button would silently fail.
    func testReportURLStaysUnderGitHubsRequestLimit() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "hb-url-\(UUID().uuidString)")
        let paths = HighballPaths(home: home)
        try paths.ensure()
        defer { try? FileManager.default.removeItem(at: home) }
        let noisy = (0..<3000).map { "0a0b:err:module:import_dll Library FOO\($0).dll not found" }
        try (["# gin E bottle=b renderer=dxvk", "info:  Game: csgo.exe"] + noisy)
            .joined(separator: "\n")
            .write(to: paths.logs.appending(path: "2026-08-30T000000Z-b-steam.exe.log"),
                   atomically: true, encoding: .utf8)

        let url = BugReport.url(version: "0.7.17", paths: paths, samplingLiveGames: false)
        XCTAssertLessThanOrEqual(url.absoluteString.count, BugReport.maxURLCharacters)
        XCTAssertTrue(url.absoluteString.contains("template=bug.yml"))
    }
}

extension RegressionTests {
    // D3D9 now reaches DXVK on every renderer, so the config that carries the per-game profiles
    // and the per-process log path must follow it. Gating these on `== .dxvk` left a D3D9 title
    // on a dxmt or d3dmetal bottle running DXVK with no profile and no log at all.
    func testDxvkConfigAndLogPathReachEveryNonWineD3DRenderer() throws {
        var manifest = try EngineManifest.load(from: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spike/engine-manifest.json"))
        manifest.acceptedLicenses = Array(EngineManifest.gatedRenderers.values)
        let root = FileManager.default.temporaryDirectory.appending(path: "hb-cfg-\(UUID().uuidString)")
        for r in ["dxmt", "d3dmetal", "dxvk", "d9vk"] {
            try FileManager.default.createDirectory(
                at: root.appending(path: "frameworks/renderer/\(r)/wine"), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = InstalledEngine(manifest: manifest, root: root)
        let bottle = Bottle(url: FileManager.default.temporaryDirectory.appending(path: "hb-cfg-bottle"),
                            settings: BottleSettings(name: "t", engineID: manifest.id))

        for renderer in [Renderer.dxmt, .d3dmetal, .dxvk] {
            let env = try bottle.environment(engine: engine, renderer: renderer)
            XCTAssertEqual(env["DXVK_CONFIG_FILE"], Bottle.dxvkConfigWindowsPath, "\(renderer.rawValue)")
            XCTAssertEqual(env["DXVK_LOG_PATH"], Bottle.dxvkLogWindowsPath, "\(renderer.rawValue)")
        }
        let plain = try bottle.environment(engine: engine, renderer: .wined3d)
        XCTAssertNil(plain["DXVK_CONFIG_FILE"], "wined3d uses no DXVK")
        XCTAssertNil(plain["DXVK_LOG_PATH"])
    }
}

extension RegressionTests {
    // Issue #21 cost five diagnostic rounds because a frozen game leaves no evidence: no crash,
    // no exit, no fresh log lines. The report flow now samples live game processes. The parser
    // must find the game and never the wine plumbing or launchers around it.
    func testGameProcessParserFindsTheGameNotThePlumbing() {
        let ps = """
          312 /Users/u/Library/Application Support/Highball/bottles/B/drive_c/Program Files (x86)/Steam/steam.exe -silent
          410 /Users/u/Library/Application Support/Highball/bottles/B/drive_c/Program Files (x86)/Steam/steamapps/common/csgo legacy/csgo.exe -steam -novid
          411 C:\\windows\\system32\\winedevice.exe
          500 /Users/u/Library/Application Support/Highball/bottles/B/drive_c/windows/system32/rundll32.exe d3d9.dll,Direct3DCreate9
          600 /Users/u/.build/debug/highball run B something
          700 /bin/zsh -c grep csgo.exe somewhere
          801 /Users/u/Library/Application Support/Highball/bottles/B/drive_c/Games/Some Game/Game.exe -windowed
        """
        let found = BugReport.gameProcesses(fromPS: ps)
        XCTAssertEqual(found.map(\.pid), [410, 801])
        XCTAssertEqual(found.map(\.exe), ["csgo.exe", "game.exe"])
    }

    // Launch args are DATA (db), and a workaround gated to one macOS must not leak onto
    // versions where the game already works (#21: windowed only on macOS 26+).
    func testLaunchArgsRespectTheOSGate() throws {
        let json = """
        {"id":"csgo-legacy","title":"CS:GO Legacy","steam_appid":4465480,"status":"community",
         "launchArgs":["-windowed","-noborder"],"launchArgsMinMacOS":"26.0"}
        """
        let entry = try JSONDecoder().decode(GameDBEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.effectiveLaunchArgs(osMajor: 26), ["-windowed", "-noborder"])
        XCTAssertEqual(entry.effectiveLaunchArgs(osMajor: 27), ["-windowed", "-noborder"])
        XCTAssertEqual(entry.effectiveLaunchArgs(osMajor: 14), [], "must not change working setups")

        // Ungated args apply everywhere; absent args apply nowhere.
        let ungated = try JSONDecoder().decode(GameDBEntry.self, from: Data("""
        {"id":"x","title":"X","steam_appid":1,"status":"community","launchArgs":["-novid"]}
        """.utf8))
        XCTAssertEqual(ungated.effectiveLaunchArgs(osMajor: 14), ["-novid"])
        let none = try JSONDecoder().decode(GameDBEntry.self, from: Data("""
        {"id":"y","title":"Y","steam_appid":2,"status":"community"}
        """.utf8))
        XCTAssertEqual(none.effectiveLaunchArgs(osMajor: 26), [])
    }
}

extension RegressionTests {
    // Reproduced on this machine 2026-08-30: legacy CS:GO on a bottle using the DEFAULT renderer
    // (dxmt) died with "Your graphics hardware does not support all features (CSM)". Neither the
    // dxmt nor the d3dmetal overlay ships a d3d9 for either architecture, so D3D9 fell through to
    // Wine's wined3d, whose D3D9 lacks the shadow-depth formats Source probes. 0.7.9 fixed this
    // for the dxvk renderer ONLY, leaving the default broken. Every renderer must now reach
    // DXVK's d3d9 (issue #21).
    func testEveryRendererReachesDXVKsD3D9() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spike/engine-manifest.json")
        var manifest = try EngineManifest.load(from: manifestURL)
        // d3dmetal is licence-gated (Apple GPTK); accept it so the gate isn't what's under test.
        manifest.acceptedLicenses = Array(EngineManifest.gatedRenderers.values)
        let root = FileManager.default.temporaryDirectory.appending(path: "hb-d9vk-\(UUID().uuidString)")
        // rendererDir only returns a directory that exists, so lay out the overlays it looks for.
        for r in ["dxmt", "d3dmetal", "dxvk", "d9vk"] {
            try FileManager.default.createDirectory(
                at: root.appending(path: "frameworks/renderer/\(r)/wine"), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = InstalledEngine(manifest: manifest, root: root)
        guard let d9vk = engine.rendererDir("d9vk") else { return XCTFail("fixture missing d9vk") }
        let d9vkPath = d9vk.appending(path: "wine").path

        for renderer in [Renderer.dxmt, .d3dmetal, .dxvk] {
            let env = try renderer.environment(engine: engine)
            let search = env["WINEDLLPATH_PREPEND"] ?? ""
            XCTAssertTrue(search.split(separator: ":").contains { $0 == d9vkPath },
                          "\(renderer.rawValue) must reach DXVK's d3d9 or D3D9 titles fall back to wined3d (CSM gate, #21)")
        }
        // wined3d is Wine's own stack by definition and contributes no overlay.
        XCTAssertNil(try Renderer.wined3d.environment(engine: engine)["WINEDLLPATH_PREPEND"])
    }

    // The alert used to edit `selectedBottle`, which launchGame never sets, so accepting a
    // suggestion could rewrite an unrelated bottle. The cycle itself must stay total.
    // A bottle with Microsoft's .NET Framework (dotnet48 recipe) hangs every `wineboot -u`:
    // wine.inf's 32-bit setup registers mscoree.dll, the registry marks it native, and the real
    // shim's DllRegisterServer never returns under wow64 (Repair and engine updates both hang,
    // reproduced 2026-09-03; overrides and a filtered inf were tried and do not work, see
    // WineRunner.setAsideForeignMscoree). The boot runs with the real file set aside and
    // restores it afterwards, overwriting what the boot dropped in the gap. A bottle whose
    // mscoree is the engine's own file is left alone, and a launch after a boot that died
    // halfway restores the file before running anything.
    func testWinebootSetsAsideForeignMscoreeAndRestoresIt() throws {
        let manifest = try EngineManifest.load(from: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spike/engine-manifest.json"))
        let root = FileManager.default.temporaryDirectory.appending(path: "hb-boot-\(UUID().uuidString)")
        let bottleURL = FileManager.default.temporaryDirectory.appending(path: "hb-boot-bottle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: bottleURL) }
        let fm = FileManager.default
        for dir in ["engine/lib/wine/x86_64-windows", "engine/lib/wine/i386-windows"] {
            try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
            try Data(repeating: 0, count: 100).write(to: root.appending(path: "\(dir)/mscoree.dll"))
        }
        let sys32 = bottleURL.appending(path: "drive_c/windows/system32")
        let wow64 = bottleURL.appending(path: "drive_c/windows/syswow64")
        try fm.createDirectory(at: sys32, withIntermediateDirectories: true)
        try fm.createDirectory(at: wow64, withIntermediateDirectories: true)
        let engine = InstalledEngine(manifest: manifest, root: root)
        let bottle = Bottle(url: bottleURL, settings: BottleSettings(name: "t", engineID: manifest.id))

        // Wine's own files (same size as the engine's): nothing happens.
        try Data(repeating: 0, count: 100).write(to: sys32.appending(path: "mscoree.dll"))
        try Data(repeating: 0, count: 100).write(to: wow64.appending(path: "mscoree.dll"))
        XCTAssertFalse(WineRunner.hasForeignMscoree(engine: engine, bottle: bottle))
        XCTAssertFalse(try WineRunner.setAsideForeignMscoree(engine: engine, bottle: bottle))
        XCTAssertTrue(fm.fileExists(atPath: wow64.appending(path: "mscoree.dll").path))

        // Microsoft's shim (a different file) in the 32-bit half only: both copies go aside.
        let real = Data(repeating: 7, count: 300)
        try real.write(to: wow64.appending(path: "mscoree.dll"))
        XCTAssertTrue(WineRunner.hasForeignMscoree(engine: engine, bottle: bottle))
        XCTAssertTrue(try WineRunner.setAsideForeignMscoree(engine: engine, bottle: bottle))
        XCTAssertFalse(fm.fileExists(atPath: wow64.appending(path: "mscoree.dll").path))
        XCTAssertFalse(fm.fileExists(atPath: sys32.appending(path: "mscoree.dll").path))
        XCTAssertTrue(fm.fileExists(atPath: wow64.appending(path: "mscoree.dll" + WineRunner.asideSuffix).path))

        // The boot drops Wine's copy into the gap; the restore overwrites it with the real one.
        try Data(repeating: 0, count: 100).write(to: wow64.appending(path: "mscoree.dll"))
        WineRunner.restoreMscoree(bottle: bottle)
        XCTAssertEqual(try Data(contentsOf: wow64.appending(path: "mscoree.dll")), real)
        XCTAssertTrue(fm.fileExists(atPath: sys32.appending(path: "mscoree.dll").path))
        XCTAssertFalse(fm.fileExists(atPath: wow64.appending(path: "mscoree.dll" + WineRunner.asideSuffix).path))

        // Nothing aside: restore is a no-op and leaves the files alone.
        WineRunner.restoreMscoree(bottle: bottle)
        XCTAssertEqual(try Data(contentsOf: wow64.appending(path: "mscoree.dll")), real)
    }

    // Stopping a bottle used to be `wineserver -k` and nothing else, and clients parked in the
    // Mac driver's run loop outlived it by a day (issue #48). The reaper identifies a prefix's
    // processes by working directory (inside the prefix, or the prefix's server directory) and
    // ends them. Tested on real processes: a sleep started inside a temp prefix is found and
    // terminated; one started elsewhere is left alone; our own process is never a candidate.
    func testProcessTableFindsAndEndsPrefixProcessesOnly() throws {
        let prefix = FileManager.default.temporaryDirectory.appending(path: "hb-prefix-\(UUID().uuidString)")
        let elsewhere = FileManager.default.temporaryDirectory.appending(path: "hb-elsewhere-\(UUID().uuidString)")
        for d in [prefix.appending(path: "drive_c/windows"), elsewhere] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: prefix); try? FileManager.default.removeItem(at: elsewhere) }
        func sleeper(in dir: URL) throws -> Process {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["60"]
            p.currentDirectoryURL = dir; try p.run(); return p
        }
        let inside = try sleeper(in: prefix.appending(path: "drive_c/windows"))
        let outside = try sleeper(in: elsewhere)
        defer { if outside.isRunning { outside.terminate() } }

        let found = ProcessTable.processes(ofPrefix: prefix)
        XCTAssertTrue(found.contains(inside.processIdentifier), "process working inside the prefix must be found")
        XCTAssertFalse(found.contains(outside.processIdentifier), "process working elsewhere must not")
        XCTAssertFalse(found.contains(getpid()), "never ourselves")

        let hard = ProcessTable.terminate(found)
        inside.waitUntilExit()
        XCTAssertFalse(inside.isRunning)
        XCTAssertTrue(hard.isEmpty, "sleep exits on SIGTERM, no SIGKILL needed: \(hard)")
        XCTAssertTrue(ProcessTable.processes(ofPrefix: prefix).isEmpty)
        XCTAssertTrue(outside.isRunning, "the unrelated process is untouched")

        // The pure matcher: prefix root, anything below it, and the server directory count;
        // a sibling directory that merely shares the name prefix does not.
        XCTAssertTrue(ProcessTable.belongs(workingDirectory: "/b/Gaming", toPrefix: "/b/Gaming", serverDirectory: nil))
        XCTAssertTrue(ProcessTable.belongs(workingDirectory: "/b/Gaming/drive_c", toPrefix: "/b/Gaming", serverDirectory: nil))
        XCTAssertFalse(ProcessTable.belongs(workingDirectory: "/b/Gaming2/drive_c", toPrefix: "/b/Gaming", serverDirectory: nil))
        XCTAssertTrue(ProcessTable.belongs(workingDirectory: "/tmp/.wine-501/server-1-2", toPrefix: "/b/Gaming", serverDirectory: "/tmp/.wine-501/server-1-2"))
        XCTAssertFalse(ProcessTable.belongs(workingDirectory: "/tmp/.wine-501/server-1-3", toPrefix: "/b/Gaming", serverDirectory: "/tmp/.wine-501/server-1-2"))

        // The server directory is derived from the prefix path's device and inode, the way
        // Wine names it.
        var st = stat(); XCTAssertEqual(stat(prefix.path, &st), 0)
        XCTAssertEqual(ProcessTable.serverDirectory(forPrefix: prefix)?.lastPathComponent,
                       "server-\(String(UInt64(st.st_dev), radix: 16))-\(String(st.st_ino, radix: 16))")
    }

    // Wine fixes the sync mode when a prefix's wineserver starts, and a client started with a
    // different one dies at msync_init before doing anything (issue #32: `bottle set winver`
    // reported ok while a Steam window, cold-started with sync off, was open). A launch now reads
    // the running server's environment and adopts its mode. The reader is exercised on a real
    // process with a known environment; the mode mapping and its inverse are pure.
    func testSyncModeFollowsTheRunningServersEnvironment() throws {
        XCTAssertEqual(SyncMode(environment: ["WINEMSYNC": "1", "WINEESYNC": "0"]), .msync)
        XCTAssertEqual(SyncMode(environment: ["WINEMSYNC": "0", "WINEESYNC": "1"]), .esync)
        XCTAssertEqual(SyncMode(environment: ["WINEMSYNC": "0", "WINEESYNC": "0"]), SyncMode.none)
        XCTAssertEqual(SyncMode(environment: [:]), SyncMode.none, "unset means off for a launch we control")
        for mode in SyncMode.allCases { XCTAssertEqual(SyncMode(environment: mode.environment), mode) }

        // The kernel hides the environment of Apple platform binaries, so the child is an
        // ad-hoc signed copy of sleep, which is what a Wine binary looks like to the kernel.
        let dir = FileManager.default.temporaryDirectory.appending(path: "hb-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sleeper = dir.appending(path: "sleeper")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: sleeper)
        let resign = Process(); resign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        resign.arguments = ["--force", "--sign", "-", sleeper.path]; try resign.run(); resign.waitUntilExit()
        let p = Process()
        p.executableURL = sleeper; p.arguments = ["30"]
        p.environment = ["WINEMSYNC": "0", "WINEESYNC": "0", "HB_TEST_MARKER": "yes"]
        try p.run(); defer { p.terminate() }
        usleep(200_000)
        guard p.isRunning else { throw XCTSkip("the re-signed copy of sleep does not run on this host; the reader is exercised on real Wine servers instead") }
        let read = try XCTUnwrap(ProcessTable.commandLineAndEnvironment(of: p.processIdentifier))
        XCTAssertEqual(read.arguments, [sleeper.path, "30"])
        XCTAssertEqual(read.environment["HB_TEST_MARKER"], "yes")
        XCTAssertEqual(SyncMode(environment: read.environment), SyncMode.none)

        // A platform binary's environment is hidden: the reader must not invent one.
        let platform = Process(); platform.executableURL = URL(fileURLWithPath: "/bin/sleep"); platform.arguments = ["30"]
        platform.environment = ["WINEMSYNC": "1"]; try platform.run(); defer { platform.terminate() }
        let hidden = try XCTUnwrap(ProcessTable.commandLineAndEnvironment(of: platform.processIdentifier))
        XCTAssertNil(hidden.environment["WINEMSYNC"], "platform binaries hide their environment; adoption must treat that as unknown")

        let prefix = FileManager.default.temporaryDirectory.appending(path: "hb-nosrv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        XCTAssertNil(ProcessTable.liveServer(forPrefix: prefix), "no wineserver runs for a fresh temp prefix")
        XCTAssertNil(ProcessTable.liveServerSync(forPrefix: prefix))
    }

    // The Steam tile must recognise a running client by its command line, with either path
    // separator, and not mistake helpers for it (issue #33).
    func testSteamExecutableIsRecognisedByCommandLine() {
        XCTAssertTrue(WineRunner.isSteamExecutable(#"C:\Program Files (x86)\Steam\steam.exe"#))
        XCTAssertTrue(WineRunner.isSteamExecutable("/x/drive_c/Program Files (x86)/Steam/Steam.exe"))
        XCTAssertFalse(WineRunner.isSteamExecutable(#"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe"#))
        XCTAssertFalse(WineRunner.isSteamExecutable(#"C:\windows\system32\services.exe"#))
        XCTAssertFalse(WineRunner.isSteamExecutable("steam.exe.bak"))
    }

    func testRendererSuggestionCyclesAndNeverSuggestsItself() {
        for r in Renderer.allCases {
            XCTAssertNotEqual(Renderer.suggestion(after: r), r)
        }
        XCTAssertEqual(Renderer.suggestion(after: .dxmt), .d3dmetal)
        XCTAssertEqual(Renderer.suggestion(after: .d3dmetal), .dxvk)
    }
}

extension RegressionTests {
    // The ISO 8601 stamp is second-resolution and createFile truncates, so two launches inside
    // one second destroyed each other's log. Repair fires reg, reg and wineboot back to back.
    func testLogNamesDoNotCollideWithinASecond() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hb-logname-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = WineRunner.uniqueLogURL(in: dir, named: "2026-08-28T111314Z-play-reg")
        FileManager.default.createFile(atPath: first.path, contents: nil)
        let second = WineRunner.uniqueLogURL(in: dir, named: "2026-08-28T111314Z-play-reg")
        XCTAssertNotEqual(first, second)
        // label falls back to args.first, which can be a full path — never make subdirectories.
        let flattened = WineRunner.uniqueLogURL(in: dir, named: "stamp-b-/Users/x/Program Files/a.exe")
        XCTAssertEqual(flattened.deletingLastPathComponent().path, dir.path)
    }

    // A pin's own environment is merged LAST, so Steam's persisted WINEMSYNC=0/WINEESYNC=0 wins
    // over the bottle's setting for everything launched from its window. The header must record
    // what the process really got, or a report cannot tell "sync was applied" from "sync was
    // silently overridden" — the ambiguity that made "try sync=none" a no-op in issue #21.
    func testEffectiveSyncReportsTheOverrideNotTheSetting() {
        var settings = BottleSettings(name: "t", engineID: "e")
        settings.sync = .msync
        let overridden = WineRunner.effectiveSync(env: ["WINEMSYNC": "0", "WINEESYNC": "0"], settings: settings)
        XCTAssertTrue(overridden.hasPrefix("none"))
        XCTAssertTrue(overridden.contains("bottle asks msync"))
        XCTAssertEqual(WineRunner.effectiveSync(env: ["WINEMSYNC": "1", "WINEESYNC": "0"], settings: settings), "msync")
    }
}

extension RegressionTests {
    // Pins written before 0.7.6 stored a bare filename, resolving to a drive_c-root path
    // that isn't there; launching them died with an opaque wine c0000135. Launch now
    // fails early with an actionable message (issue #23).
    func testStalePinFailsClearly() async throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spike/engine-manifest.json")
        let engine = InstalledEngine(manifest: try EngineManifest.load(from: manifestURL),
                                     root: FileManager.default.temporaryDirectory.appending(path: "hb-stale-\(UUID().uuidString)"))
        let bottleURL = FileManager.default.temporaryDirectory.appending(path: "hb-stale-bottle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bottleURL.appending(path: "drive_c"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bottleURL) }
        var settings = BottleSettings(name: "b", engineID: engine.id)
        settings.pins = [Pin(name: "Ghost", path: "Ghost.exe")]   // bare filename, target absent
        let runner = WineRunner(engine: engine, bottle: Bottle(url: bottleURL, settings: settings))
        do {
            _ = try await runner.start(pin: settings.pins[0])
            XCTFail("launching a stale pin must throw")
        } catch {
            XCTAssertTrue("\(error)".contains("isn't there"), "error should be actionable: \(error)")
        }
    }

    // storagePath must match the bottle prefix case-insensitively (APFS default).
    func testStoragePathCaseInsensitive() {
        let driveC = URL(fileURLWithPath: "/Users/x/Highball/bottles/b/drive_c")
        // A dropped URL with different casing on the volume path segments.
        let mixed = URL(fileURLWithPath: "/Users/x/Highball/Bottles/b/drive_c/Games/g.exe")
        XCTAssertEqual(Pin.storagePath(for: mixed, driveC: driveC), "Games/g.exe")
    }

    // The dotnet48 E2E gate caught this: install() ran linkRuntime inside the .partial
    // staging dir with ABSOLUTE symlink targets, then renamed staging into place, so every
    // fresh engine shipped dead runtime links (winetricks-based installs died in seconds;
    // games survived on DYLD_FALLBACK_LIBRARY_PATH). Links must be relative, and re-running
    // linkRuntime must heal a wrong target from an older install.
    func testRuntimeLinksSurviveStagingRename() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "hb-linkrt-\(UUID().uuidString)")
        let staging = base.appending(path: ".engine.partial")
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: staging.appending(path: "engine/lib"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appending(path: "frameworks/GStreamer.framework/Versions/1.0/lib"), withIntermediateDirectories: true)
        try Data("lib".utf8).write(to: staging.appending(path: "frameworks/libinotify.0.dylib"))
        try Data("gst".utf8).write(to: staging.appending(path: "frameworks/GStreamer.framework/Versions/1.0/lib/libgstreamer.dylib"))
        // A dead absolute link, as pre-0.7.9 installs left behind — must be healed, not skipped.
        try Data("st".utf8).write(to: staging.appending(path: "frameworks/libstale.dylib"))
        try fm.createSymbolicLink(atPath: staging.appending(path: "engine/lib/libstale.dylib").path,
                                  withDestinationPath: "/nonexistent/.old.partial/frameworks/libstale.dylib")

        try EngineStore().linkRuntime(staging)
        let final = base.appending(path: "engine-final")
        try fm.moveItem(at: staging, to: final)   // the rename that killed absolute targets

        for name in ["libinotify.0.dylib", "libgstreamer.dylib", "libstale.dylib"] {
            let link = final.appending(path: "engine/lib/\(name)")
            let target = try fm.destinationOfSymbolicLink(atPath: link.path)
            XCTAssertTrue(target.hasPrefix("../../frameworks/"), "\(name) target must be relative, got \(target)")
            XCTAssertTrue(fm.fileExists(atPath: link.path), "\(name) must resolve after the rename")
        }
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: final.appending(path: "engine/lib/GStreamer.framework").path),
                       "../../frameworks/GStreamer.framework")
    }

    // Issues #27/#28: winetricks was sha256-pinned but fetched from .../master/..., so
    // upstream's next commit broke every fresh engine install with "checksum mismatch".
    // Manifest URLs must be immutable: a commit SHA or a tagged release asset, never a
    // branch or a latest redirect. Raw-JSON scan on purpose — it also covers blocks the
    // manifest type doesn't decode (alternatives).
    func testManifestURLsAreImmutablyPinned() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spike/engine-manifest.json")
        let json = try String(contentsOf: manifestURL, encoding: .utf8)
        for bad in ["/master/", "/main/", "/refs/heads/", "/HEAD/", "/releases/latest/"] {
            XCTAssertFalse(json.contains(bad), "engine-manifest.json contains mutable ref '\(bad)' — pin a commit SHA or a release asset")
        }
        let manifest = try EngineManifest.load(from: manifestURL)
        for (name, component) in manifest.components {
            XCTAssertEqual(component.sha256.count, 64, "\(name): sha256 required")
            XCTAssertEqual(component.url.scheme, "https", "\(name): https only")
        }
    }

    // A component that replaces a file another component installed (the patched MoltenVK on
    // top of the runtime's) must extract after it. `order` is the only thing that guarantees
    // that: by key alone "moltenvk" sorts before "runtime" and would be silently overwritten.
    func testComponentOrderBeatsAlphabeticalKey() throws {
        let json = """
        {"id":"e","displayName":"e","arch":"x86_64","minMacOS":"14.0","components":{
          "moltenvk":{"kind":"runtime","url":"https://x/m.tgz","sha256":"a","order":1,
                      "extract":{"subpath":"libMoltenVK.dylib","into":"frameworks/libMoltenVK.dylib"}},
          "runtime":{"kind":"frameworks","url":"https://x/r.tgz","sha256":"b","extract":{"into":"frameworks"}},
          "d3dmetal":{"kind":"renderer","url":"https://x/d.tgz","sha256":"c","optional":true,"acceptance":"l"}
        }}
        """
        let m = try JSONDecoder().decode(EngineManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.orderedComponents.map(\.name), ["runtime", "moltenvk", "d3dmetal"],
                       "required components by order then key, optional ones last")
    }

    // The shipped manifest must keep that guarantee: the runtime's frameworks land first, the
    // patched MoltenVK replaces exactly one file inside them afterwards.
    func testShippedMoltenVKComponentLandsAfterRuntime() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spike/engine-manifest.json")
        let m = try EngineManifest.load(from: url)
        let names = m.orderedComponents.map(\.name)
        guard let r = names.firstIndex(of: "runtime"), let v = names.firstIndex(of: "moltenvk") else {
            return XCTFail("manifest needs both runtime and moltenvk components")
        }
        XCTAssertLessThan(r, v, "moltenvk must extract after runtime or the runtime overwrites it")
        XCTAssertEqual(m.components["moltenvk"]?.extract?.into, "frameworks/libMoltenVK.dylib")
    }

    // After an engine update the old and new engines coexist until the old one is removed;
    // sorted by id the old one comes first, so "first installed" would keep choosing it for
    // new bottles and the sidebar. The bundled manifest's id must win when it is installed.
    // An engine update must never remove an engine a bottle still runs on, and never the default.
    func testUnreferencedEnginesKeepsWhatBottlesUse() throws {
        func engine(_ id: String) throws -> InstalledEngine {
            let json = #"{"id":"\#(id)","displayName":"e","arch":"x86_64","minMacOS":"14.0","components":{}}"#
            let m = try JSONDecoder().decode(EngineManifest.self, from: Data(json.utf8))
            return InstalledEngine(manifest: m, root: URL(fileURLWithPath: "/tmp/\(id)"))
        }
        let r0 = try engine("x64-sikarugir10.0_6-r0"), r1 = try engine("x64-sikarugir10.0_6-r1"), r2 = try engine("x64-sikarugir11.0_0-r0")
        let all = [r0, r1, r2]
        XCTAssertEqual(EngineStore.unreferencedEngines(installed: all, referencedIDs: [r1.id], defaultID: r2.id).map(\.id), [r0.id],
                       "r1 is in use, r2 is the default: only r0 goes")
        XCTAssertEqual(EngineStore.unreferencedEngines(installed: all, referencedIDs: [r0.id, r1.id], defaultID: r2.id).map(\.id), [],
                       "every old engine still has a bottle: nothing is removed")
        XCTAssertEqual(EngineStore.unreferencedEngines(installed: all, referencedIDs: [], defaultID: r2.id).map(\.id), [r0.id, r1.id])
        XCTAssertEqual(EngineStore.unreferencedEngines(installed: all, referencedIDs: [], defaultID: nil).map(\.id), all.map(\.id))
        XCTAssertEqual(EngineStore.unreferencedEngines(installed: all, referencedIDs: [], defaultID: r2.id, keep: [r1.id]).map(\.id), [r0.id],
                       "an engine the app still offers (bundled manifest) is kept for rollback even with no bottle on it")
    }

    // The crash alert's second way out: the default engine when the bottle is not on it, else the
    // newest other engine, and nothing with a single engine installed.
    func testAlternateEngineForCrashAlert() throws {
        func engine(_ id: String) throws -> InstalledEngine {
            let json = #"{"id":"\#(id)","displayName":"e","arch":"x86_64","minMacOS":"14.0","components":{}}"#
            let m = try JSONDecoder().decode(EngineManifest.self, from: Data(json.utf8))
            return InstalledEngine(manifest: m, root: URL(fileURLWithPath: "/tmp/\(id)"))
        }
        let r1 = try engine("x64-sikarugir10.0_6-r1"), r2 = try engine("x64-sikarugir11.0_0-r0")
        XCTAssertEqual(EngineStore.alternateEngine(for: r1.id, installed: [r1, r2], defaultID: r2.id)?.id, r2.id, "old bottle: offer the default")
        XCTAssertEqual(EngineStore.alternateEngine(for: r2.id, installed: [r1, r2], defaultID: r2.id)?.id, r1.id, "on the default: offer the previous engine")
        XCTAssertNil(EngineStore.alternateEngine(for: r1.id, installed: [r1], defaultID: r1.id), "single engine: nothing to offer")
        let r9 = try engine("x64-sikarugir10.0_6-r9"), r10 = try engine("x64-sikarugir10.0_6-r10")
        XCTAssertEqual(EngineStore.alternateEngine(for: r2.id, installed: [r9, r2, r10], defaultID: r2.id)?.id, r10.id,
                       "on the default with two others: the newest by numeric order, r10 over r9")
    }

    // The Engine picker lists installed engines first, then known manifests to download, newest first.
    func testOfferedEnginesListsInstalledThenDownloadable() throws {
        func manifest(_ id: String) throws -> EngineManifest {
            let json = #"{"id":"\#(id)","displayName":"e \#(id)","arch":"x86_64","minMacOS":"14.0","components":{}}"#
            return try JSONDecoder().decode(EngineManifest.self, from: Data(json.utf8))
        }
        let r1 = InstalledEngine(manifest: try manifest("x64-a-r1"), root: URL(fileURLWithPath: "/tmp/r1"))
        let r0 = InstalledEngine(manifest: try manifest("x64-a-r0"), root: URL(fileURLWithPath: "/tmp/r0"))
        let known = [try manifest("x64-a-r1"), try manifest("x64-a-r2"), try manifest("x64-a-r10")]
        let offered = EngineStore.offeredEngines(installed: [r0, r1], known: known)
        XCTAssertEqual(offered.map(\.id), ["x64-a-r1", "x64-a-r0", "x64-a-r10", "x64-a-r2"])
        XCTAssertEqual(offered.map(\.installed), [true, true, false, false])
        XCTAssertEqual(EngineStore.offeredEngines(installed: [r1], known: [try manifest("x64-a-r1")]).count, 1, "the installed default is not listed twice")
        let withMissing = EngineStore.offeredEngines(installed: [r1], known: [], current: "x64-gone-r0")
        XCTAssertEqual(withMissing.map(\.id), ["x64-a-r1", "x64-gone-r0"], "a bottle on an engine that is gone still sees its own row")
        XCTAssertEqual(withMissing.last?.missing, true)
        XCTAssertEqual(EngineStore.offeredEngines(installed: [r1], known: [], current: r1.id).count, 1, "current engine present: no extra row")
    }

    // A bottle set up by an old Steam recipe carries WINEMSYNC=0/WINEESYNC=0 in its bottle-wide
    // environment, which silently turned msync off for every game. Format 3 drops exactly that
    // pair once; a deliberate WINEMSYNC=1 or a single variable is left alone.
    func testFormat3DropsTheStaleSyncPair() throws {
        func decode(_ env: String, version: Int) throws -> BottleSettings {
            let json = #"{"formatVersion":\#(version),"name":"g","engineID":"e","environment":\#(env)}"#
            return try JSONDecoder().decode(BottleSettings.self, from: Data(json.utf8))
        }
        let stale = try decode(#"{"WINEMSYNC":"0","WINEESYNC":"0","MVK_SHADOW_IMPORT":"1"}"#, version: 2)
        XCTAssertEqual(stale.environment, ["MVK_SHADOW_IMPORT": "1"])
        XCTAssertEqual(stale.formatVersion, 3)
        XCTAssertTrue(stale.needsSave)
        let deliberate = try decode(#"{"WINEMSYNC":"1","WINEESYNC":"0"}"#, version: 2)
        XCTAssertEqual(deliberate.environment, ["WINEMSYNC": "1", "WINEESYNC": "0"], "not the stale pair: untouched")
        let single = try decode(#"{"WINEMSYNC":"0"}"#, version: 2)
        XCTAssertEqual(single.environment, ["WINEMSYNC": "0"])
        let current = try decode(#"{"WINEMSYNC":"0","WINEESYNC":"0"}"#, version: 3)
        XCTAssertEqual(current.environment.count, 2, "already format 3: the user's own lines stay")
        XCTAssertFalse(current.needsSave)
    }

    // The verifier names the Direct3D implementation from the overlays' per-process logs written
    // during the run; Steam's helpers do not count, and nothing written means Wine's own.
    func testVerifierNamesTheDirect3DImplementationFromOverlayLogs() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hb-served-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let since = Date().addingTimeInterval(-5)
        XCTAssertEqual(Verifier.servedImplementation(logsDirectory: dir, since: since), "wined3d", "no overlay log at all")
        try "info:  Game: steamwebhelper.exe\ninfo:  DXVK-Kegworks: v1.10.4".write(to: dir.appending(path: "steamwebhelper_d3d11.log"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Verifier.servedImplementation(logsDirectory: dir, since: since), "wined3d", "Steam's own helper is not the game")
        try "info:  Game: portal2.exe\ninfo:  DXVK-Kegworks: v1.10.4-async".write(to: dir.appending(path: "portal2_d3d9.log"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Verifier.servedImplementation(logsDirectory: dir, since: since), "dxvk")
        try "info: dxmt v0.80\n".write(to: dir.appending(path: "game_d3d11.log"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Verifier.servedImplementation(logsDirectory: dir, since: since), "dxmt", "a DXMT file outranks d9vk's d3d9 file for the same run")
        XCTAssertEqual(Verifier.servedImplementation(logsDirectory: dir, since: Date().addingTimeInterval(60)), "wined3d", "files older than the run do not count")
        try? FileManager.default.removeItem(at: dir)
    }

    // Log pruning: age beyond the newest N, then size, never the verifier's results.
    func testLogPrunerPolicy() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func e(_ name: String, daysOld: Double, mb: Int64) -> LogPruner.Entry {
            LogPruner.Entry(url: URL(fileURLWithPath: "/logs/\(name)"), size: mb * 1_048_576, modified: now.addingTimeInterval(-daysOld * 86_400))
        }
        let entries = [e("old1", daysOld: 30, mb: 1), e("old2", daysOld: 20, mb: 1), e("fresh", daysOld: 1, mb: 1),
                       e("verify-results.jsonl", daysOld: 100, mb: 1), e("big-old", daysOld: 10, mb: 400), e("big-new", daysOld: 0.5, mb: 400)]
        let byAge = LogPruner.plan(entries, now: now, keepDays: 14, maxTotalBytes: 10_000 * 1_048_576, keepNewest: 2)
        XCTAssertEqual(Set(byAge.map(\.lastPathComponent)), ["old1", "old2"], "older than 14 days and not among the newest two")
        let bySize = LogPruner.plan(entries, now: now, keepDays: 14, maxTotalBytes: 500 * 1_048_576, keepNewest: 2, protectNewest: 2)
        XCTAssertTrue(bySize.map(\.lastPathComponent).contains("big-old"), "size rule removes the oldest big file")
        XCTAssertFalse(bySize.map(\.lastPathComponent).contains("big-new"), "the newest files are never removed for size")
        XCTAssertFalse(bySize.map(\.lastPathComponent).contains("verify-results.jsonl"))
        XCTAssertEqual(LogPruner.plan(entries, now: now, keepDays: 14, maxTotalBytes: 10_000 * 1_048_576, keepNewest: 10).count, 0, "everything within the newest ten stays")
        let fewHuge = (0..<40).map { e("t\($0)", daysOld: Double($0), mb: 100) }
        let bySizeFew = LogPruner.plan(fewHuge, now: now, keepDays: 14, maxTotalBytes: 300 * 1_048_576, keepNewest: 50)
        XCTAssertEqual(bySizeFew.count, 35, "the size cap holds even with fewer files than the age rule's allowance; the newest five stay")
    }

    // Preflight: the 32-bit half check is a file test, so it is free on the happy path.
    func testPreflightNeedsRepairOnlyWithoutSyswow64() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hb-preflight-\(UUID().uuidString)")
        let bottle = Bottle(url: dir, settings: BottleSettings(name: "p", engineID: "e"))
        XCTAssertTrue(BottleStore.needsPreflightRepair(bottle))
        let k32 = dir.appending(path: "drive_c/windows/syswow64/kernel32.dll")
        try FileManager.default.createDirectory(at: k32.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: k32)
        XCTAssertFalse(BottleStore.needsPreflightRepair(bottle))
        try? FileManager.default.removeItem(at: dir)
    }

    // Resumable downloads: the range request and the append-or-restart decision (Phase 0.1).
    func testDownloadResumeDecisions() {
        XCTAssertNil(DownloadResume.rangeHeaders(partialBytes: 0, etag: "\"abc\""), "nothing on disk: plain request")
        XCTAssertEqual(DownloadResume.rangeHeaders(partialBytes: 1234, etag: "\"abc\""), ["Range": "bytes=1234-", "If-Range": "\"abc\""])
        XCTAssertEqual(DownloadResume.rangeHeaders(partialBytes: 1234, etag: nil), ["Range": "bytes=1234-"])
        XCTAssertEqual(DownloadResume.decide(status: 206, partialBytes: 1234), .append)
        XCTAssertEqual(DownloadResume.decide(status: 200, partialBytes: 1234), .restart, "the server ignored the range or the asset changed: start over")
        XCTAssertEqual(DownloadResume.decide(status: 206, partialBytes: 0), .restart)
        XCTAssertEqual(DownloadResume.decide(status: 404, partialBytes: 0), .failed)
        XCTAssertEqual(DownloadResume.decide(status: 416, partialBytes: 5), .restart, "a complete or stale partial must not wedge every retry")
    }

    // Dependencies detect by artifacts, not by "our recipe ran" (plan Phase 0.3).
    func testRegistryTextAndInstalledMarkers() throws {
        let reg = """
        WINE REGISTRY Version 2

        [Software\\\\Microsoft\\\\NET Framework Setup\\\\NDP\\\\v4\\\\Full] 1788462370
        #time=1dd3c551aef527e
        "Install"=dword:00000001
        "Release"=dword:00082348

        [Software\\\\Microsoft\\\\VisualStudio\\\\14.0\\\\VC\\\\Runtimes\\\\x64] 1788462371
        "Installed"=dword:00000001
        "Version"="v14.44.35211.00"
        """
        XCTAssertEqual(RegistryText.value(in: reg, key: "Software\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full", name: "Release"), "dword:00082348")
        XCTAssertEqual(RegistryText.value(in: reg, key: "Software\\\\Microsoft\\\\NET Framework Setup\\\\NDP\\\\v4\\\\Full", name: "Release"), "dword:00082348", "doubled backslashes accepted too")
        XCTAssertEqual(RegistryText.value(in: reg, key: "Software\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\x64", name: "Version"), "\"v14.44.35211.00\"")
        XCTAssertNil(RegistryText.value(in: reg, key: "Software\\Nothing", name: "Release"))
        XCTAssertEqual(RegistryText.dword("dword:00082348"), 533320)
        XCTAssertEqual(RegistryText.value(in: reg, key: "SOFTWARE\\microsoft\\NET Framework Setup\\NDP\\v4\\Full", name: "release"), "dword:00082348", "the registry is case-insensitive")

        let dir = FileManager.default.temporaryDirectory.appending(path: "hb-markers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "drive_c/windows/system32"), withIntermediateDirectories: true)
        try reg.write(to: dir.appending(path: "system.reg"), atomically: true, encoding: .utf8)
        let bottle = Bottle(url: dir, settings: BottleSettings(name: "m", engineID: "e"))
        var recipe = Recipe(id: "dotnet48", kind: .tweak, title: ".NET", requires: nil, renderer: nil, steps: [], knownIssues: nil, lastVerified: nil, blocked: nil, installedMarkers: nil)
        XCTAssertFalse(recipe.isInstalled(in: bottle), "no markers: unknown, reported as not installed")
        recipe.installedMarkers = [.init(file: nil, registry: "Software\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full", value: "Release", equals: nil, min: 528040)]
        XCTAssertTrue(recipe.isInstalled(in: bottle), "4.8.1's Release 533320 satisfies the 4.8 minimum")
        recipe.installedMarkers = [.init(file: nil, registry: "Software\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full", value: "Release", equals: nil, min: 600000)]
        XCTAssertFalse(recipe.isInstalled(in: bottle))
        recipe.installedMarkers = [.init(file: "windows/system32/marker.dll", registry: nil, value: nil, equals: nil, min: nil)]
        XCTAssertFalse(recipe.isInstalled(in: bottle))
        try Data().write(to: dir.appending(path: "drive_c/windows/system32/marker.dll"))
        XCTAssertTrue(recipe.isInstalled(in: bottle))
        try? FileManager.default.removeItem(at: dir)
    }

    // Failures reach the user as a sentence, a meaning and at most one button (plan §3.6).
    func testRecoveryMapping() {
        let mismatch = Recovery.describe(HighballError.checksumMismatch(file: "engine.tar.gz", expected: "a", actual: "b"))
        XCTAssertEqual(mismatch.action, .retry); XCTAssertEqual(mismatch.actionTitle, "Download again")
        XCTAssertFalse(mismatch.headline.contains("engine.tar.gz"), "no file names on the primary surface")
        let boot = Recovery.describe(HighballError.processFailed(command: "wineboot -u", status: 1, output: "see /tmp/x.log"))
        XCTAssertEqual(boot.action, .repairBottle)
        XCTAssertFalse(boot.headline.contains("1") || boot.meaning.contains("/tmp"), "no exit codes or paths")
        let installer = Recovery.describe(HighballError.processFailed(command: "VC_redist.x64.exe /install", status: 3010, output: ""))
        XCTAssertEqual(installer.action, .retry); XCTAssertTrue(installer.headline.hasPrefix("VC_redist.x64.exe"))
        let wow = Recovery.describe(HighballError.invalid("Windows 32-bit support couldn't be set up in this bottle"))
        XCTAssertEqual(wow.action, .repairBottle)
        let net = Recovery.describe(URLError(.timedOut))
        XCTAssertEqual(net.action, .retry); XCTAssertFalse(net.headline.lowercased().contains("connection dropped"), "a timeout is not a diagnosed cause")
        let plain = Recovery.describe(HighballError.failed("Steam is already running."))
        XCTAssertEqual(plain.headline, "Steam is already running."); XCTAssertNil(plain.actionTitle)
    }

    // The decoder's migration flag is transient and must not appear in bottle.json.
    func testNeedsSaveIsNotEncoded() throws {
        var s = BottleSettings(name: "b", engineID: "e"); s.needsSave = true
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        XCTAssertFalse(json.contains("needsSave"))
        XCTAssertTrue(json.contains("\"formatVersion\":3"))
    }

    // Sessions are detected from processes, in both path spellings Wine reports (plan 0.6).
    func testSessionMarkersAndLiveness() {
        let m = SessionWatch.markers(installdir: "Portal 2")
        let unix = "1234 ?? 0:01.00 Z:\\Program Files (x86)\\Steam\\steamapps\\common\\Portal 2\\portal2.exe -novid"
        let win = "1234 ?? 0:01.00 /Users/me/Library/Application Support/Highball/bottles/Gaming/drive_c/Program Files (x86)/Steam/steamapps/common/Portal 2/portal2.exe"
        XCTAssertTrue(SessionWatch.isAlive(markers: m, ps: unix))
        XCTAssertTrue(SessionWatch.isAlive(markers: m, ps: win))
        XCTAssertFalse(SessionWatch.isAlive(markers: m, ps: "1 ?? 0:00.00 steam.exe -silent"))
        XCTAssertFalse(SessionWatch.isAlive(markers: m, ps: "steamapps/common/Portal 2 Fan Mod/x.exe"), "the trailing separator keeps a sibling folder out")
        let r = SessionRecord(title: "Portal 2", bottle: "Gaming", appid: 620, started: Date(timeIntervalSince1970: 0), ended: Date(timeIntervalSince1970: 754), reason: "ended")
        XCTAssertEqual(r.seconds, 754)
    }

    func testDefaultEnginePrefersBundledManifestID() throws {
        func engine(_ id: String) throws -> InstalledEngine {
            let json = #"{"id":"\#(id)","displayName":"e","arch":"x86_64","minMacOS":"14.0","components":{}}"#
            let m = try JSONDecoder().decode(EngineManifest.self, from: Data(json.utf8))
            return InstalledEngine(manifest: m, root: URL(fileURLWithPath: "/tmp/\(id)"))
        }
        let old = try engine("x64-sikarugir10.0_6-r0"), new = try engine("x64-sikarugir10.0_6-r1")
        XCTAssertEqual(EngineStore.defaultEngine(installed: [old, new], bundledID: new.id)?.id, new.id)
        XCTAssertEqual(EngineStore.defaultEngine(installed: [old, new], bundledID: nil)?.id, new.id, "no manifest (the CLI): newest installed, not the alphabetically first")
        XCTAssertEqual(EngineStore.defaultEngine(installed: [new, old], bundledID: nil)?.id, new.id, "order of discovery must not matter")
        XCTAssertEqual(EngineStore.defaultEngine(installed: [old], bundledID: new.id)?.id, old.id, "update not installed yet: keep using the old one")
        XCTAssertNil(EngineStore.defaultEngine(installed: [], bundledID: new.id))
        let r9 = try engine("x64-sikarugir10.0_6-r9"), r10 = try engine("x64-sikarugir10.0_6-r10")
        XCTAssertEqual(EngineStore.defaultEngine(installed: [r10, r9], bundledID: nil)?.id, r10.id, "numeric-aware: r10 is newer than r9 although it sorts first as a string")
    }

    // An engine update only re-runs wineboot on each bottle when the Wine build changed. r1 is
    // r0 plus a MoltenVK component; booting every prefix for it is pure risk (a bottle with a real
    // .NET install wedged in wineboot's 32-bit step on both engines when this was tried).
    func testPrefixRefreshOnlyWhenWineChanges() throws {
        func manifest(_ wineSha: String?, id: String) throws -> EngineManifest {
            let wine = wineSha.map { #","wine":{"kind":"engine","url":"https://x/w.tar.xz","sha256":"\#($0)","extract":{"into":"engine"}}"# } ?? ""
            let json = #"{"id":"\#(id)","displayName":"e","arch":"x86_64","minMacOS":"14.0","components":{"runtime":{"kind":"frameworks","url":"https://x/r.tar.xz","sha256":"r","extract":{"into":"frameworks"}}\#(wine)}}"#
            return try JSONDecoder().decode(EngineManifest.self, from: Data(json.utf8))
        }
        let r0 = try manifest("aaa", id: "r0"), r1 = try manifest("aaa", id: "r1"), r2 = try manifest("bbb", id: "r2")
        XCTAssertFalse(EngineManifest.needsPrefixRefresh(from: r0, to: r1), "same Wine: no wineboot")
        XCTAssertTrue(EngineManifest.needsPrefixRefresh(from: r0, to: r2), "Wine changed: wineboot")
        XCTAssertTrue(EngineManifest.needsPrefixRefresh(from: try manifest(nil, id: "x"), to: r1), "unknown: be safe, boot")
        XCTAssertTrue(EngineManifest.needsPrefixRefresh(from: nil, to: r1), "source engine gone: boot")
        XCTAssertFalse(EngineManifest.needsPrefixRefresh(from: Optional(r0), to: r1), "the optional overload keeps the same-Wine rule")
    }

    // A Play that auto-applies a recipe with environment or renderer steps must restart the
    // bottle: a running Steam keeps its old environment and the game would launch without the
    // fix (the Sims recipe's MVK_SHADOW_IMPORT=1 would silently do nothing).
    func testRecipeKnowsWhenItChangesTheLaunchEnvironment() throws {
        func recipe(_ steps: String) throws -> HighballKit.Recipe {
            try JSONDecoder().decode(HighballKit.Recipe.self, from: Data(#"{"id":"r","kind":"game","title":"r","steps":[\#(steps)]}"#.utf8))
        }
        XCTAssertTrue(try recipe(#"{"type":"environment","name":"MVK_SHADOW_IMPORT","value":"1"}"#).changesLaunchEnvironment)
        XCTAssertTrue(try recipe(#"{"type":"renderer","renderer":"dxvk"}"#).changesLaunchEnvironment)
        XCTAssertFalse(try recipe(#"{"type":"file","path":"a/b.txt","contents":"x"},{"type":"note","text":"n"}"#).changesLaunchEnvironment,
                       "config files alone do not need a restart")
    }

    // extract() with a single-file `into` replaces that file and nothing else in the directory.
    // The old code treated every target as a directory, so a file target would have removed
    // the whole frameworks tree on the way in.
    func testExtractSingleFileTargetKeepsSiblings() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appending(path: "hb-extract-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = tmp.appending(path: "root", directoryHint: .isDirectory)
        let frameworks = root.appending(path: "frameworks", directoryHint: .isDirectory)
        try fm.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try "old".write(to: frameworks.appending(path: "libMoltenVK.dylib"), atomically: true, encoding: .utf8)
        try "keep".write(to: frameworks.appending(path: "libother.dylib"), atomically: true, encoding: .utf8)
        let src = tmp.appending(path: "src", directoryHint: .isDirectory)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try "new".write(to: src.appending(path: "libMoltenVK.dylib"), atomically: true, encoding: .utf8)
        let archive = tmp.appending(path: "m.tar.gz")
        try Shell.run("/usr/bin/tar", ["-czf", archive.path, "-C", src.path, "libMoltenVK.dylib"])
        defer { try? fm.removeItem(at: tmp) }

        let component = try JSONDecoder().decode(EngineManifest.Component.self, from: Data("""
        {"kind":"runtime","url":"https://x/m.tgz","sha256":"a","order":1,
         "extract":{"subpath":"libMoltenVK.dylib","into":"frameworks/libMoltenVK.dylib"}}
        """.utf8))
        try EngineStore().extract(archive, component: component, name: "moltenvk", into: root)
        XCTAssertEqual(try String(contentsOf: frameworks.appending(path: "libMoltenVK.dylib"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: frameworks.appending(path: "libother.dylib"), encoding: .utf8), "keep",
                       "a file target must not wipe the directory it lands in")
    }

    // Issue #31: install progress must be legible without reading raw Wine output. The step
    // line carries the label, the hint line the slow-step expectation, and neither may leak
    // into the other.
    func testProgressParserStagesAndHints() {
        XCTAssertEqual(ProgressParser.stage(for: "[steam] step 2/6"), "Step 2 of 6")
        XCTAssertEqual(ProgressParser.stage(for: "[dotnet48] step 1/2 — dotnet48"),
                       "Step 1 of 2 — dotnet48")
        XCTAssertNil(ProgressParser.stage(for: "[dotnet48] hint: takes 20-40 minutes"),
                     "hint lines are not stages")
        XCTAssertEqual(ProgressParser.hint(for: "[dotnet48] hint: takes 20-40 minutes"),
                       "takes 20-40 minutes")
        XCTAssertNil(ProgressParser.hint(for: "0024:err:something hint: not a recipe line"),
                     "hints must come from a [recipe] line, not arbitrary output")
        XCTAssertEqual(ProgressParser.stage(for: "Extracting package foo"),
                       "Extracting the Steam client — this takes a few minutes")
        XCTAssertNil(ProgressParser.stage(for: "plain wine noise"))
    }

    // Issue #31: the `slow` field must survive a decode/encode round trip, default to nil for
    // existing recipes, and surface via slowHint for exactly the step kinds that can be slow.
    func testRecipeSlowHintDecoding() throws {
        let json = """
        {"id":"t","kind":"tweak","title":"T","steps":[
          {"type":"installer","url":"https://example.com/x.exe","label":"x",
           "slow":"takes 20-40 minutes and can look idle"},
          {"type":"winetricks","verbs":["corefonts"]},
          {"type":"winver","winver":"win10"},
          {"type":"note","text":"done"}
        ]}
        """
        let recipe = try JSONDecoder.highball.decode(Recipe.self, from: Data(json.utf8))
        XCTAssertEqual(recipe.steps[0].slowHint, "takes 20-40 minutes and can look idle")
        XCTAssertEqual(recipe.steps[0].progressLabel, "x")
        XCTAssertNil(recipe.steps[1].slowHint, "absent slow decodes as nil")
        XCTAssertEqual(recipe.steps[1].progressLabel, "corefonts")
        // The winver step (dotnet48 leaves prefixes on win7 — Steam deprecation banner —
        // unless a recipe can restore win10) must decode.
        guard case let .winver(v) = recipe.steps[2] else { return XCTFail("winver step did not decode") }
        XCTAssertEqual(v, .win10)
        XCTAssertNil(recipe.steps[3].slowHint)
        let reencoded = try JSONEncoder().encode(recipe)
        let again = try JSONDecoder.highball.decode(Recipe.self, from: reencoded)
        XCTAssertEqual(again.steps[0].slowHint, "takes 20-40 minutes and can look idle")
    }

    // Library Phase 1: Epic artwork comes from legendary's embedded catalog metadata
    // (same keyImages mapping Heroic uses); a game without metadata must still decode.
    func testEpicGameArtworkDecoding() throws {
        let json = """
        [{"app_name":"Duck","app_title":"Cardpocalypse","metadata":{"keyImages":[
           {"type":"DieselGameBox","url":"https://cdn1.epicgames.com/item/x/wide.jpg"},
           {"type":"DieselGameBoxTall","url":"https://cdn1.epicgames.com/item/x/tall.jpg"},
           {"type":"Thumbnail","url":"https://cdn1.epicgames.com/item/x/thumb.jpg"}]}},
         {"app_name":"Bare","app_title":"No Art"}]
        """
        let games = try JSONDecoder().decode([EpicStore.Game].self, from: Data(json.utf8))
        XCTAssertEqual(games[0].artworkWide?.absoluteString, "https://cdn1.epicgames.com/item/x/wide.jpg")
        XCTAssertEqual(games[0].artworkTall?.absoluteString, "https://cdn1.epicgames.com/item/x/tall.jpg")
        XCTAssertNil(games[1].artworkWide, "missing metadata decodes, without artwork")
        XCTAssertNil(games[1].artworkTall)
    }

    // Library Phase 1: legendary's install state is global; the bottle association is the
    // install path. A game installed in bottle A must not read as installed in bottle B,
    // and a sibling bottle whose name shares a prefix must not false-positive.
    func testEpicInstallStateIsPerBottle() {
        let a = URL(fileURLWithPath: "/tmp/bottles/actest/drive_c")
        let b = URL(fileURLWithPath: "/tmp/bottles/spike/drive_c")
        let path = "/tmp/bottles/actest/drive_c/Games/Cardpocalypse"
        XCTAssertTrue(EpicStore.isInstalled(path: path, inDriveC: a))
        XCTAssertFalse(EpicStore.isInstalled(path: path, inDriveC: b))
        XCTAssertFalse(EpicStore.isInstalled(path: "/tmp/bottles/actest2/drive_c/Games/X",
                                             inDriveC: a), "prefix of a sibling bottle must not match")
        XCTAssertTrue(EpicStore.isInstalled(path: "/tmp/bottles/actest/drive_c", inDriveC: a),
                      "drive_c itself counts as inside")
    }

    // Issue #37: "Can't install anything". Wine builds a prefix's 32-bit half by launching a
    // 32-bit rundll32; when that fails, wineboot skips it and STILL exits 0, so an exit-code
    // check reports a healthy bottle in which every 32-bit installer dies with
    // "could not load kernel32.dll, status c0000135". The 32-bit half must be checked by
    // its files, not by the exit code.
    func testWoW64PresenceIsCheckedByFileNotExitCode() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "hb-wow64-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bottle = Bottle(url: tmp, settings: BottleSettings(name: "b", engineID: "e"))
        let marker = BottleStore.woW64Kernel32(in: bottle)
        XCTAssertTrue(marker.path.hasSuffix("drive_c/windows/syswow64/kernel32.dll"),
                      "the 32-bit half is proven by syswow64's kernel32, the dll Wine dies without")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "absent on a bare prefix")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // An empty syswow64 directory is exactly the broken state — the folder existing is not
        // enough, which is why the check names the file.
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        try Data("pe".utf8).write(to: marker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    // Issue #36: "Visual C++ Failed to install". The exit code Swift sees is twice-truncated —
    // WiX Burn returns HRESULT_CODE (0x80070666 → 1638), then POSIX keeps 8 bits (1638 → 102).
    // A strict `== 0` guard therefore failed the VC++ recipe at step 1 of 14 whenever a newer
    // runtime was already present, leaving the 11 DLL overrides unapplied.
    func testInstallerAcceptsBenignWindowsExitCodes() throws {
        let json = """
        {"id":"t","kind":"tweak","title":"T","steps":[
          {"type":"installer","url":"https://example.com/a.exe","label":"a"},
          {"type":"installer","url":"https://example.com/b.exe","label":"b","okExitCodes":[42]},
          {"type":"winetricks","verbs":["corefonts"]}]}
        """
        let r = try JSONDecoder.highball.decode(Recipe.self, from: Data(json.utf8))
        // Truncation arithmetic is the whole point — verify it, don't assume it.
        XCTAssertEqual(1638 & 0xFF, 102); XCTAssertEqual(3010 & 0xFF, 194); XCTAssertEqual(1641 & 0xFF, 105)
        for ok in [Int32(0), 102, 194, 105] {
            XCTAssertTrue(r.steps[0].accepts(exitStatus: ok), "\(ok) is a documented success/no-op")
        }
        for bad in [Int32(67), 1, 66, 84] {   // 1603 truncated, unsupported-OS, cancelled, corrupt
            XCTAssertFalse(r.steps[0].accepts(exitStatus: bad), "\(bad) is a real failure")
        }
        XCTAssertTrue(r.steps[1].accepts(exitStatus: 42), "recipe can widen the set as data")
        XCTAssertFalse(r.steps[0].accepts(exitStatus: 42), "…and only for the step that declares it")
        // Non-installer steps keep strict semantics.
        XCTAssertTrue(r.steps[2].accepts(exitStatus: 0))
        XCTAssertFalse(r.steps[2].accepts(exitStatus: 102))
        // Round trip keeps the field; absent decodes as nil (existing recipes unchanged).
        let again = try JSONDecoder.highball.decode(Recipe.self, from: try JSONEncoder().encode(r))
        XCTAssertTrue(again.steps[1].accepts(exitStatus: 42))
        XCTAssertFalse(again.steps[0].accepts(exitStatus: 42))
    }

    // The exit code must be explained where a human reads it: "exit=102" alone told us nothing
    // and cost two research passes on #36.
    func testExitCodeNotesAreHumanReadable() {
        XCTAssertTrue(WineRunner.exitCodeNote(for: 102).contains("1638"))
        XCTAssertTrue(WineRunner.exitCodeNote(for: 194).contains("3010"))
        XCTAssertTrue(WineRunner.exitCodeNote(for: 105).contains("1641"))
        XCTAssertEqual(WineRunner.exitCodeNote(for: 0), "")
        XCTAssertEqual(WineRunner.exitCodeNote(for: 67), "")
    }

    // Play-gate: only provably harmless steps may run silently at Play (no wine process —
    // the msync trap #32 — and no long installs). Heavy or wine-touching steps must prompt.
    func testRecipeAutoApplyClassification() throws {
        let light = """
        {"id":"l","kind":"game","title":"L","steps":[
          {"type":"file","path":"a/b.cfg","contents":"x"},
          {"type":"renderer","renderer":"dxvk"},
          {"type":"dxvkconfig","exe":"csgo.exe","options":{"dxvk.enableAsync":"False"}},
          {"type":"note","text":"n"}]}
        """
        XCTAssertTrue(try JSONDecoder.highball.decode(Recipe.self, from: Data(light.utf8)).isAutoApplicable)
        for heavyStep in [
            #"{"type":"winetricks","verbs":["dotnet48"]}"#,
            #"{"type":"installer","url":"https://x.com/a.exe","label":"a"}"#,
            #"{"type":"registry","key":"HKCU\\X","name":"n","data":"1"}"#,
            #"{"type":"winver","winver":"win10"}"#,
        ] {
            let json = #"{"id":"h","kind":"game","title":"H","steps":[\#(heavyStep)]}"#
            let r = try JSONDecoder.highball.decode(Recipe.self, from: Data(json.utf8))
            XCTAssertFalse(r.isAutoApplicable, "step must not auto-apply: \(heavyStep)")
        }
    }

    // Tech-debt migration (#21): per-app DXVK options are data now. Recipe-set values
    // override the built-in csgo fallback, other exes render their own sections, and the
    // fallback survives untouched for bottles without the recipe.
    func testDxvkAppConfigDataDriven() {
        // No data: fallback exactly as 0.7.10 shipped it (covered by testDxvkConfigContent too).
        let plain = Bottle.dxvkConfig(async: true)
        XCTAssertTrue(plain.contains("[csgo.exe]"))
        // Recipe data overrides the fallback key but keeps un-overridden fallback keys.
        let merged = Bottle.dxvkConfig(async: true, appConfig: [
            "csgo.exe": ["d3d9.maxAvailableMemory": "3072"],
            "portal2.exe": ["d3d9.deferSurfaceCreation": "True"],
        ])
        XCTAssertTrue(merged.contains("d3d9.maxAvailableMemory = 3072"), "recipe value wins")
        XCTAssertFalse(merged.contains("d3d9.maxAvailableMemory = 2048"))
        XCTAssertTrue(merged.contains("d3d9.customDeviceId = 73BF"), "fallback keys survive")
        XCTAssertTrue(merged.contains("[portal2.exe]"))
        XCTAssertTrue(merged.contains("d3d9.deferSurfaceCreation = True"))
    }

    // Issue #29: a recipe's renderer is a default, never an override — the Steam recipe
    // silently reset an explicitly-d3dmetal bottle to dxmt, black-screening AC.
    func testRecipeRendererNeverOverridesExplicitChoice() {
        var s = BottleSettings(name: "t", engineID: "e")
        XCTAssertEqual(RecipeRunner.rendererToApply(recipeRenderer: .dxmt, settings: s), .dxmt,
                       "default bottle: recipe renderer applies")
        s.rendererExplicit = true
        s.renderer = .d3dmetal
        XCTAssertNil(RecipeRunner.rendererToApply(recipeRenderer: .dxmt, settings: s),
                     "explicit choice: recipe renderer must not apply")
        XCTAssertNil(RecipeRunner.rendererToApply(recipeRenderer: nil, settings: s))
        // Old bottles without the field decode as not-explicit (recipes keep working).
        let decoded = try? JSONDecoder.highball.decode(
            BottleSettings.self,
            from: Data(#"{"name":"o","engineID":"e"}"#.utf8))
        XCTAssertEqual(decoded?.rendererExplicit, false)
    }
}
