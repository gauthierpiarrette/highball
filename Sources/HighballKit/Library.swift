import Foundation
import CoreGraphics
import ImageIO

// The unified library (One Library, Phase 2): every playable thing across all bottles and
// sources as one flat, source-neutral list. The store is a badge and a filter, never a
// section; the bottle is a per-game property, never the navigation.

public enum LibrarySource: String, Sendable, Codable {
    case steam, epic, gog, pin, battlenet
}

/// A playable item in the unified library. Pure value: no Bottle, no GameDBEntry — the app
/// resolves `bottleName` to a Bottle at action time and joins the db at render time, which
/// keeps this type constructible (and the aggregator testable) without a filesystem.
public struct LibraryItem: Identifiable, Sendable, Hashable {
    public let source: LibrarySource
    /// Stable identity, also the persistence key in library.json — never change its shape:
    /// "steam:<appid>" | "epic:<app_name>" | "gog:<product id>" | "pin:<bottle>:<uuid>" | "battlenet:<product code>".
    public let id: String
    public let title: String
    /// Where it lives. nil only for an Epic or GOG title owned but not installed in any bottle.
    public let bottleName: String?
    public let installed: Bool
    /// The native build is installed: Steam for Mac's (MacSteam), or for GOG the Mac build gogdl
    /// put in the Mac games folder (GOGStore.macInstalledGames), or for Epic the Mac build
    /// legendary installed. Play goes there first.
    public let installedOnMac: Bool
    public let steamAppID: Int?
    public let epicAppName: String?
    /// GOG's product id, for a game from the GOG account or a GOG install found on disk.
    public let gogID: String?
    /// The Steam app id GOG's database gives the same game: the compatibility database is matched
    /// by it, never Steam itself (`steamAppID` stays nil, so nothing treats the copy as a Steam one).
    public let gogSteamAppID: Int?
    /// Blizzard's product code for a game Battle.net installed (BattleNetGame.productCode).
    public let battleNetProduct: String?
    public let pinID: UUID?
    public let artworkTall: URL?
    public let artworkWide: URL?
    /// Dedup leftovers: other bottles holding the same Steam game (detail view only).
    public let otherBottles: [String]
    public let sizeOnDisk: Int64
    public let lastPlayed: Date?
    /// GOG's or Epic's catalog lists a Mac version of the game, which the same purchase includes.
    /// Listed, not proven to run: neither catalog tells a 32-bit build macOS stopped running from
    /// a current one (Steam's builds have MacSteamBuild instead).
    public let macListed: Bool

    public init(source: LibrarySource, id: String, title: String, bottleName: String?,
                installed: Bool, installedOnMac: Bool = false, steamAppID: Int? = nil, epicAppName: String? = nil,
                gogID: String? = nil, gogSteamAppID: Int? = nil, battleNetProduct: String? = nil,
                pinID: UUID? = nil, artworkTall: URL? = nil, artworkWide: URL? = nil,
                otherBottles: [String] = [], sizeOnDisk: Int64 = 0, lastPlayed: Date? = nil, macListed: Bool = false) {
        self.source = source; self.id = id; self.title = title; self.bottleName = bottleName
        self.installed = installed; self.installedOnMac = installedOnMac
        self.steamAppID = steamAppID; self.epicAppName = epicAppName
        self.gogID = gogID; self.gogSteamAppID = gogSteamAppID; self.battleNetProduct = battleNetProduct
        self.pinID = pinID; self.artworkTall = artworkTall; self.artworkWide = artworkWide
        self.otherBottles = otherBottles; self.sizeOnDisk = sizeOnDisk; self.lastPlayed = lastPlayed
        self.macListed = macListed
    }

    /// Playable here in either build: the Windows one in a bottle or the Mac one in Steam for Mac.
    public var installedAnywhere: Bool { installed || installedOnMac }

    /// The same game seen from another environment: the library shows one tile per Steam game,
    /// homed where it was last played (highball#264), and this is how Play reaches a copy in one
    /// of the others, or how Install hands the game to that environment's Steam. Installed when
    /// that environment holds a copy.
    public func homed(in bottle: String) -> LibraryItem {
        guard bottle != bottleName else { return self }
        let holds = otherBottles.contains(bottle)
        let others = (otherBottles.filter { $0 != bottle } + (installed ? [bottleName].compactMap { $0 } : [])).sorted()
        return LibraryItem(source: source, id: id, title: title, bottleName: bottle, installed: holds,
                           installedOnMac: installedOnMac, steamAppID: steamAppID, epicAppName: epicAppName,
                           gogID: gogID, gogSteamAppID: gogSteamAppID, battleNetProduct: battleNetProduct,
                           pinID: pinID, artworkTall: artworkTall, artworkWide: artworkWide,
                           otherBottles: others, sizeOnDisk: holds ? 0 : sizeOnDisk, lastPlayed: lastPlayed, macListed: macListed)
    }
}

