import Foundation
import SQLite3

/// Achievements unlocked while a GOG game runs, for the pop-up. comet logs each unlock
/// ("Unlocking achievement KEY, Name") and keeps the game's achievement list, with each one's
/// description, badge and rarity, in its own database under its home; both are read here, nothing
/// is fetched from gog.com but the badge image.
public struct GOGAchievement: Sendable, Equatable {
    public let key: String
    public let name: String
    public var description = ""
    public var imageURL: URL?
    /// Share of players who have it, in percent; 0 when comet has no figure.
    public var rarity: Double = 0
    /// GOG's word for that share ("Common", "Uncommon", "Rare", "Epic", "Legendary").
    public var rarityLevel = ""

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

public enum GOGAchievements {
    /// The unlocks in a stretch of comet's log, in order, as (key, name). A name may hold commas;
    /// a key never does.
    public static func unlocks(in text: String) -> [(key: String, name: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let match = line.firstMatch(of: #/Unlocking achievement ([^\s,]+), (.*)$/#) else { return nil }
            return (String(match.1), String(match.2).trimmingCharacters(in: .whitespaces))
        }
    }

    /// comet's database for a game: gameplay/<client id>/<user id>/gameplay.db under its home.
    /// The newest when more than one account has played it here.
    public static func database(home: URL, clientID: String) -> URL? {
        let dir = home.appending(path: "Library/Application Support/comet/gameplay/\(clientID)", directoryHint: .isDirectory)
        let users = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return users.map { $0.appending(path: "gameplay.db") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .max { modified($0) < modified($1) }
    }

    private static func modified(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }

    /// The unlocked achievement as comet knows it, or only its key and logged name when the
    /// database cannot say. Opened read-only: comet keeps writing to it.
    public static func details(key: String, name: String, database: URL?) -> GOGAchievement {
        var achievement = GOGAchievement(key: key, name: name)
        guard let database else { return achievement }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return achievement }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT name, description, image_url_unlocked, rarity, rarity_level_description FROM achievement WHERE key = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return achievement }
        // SQLITE_TRANSIENT: SQLite copies the key before this call returns.
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return achievement }
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        if !text(0).isEmpty { achievement = GOGAchievement(key: key, name: text(0)) }
        achievement.description = text(1)
        achievement.imageURL = URL(string: text(2)).flatMap { $0.scheme == "https" ? $0 : nil }
        achievement.rarity = sqlite3_column_double(statement, 3)
        achievement.rarityLevel = text(4)
        return achievement
    }

    /// Reads comet's log as it grows: each call returns the unlocks written since the last.
    /// Only whole lines are taken, so a line comet is halfway through writing waits for the next call.
    public final class LogReader: @unchecked Sendable {
        let log: URL
        private var offset: UInt64 = 0

        public init(log: URL) { self.log = log }

        public func newUnlocks() -> [(key: String, name: String)] {
            guard let handle = try? FileHandle(forReadingFrom: log) else { return [] }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(),
                  let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
            let whole = data[data.startIndex...lastNewline]
            offset += UInt64(whole.count)
            return GOGAchievements.unlocks(in: String(decoding: whole, as: UTF8.self))
        }
    }
}
