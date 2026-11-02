import Foundation
import os

/// GOG cloud saves through gogdl's save-sync. Where a game keeps its saves comes from GOG's own
/// client configuration (remote-config, the file Galaxy reads); the folders are resolved inside the
/// environment, saves come down before Play and go up after the game ends, as Galaxy does.
///
/// gogdl notices a conflict (both sides changed since the last sync), transfers nothing and still
/// prints a fresh timestamp; storing that timestamp would make the next sync overwrite one side
/// unasked. So a conflict is detected from its log line and the timestamp is kept back until the
/// player chooses which copy wins.
public struct GOGSaves: Sendable {
    public let store: GOGStore
    public init(store: GOGStore) { self.store = store }

    public struct Location: Sendable, Equatable {
        public let name: String
        /// GOG's template, e.g. "<?SAVED_GAMES?>/Remedy/Control".
        public let template: String
    }

    /// The client id cloud storage is keyed by: the info file's, else the manifest gogdl kept
    /// (Control's info file has none; its manifest does), else GOG's latest build manifest for an
    /// install with neither (an offline installer, a gogdl install from elsewhere), remembered.
    /// nil when GOG couldn't be reached; lookUpClientID tells that apart from a game without one.
    public func clientID(for game: GOGStore.InstalledGame) -> String? {
        (try? lookUpClientID(for: game)) ?? nil
    }

