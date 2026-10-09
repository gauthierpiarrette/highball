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
    /// The Steam library folder the game is installed in, the directory holding `steamapps`.
    /// Steam keeps more than one, the second often on an external disk, so the install path
    /// cannot be derived from the bottle alone. nil for a game built without one.
    public let libraryRoot: URL?
    /// The Steam client that installed the game, as the ACF's LauncherPath records it: a Windows
    /// path for Steam in an environment (`C:\\Program Files (x86)\\Steam\\steam.exe`), a Mac
    /// path for Steam for Mac. nil when the manifest has none.
    public let launcherPath: String?

    public init(appid: Int, name: String, installdir: String, sizeOnDisk: Int64, stateFlags: Int, lastPlayed: Date?,
                libraryRoot: URL? = nil, launcherPath: String? = nil) {
        self.appid = appid; self.name = name; self.installdir = installdir; self.sizeOnDisk = sizeOnDisk
        self.stateFlags = stateFlags; self.lastPlayed = lastPlayed; self.libraryRoot = libraryRoot
        self.launcherPath = launcherPath
    }

    /// Installed by a Windows Steam, the one in an environment. A library folder both clients use
    /// (an external drive, say) shows Steam for Mac the Windows client's manifests too, and a
    /// Windows-only game then read as installed in Steam for Mac and played there: Forza Horizon 6
    /// got "Play on Mac" and never its own fix (Discord, 2026-10-09).
    public var installedByWindowsSteam: Bool {
        guard let path = launcherPath else { return false }
        return path.lowercased().hasSuffix(".exe") || path.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil
    }

    public var id: Int { appid }
    /// Where the game's files are, when the library folder is known.
    public var installFolder: URL? {
        guard let libraryRoot, !installdir.isEmpty else { return nil }
        return libraryRoot.appending(path: "steamapps/common/\(installdir)", directoryHint: .isDirectory)
    }
    /// StateFlags 4 = fully installed; anything else is updating/downloading/broken.
    public var isReady: Bool { stateFlags == 4 }

    /// Steam CDN artwork (no key needed).
    public var headerImage: URL { URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(appid)/header.jpg")! }
    public var capsuleImage: URL { URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(appid)/library_600x900.jpg")! }
}

public enum SteamLibrary {
    /// Path of the Windows Steam install inside a bottle, if present.
    public static func steamRoot(of bottle: Bottle) -> URL? {
        steamRoot(driveC: bottle.driveC)
    }

    /// Path of the Windows Steam install under a `drive_c` we only have the path of.
    static func steamRoot(driveC: URL) -> URL? {
        let root = driveC.appending(path: "Program Files (x86)/Steam")
        return FileManager.default.fileExists(atPath: root.appending(path: "steam.exe").path) ? root : nil
    }

    /// All games known to the bottle's Steam library folders: the one inside the environment and
    /// every folder Steam's library list adds to it.
    public static func games(in bottle: Bottle) -> [SteamGame] {
        guard let root = steamRoot(of: bottle) else { return [] }
        return games(steamRoot: root, bottleURL: bottle.url)
    }

    static func games(steamRoot root: URL, bottleURL: URL) -> [SteamGame] {
        var seen = Set<Int>(), games: [SteamGame] = []
        for library in libraryFolders(steamRoot: root, bottleURL: bottleURL) {
            // Resolved first: players move steamapps to an external disk and leave a symlink in its
            // place, and FileManager's URL listing refuses a symlink ("Not a directory"), so the
            // whole library read as empty (highball-db#316, steamapps on /Volumes/MEDIA_DEV).
            let steamapps = library.appending(path: "steamapps").resolvingSymlinksInPath()
            guard let entries = try? FileManager.default.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil) else { continue }
            for url in entries where url.lastPathComponent.hasPrefix("appmanifest_") && url.pathExtension == "acf" {
                guard let game = parseManifest(url, libraryRoot: library),
                      game.appid != 228980,                       // Steamworks Common Redistributables, not a game
                      seen.insert(game.appid).inserted else { continue }   // the environment's own copy wins
                games.append(game)
            }
        }
        return games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The Steam library folders of a bottle: the one inside the environment first, then the
    /// ones Steam's `libraryfolders.vdf` names, in Steam's order. Steam writes those as Windows
    /// paths (`D:\SteamLibrary`), which the bottle's drive letters turn back into Mac paths; a
    /// letter the bottle does not map, or a folder that is not there (an external disk left at
    /// home), is skipped. Before this a game installed in a second library folder never reached
    /// the library at all (highball-db#316, a Steam library on /Volumes/MEDIA_DEV).
    static func libraryFolders(steamRoot root: URL, bottleURL: URL) -> [URL] {
        var folders = [root.standardizedFileURL]
        let vdf = root.appending(path: "steamapps/libraryfolders.vdf")
        guard let text = try? String(contentsOf: vdf, encoding: .utf8) else { return folders }
        for path in libraryPaths(in: text) {
            guard let url = unixURL(windowsPath: path, bottleURL: bottleURL)?.standardizedFileURL,
                  !folders.contains(url),
                  FileManager.default.fileExists(atPath: url.appending(path: "steamapps").path) else { continue }
            folders.append(url)
        }
        return folders
    }

    /// The `"path"` values of a libraryfolders.vdf, their doubled backslashes made single.
    static func libraryPaths(in text: String) -> [String] {
        text.matches(of: #/"path"\s+"([^"]*)"/#).map { String($0.1).replacingOccurrences(of: "\\\\", with: "\\") }
    }

    /// A Windows path through the bottle's drive letters: `dosdevices/d:` is a symlink to the Mac
    /// folder the letter stands for (`c:` to `../drive_c`, `z:` to `/`), so the path's components
    /// go on the end of that. nil for a letter the bottle does not map.
    static func unixURL(windowsPath: String, bottleURL: URL) -> URL? {
        let parts = windowsPath.split(separator: "\\", omittingEmptySubsequences: true).map(String.init)
        guard let drive = parts.first, drive.count == 2, drive.hasSuffix(":"), let letter = drive.first?.lowercased() else { return nil }
        let dosdevices = bottleURL.appending(path: "dosdevices", directoryHint: .isDirectory)
        var base: URL
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: dosdevices.appending(path: "\(letter):").path) {
            base = dest.hasPrefix("/") ? URL(fileURLWithPath: dest, isDirectory: true) : dosdevices.appending(path: dest, directoryHint: .isDirectory)
        } else if letter == "c" {
            base = bottleURL.appending(path: "drive_c", directoryHint: .isDirectory)
        } else if letter == "z" {
            base = URL(fileURLWithPath: "/", isDirectory: true)
        } else {
            return nil
        }
        for part in parts.dropFirst() { base = base.appending(path: part, directoryHint: .isDirectory) }
        return base
    }

    /// Minimal ACF (Valve KeyValues) reader: flat `"key" "value"` pairs are all we need.
    static func parseManifest(_ url: URL, libraryRoot: URL? = nil) -> SteamGame? {
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
            lastPlayed: played > 0 ? Date(timeIntervalSince1970: played) : nil,
            libraryRoot: libraryRoot,
            launcherPath: fields["LauncherPath"]
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
    public var status: String       // verified-local | reported-upstream | community | blocked-anticheat | blocked-publisher
    public var renderer: Renderer?
    /// The game draws with Vulkan directly (The Sims Legacy Collection): every graphics mode is a
    /// Direct3D layer, so none applies, and the page must say so instead of offering a choice (#44).
    public var nativeVulkan: Bool?
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
    /// A native macOS edition. Highball marks the ones on Steam (the same purchase); `available:
    /// false` marks a Mac port that no longer runs, which outranks the store's flag (MacSteamBuild).
    public var nativeMac: NativeMacInfo?

    /// Any kind of block: kernel anti-cheat, or a publisher that stops the game on macOS on purpose
    /// (World of Warships). The game cannot run, so no renderer advice and no Play.
    public var isBlocked: Bool { status.hasPrefix("blocked-") }

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
    /// Rows by title with the spaces removed too: a program added from its executable is named
    /// after the file, "HogwartsLegacy", not "Hogwarts Legacy" (highball-db#48).
    public let byCompactTitle: [String: GameDBEntry]

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
        var compact: [String: GameDBEntry] = [:]
        for (key, entry) in titles { let c = key.replacingOccurrences(of: " ", with: ""); if compact[c] == nil { compact[c] = entry } }
        byCompactTitle = compact
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
        let normalized = Self.normalizedTitle(item.title)
        if let e = byTitle[normalized] { return e }
        return byCompactTitle[normalized.replacingOccurrences(of: " ", with: "")]
    }
}
