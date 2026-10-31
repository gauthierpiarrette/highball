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
        XCTAssertEqual(games.first?.buildID, "55")
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