public enum LibraryIndex {
    /// The installed games in the order the Home row shows them: the ones played most recently
    /// first, then the rest by title, so the row reads as "what you were playing, then what you
    /// have" (highball#252, from PR #230). Owned-but-not-installed games stay out; they belong to
    /// the grid, where the download arrow says what they are.
    public static func installedForHome(_ items: [LibraryItem]) -> [LibraryItem] {
        items.filter(\.installedAnywhere).sorted { a, b in
            switch (a.lastPlayed, b.lastPlayed) {
            case let (x?, y?) where x != y: return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
    }

    /// What the library shows (highball#445): a hidden game stays out of the grid and the Home row,
    /// and the Hidden filter shows the hidden ones alone, so each can be brought back.
    public static func visible(_ items: [LibraryItem], hidden: Set<String>, showingHidden: Bool) -> [LibraryItem] {
        guard !hidden.isEmpty || showingHidden else { return items }
        return items.filter { LibraryStore.isHidden($0.id, in: hidden) == showingHidden }
    }

    /// Launcher pins are infrastructure, not games — they never appear in the library, and
    /// launching one is not "playing" for the Continue shelf. Single source of truth for the
    /// filter BottleView's Programs section shares.
    public static func isLauncherPin(_ pin: Pin) -> Bool {
        let launcherNames = ["steam", "epic games", "battle.net", "gog galaxy", "ea app",
                             "ubisoft connect", "rockstar launcher", "rockstar"]
        return launcherNames.contains(pin.name.lowercased())
    }

    /// A program added by hand that is a GOG game the library now shows, in the same environment
    /// (a pin made before Connect GOG, or for a game an offline installer put there): it runs
    /// exactly one of the programs the GOG tile can play, the game's own launch task or one of
    /// the choices on its page. Started itself, it plays as that game, with comet and cloud saves,
    /// and runs that program (AppState.launch(pin:)). Its own tile is left out only while the GOG
    /// tile's Play runs the same program; the pin itself stays in the environment's settings.
    /// Anything else keeps its tile and plays the program the player picked: a variant beside the
    /// main one (Control_DX11.exe next to Control.exe, which GOG's Play would not run), a tool in
    /// the folder, and a pin with its own variables or graphics mode, which the GOG tile could not
    /// carry. Installs are read from disk, so this holds for players who never connect GOG too.
    public struct CoveredPin: Equatable, Sendable {
        public let pinItemID: String
        public let gogItemID: String
        /// The pin's arguments beyond the ones its GOG launch task already passes, for the GOG
        /// tile's launch arguments (Quake II RTX pinned with +set vid_rtx 0 keeps it).
        public let extraArguments: [String]
        /// The GOG launch task the pin runs.
        public let task: GOGStore.PlayTask
        /// Whether the GOG tile's Play runs that task too, with the launch choice made on the game's
        /// page: only then does the tile stand for the pin's own (Ghostrunner pinned with -dx12
        /// keeps its tile while the page plays the game's default).
        public let tilePlaysIt: Bool

        /// Whether starting the pin brings cloud saves along and runs comet: only for a game task.
        /// A tool or settings program among the launch choices (category "tool") still plays as
        /// the GOG game, but a settings window has no saves to sync and no achievements to earn.
        public var syncsLikeTheGame: Bool { task.category == nil || task.category == "game" }
    }

    /// `launchChoice` is GOGSettings.launchChoice, what each GOG tile's Play runs.
    public static func gogCoveredPins(bottles: [Bottle], gogInstalledByBottle: [String: [GOGStore.InstalledGame]],
                                      launchChoice: [String: Int] = [:]) -> [CoveredPin] {
        var covered: [CoveredPin] = []
        for bottle in bottles {
            let games = gogInstalledByBottle[bottle.name] ?? []
            guard !games.isEmpty else { continue }
            for pin in bottle.settings.pins where !isLauncherPin(pin) && pin.environment.isEmpty && pin.renderer == nil {
                let file = pin.launchURL(driveC: bottle.driveC)
                guard let found = games.lazy.compactMap({ game in gogTask(game, runBy: file, arguments: pin.arguments).map { (game, $0) } }).first
                else { continue }
                let (game, task) = found
                var extra = pin.arguments
                let taskArguments = GOGStore.launch(task, in: game)?.arguments ?? []
                for argument in taskArguments { if let i = extra.firstIndex(of: argument) { extra.remove(at: i) } }
                covered.append(CoveredPin(pinItemID: "pin:\(bottle.name):\(pin.id.uuidString)", gogItemID: "gog:\(game.id)",
                                          extraArguments: extra, task: task,
                                          tilePlaysIt: game.launchTask(choice: launchChoice[game.id]) == task))
            }
        }
        return covered
    }

    /// The task of the game's that runs `file`, when the GOG tile can play it: the default launch
    /// task, or one of the page's launch choices. Only the exact program counts, compared without
    /// case as Windows paths are; a file beside it does not. Several tasks running the same
    /// program (Ghostrunner and Ghostrunner DX12) are told apart by the arguments: the one whose
    /// own arguments the pin passes, the most of them first, the default before a choice.
    static func gogTask(_ game: GOGStore.InstalledGame, runBy file: URL, arguments: [String]) -> GOGStore.PlayTask? {
        let path = file.standardizedFileURL.path.lowercased()
        let candidates: [(task: GOGStore.PlayTask, arguments: [String])] = ([game.launchTask()].compactMap { $0 } + game.launchChoices).compactMap { task in
            guard let launch = GOGStore.launch(task, in: game), launch.executable.standardizedFileURL.path.lowercased() == path else { return nil }
            return (task, launch.arguments)
        }
        func passes(_ wanted: [String]) -> Bool {
            var left = arguments
            for argument in wanted {
                guard let i = left.firstIndex(of: argument) else { return false }
                left.remove(at: i)
            }
            return true
        }
        return (candidates.filter { passes($0.arguments) }.max { $0.arguments.count < $1.arguments.count } ?? candidates.first)?.task
    }

    /// The program a play link names when the library leaves its tile out for its GOG tile
    /// (gogCoveredPins), so a Mac app made for it before keeps working: Play still runs that
    /// program, as the GOG game (AppState.launch(pin:)), whatever the GOG tile plays. Found by its
    /// own id too when its environment was renamed since (PinID).
    public static func coveredPinItem(forLink target: PlayLink.Target, bottles: [Bottle],
                                      gogInstalledByBottle: [String: [GOGStore.InstalledGame]]) -> LibraryItem? {
        guard case let .pin(_, uuid) = target else { return nil }
        let covered = gogCoveredPins(bottles: bottles, gogInstalledByBottle: gogInstalledByBottle)
        guard let found = covered.first(where: { $0.pinItemID == target.libraryID })
                ?? covered.first(where: { PinID.uuid(in: $0.pinItemID) == uuid.uuidString }),
              let bottle = bottles.first(where: { found.pinItemID == "pin:\($0.name):\(uuid.uuidString)" }),
              let pin = bottle.settings.pins.first(where: { $0.id == uuid }) else { return nil }
        return LibraryItem(source: .pin, id: found.pinItemID, title: pin.name, bottleName: bottle.name, installed: true, pinID: pin.id)
    }

    /// Hands what a program added by hand had to the GOG tile that now stands for it
    /// (gogCoveredPins, while the tile plays the same program), once per program, so the program's
    /// tile can leave the library without the game playing or looking different: the arguments its
    /// GOG task does not already pass, the display, the graphics mode, and the name and cover the
    /// player gave it. A setting goes only where the GOG tile has none of its own, since one set
    /// there was the player's choice for the game. When it was last played needs no carrying: the
    /// GOG tile shows the latest play of the programs it stands for (build). The program keeps its
    /// own copy of everything, so its tile comes back as it was when the GOG tile stops standing
    /// for it. Returns a line per program for the log.
    @discardableResult
    public static func carryOver(_ covered: [CoveredPin], paths: HighballPaths, settings: inout GOGSettings) -> [String] {
        let store = LibraryStore(paths: paths), names = NameStore(paths: paths), covers = CoverStore(paths: paths)
        var lines: [String] = []
        for pin in covered where pin.tilePlaysIt && !wasCarriedOver(pin.pinItemID, in: settings.carriedOverPins) {
            let (from, to) = (pin.pinItemID, pin.gogItemID)
            if !pin.extraArguments.isEmpty, store.launchArguments()[to] == nil {
                store.setLaunchArguments(pin.extraArguments, for: to)
            }
            let displays = store.displayChoices()
            if let display = displays[from], displays[to] == nil { store.setDisplay(display, for: to) }
            let overrides = store.rendererOverrides()
            if let renderer = overrides[from], overrides[to] == nil { store.setRendererOverride(renderer, for: to) }
            let custom = names.names()
            if let name = NameStore.name(for: from, in: custom), NameStore.name(for: to, in: custom) == nil {
                try? names.setName(name, for: to)
            }
            if covers.coverURL(for: from) != nil, covers.coverURL(for: to) == nil { try? covers.copyCover(from: from, to: to) }
            let hidden = store.hiddenIDs()
            if LibraryStore.isHidden(from, in: hidden), !LibraryStore.isHidden(to, in: hidden) { store.setHidden(true, for: to) }
            settings.carriedOverPins.insert(from)
            lines.append("\(from): shown as its GOG game (\(to)) from now on; its settings, name and cover went along")
        }
        return lines
    }

    /// Whether a program's things went to its GOG tile already, also under an earlier name of its
    /// environment (PinID): a rename gives the program a new id, and carrying again would put back
    /// a name or cover the player has since cleared on the GOG tile.
    public static func wasCarriedOver(_ pinItemID: String, in carried: Set<String>) -> Bool {
        if carried.contains(pinItemID) { return true }
        guard let uuid = PinID.uuid(in: pinItemID) else { return false }
        return carried.contains { PinID.uuid(in: $0) == uuid }
    }

    /// Builds the unified item list. Pure: takes exactly what AppState already holds.
    /// Steam games dedup by appid across bottles — one tile per game, never per install;
    /// the primary bottle is where it was last played, then a ready copy, then name order.
    /// `steamOwnedByBottle` adds the account's games that aren't installed anywhere
    /// (SteamOwnedLibrary, highball#199), homed in the first bottle whose Steam owns them.
    /// `macInstalled` is what Steam for Mac has installed (MacSteam): those games count as
    /// installed, and one no bottle knows gets a tile of its own. `battleNetByBottle` is what
    /// Battle.net installed in each bottle (BattleNetLibrary, highball#417).
    public static func build(bottles: [Bottle],
                             steamByBottle: [String: [SteamGame]],
                             steamOwnedByBottle: [String: [OwnedSteamGame]] = [:],
                             macInstalled: [SteamGame] = [],
                             epicOwned: [EpicStore.Game],
                             epicInstalls: [String: String],
                             gogGames: [GOGStore.Game] = [],
                             gogInstalledByBottle: [String: [GOGStore.InstalledGame]] = [:],
                             gogLaunchChoice: [String: Int] = [:],
                             gogMacInstalled: Set<String> = [],
                             epicMacInstalled: Set<String> = [],
                             battleNetByBottle: [String: [BattleNetGame]] = [:],
                             plays: [String: LibraryStore.PlayRecord] = [:],
                             defaultBottle: String? = nil,
                             pinExists: (Bottle, Pin) -> Bool = { _, _ in true }) -> [LibraryItem] {
        var items: [LibraryItem] = []
        let onMac = Dictionary(macInstalled.map { ($0.appid, $0) }, uniquingKeysWith: { a, _ in a })
        // Where a game with no other reason to live somewhere goes: the default environment first,
        // then by name. By name alone, a test environment called "Clean" took every owned game
        // from "Games" (highball#264).
        func before(_ a: String, _ b: String) -> Bool {
            if let d = defaultBottle, (a == d) != (b == d) { return a == d }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        let firstBottle = bottles.map(\.name).min(by: before)

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
                return before(a.bottle, b.bottle)
            }!
            let acfPlayed = (copies.compactMap(\.game.lastPlayed) + [onMac[appid]?.lastPlayed].compactMap { $0 }).max()
            let recorded = plays[id]?.lastPlayedAt
            // The client's cached art when it has it (see OwnedSteamGame), the CDN otherwise.
            let owned = steamOwnedByBottle.values.lazy.compactMap { $0.first { $0.appid == appid } }.first
            items.append(LibraryItem(
                source: .steam, id: id, title: primary.game.name, bottleName: primary.bottle,
                installed: primary.game.isReady, installedOnMac: onMac[appid] != nil, steamAppID: appid,
                artworkTall: owned?.localCapsule ?? primary.game.capsuleImage,
                artworkWide: owned?.localHeader ?? primary.game.headerImage,
                otherBottles: copies.map(\.bottle).filter { $0 != primary.bottle }.sorted(),
                sizeOnDisk: primary.game.sizeOnDisk,
                lastPlayed: [acfPlayed, recorded].compactMap { $0 }.max()))
        }

        // Steam games owned but not installed: one tile each, like Epic's, in the first bottle
        // (the default, then by name) whose client lists them, where Install will hand them to Steam.
        var ownedOnly = Set<Int>()
        for bottle in bottles.sorted(by: { before($0.name, $1.name) }) {
            for game in steamOwnedByBottle[bottle.name] ?? [] where byAppID[game.appid] == nil && !ownedOnly.contains(game.appid) {
                ownedOnly.insert(game.appid)
                let id = "steam:\(game.appid)"
                items.append(LibraryItem(
                    source: .steam, id: id, title: game.name, bottleName: bottle.name,
                    installed: false, installedOnMac: onMac[game.appid] != nil, steamAppID: game.appid,
                    artworkTall: game.capsuleImage, artworkWide: game.headerImage,
                    lastPlayed: [onMac[game.appid]?.lastPlayed, plays[id]?.lastPlayedAt].compactMap { $0 }.max()))
            }
        }

        // Installed in Steam for Mac and nowhere else Highball can see (no bottle's Steam signed
        // in yet): still the player's game, homed where a Windows install would go.
        for game in macInstalled where byAppID[game.appid] == nil && !ownedOnly.contains(game.appid) {
            let id = "steam:\(game.appid)"
            items.append(LibraryItem(
                source: .steam, id: id, title: game.name, bottleName: firstBottle,
                installed: false, installedOnMac: true, steamAppID: game.appid,
                artworkTall: game.capsuleImage, artworkWide: game.headerImage,
                lastPlayed: [game.lastPlayed, plays[id]?.lastPlayedAt].compactMap { $0 }.max()))
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
                installed: home != nil, installedOnMac: epicMacInstalled.contains(game.app_name), epicAppName: game.app_name,
                artworkTall: game.artworkTall, artworkWide: game.artworkWide,
                lastPlayed: plays[id]?.lastPlayedAt, macListed: game.listsMac))
        }

