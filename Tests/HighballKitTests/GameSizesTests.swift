import XCTest
@testable import HighballKit

/// How much room a game takes: the store's estimate before an install, the folders after.
final class GameSizesTests: XCTestCase {
    func testFolderSizeCountsFilesAndNotLinks() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appending(path: "sub"), withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: dir.appending(path: "a.bin"))
        try Data(count: 50_000).write(to: dir.appending(path: "sub/b.bin"))
        let outside = FileManager.default.temporaryDirectory.appending(path: "big-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(count: 500_000).write(to: outside.appending(path: "c.bin"))
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "Documents"), withDestinationURL: outside)

        let size = try XCTUnwrap(DiskUsage.bytes(at: dir))
        XCTAssertGreaterThanOrEqual(size, 60_000)
        XCTAssertLessThan(size, 500_000, "a linked folder is not the game's")
        XCTAssertNil(DiskUsage.bytes(at: dir.appending(path: "missing")))
        XCTAssertNil(DiskUsage.bytes(at: [dir.appending(path: "missing")]))
    }

    func testEpicEstimateComesFromLegendarysManifest() {
        let out = #"[cli] INFO: Getting game metadata... {"game": {}, "install": {}, "manifest": {"disk_size": 356045656, "download_size": 257001326}}"#
        XCTAssertEqual(EpicStore.parseEstimate(Data(out.utf8)), DownloadEstimate(download: 257001326, disk: 356045656))
        XCTAssertNil(EpicStore.parseEstimate(Data("no json".utf8)))
    }

    func testEpicInstallRecordKeepsSizeAndSaveFolder() throws {
        let json = #"[{"app_name":"Garlic","install_path":"/x","install_size":356045656,"save_path":"/s"},{"app_name":"Old","install_path":"/y"}]"#
        let games = try JSONDecoder().decode([EpicStore.InstalledGame].self, from: Data(json.utf8))
        XCTAssertEqual(games.map(\.install_size), [356045656, nil])
        XCTAssertEqual(games.map(\.save_path), ["/s", nil])
    }

    func testSteamCloudSavesAreEachAccountsFolderForTheGame() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "steam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for account in ["1001", "1002"] {
            try FileManager.default.createDirectory(at: root.appending(path: "userdata/\(account)/7/remote"), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: root.appending(path: "userdata/1003/8"), withIntermediateDirectories: true)
        XCTAssertEqual(SteamLibrary.cloudSaveFolders(steamRoot: root, appID: 7).map { $0.deletingLastPathComponent().lastPathComponent }.sorted(),
                       ["1001", "1002"])
    }
}

/// A Steam download's size from the client's own data: the depots the purchases here bring.
final class SteamDownloadSizeTests: XCTestCase {
    typealias Depot = SteamAppInfo.App.Depot

    /// Little Nightmares III as Steam lists it: two editions' depots of about 15 GB each, and
    /// the purchases on the Mac bring one (1392863), the one that was installed.
    func testOnlyTheDepotsTheOwnedPurchasesBringCount() throws {
        var app = SteamAppInfo.App()
        app.depots = [Depot(id: 1392861, oslist: "windows", size: 14_660_122_449, download: 13_911_985_088),
                      Depot(id: 1392862, oslist: "windows", size: 1_050_249_020, download: 179_410_784),
                      Depot(id: 1392863, size: 16_913_105_339, download: 15_980_071_584),
                      Depot(id: 1392864, size: 1_079_728_799, download: 248_374_704)]
        let packages = [SteamPackageInfo.Package(id: 1096901, appIDs: [1392860], depotIDs: [1392863]),
                        SteamPackageInfo.Package(id: 1345312, appIDs: [1392860, 2088780], depotIDs: [1392863])]
        let estimate = try XCTUnwrap(SteamDownloadSize.estimate(appID: 1392860, app: app, packages: packages, mac: false))
        XCTAssertEqual(estimate.disk, 16_913_105_339)
        XCTAssertEqual(estimate.download, 15_980_071_584)
        XCTAssertNil(SteamDownloadSize.estimate(appID: 1392860, app: app, packages: [], mac: false), "owned by no account here")
    }

    func testPlatformLanguageRegionAndDLCDecide() throws {
        var app = SteamAppInfo.App()
        app.depots = [Depot(id: 1, oslist: "windows", size: 100, download: 50),
                      Depot(id: 2, oslist: "macos", size: 80, download: 40),
                      Depot(id: 3, language: "french", size: 10, download: 5),
                      Depot(id: 4, language: "english", size: 7, download: 3),
                      Depot(id: 5, restricted: true, size: 1000, download: 900),
                      Depot(id: 6, dlcAppID: 99, size: 20, download: 10),
                      Depot(id: 7, dlcAppID: 98, size: 30, download: 15)]
        let packages = [SteamPackageInfo.Package(id: 1, appIDs: [10, 99], depotIDs: [1, 2, 3, 4, 5])]
        XCTAssertEqual(SteamDownloadSize.estimate(appID: 10, app: app, packages: packages, mac: false),
                       DownloadEstimate(download: 63, disk: 127), "Windows, English, the owned DLC, no restricted depot")
        XCTAssertEqual(SteamDownloadSize.estimate(appID: 10, app: app, packages: packages, mac: true),
                       DownloadEstimate(download: 53, disk: 107))
    }
}

