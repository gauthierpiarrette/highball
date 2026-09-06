import XCTest
import CoreGraphics
import ImageIO
@testable import HighballKit

/// The unified library's data layer (One Library Phase 2): aggregation, dedup, per-bottle
/// Epic resolution, launcher-pin filtering, and last-played persistence.
final class LibraryTests: XCTestCase {
    private func bottle(_ name: String) -> Bottle {
        Bottle(url: URL(fileURLWithPath: "/tmp/hb-lib-tests/bottles/\(name)"),
               settings: BottleSettings(name: name, engineID: "e"))
    }
    private func steam(_ appid: Int, _ name: String, ready: Bool = true, played: Date? = nil) -> SteamGame {
        SteamGame(appid: appid, name: name, installdir: name, sizeOnDisk: 1,
                  stateFlags: ready ? 4 : 2, lastPlayed: played)
    }

    func testAggregationAcrossSourcesAndBottles() {
        var a = bottle("a"); let b = bottle("b")
        a.settings.pins = [Pin(name: "Steam", path: "s/steam.exe"),          // launcher: excluded
                           Pin(name: "MyGame", path: "Games/my.exe")]        // custom: included
        let items = LibraryIndex.build(
            bottles: [a, b],
            steamByBottle: ["a": [steam(620, "Portal 2")], "b": [steam(730, "CS2")]],
            epicOwned: [EpicStore.Game(app_name: "Duck", app_title: "Cardpocalypse")],
            epicInstalls: [:])
        XCTAssertEqual(items.count, 4, "2 steam + 1 epic + 1 custom pin (launcher pin excluded)")
        XCTAssertEqual(items.map(\.id).sorted(),
                       ["epic:Duck", "pin:a:\(a.settings.pins[1].id.uuidString)", "steam:620", "steam:730"].sorted())
        XCTAssertTrue(items.first { $0.id == "epic:Duck" }!.installed == false)
    }

    func testSteamDedupPrimarySelection() {
        let a = bottle("a"), b = bottle("b"), c = bottle("c")
        let both = ["a": [steam(620, "Portal 2", ready: false)],
                    "b": [steam(620, "Portal 2", ready: true)],
                    "c": [steam(620, "Portal 2", ready: true)]]
        // No play history: a ready copy wins, name order tiebreaks (b before c).
        var items = LibraryIndex.build(bottles: [a, b, c], steamByBottle: both,
                                       epicOwned: [], epicInstalls: [:])
        XCTAssertEqual(items.count, 1, "one tile per game, never per install")
        XCTAssertEqual(items[0].bottleName, "b")
        XCTAssertEqual(items[0].otherBottles, ["a", "c"])
        // Play history wins over readiness order.
        items = LibraryIndex.build(bottles: [a, b, c], steamByBottle: both,
                                   epicOwned: [], epicInstalls: [:],
                                   plays: ["steam:620": .init(lastPlayedAt: Date(), bottle: "c")])
        XCTAssertEqual(items[0].bottleName, "c", "last-played bottle is the primary")
    }

    func testEpicBottleResolutionByInstallPath() {
        let a = bottle("a"), b = bottle("b")
        let game = EpicStore.Game(app_name: "Duck", app_title: "Cardpocalypse")
        let inA = LibraryIndex.build(bottles: [a, b], steamByBottle: [:], epicOwned: [game],
                                     epicInstalls: ["Duck": a.driveC.appending(path: "Games/Cardpocalypse").path])
        XCTAssertEqual(inA[0].bottleName, "a")
        XCTAssertTrue(inA[0].installed)
        let orphan = LibraryIndex.build(bottles: [a, b], steamByBottle: [:], epicOwned: [game],
                                        epicInstalls: ["Duck": "/tmp/somewhere/else"])
        XCTAssertNil(orphan[0].bottleName, "an install outside every bottle is not installed here")
        XCTAssertFalse(orphan[0].installed)
    }

    func testLauncherPinFilter() {
        XCTAssertTrue(LibraryIndex.isLauncherPin(Pin(name: "Steam", path: "x")))
        XCTAssertTrue(LibraryIndex.isLauncherPin(Pin(name: "Battle.net", path: "x")))
        XCTAssertFalse(LibraryIndex.isLauncherPin(Pin(name: "MyGame", path: "x")))
    }