        // GOG: one tile per game. Installs are read from disk (GOGStore.installedGames), so a game
        // an offline installer put in an environment is the GOG game too. Several environments
        // holding it: the one it was last played in, then the default, then by name, like Steam.
        var gogCopies: [String: [(bottle: String, game: GOGStore.InstalledGame)]] = [:]
        for bottle in bottles {
            for game in gogInstalledByBottle[bottle.name] ?? [] { gogCopies[game.id, default: []].append((bottle.name, game)) }
        }
        // Programs the GOG tile stands for leave the library (below); their plays show on it.
        let standing = gogCoveredPins(bottles: bottles, gogInstalledByBottle: gogInstalledByBottle, launchChoice: gogLaunchChoice)
            .filter(\.tilePlaysIt)
        let coveredPins = Set(standing.map(\.pinItemID))
        var gogSeen = Set<String>()
        let gogKnown = Dictionary(gogGames.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in gogGames.map(\.id) + gogCopies.keys.sorted() where !gogSeen.contains(id) {
            gogSeen.insert(id)
            let itemID = "gog:\(id)"
            let copies = gogCopies[id] ?? []
            let lastPlayedBottle = plays[itemID]?.bottle
            let primary = copies.min { a, b in
                if let lp = lastPlayedBottle, (a.bottle == lp) != (b.bottle == lp) { return a.bottle == lp }
                return before(a.bottle, b.bottle)
            }
            let meta = gogKnown[id]
            items.append(LibraryItem(
                source: .gog, id: itemID, title: meta?.title ?? primary?.game.title ?? id, bottleName: primary?.bottle,
                installed: primary != nil, installedOnMac: gogMacInstalled.contains(id), gogID: id, gogSteamAppID: meta?.steamAppID,
                artworkTall: meta?.artworkTall, artworkWide: meta?.artworkWide,
                otherBottles: copies.map(\.bottle).filter { $0 != primary?.bottle }.sorted(),
                lastPlayed: ([itemID] + standing.filter { $0.gogItemID == itemID }.map(\.pinItemID)).compactMap { plays[$0]?.lastPlayedAt }.max(),
                macListed: meta?.listsMac == true))
        }

        // Battle.net: one tile per game like Steam's, homed where it was last played, then in the
        // default environment, then by name; the other environments holding it are remembered.
        var byProduct: [String: [(bottle: String, game: BattleNetGame)]] = [:]
        for bottle in bottles {
            for game in battleNetByBottle[bottle.name] ?? [] { byProduct[game.productCode, default: []].append((bottle.name, game)) }
        }
        for (code, copies) in byProduct {
            let id = "battlenet:\(code)"
            let lastPlayedBottle = plays[id]?.bottle
            let primary = copies.min { a, b in
                if let lp = lastPlayedBottle, (a.bottle == lp) != (b.bottle == lp) { return a.bottle == lp }
                return before(a.bottle, b.bottle)
            }!
            items.append(LibraryItem(
                source: .battlenet, id: id, title: primary.game.title, bottleName: primary.bottle,
                installed: true, battleNetProduct: code, artworkTall: primary.game.boxArt,
                otherBottles: copies.map(\.bottle).filter { $0 != primary.bottle }.sorted(),
                sizeOnDisk: primary.game.sizeOnDisk,
                lastPlayed: [primary.game.lastPlayed, plays[id]?.lastPlayedAt].compactMap { $0 }.max()))
        }

        // Custom pins (dropped exes, preinstalled games), no artwork. Installed when the program's
        // file is there: one on a drive that is unplugged, or deleted since, is not (highball#269,
        // the Installed filter kept listing them). `pinExists` is the app's check of the disk;
        // without one every pin counts, so the index stays testable without a filesystem.
        for bottle in bottles {
            for pin in bottle.settings.pins where !isLauncherPin(pin) {
                let id = "pin:\(bottle.name):\(pin.id.uuidString)"
                if coveredPins.contains(id) { continue }   // its GOG tile stands for it
                items.append(LibraryItem(
                    source: .pin, id: id, title: pin.name, bottleName: bottle.name,
                    installed: pinExists(bottle, pin), pinID: pin.id,
                    lastPlayed: plays[id]?.lastPlayedAt))
            }
        }

        return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// What an environment holds, for its card in Settings: every Steam game installed in it,
    /// whether or not the library homes that game's tile there (one tile per game, highball#264),
    /// plus the programs and Epic games that live in it. Games the account owns but has not
    /// installed are not in any environment, so they are not counted.
    public static func footprint(of bottle: String, items: [LibraryItem], steamGames: [SteamGame]) -> (count: Int, bytes: Int64) {
        let steam = steamGames.filter(\.isReady)
        let others = items.filter { $0.source != .steam && $0.bottleName == bottle && $0.installed }
        return (steam.count + others.count,
                steam.reduce(Int64(0)) { $0 + $1.sizeOnDisk } + others.reduce(Int64(0)) { $0 + $1.sizeOnDisk })
    }
}

/// The library as `highball library` prints it (highball#432): a game per line, led by the id
/// `highball play` takes, then the name the player sees, its environment and whether it can be
/// played. Tab-separated so a frontend's script can cut it; `--json` gives the same entries.
public enum LibraryListing {
    public struct Entry: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let source: String
        public let environment: String?
        public let installed: Bool
        public let installedOnMac: Bool
    }

