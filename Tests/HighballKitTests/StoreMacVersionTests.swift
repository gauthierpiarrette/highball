import XCTest
@testable import HighballKit

/// GOG's and Epic's catalogs list a game's Mac release beside the Windows one, which the same
/// purchase includes: the tile's Apple logo and the game page's Mac section come from that.
final class StoreMacVersionTests: XCTestCase {
    func testGOGReleaseListingMacOSIsMarked() throws {
        let json = """
        {"type":"game","title":{"*":"Jill of the Jungle"},"game":{"releases":[]},
         "supported_operating_systems":[{"slug":"windows","name":"Windows"},{"slug":"osx","name":"macOS"}]}
        """
        XCTAssertEqual(try XCTUnwrap(GOGStore.parseRelease(id: "1", data: Data(json.utf8))).listsMac, true)
        let windowsOnly = #"{"type":"game","title":{"*":"Control"},"game":{},"supported_operating_systems":[{"slug":"windows"}]}"#
        XCTAssertEqual(try XCTUnwrap(GOGStore.parseRelease(id: "2", data: Data(windowsOnly.utf8))).listsMac, false)
    }

    /// An entry cached before the systems were read decodes with nil, which looks it up again.
    func testGOGCacheFromBeforeReadsAsUnknown() throws {
        let old = #"{"id":"1","title":"Old"}"#
        XCTAssertNil(try JSONDecoder().decode(GOGStore.Game.self, from: Data(old.utf8)).listsMac)
    }

    func testEpicCatalogItemListingMacIsMarked() throws {
        let json = """
        [{"app_name":"Garlic","app_title":"Enter the Gungeon",
          "metadata":{"releaseInfo":[{"appId":"Garlic","platform":["Mac","Win32","Windows"]}]}},
         {"app_name":"Duck","app_title":"Cardpocalypse","metadata":{"releaseInfo":[{"platform":["Windows"]}]}},
         {"app_name":"Bare","app_title":"No metadata"}]
        """
        let games = try JSONDecoder().decode([EpicStore.Game].self, from: Data(json.utf8))
        XCTAssertEqual(games.map(\.listsMac), [true, false, false])
        let cloud = #"[{"app_name":"A","app_title":"A","metadata":{"customAttributes":{"CloudSaveFolder":{"type":"STRING","value":"{AppData}/A/Saved"}}}}]"#
        XCTAssertEqual(try JSONDecoder().decode([EpicStore.Game].self, from: Data(cloud.utf8)).map(\.cloudSaves), [true])
        XCTAssertEqual(games.map(\.cloudSaves), [false, false, false])
    }

    func testLibraryCarriesTheListingToGOGAndEpicTiles() {
        let items = LibraryIndex.build(
            bottles: [], steamByBottle: [:],
            epicOwned: [EpicStore.Game(app_name: "Garlic", app_title: "Enter the Gungeon", listsMac: true),
                        EpicStore.Game(app_name: "Duck", app_title: "Cardpocalypse")],
            epicInstalls: [:],
            gogGames: [GOGStore.Game(id: "1", title: "Jill of the Jungle", listsMac: true)])
        let listed = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.macListed) })
        XCTAssertEqual(listed["epic:Garlic"], true)
        XCTAssertEqual(listed["epic:Duck"], false)
        XCTAssertEqual(listed["gog:1"], true)
    }
}

