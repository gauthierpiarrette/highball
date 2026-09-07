import Foundation

/// A game installed by the Windows Steam client inside a bottle, read from
/// `steamapps/appmanifest_<appid>.acf`.
public struct SteamGame: Identifiable, Sendable, Hashable {
    public let appid: Int
    public let name: String
    public let installdir: String
    public let sizeOnDisk: Int64
    public let stateFlags: Int
    /// Steam's own LastPlayed from the ACF (unix seconds; 0 = never). Seeds the library's
    /// Continue shelf so it works on first run and tracks plays Steam started without us.
    public let lastPlayed: Date?

    public var id: Int { appid }
    /// StateFlags 4 = fully installed; anything else is updating/downloading/broken.
    public var isReady: Bool { stateFlags == 4 }

    /// Steam CDN artwork (no key needed).
    public var headerImage: URL { URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(appid)/header.jpg")! }
    public var capsuleImage: URL { URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(appid)/library_600x900.jpg")! }
}

public enum SteamLibrary {
    /// Path of the Windows Steam install inside a bottle, if present.
    public static func steamRoot(of bottle: Bottle) -> URL? {
        let root = bottle.driveC.appending(path: "Program Files (x86)/Steam")
        return FileManager.default.fileExists(atPath: root.appending(path: "steam.exe").path) ? root : nil
    }

    /// All games known to the bottle's Steam library folders.
    public static func games(in bottle: Bottle) -> [SteamGame] {
        guard let root = steamRoot(of: bottle) else { return [] }
        let steamapps = root.appending(path: "steamapps")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf" }
            .compactMap { parseManifest($0) }
            .filter { $0.appid != 228980 } // Steamworks Common Redistributables — not a game
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Minimal ACF (Valve KeyValues) reader: flat `"key" "value"` pairs are all we need.
    static func parseManifest(_ url: URL) -> SteamGame? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        let pattern = #/"([A-Za-z]+)"\s+"([^"]*)"/#
        for match in text.matches(of: pattern) where fields[String(match.1)] == nil {
            fields[String(match.1)] = String(match.2)
        }
        guard let appidText = fields["appid"], let appid = Int(appidText), let name = fields["name"] else { return nil }
        let played = TimeInterval(fields["LastPlayed"] ?? "") ?? 0
        return SteamGame(
            appid: appid,
            name: name,
            installdir: fields["installdir"] ?? "",
            sizeOnDisk: Int64(fields["SizeOnDisk"] ?? "") ?? 0,
            stateFlags: Int(fields["StateFlags"] ?? "") ?? 0,
            lastPlayed: played > 0 ? Date(timeIntervalSince1970: played) : nil
        )
    }
}

// MARK: - Compatibility database (db/games entries from highball-db)

/// One entry of the open compatibility database, as published in highball-db `db/games/*.json`.
public struct GameDBEntry: Codable, Sendable {
    public struct AnticheatInfo: Codable, Sendable {
        public var names: [String]
        public var macVerdict: String?
        public var note: String?
    }
    public var id: String
    public var title: String
    public var steam_appid: Int?
    /// Legendary's app name for the Epic copy (#63: an Epic copy of a row's game matched nothing,
    /// so Play never asked for D3DMetal and DXMT refused the DirectX 12 game).
    public var epic_app_name: String?
    public var status: String       // verified-local | reported-upstream | community | blocked-anticheat
    public var renderer: Renderer?
    public var provenance: String?
    public var notes: String?
    public var anticheat: AnticheatInfo?
    /// The date of the last local verification, "YYYY-MM-DD".
    public var lastVerified: String?
    /// Extra arguments appended to the game's launch (Steam forwards -applaunch trailing args
    /// to the game). Data, not code: game-specific knowledge stays in the db (issue #21's
    /// windowed workaround for legacy CS:GO's macOS 26 fullscreen freeze is the first user).
    public var launchArgs: [String]?
    /// Apply launchArgs only at or above this macOS version ("26.0"). A workaround for one OS
    /// must not change behaviour for users where the game already works (14.x fullscreen is
    /// fine); nil means the args apply everywhere.
    public var launchArgsMinMacOS: String?
    /// `renderer` applies at or above this macOS version ("15.0"); below it `rendererBelow`
    /// applies instead (nil there means the bottle's own setting). DXMT wants macOS 15 or newer
    /// and paints nothing on 14, so a verdict taken on a newer OS must not send an older Mac to
    /// a black screen. Data, not code: the row decides.
    public var rendererMinMacOS: String?
    public var rendererBelow: Renderer?
    /// The machine and build the verdict was taken on, for the game page's sentence: "Verified
    /// on an M1 Pro. About 70 frames per second on macOS 26.6.2". Free-text `provenance` stays
    /// for the site; this is the structured part the app can compare with the reader's Mac.
    public struct VerifiedOn: Codable, Sendable, Equatable {
        public var chip: String?       // "Apple M1 Pro"
        public var macos: String?      // "26.6.2"
        public var engine: String?     // engine id
        public var fps: String?        // "about 70", "60 to 82"; words, never a computed number
        public init(chip: String? = nil, macos: String? = nil, engine: String? = nil, fps: String? = nil) {
            self.chip = chip; self.macos = macos; self.engine = engine; self.fps = fps
        }
    }
    public var verified: VerifiedOn?
    /// Per-renderer outcomes ("works", "fails", ...) with a detail sentence, the data nobody
    /// else publishes; the game page shows them under "Why these settings?".
    public struct RendererResult: Codable, Sendable, Equatable {
        public var verdict: String
        public var detail: String?
    }
    public var rendererResults: [String: RendererResult]?

    public var isBlocked: Bool { status == "blocked-anticheat" }

    /// The renderer the row recommends on the given OS version, nil for "the bottle's own".
    public func effectiveRenderer(osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> Renderer? {
        guard let gate = rendererMinMacOS, let want = Int(gate.split(separator: ".").first ?? "") else { return renderer }
        return osMajor >= want ? renderer : rendererBelow
    }

    /// The launch args that apply on the given OS version. Pure for testability.
    public func effectiveLaunchArgs(osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> [String] {
        guard let args = launchArgs else { return [] }
        if let gate = launchArgsMinMacOS, let want = Int(gate.split(separator: ".").first ?? "") {
            guard osMajor >= want else { return [] }
        }
        return args
    }
}

public struct GameDB: Sendable {
    public let byAppID: [Int: GameDBEntry]
    /// Rows by Legendary app name, for Epic copies.
    public let byEpicAppName: [String: GameDBEntry]
    /// Rows by normalized title, the fallback for a copy from a store the row does not name.
    public let byTitle: [String: GameDBEntry]

    /// Default lookup locations for a CLI/dev context: a sibling highball-db checkout, or ./db/games.
    public static func defaultDirectories() -> [URL] {
        ["../highball-db/db/games", "db/games"].map { URL(fileURLWithPath: $0) }
    }

    public init(directories: [URL]) {
        var index: [Int: GameDBEntry] = [:], epic: [String: GameDBEntry] = [:], titles: [String: GameDBEntry] = [:]
        for dir in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let entry = try? JSONDecoder().decode(GameDBEntry.self, from: data) else { continue }
                if let appid = entry.steam_appid { index[appid] = entry }
                if let name = entry.epic_app_name { epic[name] = entry }
                let key = Self.normalizedTitle(entry.title)
                if !key.isEmpty, titles[key] == nil { titles[key] = entry }
            }
        }
        byAppID = index; byEpicAppName = epic; byTitle = titles
    }

    public subscript(appid: Int) -> GameDBEntry? { byAppID[appid] }

    /// Lowercased letters, digits and single spaces, apostrophes dropped: "Marvel's Guardians of
    /// the Galaxy™" and "Marvels Guardians Of The Galaxy" are the same title. Exact after that,
    /// never fuzzy.
    public static func normalizedTitle(_ title: String) -> String {
        let apostrophes: Set<Unicode.Scalar> = ["'", "\u{2019}", "\u{2018}"]
        let kept = title.lowercased().unicodeScalars.compactMap { scalar -> Character? in
            if apostrophes.contains(scalar) { return nil }
            return CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// The row for a library item, whatever store it came from: the Steam id first, then the
    /// Epic app name, then the normalized title. Nil for a program the database does not know.
    public func entry(for item: LibraryItem) -> GameDBEntry? {
        if let appid = item.steamAppID, let e = byAppID[appid] { return e }
        if let name = item.epicAppName, let e = byEpicAppName[name] { return e }
        return byTitle[Self.normalizedTitle(item.title)]
    }
}