    /// `title` is the name shown in the app: a custom one (NameStore) or the store's.
    public static func entry(_ item: LibraryItem, title: String) -> Entry {
        Entry(id: item.id, title: title, source: item.source.rawValue, environment: item.bottleName,
              installed: item.installed, installedOnMac: item.installedOnMac)
    }

    public static func line(_ entry: Entry) -> String {
        func field(_ text: String) -> String {
            text.replacingOccurrences(of: "[\t\r\n]+", with: " ", options: .regularExpression)
        }
        let state = entry.installed ? "installed" : entry.installedOnMac ? "installed on Mac" : "not installed"
        return [entry.id, field(entry.title), field(entry.environment ?? "-"), state].joined(separator: "\t")
    }
}

/// Which existing environment a game that needs another engine should use (highball-db#318).
/// The engine ask offers the best one before "New environment", so pressing Play again after
/// making one never makes a second. An environment holding the game comes first, then one
/// with the game's fix applied, then any other on an engine the fix accepts.
public enum EnvironmentFit {
    public struct Candidate: Equatable, Sendable {
        public let name: String
        public let holdsGame: Bool
        public let hasFix: Bool
        public init(name: String, holdsGame: Bool, hasFix: Bool) {
            self.name = name; self.holdsGame = holdsGame; self.hasFix = hasFix
        }
    }