/// Installing and finding a GOG game's Mac build (GOGMac).
final class GOGMacBuildTests: XCTestCase {
    private func header(_ bytes: [UInt8]) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "macho-\(UUID().uuidString)")
        try Data(bytes + [UInt8](repeating: 0, count: 64)).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    func testArchitectureIsReadFromTheExecutable() throws {
        // Thin 64-bit (little-endian magic, then cputype).
        XCTAssertEqual(MacBinaryArch.read(try header([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01])), .native)
        XCTAssertEqual(MacBinaryArch.read(try header([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01])), .intelOnly)
        // Thin 32-bit.
        XCTAssertEqual(MacBinaryArch.read(try header([0xCE, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x00])), .only32Bit)
        // Universal: x86_64 and arm64 slices (big-endian, 20 bytes each).
        let fat: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2,
                            0x01, 0, 0, 0x07] + [UInt8](repeating: 0, count: 16) +
                           [0x01, 0, 0, 0x0C] + [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(MacBinaryArch.read(try header(fat)), .native)
        // Universal with i386 and x86_64 (an old Intel build): Rosetta.
        let oldFat: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2,
                               0, 0, 0, 0x07] + [UInt8](repeating: 0, count: 16) +
                              [0x01, 0, 0, 0x07] + [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(MacBinaryArch.read(try header(oldFat)), .intelOnly)
        XCTAssertEqual(MacBinaryArch.read(try header([0x7F, 0x45, 0x4C, 0x46, 0, 0, 0, 0])), .unknown)
    }

    /// Mac builds keep goggame-<id>.info inside their app; DLC info beside it is not the game.
    func testMacInstallIsFoundByTheInfoInsideItsApp() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "macgames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let resources = base.appending(path: "Samorost 1/Samorost 1.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try #"{"gameId":"2006298293","rootGameId":"2006298293","name":"Samorost 1","buildId":"55"}"#
            .write(to: resources.appending(path: "goggame-2006298293.info"), atomically: true, encoding: .utf8)
        try #"{"gameId":"99","rootGameId":"2006298293","name":"Soundtrack"}"#
            .write(to: resources.appending(path: "goggame-99.info"), atomically: true, encoding: .utf8)
        // Still downloading: skipped.
        let partial = base.appending(path: "Partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data().write(to: partial.appending(path: ".gogdl-resume"))

        let games = GOGStore.macInstalledGames(in: base)
        XCTAssertEqual(games.map(\.id), ["2006298293"])
        XCTAssertEqual(games.first?.app?.lastPathComponent, "Samorost 1.app")
        XCTAssertEqual(games.first?.folder.lastPathComponent, "Samorost 1.app", "the info sits in the app, so the app is the game's folder")
        XCTAssertEqual(games.first?.buildID, "55")
        XCTAssertEqual(games.first?.dlcIDs, ["99"])
        XCTAssertEqual(games.first?.asInstalledGame.dlcIDs, ["99"], "the record the Windows paths take keeps the DLC")
    }

    /// DLC is the info beside the game's own that names it as root: never another app's info in
    /// the same folder of apps, whether that app is another game or names this one.
    func testDLCIsOnlyTheInfoBesideTheGamesOwn() throws {
        let applications = FileManager.default.temporaryDirectory.appending(path: "apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: applications) }
        let games = applications.appending(path: "Games")
        let foo = games.appending(path: "Foo.app/Contents/Resources"), zed = games.appending(path: "Zed.app/Contents/Resources")
        for folder in [foo, zed] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try #"{"gameId":"1","rootGameId":"1","name":"Foo"}"#.write(to: foo.appending(path: "goggame-1.info"), atomically: true, encoding: .utf8)
        try #"{"gameId":"2","rootGameId":"1","name":"Foo DLC"}"#.write(to: foo.appending(path: "goggame-2.info"), atomically: true, encoding: .utf8)
        try #"{"gameId":"5","name":"Zed"}"#.write(to: zed.appending(path: "goggame-5.info"), atomically: true, encoding: .utf8)
        try #"{"gameId":"6","rootGameId":"1","name":"Stray"}"#.write(to: zed.appending(path: "goggame-6.info"), atomically: true, encoding: .utf8)

        let game = try XCTUnwrap(GOGStore.macInstalledGames(in: applications).first)
        XCTAssertEqual(game.id, "1")
        XCTAssertEqual(game.dlcIDs, ["2"])
    }

    /// An app among others in a folder of /Applications (/Applications/Games/Foo.app): the game,
    /// and so its Trash, is that app alone, never the folder with the other apps in it.
    func testAppInAFolderOfOtherAppsIsTheGamesFolderAlone() throws {
        let applications = FileManager.default.temporaryDirectory.appending(path: "apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: applications) }
        let games = applications.appending(path: "Games")
        let resources = games.appending(path: "Foo.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: games.appending(path: "Another Game.app/Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: games.appending(path: "Zed.app/Contents/MacOS"), withIntermediateDirectories: true)
        try #"{"gameId":"1207658924","rootGameId":"1207658924"}"#
            .write(to: resources.appending(path: "goggame-1207658924.info"), atomically: true, encoding: .utf8)

        let game = try XCTUnwrap(GOGStore.macInstalledGames(in: applications).first)
        XCTAssertEqual(game.folder.lastPathComponent, "Foo.app")
        XCTAssertEqual(game.folder.deletingLastPathComponent().lastPathComponent, "Games")
        XCTAssertEqual(game.app?.lastPathComponent, "Foo.app")
        XCTAssertEqual(game.title, "Foo", "with no name in the info, the app's, not the folder's")
    }

    /// What gogdl actually made for Samorost 1: the app itself, straight in the Mac games folder.
    func testMacInstallThatIsTheAppItselfIsFound() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "macgames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let resources = base.appending(path: "Samorost 1.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try #"{"gameId":"2006298293","rootGameId":"2006298293","name":"Samorost 1"}"#
            .write(to: resources.appending(path: "goggame-2006298293.info"), atomically: true, encoding: .utf8)
        let game = try XCTUnwrap(GOGStore.macInstalledGames(in: base).first)
        XCTAssertEqual(game.id, "2006298293")
        XCTAssertEqual(game.app?.lastPathComponent, "Samorost 1.app")
        XCTAssertEqual(game.folder.lastPathComponent, "Samorost 1.app")
    }

    /// GOG Galaxy for Mac's layout (Cyberpunk 2077): the info in the folder's own
    /// Contents/Resources, the app beside it; a game in two searched folders counts once.
    func testGalaxyInstallInApplicationsIsFound() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appending(path: "Applications"), own = root.appending(path: "Highball Games")
        let folder = applications.appending(path: "Cyberpunk 2077")
        try FileManager.default.createDirectory(at: folder.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "Cyberpunk2077.app/Contents/MacOS"), withIntermediateDirectories: true)
        try #"{"gameId":"1423049311","rootGameId":"1423049311","name":"Cyberpunk 2077"}"#
            .write(to: folder.appending(path: "Contents/Resources/goggame-1423049311.info"), atomically: true, encoding: .utf8)
        try #"{"gameId":"1256837418","rootGameId":"1423049311","name":"Phantom Liberty"}"#
            .write(to: folder.appending(path: "Contents/Resources/goggame-1256837418.info"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)

        let games = GOGStore.macInstalledGames(in: [own, applications, applications])
        XCTAssertEqual(games.map(\.id), ["1423049311"])
        XCTAssertEqual(games.first?.app?.lastPathComponent, "Cyberpunk2077.app")
        XCTAssertEqual(games.first?.folder.lastPathComponent, "Cyberpunk 2077")
        XCTAssertEqual(games.first?.dlcIDs, ["1256837418"])
    }

    /// A folder with several apps beside its info opens the one the primary play task names, not
    /// the first by name, and the record the save sync and comet read keeps the info's client id
    /// and tasks.
    func testThePrimaryPlayTaskPicksTheAppAndTheRecordKeepsTheInfo() throws {
        let applications = FileManager.default.temporaryDirectory.appending(path: "apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: applications) }
        let folder = applications.appending(path: "Some Game")
        for app in ["A Config Tool.app", "Some Game.app"] {
            try FileManager.default.createDirectory(at: folder.appending(path: "\(app)/Contents/MacOS"), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: folder.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try #"{"gameId":"7","rootGameId":"7","name":"Some Game","clientId":"5150","playTasks":[{"category":"tool","type":"FileTask","path":"A Config Tool.app"},{"category":"game","isPrimary":true,"type":"FileTask","path":"Some Game.app/Contents/MacOS/Some Game"}]}"#
            .write(to: folder.appending(path: "Contents/Resources/goggame-7.info"), atomically: true, encoding: .utf8)

        let game = try XCTUnwrap(GOGStore.macInstalledGames(in: applications).first)
        XCTAssertEqual(game.app?.lastPathComponent, "Some Game.app")
        XCTAssertEqual(game.folder.lastPathComponent, "Some Game")
        XCTAssertEqual(game.asInstalledGame.clientID, "5150")
        XCTAssertEqual(game.asInstalledGame.tasks.count, 2)
        XCTAssertNil(GOGStore.taskApp([], in: folder, among: [folder.appending(path: "Some Game.app")]), "no task, no choice")
    }

    /// gogdl's sizes: the shared files under "*" plus the installed language's (Samorost 1's Mac build).
    func testDownloadSizeAddsTheLanguagesFilesToTheSharedOnes() {
        let obj: [String: Any] = ["languages": ["en-US", "fr-FR"],
                                  "size": ["*": ["download_size": 44, "disk_size": 38],
                                           "en-US": ["download_size": 68067216, "disk_size": 95828300],
                                           "fr-FR": ["download_size": 1, "disk_size": 1]]]
        let info = GOGStore.parseInfo(obj, preferred: ["en-US"])
        XCTAssertEqual(info.downloadSize, 68067260)
        XCTAssertEqual(info.diskSize, 95828338)
    }

    func testMacDownloadAsksGogdlForTheMacBuild() {
        let args = GOGStore.downloadArguments(id: "7", into: "/x", support: "/s", language: "en-US", update: false, platform: "osx")
        XCTAssertEqual(args[0...3], ["download", "7", "--platform", "osx"])
        XCTAssertEqual(GOGStore.downloadArguments(id: "7", into: "/x", support: "/s", language: "en-US", update: false)[3], "windows")
    }
}

/// Epic's Mac builds through legendary: one build per game, the Mac one in the Mac games folder.
final class EpicMacBuildTests: XCTestCase {
    func testMacInstallAsksLegendaryForTheMacBuild() {
        XCTAssertEqual(EpicStore.installArguments(appName: "Garlic", basePath: "/m", platform: "Mac"),
                       ["install", "Garlic", "--platform", "Mac", "--base-path", "/m", "-y", "--skip-sdl"])
        XCTAssertEqual(EpicStore.installArguments(appName: "Garlic", basePath: "/w")[3], "Windows")
    }

    /// Epic's catalog can list Mac with no Mac asset, and legendary's install then falls back to
    /// Windows: the Windows copy is removed only when `info` names a Mac version.
    func testAMacBuildIsThereOnlyWhenLegendaryNamesAMacVersion() {
        let both = #"[cli] INFO: Getting game metadata... {"game": {"app_name": "Garlic", "platform_versions": {"Windows": "1.0-w", "Mac": "1.0-m"}}, "install": null, "manifest": null}"#
        let windowsOnly = #"{"game": {"app_name": "Duck", "platform_versions": {"Windows": "2.0"}}, "install": {"platform": "Windows"}, "manifest": {"disk_size": 5}}"#
        XCTAssertTrue(EpicStore.listsBuild(Data(both.utf8), platform: "Mac"))
        XCTAssertFalse(EpicStore.listsBuild(Data(windowsOnly.utf8), platform: "Mac"), "a Windows manifest from the install is not a Mac build")
        XCTAssertFalse(EpicStore.listsBuild(Data(#"{"game": null, "install": null, "manifest": null}"#.utf8), platform: "Mac"))
        XCTAssertFalse(EpicStore.listsBuild(Data("No game information available.".utf8), platform: "Mac"))
    }

    func testTheFallBackToWindowsIsSeen() {
        XCTAssertTrue(EpicStore.fellBackToWindows(#"[cli] WARNING: App has no asset for platform "Mac", falling back to "Windows"."#))
        XCTAssertFalse(EpicStore.fellBackToWindows(#"[cli] INFO: Preparing download for "Garlic"..."#))
    }

    func testInstallRecordSaysWhichBuild() throws {
        let json = #"[{"app_name":"Garlic","install_path":"/m/Enter the Gungeon","platform":"Mac"},{"app_name":"Duck","install_path":"/w","platform":"Windows"},{"app_name":"Old","install_path":"/o"}]"#
        let games = try JSONDecoder().decode([EpicStore.InstalledGame].self, from: Data(json.utf8))
        XCTAssertEqual(games.map(\.isMac), [true, false, false])
    }

    func testLibraryMarksTheMacBuildInstalled() {
        let items = LibraryIndex.build(bottles: [], steamByBottle: [:],
                                       epicOwned: [EpicStore.Game(app_name: "Garlic", app_title: "Enter the Gungeon", listsMac: true)],
                                       epicInstalls: [:], epicMacInstalled: ["Garlic"])
        let item = items.first { $0.id == "epic:Garlic" }
        XCTAssertEqual(item?.installedOnMac, true)
        XCTAssertEqual(item?.installed, false, "the Windows build is not")
    }

    /// legendary's Mac install path is the folder holding the app.
    func testArchitectureOfAnAppInsideAFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "epicmac-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let macos = folder.appending(path: "Game.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Game</string></dict></plist>"#
            .write(to: folder.appending(path: "Game.app/Contents/Info.plist"), atomically: true, encoding: .utf8)
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01] + [UInt8](repeating: 0, count: 64)).write(to: macos.appending(path: "Game"))
        XCTAssertEqual(MacBinaryArch.ofApp(at: folder), .native)
        XCTAssertEqual(MacBinaryArch.ofApp(at: folder.appending(path: "Game.app")), .native)
    }
}

/// A GOG Mac build's saves: GOG's Mac locations, when GOG syncs them for the Mac build.
final class GOGMacSavesTests: XCTestCase {
    private func config(windows: String, mac: String) -> Data {
        Data(#"{"content":{"Windows":{"cloudStorage":\#(windows)},"MacOS":{"cloudStorage":\#(mac)}}}"#.utf8)
    }

    func testGOGsOwnMacLocationsSyncAsTheMacBuild() throws {
        let data = config(windows: #"{"enabled":true,"locations":[{"name":"saves","location":"<?SAVED_GAMES?>/X"}]}"#,
                          mac: #"{"enabled":true,"locations":[{"name":"saves","location":"<?APPLICATION_SUPPORT?>/X/saves"}]}"#)
        let locations = try XCTUnwrap(GOGSaves.parseLocations(data, clientID: "c", platform: "MacOS"))
        XCTAssertEqual(locations, [GOGSaves.Location(name: "saves", template: "<?APPLICATION_SUPPORT?>/X/saves", os: "osx")])
    }

    /// Cyberpunk 2077 as GOG configures it: Windows syncs, the Mac build does not, as it syncs its
    /// own saves through GOG's SDK. Highball syncs no files for it.
    func testAMacBuildGOGSyncsNoneForHasNone() {
        let data = config(windows: #"{"enabled":true,"locations":[{"name":"saves","location":"<?SAVED_GAMES?>/CD Projekt Red/Cyberpunk 2077"}]}"#,
                          mac: #"{"enabled":false,"locations":[]}"#)
        XCTAssertNil(GOGSaves.parseLocations(data, clientID: "c", platform: "MacOS"))
    }

    /// What the game page says comes from both versions' setups at once: Cyberpunk 2077 copies
    /// folders for Windows and saves through the game itself on Mac.
    func testCloudSetupReadsBothVersions() {
        let data = config(windows: #"{"enabled":true,"locations":[{"name":"saves","location":"<?SAVED_GAMES?>/CD Projekt Red/Cyberpunk 2077"}]}"#,
                          mac: #"{"enabled":false,"locations":[]}"#)
        let setup = GOGSaves.parseCloudSetup(data, clientID: "c")
        XCTAssertEqual(setup.windows.map(\.name), ["saves"])
        XCTAssertEqual(setup.mac, [])
    }

    func testMacFoldersResolveUnderTheHomeAndNeverAWholeKnownFolder() {
        let home = URL(fileURLWithPath: "/Users/someone"), install = URL(fileURLWithPath: "/Applications/Game")
        XCTAssertEqual(GOGSaves.resolveMac("<?APPLICATION_SUPPORT?>/Studio/Game", installFolder: install, home: home)?.path,
                       "/Users/someone/Library/Application Support/Studio/Game")
        XCTAssertEqual(GOGSaves.resolveMac("<?INSTALL?>/saves", installFolder: install, home: home)?.path, "/Applications/Game/saves")
        XCTAssertNil(GOGSaves.resolveMac("<?DOCUMENTS?>", installFolder: install, home: home))
        XCTAssertNil(GOGSaves.resolveMac("<?DOCUMENTS?>/../..", installFolder: install, home: home))
        XCTAssertNil(GOGSaves.resolveMac("<?SOMETHING_NEW?>/x", installFolder: install, home: home))
        // A variable reaching into a known folder names all of it, which gogdl would empty of
        // whatever the cloud lacks.
        for whole in ["<?LIBRARY?>/Preferences", "<?LIBRARY?>/Application Support", "<?LIBRARY?>/Caches",
                      "<?LIBRARY?>/Containers", "<?LIBRARY?>/Group Containers", "<?LIBRARY?>/preferences/",
                      "<?LIBRARY?>", "<?PREFERENCES?>", "<?APPLICATION_SUPPORT?>", "<?CACHES?>",
                      "<?LIBRARY?>/Mobile Documents/com~apple~CloudDocs", "<?LIBRARY?>/CloudStorage/Dropbox",
                      "<?LIBRARY?>/Containers/com.studio.game", "<?DOCUMENTS?>/../Desktop",
                      // Folders many games share one level deeper, each game in its own folder below.
                      "<?DOCUMENTS?>/My Games", "<?DOCUMENTS?>/my games/", "<?APPLICATION_SUPPORT?>/GOG.com",
                      "<?APPLICATION_SUPPORT?>/Steam", "<?APPLICATION_SUPPORT?>/Epic", "<?APPLICATION_SUPPORT?>/Epic Games",
                      "<?LIBRARY?>/Application Support/Feral Interactive", "<?APPLICATION_SUPPORT?>/Aspyr"] {
            XCTAssertNil(GOGSaves.resolveMac(whole, installFolder: install, home: home), whole)
        }
        XCTAssertEqual(GOGSaves.resolveMac("<?DOCUMENTS?>/My Games/Studio Game", installFolder: install, home: home)?.path,
                       "/Users/someone/Documents/My Games/Studio Game")
        XCTAssertEqual(GOGSaves.resolveMac("<?APPLICATION_SUPPORT?>/Feral Interactive/Game/Saves", installFolder: install, home: home)?.path,
                       "/Users/someone/Library/Application Support/Feral Interactive/Game/Saves")
        XCTAssertEqual(GOGSaves.resolveMac("<?APPLICATION_SUPPORT?>/GOG.com/Galaxy/Applications/c/Storage/Shared/Files", installFolder: install, home: home)?.path,
                       "/Users/someone/Library/Application Support/GOG.com/Galaxy/Applications/c/Storage/Shared/Files")
        XCTAssertEqual(GOGSaves.resolveMac("<?LIBRARY?>/Preferences/Studio Game", installFolder: install, home: home)?.path,
                       "/Users/someone/Library/Preferences/Studio Game")
        XCTAssertEqual(GOGSaves.resolveMac("<?LIBRARY?>/Containers/com.studio.game/Data/Saves", installFolder: install, home: home)?.path,
                       "/Users/someone/Library/Containers/com.studio.game/Data/Saves")
        XCTAssertEqual(GOGSaves.resolveMac("<?DOCUMENTS?>/Studio", installFolder: install, home: home)?.path, "/Users/someone/Documents/Studio")
        XCTAssertEqual(GOGSaves.resolveMac("<?INSTALL?>/saves", installFolder: home.appending(path: "Applications/Highball Games/Game.app"), home: home)?.path,
                       "/Users/someone/Applications/Highball Games/Game.app/saves")
    }

    func testSyncNamesTheSystemOfTheLocation() {
        let mac = GOGSaves.Location(name: "saves", template: "t", os: "osx")
        let args = GOGSaves.arguments(folder: URL(fileURLWithPath: "/s"), id: "1", location: mac, timestamp: "0", direction: .download)
        XCTAssertEqual(args[3...4], ["--os", "osx"])
    }
}

final class MacBuildDetectionTests: XCTestCase {
    /// A 64-bit universal header (0xCAFEBABF): 32-byte slices.
    func testSixtyFourBitUniversalHeader() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "fat64-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let slice: (UInt8) -> [UInt8] = { cpu in [0x01, 0, 0, cpu] + [UInt8](repeating: 0, count: 28) }
        try Data([0xCA, 0xFE, 0xBA, 0xBF, 0, 0, 0, 2] + slice(0x07) + slice(0x0C) + [UInt8](repeating: 0, count: 64)).write(to: file)
        XCTAssertEqual(MacBinaryArch.read(file), .native)
    }

    /// Highball Games inside ~/Applications is searched on its own, never read as one game: its
    /// Trash button would take every game in it.
    func testASearchedFolderInsideAnotherIsNotAGame() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appending(path: "Applications"), own = applications.appending(path: "Highball Games")
        let resources = own.appending(path: "Samorost 1.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try #"{"gameId":"2006298293","rootGameId":"2006298293","name":"Samorost 1"}"#
            .write(to: resources.appending(path: "goggame-2006298293.info"), atomically: true, encoding: .utf8)
        try Data().write(to: own.appending(path: "Samorost 1.app/.gogdl-resume"))   // its own pass skips it
        XCTAssertEqual(GOGStore.macInstalledGames(in: [own, applications]).map(\.folder.lastPathComponent), [])
    }
}

/// A Mac game ends once nothing runs from its folder, not when the process Highball started
/// quits: that one may be a launcher handing over to the game.
final class MacGameWatchTests: XCTestCase {
    func testAProcessRunsFromTheFolderOnlyInsideIt() {
        XCTAssertTrue(MacGameWatch.runs(executable: "/Applications/Games/Foo.app/Contents/MacOS/Foo", from: "/Applications/Games/Foo.app"))
        XCTAssertTrue(MacGameWatch.runs(executable: "/Applications/Games/Foo.app/Contents/MacOS/Foo", from: "/Applications/Games/Foo.app/"))
        XCTAssertFalse(MacGameWatch.runs(executable: "/Applications/Games/Foo.app2/Contents/MacOS/Foo", from: "/Applications/Games/Foo.app"))
        XCTAssertFalse(MacGameWatch.runs(executable: "/Applications/Games/Bar.app/Contents/MacOS/Bar", from: "/Applications/Games/Foo.app"))
    }

    func testALauncherThatHandsOverIsFollowedUntilTheGameQuits() async {
        var checks = 0
        let handedOver = await MacGameWatch.waitForHandover(from: URL(fileURLWithPath: "/g"), ranFor: 1, grace: 5, interval: 0.01) { _ in
            checks += 1
            return checks <= 3 ? [42] : []
        }
        XCTAssertTrue(handedOver)
        XCTAssertEqual(checks, 4, "ends at the first look that finds nothing, not after the grace")
    }

    func testAGameThatRanAWhileEndsWithItsProcess() async {
        var checks = 0
        let handedOver = await MacGameWatch.waitForHandover(from: URL(fileURLWithPath: "/g"), ranFor: 600, interval: 0.01) { _ in
            checks += 1
            return []
        }
        XCTAssertFalse(handedOver)
        XCTAssertEqual(checks, 1)
    }

    func testAQuickExitWaitsAMomentForItsSuccessor() async {
        var checks = 0
        let handedOver = await MacGameWatch.waitForHandover(from: URL(fileURLWithPath: "/g"), ranFor: 1, grace: 2, interval: 0.01) { _ in
            checks += 1
            return checks == 5 ? [42] : []
        }
        XCTAssertTrue(handedOver, "a successor that shows up after the launcher quit still counts")
    }
}
