import XCTest
@testable import HighballKit

final class MacSteamBuildTests: XCTestCase {
    private func entry(_ json: String) throws -> GameDBEntry {
        try JSONDecoder().decode(GameDBEntry.self, from: Data(json.utf8))
    }

    // MARK: Mac builds on Steam

    func testStoreFlagAloneMarksIt() {
        XCTAssertEqual(MacSteamBuild.resolve(entry: nil, storeMac: true), .onStore)
        XCTAssertNil(MacSteamBuild.resolve(entry: nil, storeMac: false))
        XCTAssertNil(MacSteamBuild.resolve(entry: nil, storeMac: nil), "not asked yet is not a Mac build")
    }

    func testRowNamingSteamMarksIt() throws {
        let hades = try entry(#"{"id":"hades-ii","title":"Hades II","steam_appid":1145350,"status":"community","nativeMac":{"available":true,"where":"Steam","note":"Native Apple Silicon build, macOS 12 and M1 or later."}}"#)
        XCTAssertEqual(MacSteamBuild.resolve(entry: hades, storeMac: nil), .inDatabase)
        // Rows list every store; Steam among them is enough.
        let cyberpunk = try entry(#"{"id":"cyberpunk-2077","title":"Cyberpunk 2077","steam_appid":1091500,"status":"community","nativeMac":{"available":true,"where":"Steam, Mac App Store, GOG, Epic"}}"#)
        XCTAssertEqual(MacSteamBuild.resolve(entry: cyberpunk, storeMac: nil), .inDatabase)
    }

    func testInstalledInSteamForMacNeedsNoOneElse() throws {
        XCTAssertEqual(MacSteamBuild.resolve(entry: nil, storeMac: nil, installedOnMac: true), .installed)
        let retired = try entry(#"{"id":"x","title":"X","steam_appid":1,"status":"community","nativeMac":{"available":false}}"#)
        XCTAssertEqual(MacSteamBuild.resolve(entry: retired, storeMac: false, installedOnMac: true), .installed,
                       "it's installed and the player has it: that outranks any row")
    }

    /// The Binding of Isaac's Mac build stops at Afterbirth+; Repentance is Windows only, so a player
    /// who owns it was sent to the old game (highball#223). A row saying the Mac build is not the one
    /// to play puts the Windows build first even with the Mac one installed; nothing else changes.
    func testARowCanPutTheWindowsBuildFirstOverAnInstalledMacOne() throws {
        let isaac = try entry(#"{"id":"the-binding-of-isaac-rebirth","title":"Isaac","steam_appid":250900,"status":"community","nativeMac":{"available":false,"where":"Steam"}}"#)
        let hades = try entry(#"{"id":"hades-ii","title":"Hades II","steam_appid":1145350,"status":"community","nativeMac":{"available":true,"where":"Steam"}}"#)
        XCTAssertFalse(MacSteamBuild.leads(entry: isaac, installedOnMac: true), "the Windows build leads")
        XCTAssertTrue(MacSteamBuild.leads(entry: hades, installedOnMac: true))
        XCTAssertTrue(MacSteamBuild.leads(entry: nil, installedOnMac: true), "no row: an installed Mac build leads as before")
        XCTAssertFalse(MacSteamBuild.leads(entry: hades, installedOnMac: false), "nothing installed on the Mac side")
    }

    // MARK: Steam for Mac's installs

    private func macSteam(_ manifests: [String: [(Int, String, Int)]], extraLibrary: URL? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "hb-macsteam-\(UUID())/Steam")
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for (library, games) in manifests {
            let dir = (library == "root" ? root : root.deletingLastPathComponent().appending(path: library)).appending(path: "steamapps")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (appid, name, flags) in games {
                try #""AppState" { "appid" "\#(appid)" "name" "\#(name)" "StateFlags" "\#(flags)" "installdir" "\#(name)" }"#
                    .write(to: dir.appending(path: "appmanifest_\(appid).acf"), atomically: true, encoding: .utf8)
            }
        }
        let other = root.deletingLastPathComponent().appending(path: "External Drive")
        try #"""
        "libraryfolders" { "0" { "path" "\#(root.path)" } "1" { "path" "\#(other.path)" } }
        """#.write(to: root.appending(path: "steamapps/libraryfolders.vdf"), atomically: true, encoding: .utf8)
        return root
    }

    func testReadsEveryMacLibraryFolderAndOnlyFinishedInstalls() throws {
        let root = try macSteam([
            "root": [(2379780, "Balatro", 4), (268910, "Cuphead", 1026), (228980, "Steamworks Common Redistributables", 4)],
            "External Drive": [(588650, "Dead Cells", 4), (2379780, "Balatro", 4)],
        ])
        XCTAssertEqual(MacSteam.steamappsDirectories(root: root).count, 2, "the root listed again isn't a second library")
        XCTAssertEqual(MacSteam.installedGames(root: root).map(\.appid), [2379780, 588650],
                       "Cuphead is still downloading; redistributables aren't a game; one Balatro")
    }

    /// A library folder both clients use shows Steam for Mac the Windows client's manifests. Those
    /// are the environment's games, not Mac installs: Forza Horizon 6 got "Play on Mac" (2026-10-09).
    func testAManifestTheWindowsClientWroteIsNoMacInstall() throws {
        let root = try macSteam(["root": [(2379780, "Balatro", 4)]])
        let dir = root.appending(path: "steamapps")
        try #""AppState" { "appid" "2483190" "name" "Forza Horizon 6" "StateFlags" "4" "installdir" "ForzaHorizon6" "LauncherPath" "C:\\Program Files (x86)\\Steam\\steam.exe" }"#
            .write(to: dir.appending(path: "appmanifest_2483190.acf"), atomically: true, encoding: .utf8)
        try #""AppState" { "appid" "588650" "name" "Dead Cells" "StateFlags" "4" "installdir" "Dead Cells" "LauncherPath" "/Users/me/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx" }"#
            .write(to: dir.appending(path: "appmanifest_588650.acf"), atomically: true, encoding: .utf8)
        XCTAssertEqual(MacSteam.installedGames(root: root).map(\.appid), [2379780, 588650],
                       "the Windows client's Forza is left out, a Mac path or no path counts as before")
        let forza = try XCTUnwrap(SteamLibrary.parseManifest(dir.appending(path: "appmanifest_2483190.acf")))
        XCTAssertTrue(forza.installedByWindowsSteam)
        XCTAssertFalse(try XCTUnwrap(SteamLibrary.parseManifest(dir.appending(path: "appmanifest_588650.acf"))).installedByWindowsSteam)
    }

    func testNoSteamForMacIsNothingInstalled() {
        let nowhere = FileManager.default.temporaryDirectory.appending(path: "hb-nosteam-\(UUID())")
        XCTAssertEqual(MacSteam.installedGames(root: nowhere), [])
    }

    func testOnlyValvesAppCountsAsSteamForMac() {
        let wrapper = URL(fileURLWithPath: "/Users/me/Applications/Wine/Steam.app")
        let steam = URL(fileURLWithPath: "/Applications/Steam.app")
        let ids = [wrapper: "com.wine.wine.steam", steam: "com.valvesoftware.steam"]
        XCTAssertEqual(MacSteam.app(among: [wrapper, steam], bundleID: { ids[$0] }), steam,
                       "a Wine wrapper ahead of it doesn't hide Steam for Mac")
        XCTAssertNil(MacSteam.app(among: [wrapper], bundleID: { ids[$0] }),
                     "a Wine wrapper alone isn't Steam for Mac")
        XCTAssertNil(MacSteam.app(among: []))
    }

    func testRowCanRetireAPortTheStoreStillLists() throws {
        let retired = try entry(#"{"id":"x","title":"X","steam_appid":1,"status":"community","nativeMac":{"available":false,"note":"32-bit, stopped running with Catalina"}}"#)
        XCTAssertNil(MacSteamBuild.resolve(entry: retired, storeMac: true))
    }

    func testEditionSoldElsewhereIsNotMarked() throws {
        // Death Stranding's Mac edition is a separate Mac App Store purchase: not marked.
        let ds = try entry(#"{"id":"death-stranding","title":"Death Stranding","steam_appid":1190460,"status":"community","nativeMac":{"available":true,"where":"Mac App Store only","note":"A native Director's Cut exists on the Mac App Store."}}"#)
        XCTAssertNil(MacSteamBuild.resolve(entry: ds, storeMac: false))
    }

    // MARK: store

    func testParsesStorePlatforms() {
        let portal = #"{"400":{"success":true,"data":{"platforms":{"windows":true,"mac":false,"linux":true}}}}"#
        let hades = #"{"1145360":{"success":true,"data":{"platforms":{"windows":true,"mac":true,"linux":false}}}}"#
        XCTAssertEqual(MacFlagStore.parse(Data(portal.utf8)), false)
        XCTAssertEqual(MacFlagStore.parse(Data(hades.utf8)), true)
        XCTAssertNil(MacFlagStore.parse(Data(#"{"999":{"success":false}}"#.utf8)), "no store page is not a no")
        XCTAssertNil(MacFlagStore.parse(Data("<html>".utf8)))
    }

    func testAsksOnlyAboutGamesAppinfoListsForMacOS() {
        // 1145350 lists macOS, 570940 doesn't, 400 isn't in the owned list yet: asked, unknown.
        XCTAssertEqual(MacFlagStore.worthAsking([1145350, 570940, 400], listsMac: [1145350: true, 570940: false]),
                       [1145350, 400])
    }

    func testCacheKeepsTwoWeeks() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-flags-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = MacFlagStore(file: file)
        let then = Date(timeIntervalSince1970: 1_790_000_000)
        store.save([400: false, 1145360: true], now: then)
        XCTAssertEqual(store.load(now: then.addingTimeInterval(13 * 86400)), [400: false, 1145360: true])
        XCTAssertEqual(store.load(now: then.addingTimeInterval(15 * 86400)), [:])
    }

    func testCorruptCacheIsEmpty() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-flags-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)
        XCTAssertEqual(MacFlagStore(file: file).load(), [:])
    }

    // MARK: page copy

    func testPageCopyNamesSourceAndRequirements() throws {
        XCTAssertNil(GamePageCopy.macBuild(nil, entry: nil, myChip: "Apple M1 Pro", macOS: "26.6.2"))

        let hades = try entry(#"{"id":"hades-ii","title":"Hades II","steam_appid":1145350,"status":"community","nativeMac":{"available":true,"where":"Steam","note":"Native Apple Silicon build, macOS 12 and M1 or later."}}"#)
        let fromRow = try XCTUnwrap(GamePageCopy.macBuild(.inDatabase, entry: hades, myChip: "Apple M1 Pro", macOS: "26.6.2"))
        XCTAssertEqual(fromRow.headline, "There is a native Mac build on Steam.")
        XCTAssertEqual(fromRow.requirements, "Native Apple Silicon build, macOS 12 and M1 or later.")
        XCTAssertEqual(fromRow.yourMac, "Your Mac is an M1 Pro on macOS 26.6.2.")
        XCTAssertEqual(fromRow.source, "From the compatibility database.")

        let fromStore = try XCTUnwrap(GamePageCopy.macBuild(.onStore, entry: nil, myChip: "Apple M1 Pro", macOS: "26.6.2"))
        XCTAssertNil(fromStore.requirements)
        XCTAssertEqual(fromStore.source, "Steam's store page lists macOS for it.")

        let installed = try XCTUnwrap(GamePageCopy.macBuild(.installed, entry: hades, myChip: "Apple M1 Pro", macOS: "26.6.2"))
        XCTAssertEqual(installed.headline, "Installed in Steam for Mac.")
        XCTAssertEqual(installed.requirements, "Native Apple Silicon build, macOS 12 and M1 or later.")
        XCTAssertEqual(installed.source, "Steam for Mac lists it as installed.")
    }
}