    /// `candidates` are already on an engine the fix accepts, in the order the app lists them.
    public static func best(_ candidates: [Candidate]) -> Candidate? {
        func rank(_ c: Candidate) -> Int { c.holdsGame ? 0 : (c.hasFix ? 1 : 2) }
        return candidates.enumerated().min { a, b in
            rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset
        }?.element
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
        /// A graphics mode chosen for one game, by library id: the guided trial's answer (item 1,
        /// #66 and #67 were users stuck on Wine's own Direct3D for old DirectX 9 games with no way
        /// to change one game without changing the whole environment). Optional so files written
        /// before it still decode.
        var overrides: [String: Renderer]?
        /// Launch arguments the player set for one game, by library id, passed after any the
        /// database adds (highball#236: the only ways were Steam's own Launch Options or a program
        /// entry). Optional so older files still decode.
        var launchArgs: [String: [String]]?
        /// The display one game's window is moved to after it opens, by library id (display UUID
        /// string). Optional so older files still decode.
        var displays: [String: String]?
        /// Games the player hid from the library, by library id (highball#445: native Mac games,
        /// demos and finished ones crowded the Windows games). Optional so older files still decode.
        var hidden: [String]?
        /// True when Steam for Mac's own installs stay out of the library (highball#445). Absent
        /// means they are in, as before.
        var macSteamExcluded: Bool?
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

    public func rendererOverrides() -> [String: Renderer] { loadShape().overrides ?? [:] }

    /// Sets, or with nil clears, the graphics mode this one game runs with.
    public func setRendererOverride(_ renderer: Renderer?, for id: String) {
        var shape = loadShape()
        var overrides = shape.overrides ?? [:]
        overrides[id] = renderer
        shape.overrides = overrides.isEmpty ? nil : overrides
        try? paths.ensure()
        if let data = try? JSONEncoder.highball.encode(shape) { try? data.write(to: fileURL, options: .atomic) }
    }

    public func launchArguments() -> [String: [String]] { loadShape().launchArgs ?? [:] }

    /// Sets, or with an empty list clears, the launch arguments of one game.
    public func setLaunchArguments(_ args: [String], for id: String) {
        var shape = loadShape()
        var all = shape.launchArgs ?? [:]
        all[id] = args.isEmpty ? nil : args
        shape.launchArgs = all.isEmpty ? nil : all
        try? paths.ensure()
        if let data = try? JSONEncoder.highball.encode(shape) { try? data.write(to: fileURL, options: .atomic) }
    }

    public func displayChoices() -> [String: String] { loadShape().displays ?? [:] }

    /// Sets, or with nil clears, the display (CoreGraphics UUID string) one game's window moves to.
    public func setDisplay(_ uuid: String?, for id: String) {
        var shape = loadShape()
        var all = shape.displays ?? [:]
        all[id] = uuid
        shape.displays = all.isEmpty ? nil : all
        try? paths.ensure()
        if let data = try? JSONEncoder.highball.encode(shape) { try? data.write(to: fileURL, options: .atomic) }
    }

    public func hiddenIDs() -> Set<String> { Set(loadShape().hidden ?? []) }

    /// Hides one game from the library, or shows it again. A program's id carries its environment's
    /// name, so showing it again also drops a mark kept under an earlier name of that environment
    /// (PinID), or the game would stay hidden after a rename.
    public func setHidden(_ hidden: Bool, for id: String) {
        var shape = loadShape()
        var all = Set(shape.hidden ?? [])
        if hidden {
            all.insert(id)
        } else {
            all.remove(id)
            if let uuid = PinID.uuid(in: id) { all = all.filter { !($0.hasPrefix("pin:") && $0.hasSuffix(":" + uuid)) } }
        }
        shape.hidden = all.isEmpty ? nil : all.sorted()
        save(shape)
    }

    /// Whether an id is hidden in a loaded set: the id itself, or for a program the mark kept under
    /// an earlier name of its environment (PinID).
    public static func isHidden(_ id: String, in hidden: Set<String>) -> Bool {
        if hidden.contains(id) { return true }
        guard let uuid = PinID.uuid(in: id) else { return false }
        return hidden.contains { $0.hasPrefix("pin:") && $0.hasSuffix(":" + uuid) }
    }

    /// Whether the games Steam for Mac installed are part of the library. On unless the player
    /// turned it off (highball#445).
    public var includesMacSteam: Bool { loadShape().macSteamExcluded != true }

    public func setIncludesMacSteam(_ on: Bool) {
        var shape = loadShape()
        shape.macSteamExcluded = on ? nil : true
        save(shape)
    }

    private func save(_ shape: FileShape) {
        try? paths.ensure()
        if let data = try? JSONEncoder.highball.encode(shape) { try? data.write(to: fileURL, options: .atomic) }
    }

    private func loadShape() -> FileShape {
        guard let data = try? Data(contentsOf: fileURL),
              let shape = try? JSONDecoder.highball.decode(FileShape.self, from: data) else { return FileShape() }
        return shape
    }

    public func recordPlay(id: String, bottle: String?, date: Date = Date()) {
        var shape = loadShape()
        shape.items[id] = PlayRecord(lastPlayedAt: date, bottle: bottle)
        try? paths.ensure()
        if let data = try? JSONEncoder.highball.encode(shape) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Drops records whose items no longer exist (uninstalled games, deleted pins).
    public func prune(validIDs: Set<String>) {
        var whole = loadShape()
        let keptItems = whole.items.filter { validIDs.contains($0.key) }
        let keptOverrides = (whole.overrides ?? [:]).filter { validIDs.contains($0.key) }
        let keptArgs = (whole.launchArgs ?? [:]).filter { validIDs.contains($0.key) }
        let keptDisplays = (whole.displays ?? [:]).filter { validIDs.contains($0.key) }
        let keptHidden = (whole.hidden ?? []).filter { validIDs.contains($0) }
        guard keptItems.count != whole.items.count
                || keptOverrides.count != (whole.overrides ?? [:]).count
                || keptArgs.count != (whole.launchArgs ?? [:]).count
                || keptDisplays.count != (whole.displays ?? [:]).count
                || keptHidden.count != (whole.hidden ?? []).count else { return }
        whole.items = keptItems
        whole.overrides = keptOverrides.isEmpty ? nil : keptOverrides
        whole.launchArgs = keptArgs.isEmpty ? nil : keptArgs
        whole.displays = keptDisplays.isEmpty ? nil : keptDisplays
        whole.hidden = keptHidden.isEmpty ? nil : keptHidden
        if let data = try? JSONEncoder.highball.encode(whole) {
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

    static let extensions = ["png", "jpg", "jpeg", "heic", "webp"]

    /// The stored override for an item, if any. A program's cover is found by its own id when
    /// the environment it lives in was renamed since (PinID).
    public func coverURL(for id: String) -> URL? {
        let base = dir.appending(path: Self.filename(for: id))
        for ext in Self.extensions {
            let url = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        guard let uuid = PinID.uuid(in: id) else { return nil }
        let suffix = "_" + uuid
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { Self.extensions.contains($0.pathExtension.lowercased()) }
            .filter { $0.deletingPathExtension().lastPathComponent.hasPrefix("pin_") && $0.deletingPathExtension().lastPathComponent.hasSuffix(suffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
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

    /// Same, from image bytes rather than a file. An image dragged out of a browser arrives as
    /// data with no file behind it, and refusing that would make the drop look broken (#175).
    public func setCover(for id: String, imageData: Data) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = try Self.normalized(imageData: imageData)
        clearCover(for: id)
        try png.write(to: dir.appending(path: Self.filename(for: id)).appendingPathExtension("png"), options: .atomic)
    }

    public static func normalized(imageData: Data) throws -> Data {
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else {
            throw HighballError.invalid("That is not an image Highball can read. Drop a PNG, JPEG or HEIC file.")
        }
        return try normalized(image)
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

    /// Removes the item's override, and for a program every copy kept under an earlier name of
    /// its environment, so Reset cover really resets.
    public func clearCover(for id: String) {
        for _ in 0..<8 {
            guard let existing = coverURL(for: id) else { return }
            guard (try? FileManager.default.removeItem(at: existing)) != nil else { return }
        }
    }

    /// Copies one item's chosen cover, as it is, to another item (a program's cover to the GOG
    /// tile that now stands for it). Nothing happens when the first has none.
    public func copyCover(from source: String, to target: String) throws {
        guard let file = coverURL(for: source) else { return }
        clearCover(for: target)
        let dest = dir.appending(path: Self.filename(for: target)).appendingPathExtension(file.pathExtension.lowercased())
        try FileManager.default.copyItem(at: file, to: dest)
    }
}

/// A program's library id carries its environment's name ("pin:<bottle>:<uuid>"), so renaming or
/// swapping environments changes it, and the cover and name chosen for the program went missing
/// although the files were still there (highball#258, 2026-10-05). The uuid is the program's own
/// and never changes, so covers and names fall back to it when the full id finds nothing.
enum PinID {
    static func uuid(in id: String) -> String? {
        guard id.hasPrefix("pin:"), let last = id.split(separator: ":").last,
              UUID(uuidString: String(last)) != nil else { return nil }
        return String(last)
    }
}

/// The names people give library entries themselves, beside the covers they choose: a Steam
/// title in a language they do not read, a program added by hand under its file name, a game
/// they call something else (asked for on Discord, 2026-10-01). One JSON file in the home,
/// keyed by the library item's id, so a rename survives rebuilds of the library and never
/// touches the store's own title, which the database lookup and Steam itself keep using.
public struct NameStore: Sendable {
    public let paths: HighballPaths
    public init(paths: HighballPaths = HighballPaths()) { self.paths = paths }

    var file: URL { paths.home.appending(path: "names.json") }

    /// Every custom name, by item id. An unreadable file reads as no names, never as an error.
    public func names() -> [String: String] {
        guard let d = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }

    public func name(for id: String) -> String? { Self.name(for: id, in: names()) }

    /// The name for an id in a loaded table: the id itself, or for a program the name kept under
    /// an earlier name of its environment (PinID).
    public static func name(for id: String, in names: [String: String]) -> String? {
        if let exact = names[id] { return exact }
        guard let uuid = PinID.uuid(in: id) else { return nil }
        return names.filter { $0.key.hasPrefix("pin:") && $0.key.hasSuffix(":" + uuid) }.sorted { $0.key < $1.key }.first?.value
    }

    /// Sets a name, or clears it when the name is empty once trimmed: a blank is a reset, not a
    /// game called nothing.
    public func setName(_ name: String?, for id: String) throws {
        var all = names()
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A program's name kept under an earlier name of its environment goes, whether this sets
        // a new name or resets it, or the reset would show the old one again.
        if let uuid = PinID.uuid(in: id) {
            for key in all.keys where key != id && key.hasPrefix("pin:") && key.hasSuffix(":" + uuid) { all.removeValue(forKey: key) }
        }
        if trimmed.isEmpty { all.removeValue(forKey: id) } else { all[id] = trimmed }
        if all.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(all).write(to: file, options: .atomic)
    }
}
