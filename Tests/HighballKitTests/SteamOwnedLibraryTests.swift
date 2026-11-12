import XCTest
@testable import HighballKit

/// The owned Steam library (highball#199): Steam's binary appinfo.vdf, the librarycache folders
/// that name the account's apps, and how owned-only games join the library.
final class SteamOwnedLibraryTests: XCTestCase {

    // MARK: A synthetic appinfo.vdf

    private struct App {
        var appid: UInt32; var name: String; var type: String; var oslist: String = "windows"
        var osextended: String? = nil
        /// Launch entries under config.launch, each with its oslist and optional osarch.
        var launch: [(oslist: String, osarch: String?)] = []
    }

    private func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

    /// Builds a v29 file (keys as indexes into a trailing string table) or a v28 one (inline keys).
    private func appinfo(_ apps: [App], v29: Bool = true) -> Data {
        let keys = ["appinfo", "Common", "name", "type", "oslist", "appid", "osextended", "config", "launch", "osarch", "0", "1", "2"]
        func key(_ k: String) -> [UInt8] { v29 ? le(UInt32(keys.firstIndex(of: k)!)) : Array(k.utf8) + [0] }
        func str(_ k: String, _ v: String) -> [UInt8] { [0x01] + key(k) + Array(v.utf8) + [0] }
        func int(_ k: String, _ v: UInt32) -> [UInt8] { [0x02] + key(k) + le(v) }
        func obj(_ k: String, _ body: [UInt8]) -> [UInt8] { [0x00] + key(k) + body + [0x08] }

        var entries: [UInt8] = []
        for app in apps {
            // Key case varies in Valve's data; the reader must not care.
            var common = str("name", app.name) + str("type", app.type) + str("oslist", app.oslist)
            if let ext = app.osextended { common += str("osextended", ext) }
            var info = int("appid", app.appid) + obj("Common", common)
            if !app.launch.isEmpty {
                let entries = app.launch.enumerated().flatMap { i, l in
                    obj(String(i), obj("config", str("oslist", l.oslist) + (l.osarch.map { str("osarch", $0) } ?? [])))
                }
                info += obj("config", obj("launch", entries))
            }
            let kv = obj("appinfo", info) + [0x08]
            let header = le(UInt32(2)) + le(UInt32(0)) + le(UInt64(0)) + [UInt8](repeating: 0, count: 20)
                + le(UInt32(1)) + [UInt8](repeating: 0, count: 20)
            entries += le(app.appid) + le(UInt32(header.count + kv.count)) + header + kv
        }
        var out = le(v29 ? SteamAppInfo.magic29 : SteamAppInfo.magic28) + le(UInt32(1))
        if v29 {
            let tableOffset = out.count + 8 + entries.count + 4
            out += le(Int64(tableOffset)) + entries + le(UInt32(0))
            out += le(UInt32(keys.count)) + keys.flatMap { Array($0.utf8) + [0] }
        } else {
            out += entries + le(UInt32(0))
        }
        return Data(out)
    }

    private let apps = [
        App(appid: 1145360, name: "Hades", type: "Game", oslist: "windows,macos"),
        App(appid: 570940, name: "DARK SOULS™: REMASTERED", type: "game"),
        App(appid: 1145361, name: "Hades Soundtrack", type: "Music"),
        App(appid: 228980, name: "Steamworks Common Redistributables", type: "Config"),
    ]

    // MARK: appinfo.vdf

    func testReadsV29() throws {
        let parsed = try SteamAppInfo.parse(appinfo(apps))
        XCTAssertEqual(parsed[1145360], SteamAppInfo.App(name: "Hades", type: "Game", oslist: "windows,macos"))
        XCTAssertEqual(parsed[570940]?.name, "DARK SOULS™: REMASTERED")
        XCTAssertEqual(parsed.count, 4)
    }

