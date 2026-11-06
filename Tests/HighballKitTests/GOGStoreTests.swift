import XCTest
@testable import HighballKit

final class GOGStoreTests: XCTestCase {
    /// The temporary folder is reached as /var and as /private/var; compare one spelling.
    private func norm(_ url: URL?) -> String? {
        url.map { $0.path.hasPrefix("/private/var/") ? String($0.path.dropFirst("/private".count)) : $0.path }
    }

    /// GOG's sign-in ends on embed.gog.com/on_login_success; people paste the whole address, the
    /// address without its scheme, or the code alone.
    func testAuthorizationCodeFromWhatPeoplePaste() {
        XCTAssertEqual(GOGStore.authorizationCode(from: "https://embed.gog.com/on_login_success?origin=client&code=AbC-123_x"), "AbC-123_x")
        XCTAssertEqual(GOGStore.authorizationCode(from: "  embed.gog.com/on_login_success?origin=client&code=AbC12345  \n"), "AbC12345")
        XCTAssertEqual(GOGStore.authorizationCode(from: "AbC123def"), "AbC123def")
        XCTAssertNil(GOGStore.authorizationCode(from: "two words"))
        XCTAssertNil(GOGStore.authorizationCode(from: ""))
    }

    /// The sheet names the usual wrong pastes, and a code is only taken from a gog.com address.
    func testWrongPastesAreNamedAndNeverSent() {
        XCTAssertEqual(GOGStore.readSignIn(""), .empty)
        XCTAssertEqual(GOGStore.readSignIn(GOGStore.loginURL.absoluteString), .signInPage, "copied before logging in")
        XCTAssertEqual(GOGStore.readSignIn("https://login.gog.com/login?code=x"), .signInPage)
        XCTAssertEqual(GOGStore.readSignIn("https://embed.gog.com/on_login_success?origin=client"), .noCode)
        XCTAssertEqual(GOGStore.readSignIn("https://www.gog.com/en/account"), .noCode)
        XCTAssertEqual(GOGStore.readSignIn("https://example.com/on_login_success?code=AbC12345"), .notGOG)
        XCTAssertEqual(GOGStore.readSignIn("https://embed.gog.com.example.com/?code=AbC12345"), .notGOG)
        XCTAssertEqual(GOGStore.readSignIn("https://notgog.com/?code=AbC12345"), .notGOG)
        XCTAssertEqual(GOGStore.readSignIn("file:///etc/?code=AbC12345"), .notGOG)
        XCTAssertEqual(GOGStore.readSignIn("https://gog.com@example.com/?code=AbC12345"), .notGOG)
        XCTAssertEqual(GOGStore.readSignIn("https://example.com%2F.gog.com/?code=AbC12345"), .notGOG, "an encoded slash is not a gog.com host")
        XCTAssertEqual(GOGStore.readSignIn("https://embed.gog.com/on_login_success?xcode=AbC12345"), .noCode)
        XCTAssertEqual(GOGStore.readSignIn("short"), .notGOG)
    }

