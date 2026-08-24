import Foundation

/// A game installed by the Windows Steam client inside a bottle, read from
/// `steamapps/appmanifest_<appid>.acf`.
public struct SteamGame: Identifiable, Sendable, Hashable {
    public let appid: Int
    public let name: String
    public let installdir: String
    public let sizeOnDisk: Int64
    public let stateFlags: Int

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
        return SteamGame(
            appid: appid,
            name: name,
            installdir: fields["installdir"] ?? "",
            sizeOnDisk: Int64(fields["SizeOnDisk"] ?? "") ?? 0,
            stateFlags: Int(fields["StateFlags"] ?? "") ?? 0
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
    public var status: String       // verified-local | reported-upstream | community | blocked-anticheat
    public var renderer: Renderer?
    public var provenance: String?
    public var notes: String?
    public var anticheat: AnticheatInfo?

    public var isBlocked: Bool { status == "blocked-anticheat" }
}

public struct GameDB: Sendable {
    public let byAppID: [Int: GameDBEntry]

    /// Default lookup locations for a CLI/dev context: a sibling highball-db checkout, or ./db/games.
    public static func defaultDirectories() -> [URL] {
        ["../highball-db/db/games", "db/games"].map { URL(fileURLWithPath: $0) }
    }

    public init(directories: [URL]) {
        var index: [Int: GameDBEntry] = [:]
        for dir in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let entry = try? JSONDecoder().decode(GameDBEntry.self, from: data),
                      let appid = entry.steam_appid else { continue }
                index[appid] = entry
            }
        }
        byAppID = index
    }

    public subscript(appid: Int) -> GameDBEntry? { byAppID[appid] }
}