    /// Steam for Mac's own reading (highball#310, #316): osextended marks a Mac build that runs,
    /// a 64-bit macOS launch entry does too, and a listed Mac build with neither is 32-bit.
    /// Shaped on the real entries (api.steamcmd.net, 2026-10-11).
    func testReadsTheMacBuildSteamForMacSees() throws {
        let parsed = try SteamAppInfo.parse(appinfo([
            App(appid: 234140, name: "Mad Max", type: "game", oslist: "windows,macos,linux", osextended: "macos64",
                launch: [("windows", nil), ("macos", "64")]),
            App(appid: 1091500, name: "Cyberpunk 2077", type: "game", oslist: "windows,macos", osextended: "macosapplesilicon"),
            App(appid: 352400, name: "LEGO Jurassic World", type: "game", oslist: "windows", osextended: "",
                launch: [("windows", nil), ("macos", "64")]),
            App(appid: 115110, name: "Stacking", type: "game", oslist: "windows,macos,linux", launch: [("macos", nil)]),
            App(appid: 570940, name: "DARK SOULS™: REMASTERED", type: "game"),
        ]))
        XCTAssertEqual(parsed[234140]?.osextended, "macos64")
        XCTAssertEqual(parsed[234140]?.macLaunchArchs, ["64"])
        XCTAssertEqual(parsed[115110]?.macLaunchArchs, [""], "a macOS launch entry naming no osarch")
        XCTAssertEqual(parsed[234140]?.macBuild, .runnable)
        XCTAssertEqual(parsed[1091500]?.macBuild, .runnable, "an Apple Silicon build carries no macos64 mark")
        XCTAssertEqual(parsed[352400]?.macBuild, .runnable, "oslist says Windows, the launch entry says a 64-bit Mac build")
        XCTAssertEqual(parsed[115110]?.macBuild, .only32Bit)
        XCTAssertEqual(parsed[570940]?.macBuild, .absent)

        let root = try steamRoot(owned: [115110, 352400, 570940], appinfo: appinfo([
            App(appid: 352400, name: "LEGO Jurassic World", type: "game", launch: [("macos", "64")]),
            App(appid: 115110, name: "Stacking", type: "game", oslist: "windows,macos,linux"),
            App(appid: 570940, name: "DARK SOULS™: REMASTERED", type: "game"),
        ]))
        XCTAssertEqual(SteamOwnedLibrary.games(steamRoot: root).map(\.macBuild), [.absent, .runnable, .only32Bit])
    }

    func testReadsV28InlineKeys() throws {
        let parsed = try SteamAppInfo.parse(appinfo(apps, v29: false))
        XCTAssertEqual(parsed[1145361]?.type, "Music")
    }

    func testOnlySkipsTheRest() throws {
        let parsed = try SteamAppInfo.parse(appinfo(apps), only: [570940])
        XCTAssertEqual(Array(parsed.keys), [570940])
    }

    func testRejectsUnknownAndTruncatedFiles() throws {
        XCTAssertThrowsError(try SteamAppInfo.parse(Data([1, 2, 3, 4, 5, 6, 7, 8])))
        let whole = appinfo(apps)
        XCTAssertThrowsError(try SteamAppInfo.parse(whole.prefix(whole.count / 2)))
    }

    // MARK: librarycache + appinfo