    /// The client id, or nil when the game has none: then it has no cloud saves. Throws when GOG
    /// had to be asked and couldn't be reached.
    public func lookUpClientID(for game: GOGStore.InstalledGame) throws -> String? {
        if let id = game.clientID, !id.isEmpty { return id }
        if let data = try? Data(contentsOf: store.installManifest(game)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = obj["clientId"] as? String { return id }
        let cacheFile = store.dir.appending(path: "client-ids.json")
        var cache = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: cacheFile))) ?? [:]
        if let id = cache[game.id] { return id }
        guard let id = try Self.publishedClientID(productID: game.id) else { return nil }
        cache[game.id] = id
        try? JSONEncoder().encode(cache).write(to: cacheFile, options: .atomic)
        return id
    }

    /// The client id in the newest Windows build's manifest. The build list and manifests are
    /// public; a v2 manifest is zlib-compressed JSON. nil when GOG has no such build or manifest
    /// (HTTP 404); throws only when GOG can't be reached or answers with another error.
    static func publishedClientID(productID: String) throws -> String? {
        let list = URL(string: "https://content-system.gog.com/products/\(productID)/os/windows/builds?generation=2")!
        guard let listing = try GOGStore.fetchIfFound(URLRequest(url: list)),
              let builds = try? JSONSerialization.jsonObject(with: listing) as? [String: Any],
              let link = ((builds["items"] as? [[String: Any]])?.first?["link"] as? String).flatMap(URL.init(string:)),
              let manifest = try GOGStore.fetchIfFound(URLRequest(url: link)) else { return nil }
        return clientID(inManifest: manifest)
    }

    static func clientID(inManifest data: Data) -> String? {
        // zlib = a 2-byte header, raw DEFLATE, then a checksum; Foundation's .zlib reads raw DEFLATE.
        let json = data.first == 0x78 ? (try? (data.dropFirst(2) as NSData).decompressed(using: .zlib) as Data) : data
        guard let json, let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        return obj["clientId"] as? String
    }

    /// Where the game keeps its saves, nil when it has no cloud saves (including when GOG has no
    /// configuration for the client: HTTP 404). An empty list from GOG means the SDK's own storage
    /// folder, which Galaxy names __default. Throws only when GOG can't be reached or answers with
    /// another error.
    public func locations(clientID: String) throws -> [Location]? {
        let url = URL(string: "https://remote-config.gog.com/components/galaxy_client/clients/\(clientID)?component_version=2.0.45")!
        guard let data = try GOGStore.fetchIfFound(URLRequest(url: url)) else { return nil }
        return Self.parseLocations(data, clientID: clientID)
    }

    static func parseLocations(_ data: Data, clientID: String) -> [Location]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = (obj["content"] as? [String: Any])?["Windows"] as? [String: Any],
              let cloud = windows["cloudStorage"] as? [String: Any], cloud["enabled"] as? Bool == true else { return nil }
        let list = (cloud["locations"] as? [[String: Any]] ?? []).compactMap { l -> Location? in
            guard let name = l["name"] as? String, let location = l["location"] as? String else { return nil }
            return Location(name: name, template: location)
        }
        return list.isEmpty
            ? [Location(name: "__default", template: "<?APPLICATION_DATA_LOCAL?>/GOG.com/Galaxy/Applications/\(clientID)/Storage/Shared/Files")]
            : list
    }

    /// A location as a folder on the Mac, inside the environment. GOG's variables are the Windows
    /// known folders; Wine keeps them under drive_c/users/<Mac user name>. A Documents folder the
    /// environment links to the Mac's (UserFolders) resolves through the link, as Wine does.
    public static func resolve(_ template: String, game: GOGStore.InstalledGame, driveC: URL,
                               userName: String = NSUserName()) -> URL? {
        let users = UserFolders.userDirectories(driveC: driveC)
        let user = users.first { $0.lastPathComponent == userName } ?? users.first
            ?? driveC.appending(path: "users/\(userName)", directoryHint: .isDirectory)
        let values: [String: URL] = [
            "INSTALL": game.folder,
            "SAVED_GAMES": user.appending(path: "Saved Games"),
            "APPLICATION_DATA_LOCAL": user.appending(path: "AppData/Local"),
            "APPLICATION_DATA_LOCAL_LOW": user.appending(path: "AppData/LocalLow"),
            "APPLICATION_DATA_ROAMING": user.appending(path: "AppData/Roaming"),
            "DOCUMENTS": user.appending(path: "Documents"),
        ]
        var path = template.replacingOccurrences(of: "\\", with: "/")
        guard let open = path.range(of: "<?"), let close = path.range(of: "?>", range: open.upperBound..<path.endIndex),
              open.lowerBound == path.startIndex else { return nil }
        let variable = String(path[open.upperBound..<close.lowerBound])
        guard let base = values[variable] else { return nil }   // a Mac-only variable, or one GOG adds later
        path.removeSubrange(path.startIndex..<close.upperBound)
        // Any %VARIABLE% left inside is a Windows environment variable no known folder covers.
        guard !path.contains("%"), !path.contains("<?") else { return nil }
        // gogdl deletes local files the cloud lacks, so a template naming a whole known folder (or
        // climbing out of one) could empty the game or the Mac's Documents: never sync those.
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return parts.reduce(base) { $0.appending(path: $1) }
    }

    /// What an uninstall does about a game's cloud-save locations, worked out before anything is
    /// deleted.
    public struct UninstallPlan: Sendable {
        /// Folders inside the game's folder, to back up before it is deleted.
        public var backUp: [(location: Location, folder: URL)] = []
        /// Locations inside the game's folder that can't be backed up: the game's folder itself,
        /// or a path that climbs out of it. Removing the game then needs the player's go-ahead.
        public var cannotBackUp: [Location] = []
        /// Folders elsewhere in the environment, left alone unless the player asks for the saves
        /// to go with the game (removeSaves).
        public var outside: [(location: Location, folder: URL)] = []
        public init() {}
    }

    /// Locations elsewhere in the environment outlive the game's folder, so they are only listed
    /// in `outside`, as far as `resolve` accepts them. A `<?INSTALL?>` location `resolve` turns down (it refuses whole folders and unknown parts,
    /// which sync could empty) is still backed up for an uninstall, which only copies: up to the
    /// first part Highball can't resolve, such as a %VARIABLE%.
    public static func uninstallPlan(_ locations: [Location], game: GOGStore.InstalledGame, driveC: URL,
                                     userName: String = NSUserName()) -> UninstallPlan {
        let root = game.folder.standardizedFileURL.path
        var plan = UninstallPlan()
        for location in locations {
            if let folder = resolve(location.template, game: game, driveC: driveC, userName: userName) {
                if folder.standardizedFileURL.path.hasPrefix(root + "/") { plan.backUp.append((location, folder)) } else { plan.outside.append((location, folder)) }
                continue
            }
            let template = location.template.replacingOccurrences(of: "\\", with: "/")
            guard template.hasPrefix("<?INSTALL?>") else { continue }
            let parts = template.dropFirst("<?INSTALL?>".count).split(separator: "/").map(String.init)
            let known = parts.prefix { !$0.contains("%") && !$0.contains("<?") && $0 != "." && $0 != ".." }
            if known.isEmpty || parts.contains("..") {
                plan.cannotBackUp.append(location)
            } else {
                plan.backUp.append((location, known.reduce(game.folder) { $0.appending(path: $1) }))
            }
        }
        return plan
    }

    /// Deletes the save folders `plan` found outside the game's folder, for a player who asked
    /// for the saves to go with the game. Links followed, only a folder inside the environment's
    /// drive_c is deleted: an environment's Documents is often a link to the Mac's own
    /// (UserFolders), whose folders are the Mac's. One that holds or sits inside Highball's
    /// save-backups or the game's folder is left alone too. Returns what was removed and what
    /// was left for that reason.
    public func removeSaves(_ plan: UninstallPlan, game: GOGStore.InstalledGame, driveC: URL) -> (removed: [URL], leftAlone: [URL]) {
        var removed: [URL] = [], leftAlone: [URL] = []
        for folder in plan.outside.map(\.folder) where FileManager.default.fileExists(atPath: folder.path) {
            guard SaveBackups.mayDelete(folder, driveC: driveC, sparing: [backupsDir, game.folder]) else { leftAlone.append(folder); continue }
            if (try? FileManager.default.removeItem(at: folder)) != nil { removed.append(folder) }
        }
        return (removed, leftAlone)
    }

    // MARK: Sync

    public enum Direction: Sendable { case download, upload, forceDownload, forceUpload }

    public enum Outcome: Sendable, Equatable {
        case synced
        /// Both sides changed since the last sync, or this is the first sync and both sides have
        /// saves. Nothing was moved; the player decides.
        case conflict
        /// gogdl refused the requested direction because the other side has newer files. Nothing
        /// was moved.
        case refused
        case failed(String)
    }

    // MARK: Backups

    /// Backups taken before a sync could replace saves (SaveBackups), stored at
    /// save-backups/<game id>-<location>-<install>/<date>-<mac|cloud>[-kept]/. gogdl syncs both
    /// ways and deletes whatever the other side lacks: a download deletes local files missing
    /// from the cloud, and an upload deletes cloud files missing locally.
    public var backups: SaveBackups { SaveBackups(root: store.dir.deletingLastPathComponent().appending(path: "save-backups", directoryHint: .isDirectory)) }
    public var backupsDir: URL { backups.root }

    /// The backup folder for one install and location. The install is part of the name (sync
    /// history is per install too), so a second copy of the game never rotates out the first
    /// one's backups.
    func backupsFolder(_ game: GOGStore.InstalledGame, _ location: Location) -> URL {
        backups.folder("\(game.id)-\(location.name)", install: game.folder)
    }

    typealias BackupKind = SaveBackups.Kind
    static func kind(of backup: URL) -> BackupKind? { SaveBackups.kind(of: backup) }
    static func isKept(_ backup: URL) -> Bool { SaveBackups.isKept(backup) }
    static func files(in folder: URL) -> [URL] { SaveBackups.files(in: folder) }
    /// files(in:), throwing for a folder inside it that can't be read: its saves would go uncopied.
    static func walk(_ folder: URL) throws -> [URL] { try SaveBackups.walk(folder) }
    static func relativePath(of file: URL, in folder: URL) -> String { SaveBackups.relativePath(file, in: folder) }
    static func fingerprint(_ folder: URL) -> String { SaveBackups.fingerprint(folder) }
    static func fingerprintFile(of backup: URL) -> URL { SaveBackups.fingerprintFile(of: backup) }
    func backups(in dir: URL) -> [URL] { backups.backups(in: dir) }

    /// A digest of a location's files in GOG's cloud: each one's path and hash.
    static func fingerprint(cloud listing: [CloudFile], location: Location) -> String {
        let own = listing.filter { $0.hash != deletedMark && $0.name.hasPrefix(location.name + "/") }
        return "cloud " + SaveBackups.digest(own.map { "\($0.name)\t\($0.hash)" })
    }

    /// Backs up the local saves before something could replace or delete them
    /// (SaveBackups.backUpLocal). `kept` backups are never pruned. `only` limits it to some of
    /// the folder's files, as files(in:) names them.
    @discardableResult
    public func backUpLocal(_ game: GOGStore.InstalledGame, location: Location, folder: URL, kept: Bool = false,
                            only: [URL]? = nil) throws -> URL? {
        try backups.backUpLocal(folder, into: backupsFolder(game, location), kept: kept, only: only)
    }

    /// Where the files a game wrote in its own folder are backed up (backUpGameFolder). Not a
    /// location GOG names, so a game without cloud saves has one too.
    public static let gameFolder = Location(name: "game-folder", template: "<?INSTALL?>")

    /// The files under `folder` the game wrote, by the install's history (SaveBackups).
    static func files(in folder: URL, writtenPer history: GOGStore.InstallHistory) throws -> [URL] {
        try SaveBackups.files(in: folder, writtenPer: history)
    }

    /// Before an uninstall, backs up (kept) every file the game wrote in its own folder: changed
    /// after Highball first set it up there (or, never set up, after it was installed) and
    /// outside its updates (GOGStore.InstallHistory), which is where a game without cloud saves
    /// often keeps them. Files under `skipping` (the locations backed up on their own) and the
    /// install's own records are left out. nil when nothing dates the install, or the game wrote
    /// nothing. Throws if the backup fails; the uninstall must then stop.
    public func backUpGameFolder(_ game: GOGStore.InstalledGame, driveC: URL, skipping: [URL] = []) throws -> URL? {
        let history = GOGStore.history(for: game, driveC: driveC)
        guard history.firstSetup != nil else { return nil }
        let skipped = skipping.map { $0.standardizedFileURL.path + "/" }
        let top = game.folder.standardizedFileURL.path + "/"
        let written = try Self.files(in: game.folder, writtenPer: history).filter { file in
            let path = file.standardizedFileURL.path
            return !skipped.contains { path.hasPrefix($0) } && !Self.isInstallerRecord(path, in: top)
        }
        guard !written.isEmpty else { return nil }
        return try backUpLocal(game, location: Self.gameFolder, folder: game.folder, kept: true, only: written)
    }

    /// Whether backUpGameFolder can tell the files the game wrote from the installer's: something
    /// dates the install. When it can't, an uninstall that keeps saves must say so first.
    public static func canTellGameFiles(_ game: GOGStore.InstalledGame, driveC: URL) -> Bool {
        GOGStore.history(for: game, driveC: driveC).firstSetup != nil
    }

    /// The uninstaller's and GOG's own records at the top of the game's folder (unins000.dat,
    /// goggame-<id>.info, …): written by the install, not the game, and putting an old one back
    /// into a new install would break its uninstaller.
    static func isInstallerRecord(_ path: String, in top: String) -> Bool {
        guard path.hasPrefix(top) else { return false }
        let rest = path.dropFirst(top.count)
        guard !rest.contains("/") else { return false }
        let name = rest.lowercased()
        return name.hasPrefix("unins") || name.hasPrefix("goggame-")
    }

    /// How many files a backup holds and their size, for the log.
    public static func contents(of backup: URL) -> (files: Int, bytes: Int64) { SaveBackups.contents(of: backup) }

    /// GOG's whole cloud listing for the game, from a gogdl run that can't move anything: an
    /// empty folder and a location name no cloud file starts with, so gogdl finds no files on
    /// either side and only logs the listing (saves.py `sync`). nil when gogdl logged none
    /// (it logs none when GOG has no cloud storage for the game at all).
    func listCloud(_ game: GOGStore.InstalledGame) throws -> [CloudFile]? {
        let empty = FileManager.default.temporaryDirectory.appending(path: "highball-listing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let nothing = Location(name: "highball-listing-only-\(UUID().uuidString)", template: "")
        let result = try run(game, location: nothing, folder: empty, timestamp: "0", direction: .download)
        guard result.status == 0, result.downloadFailures + result.otherFailures == 0 else {
            throw HighballError.failed("gogdl could not list GOG's cloud saves (status \(result.status))")
        }
        return result.listing
    }

    /// Backs up GOG's cloud saves before an upload could replace or delete them. The listing
    /// comes first: when the location has no files in the cloud there is nothing to back up
    /// (nil), and when they match the newest cloud backup that one is returned. Otherwise gogdl
    /// downloads them into an empty backup folder (with nothing local, it only downloads), which
    /// touches neither the cloud nor the game's folder. gogdl exits 0 even when a file fails to
    /// download, so the backup also checks that every file of this location in the listing came
    /// down. `kept` backups are never pruned. Throws if the backup fails; the upload must then stop.
    @discardableResult
    public func backUpCloud(_ game: GOGStore.InstalledGame, location: Location, kept: Bool = false) throws -> URL? {
        let dir = backupsFolder(game, location)
        if let listing = try listCloud(game) {
            guard !Self.ownFiles(for: location, in: listing).isEmpty else { return nil }
            if let same = backups.reuse(in: dir, kind: .cloud, fingerprint: Self.fingerprint(cloud: listing, location: location), kept: kept) {
                return same
            }
        }
        do {
            return try backups.backUp(into: dir, kind: .cloud, kept: kept) { partial in
                try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
                let result = try run(game, location: location, folder: partial, timestamp: "0", direction: .forceDownload)
                let missing = result.listing.map { Self.ownFiles(for: location, in: $0).filter { !FileManager.default.fileExists(atPath: partial.appending(path: $0).path) } } ?? []
                guard result.status == 0, Self.unexplainedFailures(result, location: location, folder: partial, since: 0) == 0, missing.isEmpty else {
                    throw HighballError.failed("gogdl could not copy all of GOG's cloud saves (status \(result.status))")
                }
                guard !Self.files(in: partial).isEmpty else { throw NothingToBackUp() }
                return result.listing.map { Self.fingerprint(cloud: $0, location: location) }
            }
        } catch is NothingToBackUp {
            return nil
        }
    }

    private struct NothingToBackUp: Error {}

    /// gogdl's log line when a file fails to download. It names no file.
    static func isDownloadFailure(_ line: String) -> Bool { line.contains("Downloading file failed") }
    /// Any other error gogdl logs and continues past, such as a failed upload.
    static func isFailure(_ line: String) -> Bool { isDownloadFailure(line) || line.contains(" ERROR: ") }

    // MARK: Locations sharing a prefix

    /// A file in GOG's cloud storage, as gogdl lists it.
    struct CloudFile: Equatable, Sendable {
        let name: String
        let hash: String
        let modified: Date?
    }

    /// The hash gogdl skips: GOG's mark for a file deleted from the cloud.
    static let deletedMark = "aadd86936a80ee8a369579c3926f1b3c"

    /// With --debug, gogdl logs the client's whole cloud listing on one line, as a Python list of
    /// dicts (saves.py `get_cloud_files_list`). Returns nil for any other line, or one that can't
    /// be read.
    static func cloudListing(in line: String) -> [CloudFile]? {
        guard let start = line.range(of: "[SAVES] DEBUG: Files: ") else { return nil }
        var reader = PythonLiteral(line[start.upperBound...])
        guard let entries = reader.value() as? [Any], reader.atEnd else { return nil }
        var files: [CloudFile] = []
        for entry in entries {
            guard let dict = entry as? [String: Any], let name = dict["name"] as? String else { return nil }
            files.append(CloudFile(name: name, hash: dict["hash"] as? String ?? "",
                                   modified: (dict["last_modified"] as? String).flatMap(Self.date(iso:))))
        }
        return files
    }

    /// gogdl reads these with Python's `fromisoformat` and then `astimezone()`, so a date with
    /// no offset is local time. GOG writes an offset and microseconds; any fraction length, "Z",
    /// a space for the "T" and missing seconds are read too.
    static func date(iso: String) -> Date? {
        let pattern = #/(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?(Z|[+-]\d{2}(?::?\d{2})?)?/#
        guard let m = iso.trimmingCharacters(in: .whitespaces).wholeMatch(of: pattern) else { return nil }
        var parts = DateComponents()
        parts.year = Int(m.1); parts.month = Int(m.2); parts.day = Int(m.3)
        parts.hour = Int(m.4); parts.minute = Int(m.5); parts.second = m.6.flatMap { Int($0) } ?? 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        if let offset = m.8 {
            if offset == "Z" { calendar.timeZone = TimeZone(secondsFromGMT: 0)! } else {
                let digits = offset.dropFirst().filter(\.isNumber)
                let hours = Int(digits.prefix(2)) ?? 0, minutes = Int(digits.dropFirst(2)) ?? 0
                let seconds = (hours * 3600 + minutes * 60) * (offset.first == "-" ? -1 : 1)
                guard let zone = TimeZone(secondsFromGMT: seconds) else { return nil }
                calendar.timeZone = zone
            }
        }
        guard let date = calendar.date(from: parts) else { return nil }
        return date.addingTimeInterval(m.7.flatMap { Double("0.\($0)") } ?? 0)
    }

    /// The paths, relative to the location's folder, of the location's own files in the cloud.
    static func ownFiles(for location: Location, in listing: [CloudFile]) -> [String] {
        listing.filter { $0.hash != deletedMark && $0.name.hasPrefix(location.name + "/") }
            .map { String($0.name.dropFirst(location.name.count + 1)).replacingOccurrences(of: "\\", with: "/") }
    }

    /// Cloud files that gogdl picks up for `location` but that belong to another location.
    /// gogdl matches a location's files with `startswith(name)` (saves.py `is_in_our_dir`), so
    /// `saves` also picks up `saves_profiles/...`. It then requests them at the wrong path
    /// (`saves/saves_profiles/...`), where the download fails, and any delete it sends for them
    /// goes to that same wrong path and removes nothing.
    static func strays(for location: Location, in listing: [CloudFile]) -> [CloudFile] {
        listing.filter { $0.hash != deletedMark && $0.name.hasPrefix(location.name) && !$0.name.hasPrefix(location.name + "/") }
    }

    /// What one gogdl save-sync run reported.
    struct Run: Sendable {
        var status: Int32 = 0
        var downloadFailures = 0
        var otherFailures = 0
        var conflict = false
        var refused = false
        /// gogdl downloaded something.
        var downloaded = false
        /// gogdl downloaded every file in the listing: the folder was empty, or the download was forced.
        var downloadedAll = false
        var timestamp: String?
        var listing: [CloudFile]?

        mutating func note(_ line: String) {
            // A debug line can quote anything (file names, arguments): only the listing is read
            // from one.
            if GOGSaves.isDebug(line) {
                if let files = GOGSaves.cloudListing(in: line) { listing = files }
                return
            }
            if GOGSaves.isConflict(line) { conflict = true }
            if GOGSaves.isRefusal(line) { refused = true }
            if GOGSaves.isDownloadFailure(line) { downloadFailures += 1 } else if GOGSaves.isFailure(line) { otherFailures += 1 }
            if line.contains("No files locally, downloading") || line.contains("Forcing download") { downloaded = true; downloadedAll = true }
            if line.contains("Downloading files") { downloaded = true }
        }
    }

    /// The failures that can't be put down to strays. Each stray gogdl tried to download fails,
    /// so those failures are expected; any beyond them are this location's own files. Without a
    /// listing to check against, every failure counts.
    static func unexplainedFailures(_ run: Run, location: Location, folder: URL, since ts: Double) -> Int {
        guard run.downloadFailures > 0, run.downloaded, let listing = run.listing else { return run.downloadFailures + run.otherFailures }
        let tried = strays(for: location, in: listing).filter { stray in
            run.downloadedAll || (stray.modified.map { $0.timeIntervalSince1970 > ts } ?? false)
        }
        // A stray that did come down, at the path gogdl asked for, did not fail.
        let failed = tried.filter { !FileManager.default.fileExists(atPath: folder.appending(path: $0.name).path) }.count
        return max(0, run.downloadFailures - failed) + run.otherFailures
    }

    /// Whether a conflict gogdl reported comes from strays alone: none of this location's own
    /// cloud files changed since the last sync, but a stray did. Then only the Mac's saves
    /// changed, which makes it an upload.
    static func conflictIsOnlyStrays(_ run: Run, location: Location, since ts: Double) -> Bool {
        guard run.conflict, let listing = run.listing else { return false }
        func newer(_ file: CloudFile) -> Bool { file.modified.map { $0.timeIntervalSince1970 > ts } ?? true }
        let own = listing.filter { $0.hash != deletedMark && $0.name.hasPrefix(location.name + "/") }
        return !own.contains(where: newer) && strays(for: location, in: listing).contains(where: newer)
    }

    // MARK: Running gogdl

    var timestampsFile: URL { store.dir.appending(path: "saves.json") }

    func timestamps() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: timestampsFile))) ?? [:]
    }

    /// Read, change and write saves.json as one step: two games' syncs can end together.
    private static let timestampsLock = NSLock()
    private func updateTimestamps(_ change: (inout [String: String]) -> Void) {
        Self.timestampsLock.withLock {
            var all = timestamps()
            change(&all)
            store.secureDirectory()
            try? JSONEncoder().encode(all).write(to: timestampsFile, options: .atomic)
        }
    }

    /// When this install's saves last synced with GOG, across its locations: gogdl's timestamp,
    /// written when a sync moved or matched files (a refusal or a failure keeps the old one).
    /// nil when it never has.
    public func lastSynced(_ game: GOGStore.InstalledGame) -> Date? {
        let suffix = "@\(game.folder.standardizedFileURL.path)"
        return timestamps().filter { $0.key.hasPrefix(game.id + ".") && $0.key.hasSuffix(suffix) }
            .compactMap { Double($0.value).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } }.max()
    }

    /// Per install, not per game: the same game in two environments has two sets of saves, each
    /// with its own last sync.
    func key(_ game: GOGStore.InstalledGame, _ location: Location) -> String {
        "\(game.id).\(location.name)@\(game.folder.standardizedFileURL.path)"
    }

    /// `--debug` makes gogdl log the cloud listing (cloudListing). Debug lines stay out of
    /// Highball's log.
    static func arguments(folder: URL, id: String, location: Location, timestamp: String, direction: Direction) -> [String] {
        let flag: String
        switch direction {
        case .download: flag = "--skip-upload"
        case .upload: flag = "--skip-download"
        case .forceDownload: flag = "--force-download"
        case .forceUpload: flag = "--force-upload"
        }
        return ["save-sync", folder.path, id, "--os", "windows", "--ts", timestamp, "--name", location.name, "--debug", flag]
    }

    static func isDebug(_ line: String) -> Bool { line.contains("] DEBUG: ") }

    /// gogdl's only stdout is the new timestamp, a bare number written without a newline, so on
    /// the shared pipe it usually arrives glued to the log line after it ("1793193913.87[SAVES] INFO:
    /// Done"). Returns the number and what follows it.
    static func timestamp(in line: String) -> (String, String)? {
        guard let match = line.firstMatch(of: #/^\s*(\d+(?:\.\d+)?)/#),
              let value = Double(match.1), value > 0 else { return nil }
        return (String(match.1), String(line[match.range.upperBound...]))
    }

    /// gogdl's line for a conflict: it moved nothing.
    static func isConflict(_ line: String) -> Bool { line.contains("Files in conflict") }

    /// gogdl's line when it refuses the requested direction ("Refused to download files, newer
    /// files locally"). Nothing was transferred.
    static func isRefusal(_ line: String) -> Bool { line.contains("Refused to") }

    private func run(_ game: GOGStore.InstalledGame, location: Location, folder: URL, timestamp: String, direction: Direction,
                     onLine: (@Sendable (String) -> Void)? = nil) throws -> Run {
        let run = OSAllocatedUnfairLock(initialState: Run())
        // save-sync refreshes the game's own token into auth.json.
        let status = try store.withAuthFile {
            try store.runStreaming(Self.arguments(folder: folder, id: game.id, location: location, timestamp: timestamp, direction: direction)) { line in
                let stamp = Self.timestamp(in: line)
                let text = stamp?.1 ?? line
                run.withLock { if let stamp { $0.timestamp = stamp.0 }; $0.note(text) }
                if !text.isEmpty, !Self.isDebug(text) { onLine?(text) }
            }
        }
        return run.withLock { $0.status = status; return $0 }
    }

    /// Syncs one location. The new timestamp is kept only when something was decided.
    /// `keepBackups`: the backup made first is never pruned (the player picked a side in a
    /// conflict).
    public func sync(_ game: GOGStore.InstalledGame, location: Location, folder: URL, direction: Direction,
                     keepBackups: Bool = false, onLine: (@Sendable (String) -> Void)? = nil) -> Outcome {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ts = timestamps()[key(game, location)] ?? "0"
        // Back up whatever the sync could replace or delete, and stop if the backup fails: the
        // Mac's saves before a download, GOG's before an upload.
        do {
            switch direction {
            case .download, .forceDownload: try backUpLocal(game, location: location, folder: folder, kept: keepBackups)
            case .upload, .forceUpload: try backUpCloud(game, location: location, kept: keepBackups)
            }
        } catch {
            return .failed("the saves could not be backed up first (\(error.localizedDescription)), so nothing was synced")
        }
        var result: Run
        do {
            result = try run(game, location: location, folder: folder, timestamp: ts, direction: direction, onLine: onLine)
            if result.status == 0, Self.conflictIsOnlyStrays(result, location: location, since: Double(ts) ?? 0) {
                // Without the strays, only the Mac's saves changed: an upload, which a download
                // leaves for after the game. The cloud was backed up above.
                guard direction == .upload else { return .refused }
                result = try run(game, location: location, folder: folder, timestamp: ts, direction: .forceUpload, onLine: onLine)
            }
        } catch { return .failed(error.localizedDescription) }
        guard result.status == 0 else { return .failed("gogdl save-sync exited with \(result.status)") }
        // gogdl exits 0 even after failing to transfer a file, and still prints a new timestamp.
        // Saving that timestamp would make the next sync skip the failed file, so it isn't saved.
        if Self.unexplainedFailures(result, location: location, folder: folder, since: Double(ts) ?? 0) > 0 {
            return .failed("gogdl could not move every file")
        }
        if result.conflict { return .conflict }
        if result.refused { return .refused }
        if let new = result.timestamp {
            updateTimestamps { $0[key(game, location)] = new }
        }
        return .synced
    }

    // MARK: Putting saves back

    /// What an uninstall kept of a game's saves, so installing it again can put them back.
    public typealias KeptSaves = HighballKit.KeptSaves

    var keptSavesFile: KeptSavesFile { KeptSavesFile(url: store.dir.appending(path: "kept-saves.json")) }

    /// Every game's kept saves, by game id.
    public func keptSaves() -> [String: KeptSaves] { keptSavesFile.all() }

    /// Remembers the backups an uninstall kept of `game`, each with the folder it came from, in
    /// place of what an earlier uninstall kept (KeptSavesFile.keep). `otherInstalls` (copies of
    /// the game still in other environments) are never asked: they still have their own saves.
    public func keep(_ backups: [(name: String, folder: URL, backup: URL)], of game: GOGStore.InstalledGame,
                     otherInstalls: [URL]) {
        let entries = backups.map { KeptSaves.Entry(name: $0.name, path: $0.folder == game.folder ? "" : Self.relativePath(of: $0.folder, in: game.folder),
                                                    backup: $0.backup) }
        store.secureDirectory()
        keptSavesFile.keep(entries, for: game.id, otherInstalls: otherInstalls)
    }

    /// The install was asked about putting saves back: it is not asked again.
    public func markAsked(_ game: GOGStore.InstalledGame) {
        store.secureDirectory()
        keptSavesFile.markAsked(game.id, install: game.folder)
    }

    /// The kept saves to offer this install: nil when there are none or it was asked already.
    public static func toOffer(_ kept: KeptSaves?, to game: GOGStore.InstalledGame) -> KeptSaves? {
        KeptSavesFile.toOffer(kept, install: game.folder)
    }

    /// Puts kept saves back into an install of the game: each backup's files to the same place
    /// in the game's folder. A file already there is backed up first (kept), so a newer one is
    /// never lost. The game-folder files are dated now, so the next uninstall counts them as the
    /// game's. Returns how many files were put back; throws, having put back what it had, when a
    /// copy fails.
    @discardableResult
    public func putBack(_ kept: KeptSaves, into game: GOGStore.InstalledGame) throws -> Int {
        var count = 0
        for entry in kept.entries {
            guard let target = entry.folder(install: game.folder, environment: nil) else { continue }
            count += try SaveBackups.putBack(entry.backup, into: target, redate: entry.name == Self.gameFolder.name) { there in
                try backUpLocal(game, location: Location(name: entry.name, template: ""), folder: target, kept: true, only: there)
            }
        }
        return count
    }

    /// Forgets an install's sync history (uninstall), so a reinstall starts by asking the cloud.
    /// Other environments' copies of the game keep theirs.
    public func forget(_ game: GOGStore.InstalledGame) {
        let suffix = "@\(game.folder.standardizedFileURL.path)"
        updateTimestamps { all in all = all.filter { !($0.key.hasPrefix(game.id + ".") && $0.key.hasSuffix(suffix)) } }
    }
}

