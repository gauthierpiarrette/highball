import Foundation
import CoreGraphics
import ImageIO

// The unified library (One Library, Phase 2): every playable thing across all bottles and
// sources as one flat, source-neutral list. The store is a badge and a filter, never a
// section; the bottle is a per-game property, never the navigation.

public enum LibrarySource: String, Sendable, Codable {
    case steam, epic, pin
}

/// A playable item in the unified library. Pure value: no Bottle, no GameDBEntry — the app
/// resolves `bottleName` to a Bottle at action time and joins the db at render time, which
/// keeps this type constructible (and the aggregator testable) without a filesystem.
public struct LibraryItem: Identifiable, Sendable, Hashable {
    public let source: LibrarySource
    /// Stable identity, also the persistence key in library.json — never change its shape:
    /// "steam:<appid>" | "epic:<app_name>" | "pin:<bottle>:<uuid>".
    public let id: String
    public let title: String
    /// Where it lives. nil only for an Epic title owned but not installed in any bottle.
    public let bottleName: String?
    public let installed: Bool
    public let steamAppID: Int?
    public let epicAppName: String?
    public let pinID: UUID?
    public let artworkTall: URL?
    public let artworkWide: URL?
    /// Dedup leftovers: other bottles holding the same Steam game (detail view only).
    public let otherBottles: [String]
    public let sizeOnDisk: Int64
    public let lastPlayed: Date?

    public init(source: LibrarySource, id: String, title: String, bottleName: String?,
                installed: Bool, steamAppID: Int? = nil, epicAppName: String? = nil,
                pinID: UUID? = nil, artworkTall: URL? = nil, artworkWide: URL? = nil,
                otherBottles: [String] = [], sizeOnDisk: Int64 = 0, lastPlayed: Date? = nil) {
        self.source = source; self.id = id; self.title = title; self.bottleName = bottleName
        self.installed = installed; self.steamAppID = steamAppID; self.epicAppName = epicAppName
        self.pinID = pinID; self.artworkTall = artworkTall; self.artworkWide = artworkWide
        self.otherBottles = otherBottles; self.sizeOnDisk = sizeOnDisk; self.lastPlayed = lastPlayed
    }
}

public enum LibraryIndex {
    /// Launcher pins are infrastructure, not games — they never appear in the library, and
    /// launching one is not "playing" for the Continue shelf. Single source of truth for the
    /// filter BottleView's Programs section shares.
    public static func isLauncherPin(_ pin: Pin) -> Bool {
        let launcherNames = ["steam", "epic games", "battle.net", "gog galaxy", "ea app",
                             "ubisoft connect", "rockstar launcher", "rockstar"]
        return launcherNames.contains(pin.name.lowercased())
    }