    private func steamRoot(owned: [Int], appinfo data: Data?) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "hb-owned-\(UUID())/Steam")
        for appid in owned {
            try FileManager.default.createDirectory(at: root.appending(path: "appcache/librarycache/\(appid)"),
                                                    withIntermediateDirectories: true)
        }
        if let data { try data.write(to: root.appending(path: "appcache/appinfo.vdf")) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        return root
    }

    func testOwnedGamesAreLibraryAppsOfTypeGame() throws {
        // 999 has artwork but no appinfo row yet: skipped rather than shown nameless.
        let root = try steamRoot(owned: [1145360, 570940, 1145361, 228980, 999], appinfo: appinfo(apps))
        let games = SteamOwnedLibrary.games(steamRoot: root)
        XCTAssertEqual(games.map(\.appid), [570940, 1145360], "games only, by name")
        XCTAssertEqual(games.map(\.listsMac), [false, true], "appinfo's oslist, for MacFlagStore")
        XCTAssertEqual(games.first?.capsuleImage.absoluteString,
                       "https://cdn.akamai.steamstatic.com/steam/apps/570940/library_600x900.jpg")
    }

    func testDemosStayInTheLibraryLikeGames() throws {
        // A demo installed on a drive that is now unplugged is still owned (highball#432).
        let root = try steamRoot(owned: [3460730, 570940, 1145361], appinfo: appinfo([
            App(appid: 3460730, name: "SlashZero Demo", type: "Demo"), App(appid: 570940, name: "DSR", type: "game"),
            App(appid: 1145361, name: "Hades Soundtrack", type: "Music")]))
        XCTAssertEqual(SteamOwnedLibrary.games(steamRoot: root).map(\.appid), [570940, 3460730], "games and demos, by name")
    }

    func testPrefersTheClientsCachedArtwork() throws {
        let root = try steamRoot(owned: [2062430, 570940], appinfo: appinfo([
            App(appid: 2062430, name: "BALL x PIT", type: "game"), App(appid: 570940, name: "DSR", type: "game")]))
        let cache = root.appending(path: "appcache/librarycache")
        // BALL x PIT keeps its cover one level down under a hash, as the client writes it.
        let hashed = cache.appending(path: "2062430/b6cabe1940c55119820eee4ed2d0b604bd5b3af4")
        try FileManager.default.createDirectory(at: hashed, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: hashed.appending(path: "library_600x900.jpg"))
        try Data([0xFF]).write(to: cache.appending(path: "2062430/library_header.jpg"))
        let games = SteamOwnedLibrary.games(steamRoot: root)
        let ball = try XCTUnwrap(games.first { $0.appid == 2062430 })
        XCTAssertEqual(ball.capsuleImage.lastPathComponent, "library_600x900.jpg")
        XCTAssertTrue(ball.capsuleImage.isFileURL)
        XCTAssertTrue(ball.headerImage.isFileURL)
        let dsr = try XCTUnwrap(games.first { $0.appid == 570940 })
        XCTAssertEqual(dsr.capsuleImage.host, "cdn.akamai.steamstatic.com", "no local art: the CDN")
    }

    /// When a game first appeared in the library: when the client made its librarycache folder
    /// (SteamAccounts.earlyArrivals).
    func testCachedAtIsWhenTheLibraryCacheFolderWasMade() throws {
        let root = try steamRoot(owned: [1145360, 570940], appinfo: appinfo(apps))
        let made = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: made],
                                              ofItemAtPath: root.appending(path: "appcache/librarycache/570940").path)
        let games = SteamOwnedLibrary.games(steamRoot: root)
        let dsr = try XCTUnwrap(games.first { $0.appid == 570940 }?.cachedAt)
        XCTAssertEqual(dsr.timeIntervalSince1970, made.timeIntervalSince1970, accuracy: 1)
        let hades = try XCTUnwrap(games.first { $0.appid == 1145360 }?.cachedAt)
        XCTAssertGreaterThan(hades, made, "a folder made just now")
    }

    func testNothingBeforeFirstSignIn() throws {
        XCTAssertEqual(SteamOwnedLibrary.games(steamRoot: try steamRoot(owned: [], appinfo: nil)), [])
        XCTAssertEqual(SteamOwnedLibrary.games(steamRoot: try steamRoot(owned: [570940], appinfo: nil)), [])
    }

    func testSignatureChangesAsTheLibraryLoads() throws {
        let root = try steamRoot(owned: [570940], appinfo: appinfo(apps))
        let before = SteamOwnedLibrary.signature(steamRoot: root)
        try FileManager.default.createDirectory(at: root.appending(path: "appcache/librarycache/1145360"), withIntermediateDirectories: true)
        XCTAssertNotEqual(SteamOwnedLibrary.signature(steamRoot: root), before)
        XCTAssertEqual(SteamOwnedLibrary.signature(steamRoot: root), SteamOwnedLibrary.signature(steamRoot: root))
    }

    // MARK: LibraryIndex

    private func bottle(_ name: String) -> Bottle {
        Bottle(url: URL(fileURLWithPath: "/tmp/hb-lib-tests/bottles/\(name)"), settings: BottleSettings(name: name, engineID: "e"))
    }

    func testOwnedOnlyGamesJoinTheLibraryOnce() {
        let a = bottle("a"), b = bottle("b")
        let installed = SteamGame(appid: 570940, name: "DARK SOULS™: REMASTERED", installdir: "DSR", sizeOnDisk: 1, stateFlags: 4, lastPlayed: nil)
        let hades = OwnedSteamGame(appid: 1145360, name: "Hades")
        let dsr = OwnedSteamGame(appid: 570940, name: "DARK SOULS™: REMASTERED")
        let items = LibraryIndex.build(
            bottles: [b, a],
            steamByBottle: ["b": [installed]],
            steamOwnedByBottle: ["a": [hades, dsr], "b": [hades, dsr]],
            epicOwned: [], epicInstalls: [:])
        XCTAssertEqual(items.map(\.id), ["steam:570940", "steam:1145360"], "one tile per game")
        let dsrItem = items.first { $0.steamAppID == 570940 }!
        XCTAssertTrue(dsrItem.installed, "the installed copy wins over the owned entry")
        XCTAssertEqual(dsrItem.bottleName, "b")
        let hadesItem = items.first { $0.steamAppID == 1145360 }!
        XCTAssertFalse(hadesItem.installed)
        XCTAssertEqual(hadesItem.bottleName, "a", "owned-only games live in the first bottle by name")
    }

    func testSteamForMacInstallsCountAsInstalled() {
        let a = bottle("a"), b = bottle("b")
        let windows = SteamGame(appid: 570940, name: "DARK SOULS™: REMASTERED", installdir: "DSR", sizeOnDisk: 1, stateFlags: 4, lastPlayed: nil)
        let played = Date(timeIntervalSince1970: 1_790_000_000)
        func mac(_ appid: Int, _ name: String, _ lastPlayed: Date? = nil) -> SteamGame {
            SteamGame(appid: appid, name: name, installdir: name, sizeOnDisk: 1, stateFlags: 4, lastPlayed: lastPlayed)
        }
        let items = LibraryIndex.build(
            bottles: [b, a],
            steamByBottle: ["b": [windows]],
            steamOwnedByBottle: ["a": [OwnedSteamGame(appid: 1145360, name: "Hades")]],
            macInstalled: [mac(570940, "DARK SOULS™: REMASTERED"), mac(1145360, "Hades", played), mac(268910, "Cuphead")],
            epicOwned: [], epicInstalls: [:])
        XCTAssertEqual(items.map(\.id), ["steam:268910", "steam:570940", "steam:1145360"], "one tile per game, Mac or not")
        let dsr = items.first { $0.steamAppID == 570940 }!
        XCTAssertTrue(dsr.installed && dsr.installedOnMac, "both builds")
        let hades = items.first { $0.steamAppID == 1145360 }!
        XCTAssertFalse(hades.installed)
        XCTAssertTrue(hades.installedAnywhere)
        XCTAssertEqual(hades.lastPlayed, played, "Steam for Mac's LastPlayed feeds Continue")
        let cuphead = items.first { $0.steamAppID == 268910 }!
        XCTAssertTrue(cuphead.installedOnMac, "no bottle knows it: a tile of its own")
        XCTAssertEqual(cuphead.bottleName, "a", "homed where a Windows install would go")
    }
}