/// Reads the Python literals gogdl logs (lists, dicts, strings, numbers, None, True, False), as
/// `repr` writes them. Works on Unicode scalars, so a quote followed by a combining mark is still
/// a quote.
struct PythonLiteral {
    private let chars: [Unicode.Scalar]
    private var i = 0
    init(_ text: Substring) { chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars) }

    var atEnd: Bool { i == chars.count }

    private mutating func skipSpace() { while i < chars.count, chars[i].properties.isWhitespace { i += 1 } }

    /// The next value, or nil when the text isn't a literal this reads.
    mutating func value() -> Any? {
        skipSpace()
        guard i < chars.count else { return nil }
        switch chars[i] {
        case "[": return sequence(close: "]").map { $0 as Any }
        case "{":
            i += 1
            var dict: [String: Any] = [:]
            while true {
                skipSpace()
                if i < chars.count, chars[i] == "}" { i += 1; return dict }
                guard let key = value() as? String else { return nil }
                skipSpace()
                guard i < chars.count, chars[i] == ":" else { return nil }
                i += 1
                guard let v = value() else { return nil }
                dict[key] = v
                skipSpace()
                if i < chars.count, chars[i] == "," { i += 1 }
            }
        case "'", "\"": return string()
        default:
            let start = i
            while i < chars.count, !",]}:".unicodeScalars.contains(chars[i]), !chars[i].properties.isWhitespace { i += 1 }
            let word = String(String.UnicodeScalarView(chars[start..<i]))
            return word.isEmpty ? nil : word
        }
    }

    private mutating func sequence(close: Unicode.Scalar) -> [Any]? {
        i += 1
        var items: [Any] = []
        while true {
            skipSpace()
            if i < chars.count, chars[i] == close { i += 1; return items }
            guard let item = value() else { return nil }
            items.append(item)
            skipSpace()
            if i < chars.count, chars[i] == "," { i += 1 }
        }
    }

    private mutating func string() -> String? {
        let quote = chars[i]
        i += 1
        var out = ""
        while i < chars.count {
            let c = chars[i]
            i += 1
            if c == quote { return out }
            guard c == "\\" else { out.unicodeScalars.append(c); continue }
            guard i < chars.count else { return nil }
            let e = chars[i]
            i += 1
            switch e {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "x", "u", "U":
                let n = e == "x" ? 2 : e == "u" ? 4 : 8
                guard i + n <= chars.count, let code = UInt32(String(String.UnicodeScalarView(chars[i..<i + n])), radix: 16),
                      let scalar = Unicode.Scalar(code) else { return nil }
                out.unicodeScalars.append(scalar)
                i += n
            default: out.unicodeScalars.append(e)   // \\ \' \"
            }
        }
        return nil
    }
}