    func testLibraryStoreRoundTripAndPrune() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "hb-lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = LibraryStore(paths: HighballPaths(home: tmp))
        XCTAssertEqual(store.load(), [:], "missing file is an empty history")
        store.recordPlay(id: "steam:620", bottle: "a", date: Date(timeIntervalSince1970: 1000))
        store.recordPlay(id: "epic:Duck", bottle: "b", date: Date(timeIntervalSince1970: 2000))
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded["steam:620"]?.bottle, "a")
        store.prune(validIDs: ["epic:Duck"])
        XCTAssertEqual(store.load().keys.sorted(), ["epic:Duck"])
        // Corrupt file tolerated.
        try Data("not json".utf8).write(to: tmp.appending(path: "library.json"))
        XCTAssertEqual(store.load(), [:])
    }

    /// A real image file of the given size, for the cover tests.
    private func makeImage(width: Int, height: Int, at url: URL, type: String = "public.png") throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func size(of url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// Covers are stored cropped to the tile's 2:3 and capped, as PNG, whatever came in (#64: a
    /// macOS 27 beta drew nothing for a tile image of any other aspect, and the crop belongs
    /// to the store, not to a layout). An unreadable file is refused, never stored.
    func testCoverStoreRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "hb-cover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = CoverStore(paths: HighballPaths(home: tmp))
        XCTAssertNil(store.coverURL(for: "steam:620"))

        let wide = tmp.appending(path: "wide.png"); try makeImage(width: 300, height: 100, at: wide)
        try store.setCover(for: "steam:620", from: wide)
        let stored = try XCTUnwrap(store.coverURL(for: "steam:620"))
        XCTAssertEqual(stored.lastPathComponent, "steam_620.png", "id colon sanitized, always PNG")
        let (w, h) = try XCTUnwrap(size(of: stored))
        XCTAssertEqual(h, 100, "never upscaled")
        XCTAssertEqual(Double(w) / Double(h), 2.0 / 3.0, accuracy: 0.02, "centre-cropped to 2:3")

        let huge = tmp.appending(path: "huge.jpg"); try makeImage(width: 3000, height: 4500, at: huge, type: "public.jpeg")
        try store.setCover(for: "steam:620", from: huge)
        XCTAssertEqual(store.coverURL(for: "steam:620")?.pathExtension, "png", "a JPEG source is stored as PNG and replaces the old file")
        XCTAssertEqual(try XCTUnwrap(size(of: store.coverURL(for: "steam:620")!)).1, CoverStore.maxHeight, "capped in height")

        let exact = tmp.appending(path: "exact.png"); try makeImage(width: 100, height: 150, at: exact)
        try store.setCover(for: "steam:620", from: exact)
        XCTAssertEqual(try XCTUnwrap(size(of: store.coverURL(for: "steam:620")!)).0, 100, "an exact 2:3 image keeps its size")

        let junk = tmp.appending(path: "junk.png"); try Data([0x89, 0x50, 0x4E, 0x47]).write(to: junk)
        XCTAssertThrowsError(try store.setCover(for: "steam:620", from: junk), "four bytes are not a cover")
        XCTAssertNotNil(store.coverURL(for: "steam:620"), "a refused file leaves the previous cover in place")

        store.clearCover(for: "steam:620")
        XCTAssertNil(store.coverURL(for: "steam:620"))
    }

    func testACFLastPlayedSeedsShelf() {
        let acf = """
        "AppState" { "appid" "620" "name" "Portal 2" "StateFlags" "4" "LastPlayed" "1756300000" }
        """
        let tmp = FileManager.default.temporaryDirectory.appending(path: "hb-acf-\(UUID().uuidString).acf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? Data(acf.utf8).write(to: tmp)
        let game = SteamLibrary.parseManifest(tmp)
        XCTAssertEqual(game?.lastPlayed, Date(timeIntervalSince1970: 1756300000))
        // LastPlayed 0 (never played) must stay nil.
        try? Data(acf.replacingOccurrences(of: "1756300000", with: "0").utf8).write(to: tmp)
        XCTAssertNil(SteamLibrary.parseManifest(tmp)?.lastPlayed)
    }
}
