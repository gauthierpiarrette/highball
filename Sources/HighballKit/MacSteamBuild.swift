import Foundation

/// A native macOS build of a game on Steam: the same purchase the player already made, which the
/// Mac Steam app installs and runs without Wine. Only Steam builds count; a native edition sold
/// elsewhere (Death Stranding's on the Mac App Store) is a different purchase and isn't marked.
///
/// Three sources, curated first:
/// - the database row's `nativeMac`, when its `where` names Steam; a row can also say
///   `"available": false` for a port that no longer runs;
/// - then Steam's own app data, the way Steam for Mac reads it (MacAppInfoBuild): a build marked
///   64-bit counts even when the store page leaves macOS out (LEGO Jurassic World, highball#310),
///   and a 32-bit one never counts, since macOS stopped running those with Catalina (Stacking,
///   highball#316, and Portal);
/// - otherwise the Steam store's `platforms.mac` for the appid, for a game whose app data isn't
///   in hand.
public enum MacSteamBuild: Equatable, Sendable {
    /// Steam for Mac has it installed (MacSteam): no need to ask anyone.
    case installed
    /// The database row says so (and may carry requirements in its note).
    case inDatabase
    /// Steam's app data marks a Mac build that runs on current macOS.
    case inAppInfo
    /// Steam's store page lists macOS.
    case onStore

    /// Pure. nil: no Mac build on Steam known, or the store hasn't been asked yet.
    public static func resolve(entry: GameDBEntry?, storeMac: Bool?, installedOnMac: Bool = false,
                               appInfo: MacAppInfoBuild? = nil) -> MacSteamBuild? {
        if installedOnMac { return .installed }
        if let native = entry?.nativeMac {
            guard native.available else { return nil }
            // A list ("Steam, Mac App Store, GOG, Epic" for Cyberpunk 2077) counts when Steam is in it.
            let stores = (native.where ?? "Steam").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if stores.contains("steam") { return .inDatabase }
        }
        switch appInfo {
        case .runnable?: return .inAppInfo
        case .only32Bit?: return nil
        case .absent?, nil: return storeMac == true ? .onStore : nil
        }
    }

    /// Whether Play starts the native build: Steam for Mac has it installed, and the row does not
    /// say the Mac build is the wrong one to play. The Binding of Isaac's Mac build stops at
    /// Afterbirth+, so a player who owns the Windows-only Repentance got the old game (highball#223);
    /// its row says `"available": false` and the Windows build leads, with the Mac one a click away.
    /// Without a row, a Mac build Steam's data says is 32-bit never leads: it can't run.
    public static func leads(entry: GameDBEntry?, installedOnMac: Bool, appInfo: MacAppInfoBuild? = nil) -> Bool {
        guard installedOnMac else { return false }
        if let available = entry?.nativeMac?.available { return available }
        return appInfo != .only32Bit
    }
}

/// A Mac build GOG's or Epic's catalog lists (LibraryItem.macListed), weighed the way MacSteamBuild
/// weighs Steam's: the database row first, so one saying `"available": false` (a Mac port that no
/// longer runs, or one missing content, highball#223) keeps the badge and the page on the Windows build.
public enum StoreMacBuild {
    /// Whether the store's listing counts.
    public static func listed(_ storeLists: Bool, entry: GameDBEntry?) -> Bool {
        storeLists && entry?.nativeMac?.available != false
    }
}

/// What Steam's app data says about a game's Mac build, read the way Steam for Mac reads it.
/// Steam marks a build that runs on current macOS with `macos64` or `macosapplesilicon` in
/// `common.osextended` (Cyberpunk 2077 and Lies of P carry only the second), and a macOS launch
/// entry can say `osarch` 64 on its own (LEGO Jurassic World, whose oslist names Windows only).
/// A Mac build with neither is 32-bit, the case where Steam for Mac says it is "unable to run
/// 32-bit games": Stacking, LEGO Marvel Super Heroes, Portal. Checked against Steam's data
/// through api.steamcmd.net for 15 titles on 2026-10-11.
public enum MacAppInfoBuild: Sendable, Hashable {
    /// No Mac build in the data.
    case absent
    /// A Mac build exists and is 32-bit only.
    case only32Bit
    /// A Mac build that runs on current macOS.
    case runnable