    /// Token values never reach an error message or a log line, however gogdl prints them.
    func testGogdlOutputIsRedacted() {
        let out = GOGStore.redacted(#"{"access_token": "aaa111", "refresh_token":"bbb222", "user_id": "42"} 'session_id': 'ccc333' code=ddd444&x=1 Authorization: Bearer eee555 auth --code fff666"#)
        for secret in ["aaa111", "bbb222", "ccc333", "ddd444", "eee555", "fff666"] { XCTAssertFalse(out.contains(secret), secret) }
        XCTAssertTrue(out.contains(#""user_id": "42""#), "the rest stays readable")
        let progress = "[PROGRESS] INFO: = Progress: 0.00 137861/45061146188, Running for: 00:00:02"
        XCTAssertEqual(GOGStore.redacted(progress), progress)
    }

    /// The folder with the tokens is this user's only, even when it already existed.
    func testGOGFolderIsPrivate() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = GOGStore(paths: HighballPaths(home: home))
        try FileManager.default.createDirectory(at: store.dir, withIntermediateDirectories: true)
        store.secureDirectory()
        let mode = try FileManager.default.attributesOfItem(atPath: store.dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    func testLoginURLIsGalaxysPublicClient() {
        let c = URLComponents(url: GOGStore.loginURL, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c.queryItems?.first { $0.name == "client_id" }?.value, "46899977096215655")
        XCTAssertEqual(c.queryItems?.first { $0.name == "redirect_uri" }?.value, "https://embed.gog.com/on_login_success?origin=client")
        XCTAssertEqual(c.queryItems?.first { $0.name == "response_type" }?.value, "code")
    }

    /// gogdl's progress lines as a Control download printed them (2026-10-28).
    func testProgressLines() {
        let p = GOGStore.progress(inGogdlLine: "[PROGRESS] INFO: = Progress: 0.00 137861/45061146188, Running for: 00:00:02, ETA: 271:03:22")
        XCTAssertEqual(p?.written, 137861)
        XCTAssertEqual(p?.total, 45061146188)
        for other in ["[PROGRESS] INFO: = Downloaded: 27.50 MiB, Written: 0.00 MiB",
                      "[PROGRESS] INFO:  + Download\t- 27.50 MiB/s (raw) / 64.99 MiB/s (decompressed)",
                      "[V2] INFO: Initialized V2 Download Manager"] {
            XCTAssertNil(GOGStore.progress(inGogdlLine: other), other)
        }
    }

    func testInstallFailuresBecomeSentences() {
        XCTAssertEqual(GOGStore.installFailure("[TASK_EXECUTOR] ERROR: Unable to proceed, Not enough disk space"),
                       "This Mac doesn't have enough free space for the game. Free some space, then press Install again.")
        XCTAssertNotNil(GOGStore.installFailure("[CLI] ERROR: Game doesn't support content system api, unable to proceed using platform windows"))
        XCTAssertEqual(GOGStore.installFailure("[API] ERROR: Failed to get manifest"), "GOG's downloader stopped with this message. Failed to get manifest")
        XCTAssertNil(GOGStore.installFailure("[PROGRESS] INFO: = Progress: 12.00 1/2, Running for: 00:00:01, ETA: 00:00:01"))
    }

    func testDownloadAndUpdateArguments() {
        let download = GOGStore.downloadArguments(id: "1957528513", into: "/c/Games", support: "/s", language: "en-US", update: false)
        XCTAssertEqual(Array(download.prefix(2)), ["download", "1957528513"])
        XCTAssertEqual(download[download.firstIndex(of: "--path")! + 1], "/c/Games")
        XCTAssertEqual(download[download.firstIndex(of: "--platform")! + 1], "windows")
        XCTAssertTrue(download.contains("--with-dlcs"))
        let update = GOGStore.downloadArguments(id: "1957528513", into: "/c/Games/Ghostrunner", support: "/s", language: "en-US", update: true)
        XCTAssertEqual(update.first, "update")
    }

    func testLanguageFollowsTheMac() {
        XCTAssertEqual(GOGStore.language(for: ["en-US", "fr-FR", "de-DE"], preferred: ["fr-CA", "en-US"]), "fr-FR")
        XCTAssertEqual(GOGStore.language(for: ["en-US", "de-DE"], preferred: ["ja-JP"]), "en-US")
        XCTAssertEqual(GOGStore.language(for: ["de-DE"], preferred: ["ja-JP"]), "de-DE")
        XCTAssertEqual(GOGStore.language(for: [], preferred: ["ja-JP"]), "en-US")
    }

    // MARK: gamesdb

    /// A trimmed gamesdb release: Steam id taken from GOG's own release list, so the cover is
    /// Steam's 600×900 capsule and the compatibility row matches by Steam id.
    func testReleaseUsesTheSteamIDGOGGives() throws {
        let json = """
        {"type":"game","title":{"*":"Ghostrunner "},"game":{"visible_in_library":true,
         "releases":[{"platform_id":"gog","external_id":"1957528513"},{"platform_id":"steam","external_id":"1139900"}],
         "vertical_cover":{"url_format":"https://images.gog.com/abc{formatter}.{ext}?namespace=gamesdb"},
         "background":{"url_format":"https://images.gog.com/bg{formatter}.{ext}?namespace=gamesdb"}}}
        """
        let game = try XCTUnwrap(GOGStore.parseRelease(id: "1957528513", data: Data(json.utf8)))
        XCTAssertEqual(game.title, "Ghostrunner")
        XCTAssertEqual(game.steamAppID, 1139900)
        XCTAssertEqual(game.artworkTall?.absoluteString, "https://cdn.akamai.steamstatic.com/steam/apps/1139900/library_600x900.jpg")
        XCTAssertEqual(game.gogVerticalCover?.absoluteString, "https://images.gog.com/abc.jpg?namespace=gamesdb")
    }

    func testReleaseWithoutSteamFallsBackToGOGArt() throws {
        let json = """
        {"type":"game","title":{"*":"Quake II RTX"},"game":{"releases":[],
         "vertical_cover":{"url_format":"https://images.gog.com/q2{formatter}.{ext}?namespace=gamesdb"}}}
        """
        let game = try XCTUnwrap(GOGStore.parseRelease(id: "1825786806", data: Data(json.utf8)))
        XCTAssertNil(game.steamAppID)
        XCTAssertEqual(game.artworkTall?.absoluteString, "https://images.gog.com/q2.jpg?namespace=gamesdb")
    }

    func testDLCAndHiddenReleasesStayOutOfTheLibrary() {
        let dlc = #"{"type":"dlc","title":{"*":"Ghostrunner - Katana Pack"},"game":{"visible_in_library":true}}"#
        let hidden = #"{"type":"game","title":{"*":"Hidden"},"game":{"visible_in_library":false}}"#
        XCTAssertNil(GOGStore.parseRelease(id: "1", data: Data(dlc.utf8)))
        XCTAssertNil(GOGStore.parseRelease(id: "2", data: Data(hidden.utf8)))
    }

    // MARK: Installs on disk

    private func makeGame(_ root: URL, folder: String, infos: [String: String]) throws -> URL {
        let dir = root.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, json) in infos { try json.write(to: dir.appending(path: name), atomically: true, encoding: .utf8) }
        return dir
    }

    /// highball#600: Games is a symlink to a folder on an external drive. The install is found,
    /// and its folder stays under the environment's Games.
    func testGamesFolderThatIsASymlinkIsListed() throws {
        let top = FileManager.default.temporaryDirectory.appending(path: "gog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: top) }
        let driveC = top.appending(path: "drive_c"), external = top.appending(path: "external/Games")
        try FileManager.default.createDirectory(at: driveC, withIntermediateDirectories: true)
        _ = try makeGame(external, folder: "Ghostrunner", infos: [
            "goggame-1957528513.info": #"{"gameId":"1957528513","rootGameId":"1957528513","name":"Ghostrunner"}"#,
        ])
        try FileManager.default.createSymbolicLink(at: driveC.appending(path: "Games"), withDestinationURL: external)
        let games = GOGStore.installedGames(driveC: driveC)
        XCTAssertEqual(games.map(\.id), ["1957528513"])
        XCTAssertEqual(games.first?.folder.path, driveC.appending(path: "Games/Ghostrunner").path)
    }

    /// Ghostrunner as gogdl installed it, with its DLC's info file beside the game's, and Control
    /// from an offline installer in GOG's default folder: both found, with the DLC attached.
    func testInstalledGamesComeFromInfoFiles() throws {
        let driveC = FileManager.default.temporaryDirectory.appending(path: "gog-\(UUID().uuidString)/drive_c")
        defer { try? FileManager.default.removeItem(at: driveC.deletingLastPathComponent()) }
        let gr = try makeGame(driveC.appending(path: "Games"), folder: "Ghostrunner", infos: [
            "goggame-1957528513.info": #"{"gameId":"1957528513","rootGameId":"1957528513","name":"Ghostrunner","buildId":"555","clientId":"533","playTasks":[{"category":"game","isPrimary":true,"name":"Ghostrunner","path":"Ghostrunner\\Binaries\\Win64\\Ghostrunner-Win64-Shipping.exe","arguments":"-GOG","type":"FileTask"},{"category":"game","name":"Ghostrunner DX12","path":"Ghostrunner/Binaries/Win64/Ghostrunner-Win64-Shipping.exe","arguments":"-GOG -dx12","type":"FileTask"}]}"#,
            "goggame-2009792833.info": #"{"gameId":"2009792833","rootGameId":"1957528513","name":"Ghostrunner - Katana Pack"}"#,
        ])
        try FileManager.default.createDirectory(at: gr.appending(path: "Ghostrunner/Binaries/Win64"), withIntermediateDirectories: true)
        _ = try makeGame(driveC.appending(path: "GOG Games"), folder: "Control", infos: [
            "goggame-2049187585.info": #"{"gameId":"2049187585","rootGameId":"2049187585","name":"Control Ultimate Edition","buildId":"592","playTasks":[{"isPrimary":true,"name":"Control","path":"Control.exe","category":"launcher","type":"FileTask"},{"name":"Support","type":"URLTask","path":"","category":"document","url":"http://www.gog.com/support"}]}"#,
        ])
        // A download still running is not an install yet.
        let partial = try makeGame(driveC.appending(path: "Games"), folder: "Half", infos: ["goggame-1.info": #"{"gameId":"1","name":"Half"}"#])
        try "".write(to: partial.appending(path: ".gogdl-resume"), atomically: true, encoding: .utf8)

        let games = GOGStore.installedGames(driveC: driveC).sorted { $0.title < $1.title }
        XCTAssertEqual(games.map(\.id), ["2049187585", "1957528513"])
        let ghostrunner = games[1]
        XCTAssertEqual(ghostrunner.dlcIDs, ["2009792833"])
        XCTAssertEqual(ghostrunner.clientID, "533")
        XCTAssertEqual(ghostrunner.launchChoices.count, 2, "two visible game tasks: a choice on the page")

        let primary = try XCTUnwrap(ghostrunner.launchTask())
        let launch = try XCTUnwrap(GOGStore.launch(primary, in: ghostrunner))
        XCTAssertEqual(norm(launch.executable), norm(gr.appending(path: "Ghostrunner/Binaries/Win64/Ghostrunner-Win64-Shipping.exe")),
                       "Windows separators become Unix ones")
        XCTAssertEqual(launch.arguments, ["-GOG"])
        XCTAssertEqual(norm(launch.workingDirectory), norm(gr))
        XCTAssertEqual(ghostrunner.launchTask(choice: 1)?.arguments, "-GOG -dx12")

        // Control.exe is a launcher that hands over to Control_DX11.exe and exits: the session
        // watches every program in the folder, not the redist installers or the uninstaller.
        let controlFolder = driveC.appending(path: "GOG Games/Control")
        for exe in ["Control.exe", "Control_DX11.exe", "unins000.exe", "__redist/DirectX/DXSETUP.exe", "_CommonRedist/vcredist_x64.exe"] {
            let file = controlFolder.appending(path: exe)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }
        XCTAssertEqual(games[0].sessionMarkers(launching: controlFolder.appending(path: "Control.exe")), ["Control.exe", "Control_DX11.exe"])
        XCTAssertTrue(SessionWatch.isAlive(markers: games[0].sessionMarkers(launching: controlFolder.appending(path: "Control.exe")), ps: "77480 Control_DX11.exe \n"))

        let control = games[0]
        XCTAssertTrue(control.launchChoices.isEmpty, "a manual is not a launch option")
        XCTAssertEqual(control.launchTask()?.path, "Control.exe")
    }

    /// Info files are written on Windows, where case does not matter; the Mac volume may care.
    func testPathsAreFoundWhateverTheirCase() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "gogcase-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Bin"), withIntermediateDirectories: true)
        try "".write(to: root.appending(path: "Bin/Game.exe"), atomically: true, encoding: .utf8)
        // On a case-insensitive volume the spelling as written already opens; on a case-sensitive
        // one the lookup finds the file's own spelling. Either way the file is there.
        XCTAssertTrue(FileManager.default.fileExists(atPath: GOGStore.resolve(#"bin\GAME.EXE"#, in: root).path))
    }

    // MARK: Cloud saves

    func testSaveLocationsFromRemoteConfig() {
        let json = #"{"content":{"Windows":{"cloudStorage":{"enabled":true,"locations":[{"name":"saves","location":"<?SAVED_GAMES?>/Remedy/Control"}]}}}}"#
        XCTAssertEqual(GOGSaves.parseLocations(Data(json.utf8), clientID: "c"), [.init(name: "saves", template: "<?SAVED_GAMES?>/Remedy/Control")])
        let empty = #"{"content":{"Windows":{"cloudStorage":{"enabled":true,"locations":[]}}}}"#
        XCTAssertEqual(GOGSaves.parseLocations(Data(empty.utf8), clientID: "533")?.first?.name, "__default",
                       "an empty list is the SDK's own storage folder")
        XCTAssertEqual(GOGSaves.parseLocations(Data(empty.utf8), clientID: "533")?.first?.template,
                       "<?APPLICATION_DATA_LOCAL?>/GOG.com/Galaxy/Applications/533/Storage/Shared/Files")
        let off = #"{"content":{"Windows":{"cloudStorage":{"enabled":false}}}}"#
        XCTAssertNil(GOGSaves.parseLocations(Data(off.utf8), clientID: "c"))
    }

    func testClientIDFromCompressedBuildManifest() throws {
        let json = Data(#"{"baseProductId":"2049187585","clientId":"53538800219319237"}"#.utf8)
        // A v2 manifest as GOG serves it: zlib header, raw DEFLATE (checksum left off; not read).
        let zlib = Data([0x78, 0x9c]) + (try (json as NSData).compressed(using: .zlib) as Data)
        XCTAssertEqual(GOGSaves.clientID(inManifest: zlib), "53538800219319237")
        XCTAssertEqual(GOGSaves.clientID(inManifest: json), "53538800219319237", "plain JSON reads too")
        XCTAssertNil(GOGSaves.clientID(inManifest: Data([0x78, 0x9c, 0x00])))
    }

    func testSaveFoldersResolveInsideTheEnvironment() throws {
        let driveC = FileManager.default.temporaryDirectory.appending(path: "gogsaves-\(UUID().uuidString)/drive_c")
        defer { try? FileManager.default.removeItem(at: driveC.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: driveC.appending(path: "users/player"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: driveC.appending(path: "users/Public"), withIntermediateDirectories: true)
        let game = GOGStore.InstalledGame(id: "1", title: "G", folder: driveC.appending(path: "Games/G"), buildID: nil, clientID: nil, dlcIDs: [], tasks: [])
        let user = driveC.appending(path: "users/player")
        func path(_ template: String) -> String? { norm(GOGSaves.resolve(template, game: game, driveC: driveC, userName: "player")) }
        XCTAssertEqual(path("<?SAVED_GAMES?>/Remedy/Control"),
                       norm(user.appending(path: "Saved Games/Remedy/Control")))
        XCTAssertEqual(path(#"<?APPLICATION_DATA_LOCAL_LOW?>\Studio\Game"#),
                       norm(user.appending(path: "AppData/LocalLow/Studio/Game")))
        XCTAssertEqual(GOGSaves.resolve("<?INSTALL?>/saves", game: game, driveC: driveC)?.path, game.folder.appending(path: "saves").path)
        XCTAssertNil(GOGSaves.resolve("<?APPLICATION_SUPPORT?>/x", game: game, driveC: driveC), "a Mac-native variable has no Windows folder")
        XCTAssertNil(GOGSaves.resolve("<?DOCUMENTS?>/%USERNAME%/x", game: game, driveC: driveC), "an unknown Windows variable is not guessed")
        XCTAssertNil(GOGSaves.resolve("<?DOCUMENTS?>", game: game, driveC: driveC), "a whole known folder is never synced")
        XCTAssertNil(GOGSaves.resolve("<?INSTALL?>/", game: game, driveC: driveC))
        XCTAssertNil(GOGSaves.resolve("<?INSTALL?>/../..", game: game, driveC: driveC), "nor one outside it")
    }

    /// gogdl's conflict line, and the flags each direction passes (gogdl/saves.py).
    func testSaveSyncArgumentsAndConflictLine() {
        let location = GOGSaves.Location(name: "saves", template: "")
        let down = GOGSaves.arguments(folder: URL(fileURLWithPath: "/s"), id: "1", location: location, timestamp: "0", direction: .download)
        XCTAssertEqual(down, ["save-sync", "/s", "1", "--os", "windows", "--ts", "0", "--name", "saves", "--debug", "--skip-upload"])
        XCTAssertEqual(GOGSaves.arguments(folder: URL(fileURLWithPath: "/s"), id: "1", location: location, timestamp: "5", direction: .upload).last, "--skip-download")
        XCTAssertEqual(GOGSaves.arguments(folder: URL(fileURLWithPath: "/s"), id: "1", location: location, timestamp: "5", direction: .forceDownload).last, "--force-download")
        XCTAssertTrue(GOGSaves.isConflict("[SAVES] WARNING: Files in conflict force downloading or uploading of files"))
        XCTAssertFalse(GOGSaves.isConflict("[SAVES] INFO: Downloading 3 files"))
    }

    /// The new timestamp is written without a newline, so it reaches the shared pipe glued to the
    /// next log line (gogdl/saves.py), and still has to be kept.
    func testSaveTimestampIsReadOffAGluedLine() throws {
        let glued = try XCTUnwrap(GOGSaves.timestamp(in: "1793193913.871504[SAVES] INFO: Done"))
        XCTAssertEqual(glued.0, "1793193913.871504")
        XCTAssertEqual(glued.1, "[SAVES] INFO: Done")
        XCTAssertEqual(GOGSaves.timestamp(in: "1793193913.871504")?.1, "")
        XCTAssertNil(GOGSaves.timestamp(in: "0"), "the unchanged 0 is not a sync")
        XCTAssertNil(GOGSaves.timestamp(in: "[SAVES] INFO: Downloading 3 files"))
    }

    // MARK: comet

    /// Tokens reach comet through a file in its private HOME, never its command line.
    func testCometArgumentsCarryNoTokens() {
        let args = GOGComet.arguments(username: "player")
        XCTAssertEqual(args, ["--from-heroic", "--username", "player", "--quit"])
        XCTAssertFalse(args.contains { $0.contains("token") })
    }

    func testCometSettingsRoundTrip() throws {
        var s = GOGSettings()
        s.cometOff["1"] = "crashed with comet"
        s.cloudSavesOff.insert("2")
        s.launchChoice["3"] = 1
        let back = try JSONDecoder().decode(GOGSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    // MARK: Library, play links, uninstall

    func testLibraryBuildsOneGOGTilePerGame() throws {
        func bottle(_ name: String) -> Bottle {
            Bottle(url: URL(fileURLWithPath: "/tmp/hb-gog-tests/bottles/\(name)"), settings: BottleSettings(name: name, engineID: "e"))
        }
        let games = bottle("Games"), clean = bottle("Clean")
        let installed = GOGStore.InstalledGame(id: "1957528513", title: "Ghostrunner", folder: games.driveC.appending(path: "Games/Ghostrunner"),
                                               buildID: "1", clientID: nil, dlcIDs: [], tasks: [])
        let offline = GOGStore.InstalledGame(id: "42", title: "From an offline installer", folder: clean.driveC.appending(path: "GOG Games/X"),
                                             buildID: nil, clientID: nil, dlcIDs: [], tasks: [])
        let items = LibraryIndex.build(bottles: [games, clean], steamByBottle: [:], epicOwned: [], epicInstalls: [:],
                                       gogGames: [GOGStore.Game(id: "1957528513", title: "Ghostrunner", steamAppID: 1139900),
                                                  GOGStore.Game(id: "7", title: "Owned, not installed")],
                                       gogInstalledByBottle: ["Games": [installed], "Clean": [offline]],
                                       defaultBottle: "Games")
        let gog = items.filter { $0.source == .gog }
        XCTAssertEqual(gog.count, 3)
        let gr = try XCTUnwrap(gog.first { $0.gogID == "1957528513" })
        XCTAssertEqual(gr.bottleName, "Games")
        XCTAssertTrue(gr.installed)
        XCTAssertNil(gr.steamAppID, "a GOG copy is never treated as a Steam game")
        XCTAssertEqual(gr.gogSteamAppID, 1139900)
        XCTAssertEqual(gr.artworkTall?.absoluteString, "https://cdn.akamai.steamstatic.com/steam/apps/1139900/library_600x900.jpg")
        let notInstalled = try XCTUnwrap(gog.first { $0.gogID == "7" })
        XCTAssertNil(notInstalled.bottleName)
        XCTAssertFalse(notInstalled.installed)
        let found = try XCTUnwrap(gog.first { $0.gogID == "42" }, "an install the account list does not name still gets a tile")
        XCTAssertEqual(found.bottleName, "Clean")
    }

    func testPinsInsideAGOGGameFolderGiveWayToItsTile() throws {
        var games = Bottle(url: URL(fileURLWithPath: "/tmp/hb-gog-tests/bottles/Games"), settings: BottleSettings(name: "Games", engineID: "e"))
        func tasks(_ json: String) throws -> [GOGStore.PlayTask] { try JSONDecoder().decode([GOGStore.PlayTask].self, from: Data(json.utf8)) }
        let quake = GOGStore.InstalledGame(id: "1825786806", title: "Quake II RTX", folder: games.driveC.appending(path: "GOG Games/Quake II RTX"),
                                           buildID: nil, clientID: nil, dlcIDs: [], tasks: try tasks(#"[{"isPrimary":true,"name":"Quake II RTX","path":"q2rtx.exe","type":"FileTask"}]"#))
        let control = GOGStore.InstalledGame(id: "2049187585", title: "Control", folder: games.driveC.appending(path: "GOG Games/Control"),
                                             buildID: nil, clientID: nil, dlcIDs: [], tasks: try tasks(#"[{"isPrimary":true,"name":"Control","path":"Control.exe","type":"FileTask"}]"#))
        let ghostrunner = GOGStore.InstalledGame(
            id: "1957528513", title: "Ghostrunner", folder: games.driveC.appending(path: "GOG Games/Ghostrunner"), buildID: nil, clientID: nil, dlcIDs: [],
            tasks: try tasks(#"[{"isPrimary":true,"name":"Ghostrunner","path":"Ghostrunner\\Binaries\\Win64\\Ghostrunner-Win64-Shipping.exe","arguments":"-GOG","type":"FileTask"}]"#))
        let quakePin = Pin(name: "Quake II", path: "GOG Games/Quake II RTX/q2rtx.exe", arguments: ["+set", "vid_rtx", "0"])
        let grPin = Pin(name: "Ghostrunner", path: "GOG Games/ghostrunner/Ghostrunner/Binaries/Win64/Ghostrunner-Win64-Shipping.exe", arguments: ["-GOG"])
        let tuned = Pin(name: "Quake tuned", path: "GOG Games/Quake II RTX/q2rtx.exe", environment: ["DXVK_HUD": "1"])
        let other = Pin(name: "Something else", path: "Games/Other/other.exe")
        let lookalike = Pin(name: "Not Quake", path: "GOG Games/Quake II RTX Mod/mod.exe")
        let tool = Pin(name: "Quake setup", path: "GOG Games/Quake II RTX/setup/Quake2RTX-Steam-Setup.exe")
        let dx11 = Pin(name: "Control", path: "GOG Games/Control/Control_DX11.exe")
        let controlTool = Pin(name: "Control settings", path: "GOG Games/Control/ControlConfig.exe")
        games.settings.pins = [quakePin, grPin, tuned, other, lookalike, tool, dx11, controlTool]
        let installs = ["Games": [quake, ghostrunner, control]]

        let covered = LibraryIndex.gogCoveredPins(bottles: [games], gogInstalledByBottle: installs)
        XCTAssertEqual(covered.map(\.pinItemID), ["pin:Games:\(quakePin.id.uuidString)", "pin:Games:\(grPin.id.uuidString)"],
                       "the game's own programs give way; a variant beside the main one, a tool in the folder, a pin with its own variables and a folder that only starts the same keep their tiles")
        XCTAssertEqual(covered[0].gogItemID, "gog:1825786806")
        XCTAssertEqual(covered[0].extraArguments, ["+set", "vid_rtx", "0"], "the pin's arguments go to the GOG tile")
        XCTAssertEqual(covered[1].extraArguments, [], "-GOG is already what the GOG task passes, so it is not added twice")
        XCTAssertTrue(covered.allSatisfy(\.tilePlaysIt), "the GOG tile's Play runs the same program")

        let items = LibraryIndex.build(bottles: [games], steamByBottle: [:], epicOwned: [], epicInstalls: [:],
                                       gogInstalledByBottle: installs)
        XCTAssertEqual(items.filter { $0.source == .pin }.map(\.title).sorted(), ["Control", "Control settings", "Not Quake", "Quake setup", "Quake tuned", "Something else"])
        XCTAssertEqual(items.filter { $0.source == .gog }.count, 3)
    }

    /// Owner review on #539: Control_DX11.exe pinned beside Control.exe gave way to the GOG tile,
    /// and Play then ran Control.exe, for players who never connected GOG too (installs are read
    /// off disk). It keeps its own tile, which plays the program the player picked.
    func testAVariantBesideTheMainProgramKeepsItsTileAndItsProgram() throws {
        var games = Bottle(url: URL(fileURLWithPath: "/tmp/hb-gog-tests/bottles/Games"), settings: BottleSettings(name: "Games", engineID: "e"))
        let tasks = try JSONDecoder().decode([GOGStore.PlayTask].self, from: Data(#"[{"isPrimary":true,"name":"Control","path":"Control.exe","category":"launcher","type":"FileTask"}]"#.utf8))
        let control = GOGStore.InstalledGame(id: "2049187585", title: "Control", folder: games.driveC.appending(path: "GOG Games/Control"),
                                             buildID: nil, clientID: nil, dlcIDs: [], tasks: tasks)
        let dx11 = Pin(name: "Control DX11", path: "GOG Games/Control/Control_DX11.exe")
        let main = Pin(name: "Control", path: "GOG Games/control/CONTROL.EXE")
        games.settings.pins = [dx11, main]
        let installs = ["Games": [control]]

        let covered = LibraryIndex.gogCoveredPins(bottles: [games], gogInstalledByBottle: installs)
        XCTAssertEqual(covered.map(\.pinItemID), ["pin:Games:\(main.id.uuidString)"], "only the exact program, whatever its case, gives way")
        XCTAssertEqual(covered[0].task.path, "Control.exe")

        // No account: the GOG games list is empty, the install alone makes the tile.
        let items = LibraryIndex.build(bottles: [games], steamByBottle: [:], epicOwned: [], epicInstalls: [:], gogGames: [],
                                       gogInstalledByBottle: installs)
        let tile = try XCTUnwrap(items.first { $0.id == "pin:Games:\(dx11.id.uuidString)" })
        XCTAssertEqual(tile.source, .pin)
        let pin = try XCTUnwrap(games.settings.pins.first { $0.id == tile.pinID })
        XCTAssertEqual(pin.launchURL(driveC: games.driveC).lastPathComponent, "Control_DX11.exe", "Play runs the pinned program")
        XCTAssertFalse(items.contains { $0.id == "pin:Games:\(main.id.uuidString)" })
    }

    /// A pin on another of the page's launch choices plays as the GOG game with its own task, but
    /// keeps its tile while the GOG tile plays something else: the tile stands for a pin only when
    /// its Play would run the same program. Changing the choice on the page swaps which one shows.
    func testAPinOnAnotherLaunchChoiceKeepsItsTaskAndItsTile() throws {
        var games = Bottle(url: URL(fileURLWithPath: "/tmp/hb-gog-tests/bottles/Games"), settings: BottleSettings(name: "Games", engineID: "e"))
        let tasks = try JSONDecoder().decode([GOGStore.PlayTask].self, from: Data(#"""
            [{"isPrimary":true,"category":"game","name":"Ghostrunner","path":"Ghostrunner\\Binaries\\Win64\\Ghostrunner-Win64-Shipping.exe","arguments":"-GOG","type":"FileTask"},
             {"category":"game","name":"Ghostrunner DX12","path":"Ghostrunner/Binaries/Win64/Ghostrunner-Win64-Shipping.exe","arguments":"-GOG -dx12","type":"FileTask"},
             {"category":"tool","name":"Benchmark","path":"Bench.exe","type":"FileTask"}]
            """#.utf8))
        let gr = GOGStore.InstalledGame(id: "1957528513", title: "Ghostrunner", folder: games.driveC.appending(path: "GOG Games/Ghostrunner"),
                                        buildID: nil, clientID: nil, dlcIDs: [], tasks: tasks)
        let exe = "GOG Games/Ghostrunner/Ghostrunner/Binaries/Win64/Ghostrunner-Win64-Shipping.exe"
        let dx12 = Pin(name: "Ghostrunner DX12", path: exe, arguments: ["-GOG", "-dx12", "-novid"])
        let main = Pin(name: "Ghostrunner", path: exe, arguments: ["-GOG"])
        let bench = Pin(name: "Benchmark", path: "GOG Games/Ghostrunner/Bench.exe")
        games.settings.pins = [dx12, main, bench]
        let installs = ["Games": [gr]]

        let covered = LibraryIndex.gogCoveredPins(bottles: [games], gogInstalledByBottle: installs)
        XCTAssertEqual(covered.map(\.task.name), ["Ghostrunner DX12", "Ghostrunner", "Benchmark"], "the task whose own arguments the pin passes")
        XCTAssertEqual(covered[0].extraArguments, ["-novid"])
        XCTAssertEqual(covered.map(\.tilePlaysIt), [false, true, false], "with no choice made, the GOG tile plays the default")

        func pinTiles(_ choice: [String: Int]) -> [String] {
            LibraryIndex.build(bottles: [games], steamByBottle: [:], epicOwned: [], epicInstalls: [:], gogInstalledByBottle: installs,
                               gogLaunchChoice: choice).filter { $0.source == .pin }.map(\.title).sorted()
        }
        XCTAssertEqual(pinTiles([:]), ["Benchmark", "Ghostrunner DX12"])
        XCTAssertEqual(pinTiles(["1957528513": 1]), ["Benchmark", "Ghostrunner"], "the page now plays DX12, so the default's pin shows instead")
        let chosen = LibraryIndex.gogCoveredPins(bottles: [games], gogInstalledByBottle: installs, launchChoice: ["1957528513": 1])
        XCTAssertEqual(chosen.map(\.tilePlaysIt), [true, false, false])
    }

    /// Owner review on #539: a Mac app made for a program before its GOG tile stood for it ended
    /// with "not in this Highball's library". Its link now finds the program, whose Play runs it
    /// as the GOG game (AppState.launch(pin:), with the CoveredPin's task and arguments), not
    /// whatever the GOG tile plays.
    func testAPlayLinkToACoveredProgramStillFindsTheProgram() throws {
        var games = Bottle(url: URL(fileURLWithPath: "/tmp/hb-gog-tests/bottles/Games"), settings: BottleSettings(name: "Games", engineID: "e"))
        let tasks = try JSONDecoder().decode([GOGStore.PlayTask].self, from: Data(#"[{"isPrimary":true,"name":"Quake II RTX","path":"q2rtx.exe","type":"FileTask"}]"#.utf8))
        let quake = GOGStore.InstalledGame(id: "1825786806", title: "Quake II RTX", folder: games.driveC.appending(path: "GOG Games/Quake II RTX"),
                                           buildID: nil, clientID: nil, dlcIDs: [], tasks: tasks)
        let covered = Pin(name: "Quake II", path: "GOG Games/Quake II RTX/q2rtx.exe", arguments: ["+set", "vid_rtx", "0"])
        let own = Pin(name: "Setup", path: "GOG Games/Quake II RTX/setup.exe")
        games.settings.pins = [covered, own]
        let installs = ["Games": [quake]]
        let items = LibraryIndex.build(bottles: [games], steamByBottle: [:], epicOwned: [], epicInstalls: [:], gogInstalledByBottle: installs)
        XCTAssertFalse(items.contains { $0.pinID == covered.id }, "the GOG tile stands for it in the library")
        func open(_ target: PlayLink.Target) -> HighballKit.LibraryItem? {
            LibraryIndex.coveredPinItem(forLink: target, bottles: [games], gogInstalledByBottle: installs)
        }

        let link = try XCTUnwrap(PlayLink.parse(PlayLink.url(for: .pin(bottle: "Games", id: covered.id), token: "t")))
        let item = try XCTUnwrap(open(link.target))
        XCTAssertEqual(item.id, "pin:Games:\(covered.id.uuidString)")
        XCTAssertEqual(item.source, .pin)
        XCTAssertEqual(item.pinID, covered.id)
        XCTAssertEqual(item.bottleName, "Games")
        XCTAssertEqual(item.title, "Quake II", "the confirmation names what the Mac app was made for")
        XCTAssertEqual(open(.pin(bottle: "Old name", id: covered.id))?.id, item.id, "made before the environment was renamed")
        XCTAssertNil(open(.pin(bottle: "Games", id: own.id)), "a program with its own tile is found in the library as before")
        XCTAssertNil(open(.gog(id: "1825786806")))
        XCTAssertNil(open(.pin(bottle: "Games", id: UUID())), "a program that is gone stays an error")

        // What that Play runs: the program's own task and arguments, as the GOG game.
        let standing = try XCTUnwrap(LibraryIndex.gogCoveredPins(bottles: [games], gogInstalledByBottle: installs).first { $0.pinItemID == item.id })
        XCTAssertEqual(standing.gogItemID, "gog:1825786806")
        XCTAssertEqual(standing.task.path, "q2rtx.exe")
        XCTAssertEqual(standing.extraArguments, ["+set", "vid_rtx", "0"])
    }

    /// Owner review on #539: the carry-over took the arguments, display and graphics mode, but the
    /// name and cover the program had stayed behind. They go now, never over a choice the GOG tile
    /// already has, and only once. (Its plays show on the GOG tile without carrying: see
    /// testAProgramsPlaysShowOnTheTileThatStandsForIt.)
    func testCarryOverTakesNameAndCoverOnce() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "gog-carry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = HighballPaths(home: home)
        let store = LibraryStore(paths: paths), names = NameStore(paths: paths), covers = CoverStore(paths: paths)
        let task = GOGStore.PlayTask(name: "DX12", path: "Game.exe", arguments: "-dx12")
        func pin(_ uuid: UUID, _ gog: String, extra: [String] = [], tilePlaysIt: Bool = true) -> LibraryIndex.CoveredPin {
            LibraryIndex.CoveredPin(pinItemID: "pin:Games:\(uuid.uuidString)", gogItemID: "gog:\(gog)", extraArguments: extra, task: task, tilePlaysIt: tilePlaysIt)
        }
        let a = UUID(), b = UUID(), c = UUID()
        let first = pin(a, "1", extra: ["-novid"]), second = pin(b, "2")
        // A program on a task the GOG tile does not play keeps its tile, and so its things.
        let elsewhere = pin(c, "3", extra: ["-other"], tilePlaysIt: false)
        try names.setName("Kept", for: elsewhere.pinItemID)

        // The first program has everything; its GOG tile nothing. The second one's GOG tile was
        // renamed by the player.
        try names.setName("My Game", for: first.pinItemID)
        try FileManager.default.createDirectory(at: covers.dir, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: covers.dir.appending(path: "pin_Games_\(a.uuidString).png"))
        store.setDisplay("DISPLAY-UUID", for: first.pinItemID)
        store.setRendererOverride(.dxvk, for: first.pinItemID)
        try names.setName("Old", for: second.pinItemID)
        try names.setName("Mine", for: second.gogItemID)

        var settings = GOGSettings()
        let lines = LibraryIndex.carryOver([first, second, elsewhere], paths: paths, settings: &settings)
        XCTAssertEqual(lines.count, 2)

        XCTAssertEqual(names.name(for: "gog:1"), "My Game")
        XCTAssertEqual(covers.coverURL(for: "gog:1")?.lastPathComponent, "gog_1.png")
        XCTAssertEqual(store.displayChoices()["gog:1"], "DISPLAY-UUID")
        XCTAssertEqual(store.rendererOverrides()["gog:1"], .dxvk)
        XCTAssertEqual(store.launchArguments()["gog:1"], ["-novid"])

        XCTAssertEqual(names.name(for: "gog:2"), "Mine", "a name the player gave the GOG tile stays")
        XCTAssertNil(covers.coverURL(for: "gog:2"))

        XCTAssertEqual(names.name(for: first.pinItemID), "My Game", "the program keeps its own copy, for when its tile comes back")
        XCTAssertEqual(settings.carriedOverPins, [first.pinItemID, second.pinItemID])
        XCTAssertNil(names.name(for: "gog:3"))
        XCTAssertNil(store.launchArguments()["gog:3"])

        // Once only: a later change on the GOG tile is not undone by the next rebuild.
        try names.setName("Renamed again", for: "gog:1")
        XCTAssertTrue(LibraryIndex.carryOver([first], paths: paths, settings: &settings).isEmpty)
        XCTAssertEqual(names.name(for: "gog:1"), "Renamed again")
    }

    /// Owner review on #539: a program the player hid came back as a visible GOG tile once that
    /// tile stood for it. Hide goes along with the name and cover, once, and a GOG tile the player
    /// showed again after that stays shown.
    func testCarryOverTakesHideOnce() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "gog-carry-hide-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = HighballPaths(home: home)
        let store = LibraryStore(paths: paths)
        let task = GOGStore.PlayTask(path: "Game.exe")
        let uuid = UUID(), shown = UUID()
        let hidden = LibraryIndex.CoveredPin(pinItemID: "pin:Games:\(uuid.uuidString)", gogItemID: "gog:1", extraArguments: [], task: task, tilePlaysIt: true)
        let visible = LibraryIndex.CoveredPin(pinItemID: "pin:Games:\(shown.uuidString)", gogItemID: "gog:2", extraArguments: [], task: task, tilePlaysIt: true)
        // Hidden under an earlier name of its environment (PinID) counts too.
        store.setHidden(true, for: "pin:Old name:\(uuid.uuidString)")

        var settings = GOGSettings()
        LibraryIndex.carryOver([hidden, visible], paths: paths, settings: &settings)
        XCTAssertTrue(LibraryStore.isHidden("gog:1", in: store.hiddenIDs()))
        XCTAssertFalse(LibraryStore.isHidden("gog:2", in: store.hiddenIDs()), "a program the player did not hide leaves its GOG tile shown")

        // Once only: showing the GOG tile again is not undone by the next rebuild.
        store.setHidden(false, for: "gog:1")
        LibraryIndex.carryOver([hidden], paths: paths, settings: &settings)
        XCTAssertFalse(LibraryStore.isHidden("gog:1", in: store.hiddenIDs()))
    }

    /// Owner review on #539: a pinned tool among a game's launch choices (category "tool") plays
    /// as the GOG game, but must not bring cloud saves down or up, nor run comet, around a
    /// settings window. Game tasks, and tasks that name no category, still do.
    func testPinnedToolSkipsSavesAndComet() {
        func pin(_ category: String?) -> LibraryIndex.CoveredPin {
            LibraryIndex.CoveredPin(pinItemID: "pin:Games:\(UUID().uuidString)", gogItemID: "gog:1", extraArguments: [],
                                    task: GOGStore.PlayTask(path: "Tool.exe", category: category), tilePlaysIt: false)
        }
        XCTAssertFalse(pin("tool").syncsLikeTheGame)
        XCTAssertTrue(pin("game").syncsLikeTheGame)
        XCTAssertTrue(pin(nil).syncsLikeTheGame)
    }

    // MARK: Launch option swaps (round 3)

    /// Ghostrunner with a default task, a DX12 choice, a Benchmark choice nobody pinned, and a
    /// hidden crash reporter; pins on the default, on DX12 (with an extra argument) and on the
    /// hidden task.
    private func swapFixture(bottleName: String = "Games") throws -> (bottle: Bottle, game: GOGStore.InstalledGame, main: Pin, dx12: Pin, hidden: Pin) {
        var games = Bottle(url: URL(fileURLWithPath: "/tmp/hb-gog-tests/bottles/\(bottleName)"), settings: BottleSettings(name: bottleName, engineID: "e"))
        let tasks = try JSONDecoder().decode([GOGStore.PlayTask].self, from: Data(#"""
            [{"isPrimary":true,"category":"game","name":"Ghostrunner","path":"Ghostrunner\\Binaries\\Win64\\Ghostrunner-Win64-Shipping.exe","arguments":"-GOG","type":"FileTask"},
             {"category":"game","name":"Ghostrunner DX12","path":"Ghostrunner/Binaries/Win64/Ghostrunner-Win64-Shipping.exe","arguments":"-GOG -dx12","type":"FileTask"},
             {"category":"tool","name":"Benchmark","path":"Bench.exe","type":"FileTask"},
             {"name":"Crash reporter","path":"CrashReporter.exe","isHidden":true,"type":"FileTask"}]
            """#.utf8))
        let gr = GOGStore.InstalledGame(id: "1957528513", title: "Ghostrunner", folder: games.driveC.appending(path: "GOG Games/Ghostrunner"),
                                        buildID: nil, clientID: nil, dlcIDs: [], tasks: tasks)
        let exe = "GOG Games/Ghostrunner/Ghostrunner/Binaries/Win64/Ghostrunner-Win64-Shipping.exe"
        let main = Pin(name: "Ghostrunner", path: exe, arguments: ["-GOG"])
        let dx12 = Pin(name: "Ghostrunner DX12", path: exe, arguments: ["-GOG", "-dx12", "-novid"])
        let hidden = Pin(name: "Crash reporter", path: "GOG Games/Ghostrunner/CrashReporter.exe")
        games.settings.pins = [main, dx12, hidden]
        return (games, gr, main, dx12, hidden)
    }

    /// What Play on a tile runs, decided as AppState does: the GOG tile its page's choice
    /// (gogPlay), a program the GOG game when it runs one of its tasks, with its own task and
    /// arguments (launch(pin:) → gogPlay(as:)), any other program itself.
    private func playTarget(_ item: HighballKit.LibraryItem, bottles: [Bottle], installs: [String: [GOGStore.InstalledGame]],
                            choice: [String: Int]) -> (exe: String, arguments: [String], asGOG: Bool)? {
        switch item.source {
        case .gog:
            guard let game = installs[item.bottleName ?? ""]?.first(where: { $0.id == item.gogID }),
                  let launch = game.launchTask(choice: choice[game.id]).flatMap({ GOGStore.launch($0, in: game) }) else { return nil }
            return (launch.executable.lastPathComponent, launch.arguments, true)
        case .pin:
            guard let bottle = bottles.first(where: { $0.name == item.bottleName }),
                  let pin = bottle.settings.pins.first(where: { $0.id == item.pinID }) else { return nil }
            if let covered = LibraryIndex.gogCoveredPins(bottles: [bottle], gogInstalledByBottle: installs).first(where: { $0.pinItemID == item.id }),
               let game = installs[bottle.name]?.first(where: { "gog:\($0.id)" == covered.gogItemID }),
               let launch = GOGStore.launch(covered.task, in: game) {
                return (launch.executable.lastPathComponent, launch.arguments + covered.extraArguments, true)
            }
            return (pin.launchURL(driveC: bottle.driveC).lastPathComponent, pin.arguments, false)
        default:
            return nil
        }
    }

    /// The launch option switched between two pinned programs, to one nobody pinned, and back,
    /// several times: the tiles swap each time, every tile on screen plays what it shows, and
    /// the same choice always gives the same library (no drift, no duplicate tiles).
    func testSwitchingTheLaunchOptionSwapsTilesAndComesBackTheSame() throws {
        let f = try swapFixture()
        let bottles = [f.bottle], installs = ["Games": [f.game]]
        let main = "pin:Games:\(f.main.id.uuidString)", dx12 = "pin:Games:\(f.dx12.id.uuidString)", hidden = "pin:Games:\(f.hidden.id.uuidString)"
        func library(_ choice: [String: Int]) -> [HighballKit.LibraryItem] {
            LibraryIndex.build(bottles: bottles, steamByBottle: [:], epicOwned: [], epicInstalls: [:], gogInstalledByBottle: installs,
                               gogLaunchChoice: choice)
        }
        func check(_ choice: [String: Int], shows pins: Set<String>, gogPlays exe: String, _ gogArguments: [String],
                   file: StaticString = #filePath, line: UInt = #line) {
            let items = library(choice)
            XCTAssertEqual(items, library(choice), "a second rebuild gives the same library", file: file, line: line)
            XCTAssertEqual(Set(items.map(\.id)).count, items.count, "no tile twice", file: file, line: line)
            XCTAssertEqual(Set(items.filter { $0.source == .pin }.map(\.id)), pins, file: file, line: line)
            XCTAssertEqual(items.filter { $0.source == .gog }.map(\.id), ["gog:1957528513"], file: file, line: line)
            var targets: [String: (exe: String, arguments: [String], asGOG: Bool)] = [:]
            for item in items { targets[item.id] = playTarget(item, bottles: bottles, installs: installs, choice: choice) }
            XCTAssertEqual(targets["gog:1957528513"]?.exe, exe, file: file, line: line)
            XCTAssertEqual(targets["gog:1957528513"]?.arguments, gogArguments, file: file, line: line)
            if let t = targets[main] {
                XCTAssertEqual(t.arguments, ["-GOG"], file: file, line: line); XCTAssertTrue(t.asGOG, file: file, line: line)
            }
            if let t = targets[dx12] {
                XCTAssertEqual(t.arguments, ["-GOG", "-dx12", "-novid"], file: file, line: line); XCTAssertTrue(t.asGOG, file: file, line: line)
            }
            XCTAssertEqual(targets[hidden]?.exe, "CrashReporter.exe", file: file, line: line)
            XCTAssertEqual(targets[hidden]?.asGOG, false, "a hidden task is not one the GOG tile plays: a plain program", file: file, line: line)
            // A pin hidden behind the GOG tile runs exactly what the GOG tile runs.
            for pin in LibraryIndex.gogCoveredPins(bottles: bottles, gogInstalledByBottle: installs, launchChoice: choice) where pin.tilePlaysIt {
                XCTAssertFalse(pins.contains(pin.pinItemID), file: file, line: line)
                XCTAssertEqual(f.game.launchTask(choice: choice[f.game.id]), pin.task, file: file, line: line)
            }
        }
        let first = library([:])
        for _ in 0..<3 {
            check([:], shows: [dx12, hidden], gogPlays: "Ghostrunner-Win64-Shipping.exe", ["-GOG"])
            check(["1957528513": 1], shows: [main, hidden], gogPlays: "Ghostrunner-Win64-Shipping.exe", ["-GOG", "-dx12"])
            check(["1957528513": 2], shows: [main, dx12, hidden], gogPlays: "Bench.exe", [])
            check(["1957528513": 0], shows: [dx12, hidden], gogPlays: "Ghostrunner-Win64-Shipping.exe", ["-GOG"])   // the page's own entry for the default
            check(["1957528513": 9], shows: [dx12, hidden], gogPlays: "Ghostrunner-Win64-Shipping.exe", ["-GOG"])   // a choice gone after an update
        }
        XCTAssertEqual(library([:]), first, "back where it started")
        XCTAssertEqual(LibraryIndex.gogCoveredPins(bottles: bottles, gogInstalledByBottle: installs).map(\.pinItemID), [main, dx12],
                       "the hidden task's program is never covered")
    }

    /// Program paths and GOG's task paths are matched as Windows would: case, \ against /, and a
    /// path with . or .. in it; a file beside the program never counts.
    func testProgramPathsMatchTheTaskWhateverTheirSpelling() throws {
        let f = try swapFixture()
        var bottle = f.bottle
        let drive = bottle.driveC.path
        let spellings = ["gog games/GHOSTRUNNER/ghostrunner/binaries/win64/GHOSTRUNNER-WIN64-SHIPPING.EXE",
                         "GOG Games/Ghostrunner/./Ghostrunner/Binaries/Win64/../Win64/Ghostrunner-Win64-Shipping.exe",
                         "\(drive)/GOG Games/Ghostrunner/Ghostrunner/Binaries/Win64/Ghostrunner-Win64-Shipping.exe"]
        let pins = spellings.map { Pin(name: $0, path: $0, arguments: ["-GOG"]) }
        let beside = Pin(name: "Beside", path: "GOG Games/Ghostrunner/Ghostrunner/Binaries/Win64/Ghostrunner-Win64-Shipping_DX11.exe", arguments: ["-GOG"])
        bottle.settings.pins = pins + [beside]
        let covered = LibraryIndex.gogCoveredPins(bottles: [bottle], gogInstalledByBottle: ["Games": [f.game]])
        XCTAssertEqual(covered.map(\.pinItemID), pins.map { "pin:Games:\($0.id.uuidString)" })
        XCTAssertTrue(covered.allSatisfy { $0.task.name == "Ghostrunner" && $0.tilePlaysIt })
    }

    /// The name and cover go to the GOG tile once per program, however often swaps hide and show
    /// it, and not again after its environment is renamed (its id changes then).
    func testCarryOverRunsOncePerProgramThroughSwapsAndARename() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "gog-swap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = HighballPaths(home: home)
        let names = NameStore(paths: paths), store = LibraryStore(paths: paths)
        var f = try swapFixture()
        var installs = ["Games": [f.game]]
        try names.setName("My Ghostrunner", for: "pin:Games:\(f.main.id.uuidString)")
        try names.setName("DX12 run", for: "pin:Games:\(f.dx12.id.uuidString)")
        store.setDisplay("PIN-DISPLAY", for: "pin:Games:\(f.main.id.uuidString)")
        store.setDisplay("TILE-DISPLAY", for: "gog:1957528513")
        var settings = GOGSettings()
        // What rebuildLibrary does before building (AppState.carryOverGOGCoveredPins).
        func rebuild(_ choice: [String: Int]) -> [String] {
            let covered = LibraryIndex.gogCoveredPins(bottles: [f.bottle], gogInstalledByBottle: installs, launchChoice: choice)
                .filter { $0.tilePlaysIt && !LibraryIndex.wasCarriedOver($0.pinItemID, in: settings.carriedOverPins) }
            return LibraryIndex.carryOver(covered, paths: paths, settings: &settings)
        }

        XCTAssertEqual(rebuild([:]).count, 1)
        XCTAssertEqual(names.name(for: "gog:1957528513"), "My Ghostrunner")
        XCTAssertEqual(store.displayChoices()["gog:1957528513"], "TILE-DISPLAY", "the GOG tile's own display stays")
        try names.setName(nil, for: "gog:1957528513")   // the player clears it on the GOG tile

        XCTAssertEqual(rebuild(["1957528513": 1]).count, 1, "the DX12 program is hidden for the first time")
        XCTAssertEqual(names.name(for: "gog:1957528513"), "DX12 run")
        try names.setName("Mine", for: "gog:1957528513")
        for choice in [[:], ["1957528513": 1], [:], ["1957528513": 2], [:]] as [[String: Int]] {
            XCTAssertTrue(rebuild(choice).isEmpty, "hidden again: nothing goes twice")
        }
        XCTAssertEqual(names.name(for: "gog:1957528513"), "Mine")

        // The environment is renamed: the programs get new ids, which were carried under the old one.
        f.bottle.settings.name = "Games 2"
        f.bottle = Bottle(url: URL(fileURLWithPath: "/tmp/hb-gog-tests/bottles/Games 2"), settings: f.bottle.settings)
        // Installs are read off disk again, from the renamed environment's folder.
        installs = ["Games 2": [GOGStore.InstalledGame(id: f.game.id, title: f.game.title, folder: f.bottle.driveC.appending(path: "GOG Games/Ghostrunner"),
                                                       buildID: nil, clientID: nil, dlcIDs: [], tasks: f.game.tasks)]]
        try names.setName(nil, for: "gog:1957528513")
        XCTAssertEqual(LibraryIndex.gogCoveredPins(bottles: [f.bottle], gogInstalledByBottle: installs).filter(\.tilePlaysIt).map(\.pinItemID),
                       ["pin:Games 2:\(f.main.id.uuidString)"], "hiding still follows the program")
        XCTAssertTrue(rebuild([:]).isEmpty, "not carried again after a rename")
        XCTAssertNil(names.name(for: "gog:1957528513"), "a name cleared on the GOG tile stays cleared")
        XCTAssertEqual(settings.carriedOverPins.count, 2)
    }

    /// When a program was last played shows on whichever tile stands for it now: the GOG tile while
    /// it is hidden behind it, its own tile when a swap shows it again. A play is never lost and
    /// never on two tiles.
    func testAProgramsPlaysShowOnTheTileThatStandsForIt() throws {
        let f = try swapFixture()
        let installs = ["Games": [f.game]]
        let main = "pin:Games:\(f.main.id.uuidString)", dx12 = "pin:Games:\(f.dx12.id.uuidString)"
        let t = (gog: Date(timeIntervalSince1970: 1_000), main: Date(timeIntervalSince1970: 2_000), dx12: Date(timeIntervalSince1970: 3_000))
        let plays = ["gog:1957528513": LibraryStore.PlayRecord(lastPlayedAt: t.gog, bottle: "Games"),
                     main: LibraryStore.PlayRecord(lastPlayedAt: t.main, bottle: "Games"),
                     dx12: LibraryStore.PlayRecord(lastPlayedAt: t.dx12, bottle: "Games")]
        func lastPlayed(_ choice: [String: Int]) -> [String: Date] {
            let items = LibraryIndex.build(bottles: [f.bottle], steamByBottle: [:], epicOwned: [], epicInstalls: [:], gogInstalledByBottle: installs,
                                           gogLaunchChoice: choice, plays: plays)
            return Dictionary(uniqueKeysWithValues: items.compactMap { item in item.lastPlayed.map { (item.id, $0) } })
        }
        XCTAssertEqual(lastPlayed([:]), ["gog:1957528513": t.main, dx12: t.dx12])
        XCTAssertEqual(lastPlayed(["1957528513": 1]), ["gog:1957528513": t.dx12, main: t.main])
        XCTAssertEqual(lastPlayed(["1957528513": 2]), ["gog:1957528513": t.gog, main: t.main, dx12: t.dx12], "nothing hidden: each its own")
        XCTAssertEqual(lastPlayed([:]), ["gog:1957528513": t.main, dx12: t.dx12])
    }

    /// A Mac app made for a program finds it whether its tile is shown or hidden at the time, and
    /// plays its own task and arguments as the GOG game either way, also after a rename.
    func testAPlayLinkRunsTheProgramWhetherItsTileIsShownOrHidden() throws {
        let f = try swapFixture()
        let bottles = [f.bottle], installs = ["Games": [f.game]]
        for choice in [[:], ["1957528513": 1]] as [[String: Int]] {
            let items = LibraryIndex.build(bottles: bottles, steamByBottle: [:], epicOwned: [], epicInstalls: [:], gogInstalledByBottle: installs,
                                           gogLaunchChoice: choice)
            for (pin, arguments) in [(f.main, ["-GOG"]), (f.dx12, ["-GOG", "-dx12", "-novid"])] {
                for target in [PlayLink.Target.pin(bottle: "Games", id: pin.id), .pin(bottle: "Before a rename", id: pin.id)] {
                    // AppState.resolvePlayLink: the library first, then the program behind its GOG tile.
                    let item = try XCTUnwrap(items.first { $0.id == target.libraryID }
                                             ?? LibraryIndex.coveredPinItem(forLink: target, bottles: bottles, gogInstalledByBottle: installs))
                    XCTAssertEqual(item.pinID, pin.id)
                    let played = try XCTUnwrap(playTarget(item, bottles: bottles, installs: installs, choice: choice))
                    XCTAssertEqual(played.arguments, arguments)
                    XCTAssertTrue(played.asGOG)
                }
            }
        }
    }

    /// Without the game installed in a program's own environment nothing is hidden and every
    /// program plays itself; a GOG account is not needed for an install on disk to stand in.
    func testNothingIsHiddenWithoutTheGameInThatEnvironment() throws {
        let f = try swapFixture()
        let other = Bottle(url: URL(fileURLWithPath: "/tmp/hb-gog-tests/bottles/Other"), settings: BottleSettings(name: "Other", engineID: "e"))
        for installs in [[:], ["Other": [f.game]]] as [[String: [GOGStore.InstalledGame]]] {
            XCTAssertTrue(LibraryIndex.gogCoveredPins(bottles: [f.bottle, other], gogInstalledByBottle: installs).isEmpty)
            let items = LibraryIndex.build(bottles: [f.bottle, other], steamByBottle: [:], epicOwned: [], epicInstalls: [:], gogInstalledByBottle: installs)
            XCTAssertEqual(items.filter { $0.source == .pin }.count, 3)
            for item in items where item.source == .pin {
                XCTAssertEqual(playTarget(item, bottles: [f.bottle, other], installs: installs, choice: [:])?.asGOG, false)
            }
        }
        // Not signed in (no account games), installed here: the install alone stands in.
        let items = LibraryIndex.build(bottles: [f.bottle], steamByBottle: [:], epicOwned: [], epicInstalls: [:], gogGames: [],
                                       gogInstalledByBottle: ["Games": [f.game]])
        XCTAssertEqual(items.filter { $0.source == .pin }.count, 2)
    }

    func testSetupStepCommands() {
        let dir = URL(fileURLWithPath: "/tmp/redist")
        let msi = GOGStore.SetupStep(label: "PhysX", executable: nil, arguments: ["/i", "/tmp/redist/physx.msi", "/qb"], workingDirectory: dir)
        XCTAssertEqual(msi.command, ["msiexec", "/i", "/tmp/redist/physx.msi", "/qb"], "an .msi runtime runs through Wine's own msiexec, by name")
        let exe = GOGStore.SetupStep(label: "VC++", executable: dir.appending(path: "vcredist.exe"), arguments: ["/quiet"], workingDirectory: dir)
        XCTAssertEqual(exe.command, ["/tmp/redist/vcredist.exe", "/quiet"])
    }

    func testGOGSettingsReadAFileWrittenBeforeANewField() throws {
        let old = Data(#"{"cometOff":{"1":"turned off"},"cloudSavesOff":["2"],"launchChoice":{"3":1}}"#.utf8)
        let s = try JSONDecoder().decode(GOGSettings.self, from: old)
        XCTAssertEqual(s.cometOff["1"], GOGSettings.turnedOff)
        XCTAssertEqual(s.cloudSavesOff, ["2"])
        XCTAssertTrue(s.carriedOverPins.isEmpty)
    }

    func testPlayLinkAndUninstallForGOG() {
        let item = LibraryItem(source: .gog, id: "gog:1957528513", title: "Ghostrunner", bottleName: "Games", installed: true, gogID: "1957528513")
        let target = PlayLink.target(for: item)
        XCTAssertEqual(target, .gog(id: "1957528513"))
        let url = PlayLink.url(for: target!, token: "t")
        XCTAssertEqual(url.absoluteString, "highball://play/gog/1957528513?t=t")
        XCTAssertEqual(PlayLink.parse(url)?.target.libraryID, "gog:1957528513")
        XCTAssertNil(PlayLink.parse(URL(string: "highball://play/gog/../../x?t=t")!), "ids are numbers only")
        XCTAssertEqual(Uninstall.route(for: item), .gog(id: "1957528513"))
        let notHere = LibraryItem(source: .gog, id: "gog:7", title: "X", bottleName: nil, installed: false, gogID: "7")
        XCTAssertFalse(Uninstall.isActionable(Uninstall.route(for: notHere)))
    }

    /// comet's unlock lines, as v0.4.0 writes them; a name may hold a comma.
    func testAchievementUnlocksAreReadOffCometsLog() {
        let log = """
        [2026-10-28T14:15:48Z INFO  comet::api::handlers] Uploading new achievements
        [2026-10-28T14:32:50Z INFO  comet::api::handlers::utils] Unlocking achievement HILT_ACHIEVEMENT, Choose to be Chosen
        [2026-10-28T14:40:01Z INFO  comet::api::handlers::utils] Unlocking achievement A_2, Well, That Happened
        """
        let unlocks = GOGAchievements.unlocks(in: log)
        XCTAssertEqual(unlocks.map(\.key), ["HILT_ACHIEVEMENT", "A_2"])
        XCTAssertEqual(unlocks.map(\.name), ["Choose to be Chosen", "Well, That Happened"])
    }

    /// Each read returns only what is new, and a line still being written waits for the next read.
    func testAchievementLogReaderTakesWholeNewLinesOnce() throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "comet-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        try "x Unlocking achievement ONE, First\nx Unlocking achievement TWO, Sec".write(to: log, atomically: true, encoding: .utf8)
        let reader = GOGAchievements.LogReader(log: log)
        XCTAssertEqual(reader.newUnlocks().map(\.key), ["ONE"])
        XCTAssertTrue(reader.newUnlocks().isEmpty)
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ond\n".utf8))
        try handle.close()
        XCTAssertEqual(reader.newUnlocks().map(\.name), ["Second"])
    }

    /// The pop-up's details come from comet's database, found by client id; a key it lacks keeps
    /// the logged name.
    func testAchievementDetailsComeFromCometsDatabase() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "comet-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appending(path: "Library/Application Support/comet/gameplay/5353/1001")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "gameplay.db")
        let sql = """
        CREATE TABLE achievement (id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, name TEXT NOT NULL, description TEXT NOT NULL,
          visible_while_locked INTEGER NOT NULL, unlock_time TEXT, image_url_locked TEXT NOT NULL, image_url_unlocked TEXT NOT NULL,
          changed INTEGER NOT NULL, rarity REAL NOT NULL DEFAULT 0.0, rarity_level_description TEXT NOT NULL DEFAULT "",
          rarity_level_slug TEXT NOT NULL DEFAULT "");
        INSERT INTO achievement VALUES (1, 'HARTFELT', 'The Third Thing', 'Defeat Hartman', 0, NULL,
          'https://images.gog.com/a_gac_60.jpg', 'https://images.gog.com/b_gac_60.jpg', 0, 12.1, 'Uncommon', 'uncommon');
        """
        _ = try Shell.capture("/usr/bin/sqlite3", [file.path, sql])
        let db = GOGAchievements.database(home: home, clientID: "5353")
        XCTAssertEqual(db?.lastPathComponent, "gameplay.db")
        XCTAssertNil(GOGAchievements.database(home: home, clientID: "9999"))
        let found = GOGAchievements.details(key: "HARTFELT", name: "logged", database: db)
        XCTAssertEqual(found.name, "The Third Thing")
        XCTAssertEqual(found.description, "Defeat Hartman")
        XCTAssertEqual(found.imageURL?.absoluteString, "https://images.gog.com/b_gac_60.jpg")
        XCTAssertEqual(found.rarity, 12.1, accuracy: 0.001)
        XCTAssertEqual(found.rarityLevel, "Uncommon")
        XCTAssertEqual(GOGAchievements.details(key: "OTHER", name: "logged", database: db), GOGAchievement(key: "OTHER", name: "logged"))
    }

    // MARK: Pinned tools

    /// Owner review on #539: ensure() kept whatever sat at tools/gogdl, so moving the pin to a
    /// newer gogdl or comet never reached existing installs. The file there is checked against the
    /// pinned checksum and replaced when it differs; a right one is left alone. No network: the
    /// "release" is a local file, which EngineStore.download verifies the same way.
    func testPinnedToolIsReplacedWhenItIsNotThePinnedBuild() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "gog-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let gog = GOGStore(paths: HighballPaths(home: root.appending(path: "home")))
        let release = root.appending(path: "gogdl-1.4.0")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("gogdl 1.4.0".utf8).write(to: release)
        let sha = try EngineStore(paths: gog.paths).sha256(of: release)
        func component(_ url: URL) -> EngineManifest.Component {
            EngineManifest.Component(kind: "tool", url: url, sha256: sha, size: nil, license: nil, optional: nil,
                                     acceptance: nil, extract: nil, note: nil, version: "1.4.0")
        }
        let binary = gog.gogdlBinary
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("gogdl 1.3.1".utf8).write(to: binary)
        XCTAssertFalse(gog.isPinned(binary, sha256: sha))

        _ = try await gog.ensure(component(release), name: "gogdl", at: binary, progress: nil)
        XCTAssertEqual(try Data(contentsOf: binary), Data("gogdl 1.4.0".utf8), "the old build is replaced")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: binary.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: binary.deletingLastPathComponent().path), ["gogdl"],
                       "nothing staged is left beside it")

        // Now right: a release that cannot be fetched is never asked for.
        let gone = root.appending(path: "missing")
        _ = try await gog.ensure(component(gone), name: "gogdl", at: binary, progress: nil)

        // Changed on disk since it was checked (a damaged copy): checked again, and replaced.
        try Data("damaged!!!!".utf8).write(to: binary)
        XCTAssertFalse(gog.isPinned(binary, sha256: sha))
        _ = try await gog.ensure(component(release), name: "gogdl", at: binary, progress: nil)
        XCTAssertTrue(gog.isPinned(binary, sha256: sha))
    }

    /// The program running from the old file keeps it: the new one is renamed over the path, so
    /// an open handle on the old file still reads the old build.
    func testReplacingAToolLeavesARunningCopyItsFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "gog-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let gog = GOGStore(paths: HighballPaths(home: root.appending(path: "home")))
        let release = root.appending(path: "comet-0.4.1")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("comet 0.4.1".utf8).write(to: release)
        let component = EngineManifest.Component(kind: "tool", url: release, sha256: try EngineStore(paths: gog.paths).sha256(of: release),
                                                 size: nil, license: nil, optional: nil, acceptance: nil, extract: nil, note: nil, version: "0.4.1")
        let binary = gog.cometBinary
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("comet 0.4.0".utf8).write(to: binary)
        let running = try FileHandle(forReadingFrom: binary)
        defer { try? running.close() }

        _ = try await gog.ensure(component, name: "comet", at: binary, progress: nil)
        XCTAssertEqual(try running.readToEnd(), Data("comet 0.4.0".utf8))
        XCTAssertEqual(try Data(contentsOf: binary), Data("comet 0.4.1".utf8))
    }

    /// highball#432: `highball library` listed only installed GOG games. The CLI now reads the
    /// owned list the app saved in library-cache.json, beside Epic's lists it ignores here.
    func testTheCLIReadsTheOwnedListTheAppSaved() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "hb-gogcache-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(GOGStore.lastSeenOwnedGames(home: home), [], "no cache yet")
        let owned = [GOGStore.Game(id: "1440148836", title: "Fallout"), GOGStore.Game(id: "1207658924", title: "Heretic", listsMac: true)]
        let cache: [String: Any] = [
            "epicOwned": [["appName": "Fortnite", "title": "Fortnite"]],
            "epicInstalls": [String: String](),
            "gogGames": try JSONSerialization.jsonObject(with: JSONEncoder().encode(owned)),
        ]
        try JSONSerialization.data(withJSONObject: cache).write(to: home.appending(path: "library-cache.json"))
        XCTAssertEqual(GOGStore.lastSeenOwnedGames(home: home), owned)
        try Data("not json".utf8).write(to: home.appending(path: "library-cache.json"))
        XCTAssertEqual(GOGStore.lastSeenOwnedGames(home: home), [], "a damaged cache lists nothing rather than failing")
    }
}
