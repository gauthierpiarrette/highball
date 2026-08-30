import XCTest
@testable import HighballKit

/// Tripwires for bugs that shipped once and must not ship twice.
final class RegressionTests: XCTestCase {

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
        XCTAssertEqual(s.dxvkAsync, true)
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
    func testCommandKeyMappingMovesAsASet() throws {
        let on = WineRunner.keyboardRegistry(commandIsControl: true)
        XCTAssertEqual(on.count, 4)
        XCTAssertEqual(Set(on.map(\.name)),
                       ["LeftCommandIsCtrl", "RightCommandIsCtrl", "LeftOptionIsAlt", "RightOptionIsAlt"])
        XCTAssertTrue(on.allSatisfy { $0.data == "1" }, "Command→Ctrl is useless without Option→Alt")

        let off = WineRunner.keyboardRegistry(commandIsControl: false)
        XCTAssertTrue(off.allSatisfy { $0.data == "0" }, "off restores Wine's default mapping")
        XCTAssertEqual(Set(off.map(\.name)), Set(on.map(\.name)),
                       "turning it off must clear the same keys it set, not leave half behind")
    }

    // New bottles get Mac-native copy/paste; the setting is what the registry write follows.
    func testCommandIsControlDefaultsOn() throws {
        let s = BottleSettings(name: "t", engineID: "e")
        XCTAssertTrue(s.commandIsControl, "Mac users expect ⌘C/⌘V to work in Windows apps")
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
    // The report button used to attach the single newest log; when a game is launched
    // through Steam the launcher's log is newest, so triage got Steam's log, not the
    // game's (#22). Confirm the launcher-marker filter is exhaustive for known launchers.
    func testReportLogPrefersGameOverLauncher() {
        // These are the launcher log basenames the picker must skip when a game log exists.
        let launcherLogs = [
            "2026-08-26T104357Z-Steam for cyberpunk-steam.exe.log",
            "2026-08-26T000000Z-b-EpicGamesLauncher.exe.log",
            "2026-08-26T000000Z-b-UbisoftConnect.exe.log",
            "2026-08-26T000000Z-b-Launcher.exe.log",
        ]
        let markers = ["steam.exe", "epicgameslauncher", "ubisoftconnect", "galaxyclient", "battle.net", "launcher.exe", "rockstarservice"]
        for name in launcherLogs {
            XCTAssertTrue(markers.contains { name.lowercased().contains($0) }, "'\(name)' should be recognized as a launcher log")
        }
        // A real game log must NOT match any launcher marker.
        XCTAssertFalse(markers.contains { "2026-08-26T104400Z-cyberpunk-Cyberpunk2077.exe.log".lowercased().contains($0) })
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
