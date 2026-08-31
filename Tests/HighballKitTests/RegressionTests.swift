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
        XCTAssertEqual(s.formatVersion, 2, "and stamped, so the migration never runs twice")
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

        let body = BugReport.url(version: "0.7.17", paths: paths).absoluteString.removingPercentEncoding ?? ""
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

        let body = BugReport.url(version: "0.7.17", paths: paths).absoluteString.removingPercentEncoding ?? ""
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

        let url = BugReport.url(version: "0.7.17", paths: paths)
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