    /// Builds the unified item list. Pure: takes exactly what AppState already holds.
    /// Steam games dedup by appid across bottles — one tile per game, never per install;
    /// the primary bottle is where it was last played, then a ready copy, then name order.
    public static func build(bottles: [Bottle],
                             steamByBottle: [String: [SteamGame]],
                             epicOwned: [EpicStore.Game],
                             epicInstalls: [String: String],
                             plays: [String: LibraryStore.PlayRecord] = [:]) -> [LibraryItem] {
        var items: [LibraryItem] = []

        // Steam: group by appid, pick a primary copy, remember the others.
        var byAppID: [Int: [(bottle: String, game: SteamGame)]] = [:]
        for bottle in bottles {
            for game in steamByBottle[bottle.name] ?? [] {
                byAppID[game.appid, default: []].append((bottle.name, game))
            }
        }
        for (appid, copies) in byAppID {
            let id = "steam:\(appid)"
            let lastPlayedBottle = plays[id]?.bottle
            let primary = copies.min { a, b in
                if let lp = lastPlayedBottle, (a.bottle == lp) != (b.bottle == lp) { return a.bottle == lp }
                if a.game.isReady != b.game.isReady { return a.game.isReady }
                return a.bottle.localizedCaseInsensitiveCompare(b.bottle) == .orderedAscending
            }!
            let acfPlayed = copies.compactMap(\.game.lastPlayed).max()
            let recorded = plays[id]?.lastPlayedAt
            items.append(LibraryItem(
                source: .steam, id: id, title: primary.game.name, bottleName: primary.bottle,
                installed: primary.game.isReady, steamAppID: appid,
                artworkTall: primary.game.capsuleImage, artworkWide: primary.game.headerImage,
                otherBottles: copies.map(\.bottle).filter { $0 != primary.bottle }.sorted(),
                sizeOnDisk: primary.game.sizeOnDisk,
                lastPlayed: [acfPlayed, recorded].compactMap { $0 }.max()))
        }

        // Epic: legendary installs one copy; the owning bottle is whichever drive_c
        // prefixes the install path (see EpicStore.isInstalled).
        for game in epicOwned {
            let id = "epic:\(game.app_name)"
            let home = epicInstalls[game.app_name].flatMap { path in
                bottles.first { EpicStore.isInstalled(path: path, inDriveC: $0.driveC) }?.name
            }
            items.append(LibraryItem(
                source: .epic, id: id, title: game.app_title, bottleName: home,
                installed: home != nil, epicAppName: game.app_name,
                artworkTall: game.artworkTall, artworkWide: game.artworkWide,
                lastPlayed: plays[id]?.lastPlayedAt))
        }

        // Custom pins (dropped exes, preinstalled games) — always installed, no artwork.
        for bottle in bottles {
            for pin in bottle.settings.pins where !isLauncherPin(pin) {
                let id = "pin:\(bottle.name):\(pin.id.uuidString)"
                items.append(LibraryItem(
                    source: .pin, id: id, title: pin.name, bottleName: bottle.name,
                    installed: true, pinID: pin.id,
                    lastPlayed: plays[id]?.lastPlayedAt))
            }
        }

        return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

/// Last-played persistence for the Continue shelf. Lives in its own library.json at the
/// Highball home — NOT in bottle.json: an Epic item's bottle is derived, dedup makes the
/// timestamp belong to the game identity, and a duplicated bottle must not duplicate play
/// history. Steam items additionally seed from the ACF's own LastPlayed, so the shelf is
/// meaningful on first run and stays right when Steam launches games without us.
public struct LibraryStore: Sendable {
    public struct PlayRecord: Codable, Sendable, Equatable {
        public var lastPlayedAt: Date
        public var bottle: String?
        public init(lastPlayedAt: Date, bottle: String?) {
            self.lastPlayedAt = lastPlayedAt; self.bottle = bottle
        }
    }
    private struct FileShape: Codable {
        var formatVersion: Int = 1
        var items: [String: PlayRecord] = [:]
    }

    public let paths: HighballPaths
    public init(paths: HighballPaths = HighballPaths()) { self.paths = paths }

    var fileURL: URL { paths.home.appending(path: "library.json") }

    /// Tolerant load: missing or corrupt file is an empty history, never an error.
    public func load() -> [String: PlayRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let shape = try? JSONDecoder.highball.decode(FileShape.self, from: data) else { return [:] }
        return shape.items
    }

    public func recordPlay(id: String, bottle: String?, date: Date = Date()) {
        var shape = FileShape(items: load())
        shape.items[id] = PlayRecord(lastPlayedAt: date, bottle: bottle)
        try? paths.ensure()
        if let data = try? JSONEncoder.highball.encode(shape) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Drops records whose items no longer exist (uninstalled games, deleted pins).
    public func prune(validIDs: Set<String>) {
        let current = load()
        let kept = current.filter { validIDs.contains($0.key) }
        guard kept.count != current.count else { return }
        let shape = FileShape(items: kept)
        if let data = try? JSONEncoder.highball.encode(shape) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// User-chosen cover art (Phase 3): a local image per library item, overriding the store's
/// artwork. Pure files under covers/ at the Highball home — no API, no keys; the automatic
/// pipeline (SteamGridDB) stays a deliberate non-feature until its ToS/key story is decided.
public struct CoverStore: Sendable {
    public let paths: HighballPaths
    public init(paths: HighballPaths = HighballPaths()) { self.paths = paths }

    var dir: URL { paths.home.appending(path: "covers", directoryHint: .isDirectory) }

    /// Item ids contain ':'; filenames must not. Deterministic and collision-safe for our
    /// id shapes (bottle names already reject path characters — issue #12).
    static func filename(for id: String) -> String {
        id.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
    }

    /// The stored override for an item, if any.
    public func coverURL(for id: String) -> URL? {
        let base = dir.appending(path: Self.filename(for: id))
        for ext in ["png", "jpg", "jpeg", "heic", "webp"] {
            let url = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Copies the chosen image in (replacing any previous override).
    /// The tile's aspect and the stored cover's cap. Covers are normalized at import: centre-
    /// cropped to 2:3, capped at `maxHeight` pixels tall, written as PNG, orientation applied.
    /// The crop belongs here and not to a layout: a macOS 27 beta drew nothing for a tile image
    /// of any other aspect (#64), and a 20 MB photo should not travel the library as a texture.
    public static let aspect: Double = 2.0 / 3.0
    public static let maxHeight = 900

    public func setCover(for id: String, from source: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = try Self.normalized(imageAt: source)
        clearCover(for: id)
        let dest = dir.appending(path: Self.filename(for: id)).appendingPathExtension("png")
        try png.write(to: dest, options: .atomic)
    }

    /// The stored form of an image file: 2:3, capped, PNG. Refuses what ImageIO cannot read.
    public static func normalized(imageAt url: URL) throws -> Data {
        // A thumbnail request applies the EXIF orientation and pre-shrinks a huge photo before
        // any pixel is touched; the max size keeps the crop below at full quality for covers.
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else {
            throw HighballError.invalid("\(url.lastPathComponent) is not an image Highball can read. Choose a PNG, JPEG or HEIC file.")
        }
        return try normalized(image)
    }

    static func normalized(_ image: CGImage) throws -> Data {
        let w = image.width, h = image.height
        var cropW = w, cropH = h
        if Double(w) / Double(h) > aspect { cropW = max(1, Int((Double(h) * aspect).rounded())) }
        else { cropH = max(1, Int((Double(w) / aspect).rounded())) }
        let rect = CGRect(x: (w - cropW) / 2, y: (h - cropH) / 2, width: cropW, height: cropH)
        guard let cropped = image.cropping(to: rect) else { throw HighballError.invalid("could not crop the cover") }
        let scale = min(1, Double(maxHeight) / Double(cropped.height))
        let outW = max(1, Int((Double(cropped.width) * scale).rounded()))
        let outH = max(1, Int((Double(cropped.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw HighballError.invalid("could not prepare the cover")
        }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        let data = NSMutableData()
        guard let out = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw HighballError.invalid("could not encode the cover")
        }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { throw HighballError.invalid("could not encode the cover") }
        return data as Data
    }

    public func clearCover(for id: String) {
        guard let existing = coverURL(for: id) else { return }
        try? FileManager.default.removeItem(at: existing)
    }
}