    /// `macLaunchArchs`: the `osarch` of each macOS launch entry, "" for one that names none.
    public init(oslist: String?, osextended: String?, macLaunchArchs: [String]) {
        let marks = (osextended ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if marks.contains("macos64") || marks.contains("macosapplesilicon") || macLaunchArchs.contains("64") {
            self = .runnable
        } else if (oslist ?? "").lowercased().contains("macos") || !macLaunchArchs.isEmpty {
            self = .only32Bit
        } else {
            self = .absent
        }
    }
}

/// The row field: `"nativeMac": {"available": true, "where": "Steam", "note": "…", "url": "…"}`.
public struct NativeMacInfo: Codable, Sendable, Equatable {
    public var available: Bool
    public var `where`: String?
    public var note: String?
    public var url: String?
}

/// Store `platforms.mac` flags, cached in `mac-flags.json` for two weeks. Only Steam games whose
/// appinfo lists macOS are asked about (worthAsking), using the shared full appdetails response: the store API takes one
/// appid per request and allows about 200 requests per five minutes. A failed or
/// refused request is "don't know", never "no Mac version". The shared appdetails client
/// remembers failures for a day and stops both consumers when Steam refuses requests.
public struct MacFlagStore: Sendable {
    public struct Record: Codable, Sendable, Equatable {
        public var mac: Bool
        public var checked: Date
    }

    public static let maxAge: TimeInterval = 14 * 24 * 3600
    public let file: URL

    public init(paths: HighballPaths = HighballPaths()) {
        file = paths.home.appending(path: "mac-flags.json")
    }

    public init(file: URL) { self.file = file }

    /// Tolerant load: missing or corrupt file is an empty cache.
    public func load(now: Date = Date()) -> [Int: Bool] {
        guard let data = try? Data(contentsOf: file),
              let records = try? JSONDecoder().decode([Int: Record].self, from: data) else { return [:] }
        return records.filter { now.timeIntervalSince($0.value.checked) < Self.maxAge }.mapValues(\.mac)
    }

    func save(_ flags: [Int: Bool], now: Date = Date()) {
        var records = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Int: Record].self, from: $0) } ?? [:]
        for (appid, mac) in flags { records[appid] = Record(mac: mac, checked: now) }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The Steam games to ask the store about: the ones whose appinfo lists macOS, and any the
    /// owned library can't speak for yet (an installed game before the client's cache has it).
    /// A game appinfo doesn't list for macOS has no Mac build on Steam, so a library of hundreds
    /// costs a handful of requests.
    public static func worthAsking(_ appids: [Int], listsMac: [Int: Bool]) -> [Int] {
        appids.filter { listsMac[$0] ?? true }
    }

    /// Asks the store about the appids not cached yet and returns every known flag.
    public func refresh(_ appids: [Int], now: Date = Date(), client: SteamAppDetailsClient = .shared) async -> [Int: Bool] {
        var known = load(now: now)
        let missing = appids.filter { known[$0] == nil }
        guard !missing.isEmpty else { return known }
        var fetched: [Int: Bool] = [:]
        for appid in missing {
            if Task.isCancelled { break }
            guard let data = await client.appDetails(appID: appid, now: now),
                  let mac = Self.parse(data) else { continue }
            fetched[appid] = mac
        }
        if !fetched.isEmpty { save(fetched, now: now) }
        known.merge(fetched) { $1 }
        return known
    }

    /// `{"400":{"success":true,"data":{"platforms":{"windows":true,"mac":false,"linux":false}}}}`.
    /// nil when the store has no page for the appid (delisted, region-locked): that isn't a no.
    static func parse(_ data: Data) -> Bool? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = json.values.first as? [String: Any],
              app["success"] as? Bool == true,
              let platforms = (app["data"] as? [String: Any])?["platforms"] as? [String: Any] else { return nil }
        return platforms["mac"] as? Bool
    }
}