/// Steam's binary formats as the size estimate reads them, built byte by byte: KeyValues objects
/// with inline keys (type, name, value; 0x08 ends an object), little-endian integers.
private enum SteamBinary {
    static func u32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
    static func cString(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }
    indirect enum Value { case string(String), int(Int32), object([(String, Value)]) }
    static func object(_ entries: [(String, Value)]) -> [UInt8] {
        entries.flatMap { key, value -> [UInt8] in
            switch value {
            case .string(let s): return [0x01] + cString(key) + cString(s)
            case .int(let i): return [0x02] + cString(key) + u32(UInt32(bitPattern: i))
            case .object(let o): return [0x00] + cString(key) + object(o)
            }
        } + [0x08]
    }
}

final class SteamBinaryParsingTests: XCTestCase {
    /// packageinfo.vdf v40: magic, universe, then per package its id, SHA-1, change number and
    /// token before the object; 0xFFFFFFFF ends it.
    private func packageInfo(_ packages: [(Int, [Int], [Int])], damagedAfter: Int? = nil) -> Data {
        var bytes = SteamBinary.u32(0x0656_5528) + SteamBinary.u32(1)
        for (n, (id, apps, depots)) in packages.enumerated() {
            if n == damagedAfter { bytes += SteamBinary.u32(UInt32(id)) + [UInt8](repeating: 0, count: 32) + [0x09]; break }
            let body: [(String, SteamBinary.Value)] = [
                ("packageid", .int(Int32(id))),
                ("appids", .object(apps.enumerated().map { (String($0.offset), .int(Int32($0.element))) })),
                ("depotids", .object(depots.enumerated().map { (String($0.offset), .int(Int32($0.element))) }))]
            bytes += SteamBinary.u32(UInt32(id)) + [UInt8](repeating: 0, count: 20 + 4 + 8) + SteamBinary.object([(String(id), .object(body))])
        }
        if damagedAfter == nil { bytes += SteamBinary.u32(0xFFFF_FFFF) }
        return Data(bytes)
    }

    func testPackagesAreReadWithTheirAppsAndDepots() {
        let packages = SteamPackageInfo.parse(packageInfo([(1096901, [1392860], [1392863]), (7, [10, 99], [11])]))
        XCTAssertEqual(packages.map(\.id), [1096901, 7])
        XCTAssertEqual(packages.first?.appIDs, [1392860])
        XCTAssertEqual(packages.last?.depotIDs, [11])
    }

    /// One damaged entry keeps what came before it, rather than hiding every purchase.
    func testADamagedPackageKeepsTheOnesBeforeIt() {
        XCTAssertEqual(SteamPackageInfo.parse(packageInfo([(1, [10], [11]), (2, [20], [21])], damagedAfter: 1)).map(\.id), [1])
        XCTAssertEqual(SteamPackageInfo.parse(Data([0, 1, 2, 3])), [], "an unknown version reads as none")
    }

    /// appinfo.vdf v28's depots: shared redistributables left out, restrictions and sizes read.
    func testDepotsComeWithTheirSystemLanguageRestrictionAndSize() throws {
        let depots: [(String, SteamBinary.Value)] = [
            ("11", .object([("config", .object([("oslist", .string("windows")), ("language", .string("french"))])),
                            ("manifests", .object([("public", .object([("size", .string("1000")), ("download", .string("400"))]))]))])),
            ("12", .object([("config", .object([("lowviolence", .string("1"))]))])),
            ("13", .object([("dlcappid", .string("99")), ("manifests", .object([("public", .object([("size", .string("50"))]))]))])),
            ("228988", .object([("sharedinstall", .string("1")), ("depotfromapp", .string("228980"))])),
            ("branches", .object([("public", .object([("buildid", .string("1"))]))]))]
        let kv = SteamBinary.object([("appinfo", .object([("common", .object([("name", .string("Game")), ("type", .string("Game"))])),
                                                          ("ufs", .object([("quota", .int(104_857_600))])),
                                                          ("depots", .object(depots))]))])
        let entry = SteamBinary.u32(10) + SteamBinary.u32(UInt32(60 + kv.count)) + [UInt8](repeating: 0, count: 60) + kv
        let data = Data(SteamBinary.u32(0x0756_4428) + SteamBinary.u32(1) + entry + SteamBinary.u32(0))
        let app = try XCTUnwrap(try SteamAppInfo.parse(data)[10])
        XCTAssertEqual(app.depots.map(\.id), [11, 12, 13], "the shared redistributable is not the game's")
        XCTAssertEqual(app.depots[0], SteamAppInfo.App.Depot(id: 11, oslist: "windows", language: "french", size: 1000, download: 400))
        XCTAssertTrue(app.depots[1].restricted)
        XCTAssertEqual(app.depots[2].dlcAppID, 99)
        XCTAssertEqual(app.steamCloudQuota, 104_857_600, "Steam Cloud keeps its saves")
    }

    /// A DLC bought on its own is a package without the base game; its depots still count.
    func testADLCBoughtSeparatelyCounts() {
        var app = SteamAppInfo.App()
        app.depots = [.init(id: 1, size: 100, download: 50), .init(id: 2, dlcAppID: 99, size: 20, download: 10)]
        let packages = [SteamPackageInfo.Package(id: 1, appIDs: [10], depotIDs: [1]),
                        SteamPackageInfo.Package(id: 2, appIDs: [99], depotIDs: [2])]
        XCTAssertEqual(SteamDownloadSize.estimate(appID: 10, app: app, packages: packages, mac: false), DownloadEstimate(download: 60, disk: 120))
    }
}
