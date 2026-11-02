import Darwin
import Foundation
import os

/// Epic cloud saves, through legendary's `sync-saves`, before and after an Epic game plays.
///
/// legendary 0.21.0 decides by age alone: it compares the newest local file with the newest cloud
/// save and lets the newer side win, with no notion of both sides having changed (cli.py
/// `sync_saves`, core.py `check_savegame_state`). A download first deletes the save folder's files
/// (`download_saves(clean_dir=True)`), and carries on and exits 0 when a manifest or chunk then
/// fails to download. An upload adds a new cloud save and ignores the status of each file it puts.
/// So Highball works around it:
/// - It records, per install, when the saves were last in step and which cloud save they matched.
///   A sync then knows which side changed since, and asks when both did, in either direction, or
///   when a first sync finds saves on both sides. Age alone never decides.
/// - Before a download, the files it would delete are backed up (SaveBackups), and a failed backup
///   stops it. A download that reports any failure, or after which legendary does not see the two
///   sides in step, is undone from that backup. A marker kept during the download undoes one that
///   was interrupted.
/// - After an upload, legendary must see a new cloud save in step with the Mac, or the upload
///   counts as failed.
/// - A save folder that holds more than one game's saves (the home folder, Documents, Application
///   Support, a whole install folder) is never synced: a download would empty it.
/// - A save folder legendary resolved for another environment is resolved again.
/// - Syncs of one game never overlap.
/// legendary runs with `-y` (it would otherwise stop at a question with no terminal to answer),
/// `--accept-path` (to take the save folder it resolves) and `-v` (its debug line carries the
/// cloud save's date in every case).
public struct EpicSaves: Sendable {
    public let store: EpicStore
    public init(store: EpicStore) { self.store = store }

    public enum Direction: Sendable { case download, upload, forceDownload, forceUpload }

    public enum Outcome: Sendable, Equatable {
        /// The two sides are in step, or one was copied to the other and checked.
        case synced
        /// Only the other side's direction has anything to do (newer saves on the Mac before Play,
        /// or newer saves in the cloud after it). Nothing moved.
        case left
        /// Both sides changed since the last sync, or a first sync found saves on both. Nothing
        /// moved; the player chooses.
        case conflict(firstSync: Bool)
        /// Nothing moved.
        case failed(String)
        /// A download failed partway, and the Mac's saves were put back from the backup.
        case restored(String)
    }

    /// What legendary found, from its log.
    public enum State: Sendable, Equatable { case nothing, inStep, cloudNewer, localNewer }

    /// One comparison: the state, and the date of the newest cloud save (as legendary names it,
    /// "yyyy-MM-dd HH:mm:ss" in UTC), nil when the cloud has none.
    public struct Check: Sendable, Equatable {
        public let state: State
        public let cloud: String?
        public init(state: State, cloud: String?) { self.state = state; self.cloud = cloud }
    }

    static func state(in lines: [String]) -> State? {
        for line in lines {
            if line.contains("No cloud or local savegame found") { return .nothing }
            if line.contains("is up to date") { return .inStep }
            if line.contains("Cloud save for"), line.contains("is newer") { return .cloudNewer }
            if line.contains("Local save for"), line.contains("is newer") { return .localNewer }
        }
        return nil
    }

    /// The newest cloud save's date. The debug line ("Remote save date: 2026-11-01 01:36:04+00:00")
    /// appears whenever both sides have saves; the info line ("- Cloud save date: …") covers the
    /// rest.
    static func cloudDate(in lines: [String]) -> String? {
        for line in lines {
            if let range = line.range(of: "Remote save date: ") {
                return String(line[range.upperBound...].prefix(19))
            }
        }
        for line in lines {
            if let range = line.range(of: "- Cloud save date: ") {
                let value = String(line[range.upperBound...].prefix(19))
                return value.hasPrefix("N/A") ? nil : value
            }
        }
        return nil
    }

    static func check(in lines: [String]) -> Check? {
        state(in: lines).map { Check(state: $0, cloud: $0 == .nothing ? nil : cloudDate(in: lines)) }
    }

    static func isDebug(_ line: String) -> Bool { line.contains("] DEBUG: ") }

    /// legendary's lines for something it could not do and carried on past. A download that
    /// skips a chunk or a file part only warns or errors and still "completes".
    static func isFailure(_ line: String) -> Bool {
        line.contains(" ERROR: ") || line.contains(" CRITICAL: ")
            || line.contains("may be incomplete") || line.contains("may have been corrupted")
    }

    /// Why a run told nothing about the game, in the player's terms, from legendary's log.
    static func explanation(_ lines: [String]) -> String {
        let all = lines.joined(separator: "\n")
        if all.contains("Login failed") { return "Highball's Epic sign-in has expired; sign in to Epic again" }
        if all.contains("Unable to lock install data") { return "legendary was busy with another task" }
        if all.contains("unprocessed variables") { return "legendary couldn't work out where this game keeps its saves on this Mac" }
        if all.contains("Game not installed") { return "legendary doesn't list this game as installed" }
        if all.contains("does not support cloud saves") { return "Epic lists no cloud saves for this game" }
        if let error = lines.first(where: isFailure) {
            return "legendary reported: " + (error.components(separatedBy: ": ").dropFirst().joined(separator: ": "))
        }
        return "legendary said nothing about this game's saves"
    }

    static func arguments(app: String, direction: Direction?) -> [String] {
        let flags: [String]
        switch direction {
        case nil: flags = ["--skip-upload", "--skip-download"]   // only resolve the folder and compare
        case .download?: flags = ["--skip-upload"]
        case .upload?: flags = ["--skip-download"]
        case .forceDownload?: flags = ["--force-download"]
        case .forceUpload?: flags = ["--force-upload"]
        }
        return ["-v", "sync-saves", app, "-y", "--accept-path"] + flags
    }

    // MARK: The catalog

    /// What Epic's catalog says about a game's cloud saves, from the metadata legendary keeps
    /// (metadata/<app>.json customAttributes).
    public struct Catalog: Sendable, Equatable {
        public let windowsFolder: String?
        public let macFolder: String?
        public let filter: SaveFilter
    }

    public func catalog(_ app: String) -> Catalog? {
        let file = store.configDir.appending(path: "metadata/\(app).json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let attributes = (obj["metadata"] as? [String: Any])?["customAttributes"] as? [String: Any] else { return nil }
        func value(_ key: String) -> String? { (attributes[key] as? [String: Any])?["value"] as? String }
        return Catalog(windowsFolder: value("CloudSaveFolder").flatMap { $0.isEmpty ? nil : $0 },
                       macFolder: value("CloudSaveFolder_MAC").flatMap { $0.isEmpty ? nil : $0 },
                       filter: SaveFilter(includeList: value("CloudIncludeList"), excludeList: value("CloudExcludeList")))
    }

    /// Whether the catalog names a cloud save folder for that build.
    public func supportsCloudSaves(_ app: String, mac: Bool = false) -> Bool {
        guard let catalog = catalog(app) else { return false }
        return (mac ? catalog.macFolder : catalog.windowsFolder) != nil
    }

    // MARK: Where the saves are

    var installedFile: URL { store.configDir.appending(path: "installed.json") }

    /// The save folder legendary stored for the game, read from its install records directly.
    public func savePath(_ app: String) -> URL? {
        guard let data = try? Data(contentsOf: installedFile),
              let all = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = (all[app] as? [String: Any])?["save_path"] as? String, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Forgets the save folder legendary stored, so its next run resolves it again. Holds
    /// legendary's own lock on its install records (installed.json.lock, the flock its filelock
    /// takes) while writing, and gives up when another legendary holds it.
    func forgetSavePath(_ app: String) throws {
        let lockPath = installedFile.path + ".lock"
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw HighballError.failed("couldn't open legendary's lock") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw HighballError.failed("legendary was busy with another task") }
        defer { flock(fd, LOCK_UN) }
        let data = try Data(contentsOf: installedFile)
        guard var all = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var game = all[app] as? [String: Any] else { return }
        game["save_path"] = NSNull()
        all[app] = game
        try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]).write(to: installedFile, options: .atomic)
    }

    /// Where a save folder may be: inside the environment, or in a Mac folder one of its user
    /// folders links to (Documents, by default, is ~/Documents). For a Mac build, anywhere in the
    /// home folder.
    static func allowedRoots(prefix: URL?, home: URL) -> [URL] {
        guard let prefix else { return [home] }
        var roots = [prefix]
        for user in UserFolders.userDirectories(driveC: prefix.appending(path: "drive_c")) {
            let entries = (try? FileManager.default.contentsOfDirectory(at: user, includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path) {
                    roots.append(URL(fileURLWithPath: target, relativeTo: user).standardizedFileURL)
                }
            }
        }
        return roots
    }

    /// A path's components with symlinks resolved, lowercased (APFS ignores case). Only an
    /// existing path resolves, so the nearest existing folder above it is resolved and the rest
    /// appended.
    static func components(_ url: URL) -> [String] {
        var existing = url.standardizedFileURL, rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return (existing.resolvingSymlinksInPath().pathComponents + rest).map { $0.lowercased() }
    }

    public static func isInside(_ path: URL, roots: [URL]) -> Bool {
        let parts = components(path)
        return roots.contains { parts.starts(with: components($0)) }
    }

    /// Why a save folder must not be synced, nil when it may. A download deletes every file in the
    /// folder that the game's filters pick (all of them, without filters), so a folder that holds
    /// more than the game's saves never syncs: the home folder and its usual folders, an
    /// environment's drive and user folders, and the game's install folder or anything above it
    /// (unless an include list limits the sync to the saves in it).
    static func refusal(for folder: URL, install: URL, prefix: URL?, home: URL, filter: SaveFilter) -> String? {
        let parts = components(folder)
        var shared = [home]
        shared += ["Documents", "Documents/My Games", "Desktop", "Downloads", "Music", "Pictures", "Movies",
                   "Library", "Library/Application Support", "Library/Preferences", "Library/Caches",
                   "Library/Containers", "Library/Group Containers", "Saved Games"].map { home.appending(path: $0) }
        if let prefix {
            let driveC = prefix.appending(path: "drive_c")
            shared += [prefix, driveC, driveC.appending(path: "users"), driveC.appending(path: "users/Public"),
                       driveC.appending(path: "users/Public/Documents"), driveC.appending(path: "ProgramData"),
                       driveC.appending(path: "Program Files"), driveC.appending(path: "Program Files (x86)"),
                       driveC.appending(path: "windows")]
            for user in UserFolders.userDirectories(driveC: driveC) {
                shared += [user] + ["AppData", "AppData/Local", "AppData/Roaming", "AppData/LocalLow", "Documents",
                                    "Documents/My Games", "Saved Games", "Desktop"].map { user.appending(path: $0) }
            }
        }
        let shown = (folder.path as NSString).abbreviatingWithTildeInPath
        let why = "Epic names \(shown) as this game's save folder, and it holds more than this game's saves, so Highball doesn't sync it: a download from Epic would empty it first"
        if shared.contains(where: { components($0) == parts }) { return why }
        // Above the home folder or an environment (/, /Users).
        if ([home] + (prefix.map { [$0] } ?? [])).contains(where: { components($0).starts(with: parts) }) { return why }
        let installParts = components(install)
        if installParts.starts(with: parts), parts != installParts || filter.include?.isEmpty != false { return why }
        return nil
    }

    // MARK: Sync history

    /// What Highball knows about an install's saves after its last sync.
    public struct Record: Codable, Sendable, Equatable {
        /// When the two sides were last in step.
        public var synced: Date
        /// The newest cloud save they matched then; nil in a record from before it was kept.
        public var cloud: String? = nil
        /// The save folder they were in.
        public var path: String? = nil
        /// A summary of the folder's saves then (SaveBackups.fingerprint): any change to them
        /// since, however soon after, changes it.
        public var local: String? = nil
        /// Set while a download runs: the backup to put back if it never finished ("" when the
        /// folder held no saves before it).
        public var restoring: String? = nil
    }

    /// Backups taken before a download (SaveBackups), next to GOG's.
    public var backups: SaveBackups { SaveBackups(root: store.configDir.deletingLastPathComponent().appending(path: "save-backups", directoryHint: .isDirectory)) }

    var recordsFile: URL { store.configDir.deletingLastPathComponent().appending(path: "epic-saves.json") }

    public func records() -> [String: Record] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: recordsFile) else { return [:] }
        if let records = try? decoder.decode([String: Record].self, from: data) { return records }
        // The first version kept only the date.
        let dates = (try? decoder.decode([String: Date].self, from: data)) ?? [:]
        return dates.mapValues { Record(synced: $0) }
    }

    private static let recordsLock = NSLock()
    func update(_ key: String, _ change: (inout Record?) -> Void) {
        Self.recordsLock.withLock {
            var all = records()
            var record = all[key]
            change(&record)
            all[key] = record
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            try? encoder.encode(all).write(to: recordsFile, options: .atomic)
        }
    }

    /// Drops a download's marker, and the whole record when the marker was all there was.
    func clearRestoring(_ key: String) {
        update(key) { record in
            record?.restoring = nil
            if record?.synced == .distantPast { record = nil }
        }
    }

    public static func key(app: String, install: URL) -> String { "\(app)@\(install.standardizedFileURL.path)" }

    // MARK: Deciding

    public enum Decision: Sendable, Equatable { case inStep, leave, conflict(firstSync: Bool), transfer(download: Bool) }

    /// What a sync does once legendary has compared the two sides, from what changed on each
    /// since the record: never the age alone. With no record, a side with saves counts as changed.
    static func decide(_ check: Check, direction: Direction, record: Record?, lastChange: Date?, hasLocal: Bool,
                       fingerprint: String? = nil) -> Decision {
        switch direction {
        case .forceDownload: return .transfer(download: true)
        case .forceUpload: return .transfer(download: false)
        case .download, .upload: break
        }
        if check.state == .nothing || check.state == .inStep { return .inStep }
        let cloudChanged: Bool
        let localChanged: Bool
        if let record {
            if let seen = record.cloud {
                cloudChanged = check.cloud != seen
            } else {
                // A record from before the cloud save was kept: a cloud save newer than the sync
                // (beyond legendary's 60 seconds) came from elsewhere.
                cloudChanged = check.cloud.flatMap(Self.date(legendary:)).map { $0 > record.synced.addingTimeInterval(60) } ?? false
            }
            if let then = record.local, let now = fingerprint {
                localChanged = then != now
            } else {
                localChanged = lastChange.map { $0 > record.synced.addingTimeInterval(60) } ?? false
            }
        } else {
            cloudChanged = check.cloud != nil
            localChanged = hasLocal
        }
        if cloudChanged && localChanged && hasLocal && check.cloud != nil { return .conflict(firstSync: record == nil) }
        switch direction {
        case .download:
            // Also with nothing here to lose: saves deleted on the Mac come back.
            return cloudChanged || (!hasLocal && check.cloud != nil) ? .transfer(download: true) : .leave
        default:
            return localChanged || (hasLocal && check.cloud == nil) ? .transfer(download: false) : .leave
        }
    }

    static func date(legendary: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: legendary)
    }

    static func latestChange(of files: [URL]) -> Date? {
        files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    // MARK: Sync

    /// One lock per game: a sync that starts while another runs (an upload still going when
    /// Play is pressed again) waits for it.
    private static let gameLocks = OSAllocatedUnfairLock(initialState: [String: NSLock]())
    static func lock(for app: String) -> NSLock {
        gameLocks.withLock { locks in
            if let lock = locks[app] { return lock }
            let lock = NSLock(); locks[app] = lock
            return lock
        }
    }

    private struct Run { var status: Int32; var lines: [String] }

    private func run(_ app: String, direction: Direction?, environment: [String: String],
                     onLine: (@Sendable (String) -> Void)?) throws -> Run {
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let status = try store.runStreaming(Self.arguments(app: app, direction: direction), environment: environment) { line in
            lines.withLock { $0.append(line) }
            if !Self.isDebug(line) { onLine?(line) }
        }
        return Run(status: status, lines: lines.withLock { $0 })
    }

    enum Compared { case success(Check), failure(String) }

    func compare(_ app: String, environment: [String: String], onLine: (@Sendable (String) -> Void)?) -> Compared {
        do {
            let result = try run(app, direction: nil, environment: environment, onLine: onLine)
            guard result.status == 0, !result.lines.contains(where: Self.isFailure), let check = Self.check(in: result.lines) else {
                return .failure(Self.explanation(result.lines))
            }
            return .success(check)
        } catch { return .failure(error.localizedDescription) }
    }

    /// Syncs an Epic game's saves. `prefix` is the environment a Windows build is installed in,
    /// which legendary reads to resolve the save folder; nil for a Mac build, whose folder it
    /// resolves under the home folder. `install` keys the backups and the sync history.
    /// `keepBackups` makes the backup a kept one, never pruned: for the sync the player chose in
    /// a conflict.
    public func sync(_ app: String, install: URL, prefix: URL?, direction: Direction, keepBackups: Bool = false,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     onLine: (@Sendable (String) -> Void)? = nil) -> Outcome {
        let gameLock = Self.lock(for: app)
        gameLock.lock()
        defer { gameLock.unlock() }

        let key = Self.key(app: app, install: install)
        let environment = prefix.map { ["WINEPREFIX": $0.path] } ?? [:]
        let filter = catalog(app)?.filter ?? .everything
        let backupDir = backups.folder("epic-\(app)", install: install)

        // A download that never finished: its backup goes back first.
        if let pending = records()[key]?.restoring, let folder = savePath(app) {
            do {
                let backup = pending.isEmpty ? nil : URL(fileURLWithPath: pending)
                try SaveBackups.restore(backup, into: folder, filter: filter)
                if let backup { SaveBackups.unpin(backup) }
                clearRestoring(key)
                onLine?("Highball: an earlier download of these saves didn't finish, so this Mac's saves were put back from their backup")
            } catch {
                return .failed("an earlier download didn't finish, and the saves couldn't be put back from \((pending as NSString).abbreviatingWithTildeInPath) (\(error.localizedDescription))")
            }
        }

        // A save folder resolved for another environment (the game moved) is resolved again.
        if let stored = savePath(app), !Self.isInside(stored, roots: Self.allowedRoots(prefix: prefix, home: home)) {
            do { try forgetSavePath(app) } catch { return .failed(error.localizedDescription) }
            onLine?("Highball: the save folder legendary had for this game is outside its environment, so it is worked out again")
        }

        let before: Check
        switch compare(app, environment: environment, onLine: onLine) {
        case .success(let check): before = check
        case .failure(let why): return .failed(why)
        }
        guard let folder = savePath(app) else { return .failed("legendary kept no save folder for this game") }
        if let why = Self.refusal(for: folder, install: install, prefix: prefix, home: home, filter: filter) { return .failed(why) }

        // History for another folder doesn't describe this one: a first sync.
        var record = records()[key]
        if let path = record?.path, path != folder.path { record = nil }
        if record?.synced == .distantPast { record = nil }   // only a download's marker, never synced
        let local = SaveBackups.files(in: folder, matching: filter)
        let decision = Self.decide(before, direction: direction, record: record, lastChange: Self.latestChange(of: local),
                                   hasLocal: !local.isEmpty, fingerprint: SaveBackups.fingerprint(folder, filter: filter))
        func noteSynced(_ cloud: String?) {
            let fingerprint = SaveBackups.fingerprint(folder, filter: filter)
            update(key) { $0 = Record(synced: Date(), cloud: cloud, path: folder.path, local: fingerprint) }
        }
        switch decision {
        case .inStep:
            noteSynced(before.cloud)
            return .synced
        case .leave:
            return .left
        case .conflict(let first):
            return .conflict(firstSync: first)
        case .transfer(download: true):
            return download(app, folder: folder, filter: filter, backupDir: backupDir, key: key, kept: keepBackups,
                            before: before, environment: environment, onLine: onLine, noteSynced: noteSynced)
        case .transfer(download: false):
            let upload: Run
            // Forced: Highball decided from what changed, and legendary's age check could
            // otherwise skip it (a Mac clock behind, or legendary's DST slip).
            do { upload = try run(app, direction: .forceUpload, environment: environment, onLine: onLine) } catch {
                return .failed(error.localizedDescription)
            }
            guard upload.status == 0, !upload.lines.contains(where: Self.isFailure) else {
                return .failed("the upload to Epic didn't finish (\(Self.explanation(upload.lines)))")
            }
            if upload.lines.contains(where: { $0.contains("No files to upload") }) {
                return .failed("none of the files in the save folder match what Epic syncs for this game")
            }
            // legendary ignores whether each file reached Epic: a new cloud save, in step with
            // the Mac, is what shows it did.
            guard case .success(let after) = compare(app, environment: environment, onLine: onLine),
                  after.state == .inStep, let cloud = after.cloud, cloud != before.cloud else {
                return .failed("Highball couldn't confirm that Epic's cloud received the saves")
            }
            noteSynced(cloud)
            return .synced
        }
    }

    private func download(_ app: String, folder: URL, filter: SaveFilter, backupDir: URL, key: String, kept: Bool,
                          before: Check, environment: [String: String], onLine: (@Sendable (String) -> Void)?,
                          noteSynced: (String?) -> Void) -> Outcome {
        let backup: URL?
        do {
            backup = try backups.backUpLocal(folder, into: backupDir, filter: filter, kept: kept)
            // Pinned until the download is done or undone, so no backup made meanwhile prunes it.
            if let backup { try SaveBackups.pin(backup) }
        } catch {
            return .failed("the saves couldn't be backed up first (\(error.localizedDescription)), so nothing was synced")
        }
        update(key) { record in
            if record == nil { record = Record(synced: .distantPast, cloud: nil, path: folder.path) }
            record?.restoring = backup?.path ?? ""
        }
        var problem: String?
        do {
            let result = try run(app, direction: .forceDownload, environment: environment, onLine: onLine)
            if result.status != 0 || result.lines.contains(where: Self.isFailure) {
                problem = Self.explanation(result.lines)
            } else if case .success(let after) = compare(app, environment: environment, onLine: onLine) {
                if after.state != .inStep || after.cloud != before.cloud { problem = "legendary doesn't see the saves in step afterwards" }
                else if SaveBackups.files(in: folder, matching: filter).isEmpty { problem = "no saves came down" }
            } else {
                problem = "legendary couldn't compare the saves afterwards"
            }
        } catch { problem = error.localizedDescription }

        guard let problem else {
            if let backup { SaveBackups.unpin(backup) }
            noteSynced(before.cloud)
            return .synced
        }
        do {
            try SaveBackups.restore(backup, into: folder, filter: filter)
            if let backup { SaveBackups.unpin(backup) }
            clearRestoring(key)
        } catch {
            return .failed("the download from Epic failed (\(problem)), and the saves couldn't be put back automatically; their backup is in \(((backup?.path ?? backupDir.path) as NSString).abbreviatingWithTildeInPath)")
        }
        return .restored(problem)
    }
}

// MARK: Uninstalling and putting saves back

extension EpicSaves {
    /// When Highball first installed a game into an environment through legendary and when it
    /// installed over it again (an update or a repair), so an uninstall can tell the files the
    /// game wrote in its folder from legendary's (GameInstallHistory). Kept in the environment,
    /// like GOG's next to its setup marker; removed with the game.
    public static func historyFile(app: String, driveC: URL) -> URL {
        driveC.appending(path: "highball/epic-installs/\(app).history.json")
    }

    /// An install from before the history was kept has none: nothing tells its files apart.
    public static func history(app: String, driveC: URL) -> GameInstallHistory {
        GameInstallHistory.read(historyFile(app: app, driveC: driveC)) ?? GameInstallHistory()
    }

    /// A legendary install of the game into the environment ran from `start` to `end`. The first
    /// one that `finished` starts the history at its end; after that each run, finished or not,
    /// is a window whose changes are legendary's.
    public static func recordInstall(app: String, driveC: URL, start: Date, end: Date, finished: Bool) {
        var history = history(app: app, driveC: driveC)
        if history.firstSetup != nil {
            history.updates.append(.init(start: start, end: end))
        } else if finished {
            history.firstSetup = end
        } else {
            return
        }
        history.write(to: historyFile(app: app, driveC: driveC))
    }

    /// The game moved to another environment: its history goes with it.
    public static func moveHistory(app: String, from: URL, to: URL) {
        let source = historyFile(app: app, driveC: from), target = historyFile(app: app, driveC: to)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: source, to: target)
    }

    public static func forgetHistory(app: String, driveC: URL) {
        try? FileManager.default.removeItem(at: historyFile(app: app, driveC: driveC))
    }

    /// The kept copy of the save folder, and of what the game wrote in its install folder.
    public static let savesName = "saves"
    public static let gameFolderName = "game-folder"

    func backupFolder(_ app: String, _ name: String, install: URL) -> URL {
        // The save folder's kept copies sit with its sync backups, so an unchanged one is reused.
        backups.folder(name == Self.gameFolderName ? "epic-\(app)-\(name)" : "epic-\(app)", install: install)
    }

    /// The save folder an uninstall deals with: the one legendary stored, when it lies in the
    /// environment, a Mac folder its user folders link to, or the install folder (where sync
    /// would look), and isn't one sync refuses for holding more than this game's saves. With
    /// `resolve`, a game whose folder legendary hasn't worked out yet (or worked out for another
    /// environment) has it resolve the folder, comparing without moving anything, as a sync
    /// starts. nil when there is none.
    public func uninstallSaveFolder(_ app: String, install: URL, prefix: URL, resolve: Bool,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                    onLine: (@Sendable (String) -> Void)? = nil) -> URL? {
        let roots = Self.allowedRoots(prefix: prefix, home: home) + [install]
        func usable(_ folder: URL?) -> URL? {
            guard let folder, Self.isInside(folder, roots: roots),
                  Self.refusal(for: folder, install: install, prefix: prefix, home: home, filter: catalog(app)?.filter ?? .everything) == nil
            else { return nil }
            return folder
        }
        if let folder = usable(savePath(app)) { return folder }
        guard resolve, supportsCloudSaves(app) else { return nil }
        let gameLock = Self.lock(for: app)
        gameLock.lock()
        defer { gameLock.unlock() }
        if let stored = savePath(app), !Self.isInside(stored, roots: roots) {
            guard (try? forgetSavePath(app)) != nil else { return nil }
        }
        guard case .success = compare(app, environment: ["WINEPREFIX": prefix.path], onLine: onLine) else { return nil }
        return usable(savePath(app))
    }

    /// How an uninstall tells the files the game wrote in its install folder from the ones
    /// legendary put down.
    public struct GameFiles: Sendable, Equatable {
        /// The files legendary's installed manifests name there (the game's and its DLC's, which
        /// share the folder), lowercased: Windows names ignore case. nil when it had none.
        public let installed: Set<String>?
        /// When Highball installed the game and ran legendary over it (no firstSetup for an
        /// install from before the history was kept).
        public let history: GameInstallHistory

        /// A file no manifest names is the game's; so is one changed after Highball installed the
        /// game outside legendary's runs (a config the game rewrote).
        public func isGameWritten(_ relativePath: String, changed: Date?) -> Bool {
            if let installed, !installed.contains(relativePath.lowercased()) { return true }
            return history.isGameWritten(changed ?? .distantPast)
        }
    }

    /// What tells the game's files in its install folder apart: legendary's manifests, while the
    /// game is installed, and the install history. nil when there is neither, and then nothing
    /// in the install folder can be copied as the game's.
    public func gameFiles(_ app: String, install: URL, prefix: URL) -> GameFiles? {
        let history = Self.history(app: app, driveC: prefix.appending(path: "drive_c"))
        let installed = manifestFiles(app, install: install)
        guard installed != nil || history.firstSetup != nil else { return nil }
        return GameFiles(installed: installed, history: history)
    }

    /// The files legendary's manifests name in the install folder, for the game and every DLC
    /// legendary records in the same folder. nil when any of them can't be listed, or names none
    /// of the files on disk (an encrypted manifest lists obfuscated names), so the installer's
    /// files are never taken for the game's.
    func manifestFiles(_ app: String, install: URL) -> Set<String>? {
        let path = install.standardizedFileURL.path
        let sharing = (store.installRecords() ?? [:]).filter { URL(fileURLWithPath: $0.value).standardizedFileURL.path == path }.keys
        let onDisk = Set(SaveBackups.files(in: install).map { SaveBackups.relativePath($0, in: install).lowercased() })
        var names = Set<String>()
        for each in Set(sharing).union([app]).sorted() {
            guard let files = try? store.installedFiles(each) else { return nil }
            let listed = Set(files.map { $0.replacingOccurrences(of: "\\", with: "/").lowercased() })
            guard !listed.isDisjoint(with: onDisk) else { return nil }
            names.formUnion(listed)
        }
        return names
    }

    /// Before an uninstall, copies as kept backups (never pruned): the save folder's files the
    /// catalog's include and exclude lists pick, when `saveFolder` is given, and every file the
    /// game wrote in its install folder (gameFiles), leaving out the save folder. Nothing tells
    /// them apart: no install-folder copy. Returns what was kept, each with where it came from;
    /// throws when a copy fails, and the uninstall must then stop.
    public func backUpForUninstall(_ app: String, install: URL, prefix: URL, saveFolder: URL?) throws -> [KeptSaves.Entry] {
        try backUpForUninstall(app, install: install, prefix: prefix, saveFolder: saveFolder,
                               gameFiles: gameFiles(app, install: install, prefix: prefix))
    }

    /// The same, with what gameFiles found (an uninstall asks first when it is nil).
    public func backUpForUninstall(_ app: String, install: URL, prefix: URL, saveFolder: URL?,
                                   gameFiles: GameFiles?) throws -> [KeptSaves.Entry] {
        var kept: [KeptSaves.Entry] = []
        if let saveFolder,
           let copy = try backups.backUpLocal(saveFolder, into: backupFolder(app, Self.savesName, install: install),
                                              filter: catalog(app)?.filter ?? .everything, kept: true) {
            kept.append(KeptSaves.Entry(name: Self.savesName, folder: saveFolder, backup: copy, install: install, environment: prefix))
        }
        guard let gameFiles else { return kept }
        let skipped = saveFolder.map { $0.standardizedFileURL.path + "/" }
        let written = try SaveBackups.walk(install).filter { file in
            guard skipped.map({ !file.standardizedFileURL.path.hasPrefix($0) }) ?? true else { return false }
            let changed = try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return gameFiles.isGameWritten(SaveBackups.relativePath(file, in: install), changed: changed)
        }
        if !written.isEmpty,
           let copy = try backups.backUpLocal(install, into: backupFolder(app, Self.gameFolderName, install: install), kept: true, only: written) {
            kept.append(KeptSaves.Entry(name: Self.gameFolderName, path: "", backup: copy, place: .game))
        }
        return kept
    }

    /// For a player who asked for the saves to go with the game: deletes the save folder (only
    /// the files the include and exclude lists pick, when the catalog has them) when, links
    /// followed, it lies inside the environment's drive_c and neither holds nor sits inside
    /// Highball's save-backups, nor holds the install folder. One inside the install folder is
    /// deleted too: legendary deletes only the files it installed, so the saves stay otherwise.
    /// Returns whether it was deleted.
    public func removeSaves(_ app: String, folder: URL, install: URL, prefix: URL) -> Bool {
        let inInstall = Self.isInside(folder, roots: [install]) && Self.components(folder) != Self.components(install)
        guard FileManager.default.fileExists(atPath: folder.path),
              SaveBackups.mayDelete(folder, driveC: prefix.appending(path: "drive_c"),
                                    sparing: inInstall ? [backups.root] : [backups.root, install]) else { return false }
        let filter = catalog(app)?.filter ?? .everything
        if filter.isEverything { return (try? FileManager.default.removeItem(at: folder)) != nil }
        for file in SaveBackups.files(in: folder, matching: filter) {
            guard (try? FileManager.default.removeItem(at: file)) != nil else { return false }
        }
        return true
    }

    /// legendary leaves an uninstalled game's folder behind when anything it didn't install is in
    /// it (a log, a config, a save), and installing the game there again then fails. Once its
    /// record is gone and what was worth keeping is copied, the folder goes too, but only one at
    /// least two levels inside the environment's drive_c, never under its users or windows
    /// folders, holding no game legendary still has installed, and never Highball's
    /// save-backups. Whether it was removed.
    public func removeLeftover(_ install: URL, prefix: URL, stillInstalled: [URL]) -> Bool {
        let driveC = prefix.appending(path: "drive_c")
        let inside = Self.components(install).dropFirst(Self.components(driveC).count).map { $0.lowercased() }
        guard FileManager.default.fileExists(atPath: install.path), inside.count >= 2,
              !["users", "windows"].contains(inside[0]),
              !stillInstalled.contains(where: { Self.isInside($0, roots: [install]) }),
              SaveBackups.mayDelete(install, driveC: driveC, sparing: [backups.root]) else { return false }
        return (try? FileManager.default.removeItem(at: install)) != nil
    }

    var keptSavesFile: KeptSavesFile { KeptSavesFile(url: store.configDir.deletingLastPathComponent().appending(path: "epic-kept-saves.json")) }

    /// Remembers what an uninstall kept of the game, in place of what an earlier one kept.
    /// legendary installs a game once, so there is no other install to leave out.
    public func keep(_ entries: [KeptSaves.Entry], of app: String) {
        keptSavesFile.keep(entries, for: app, otherInstalls: [])
    }

    public func keptSaves() -> [String: KeptSaves] { keptSavesFile.all() }

    public func markAsked(_ app: String, install: URL) { keptSavesFile.markAsked(app, install: install) }

    /// Puts kept saves back into a new install of the game: the save folder's to the same place in
    /// the environment (or the install folder, or the Mac folder it was in), the game-folder copy
    /// to the same paths in the install folder, dated now so the next uninstall counts them as the
    /// game's. A file already there is backed up first (kept). Returns how many files were put
    /// back; throws, having put back what it had, when a copy fails.
    @discardableResult
    public func putBack(_ kept: KeptSaves, app: String, install: URL, prefix: URL) throws -> Int {
        var count = 0
        for entry in kept.entries {
            guard let target = entry.folder(install: install, environment: prefix) else { continue }
            count += try SaveBackups.putBack(entry.backup, into: target, redate: entry.name == Self.gameFolderName) { there in
                try backups.backUpLocal(target, into: backupFolder(app, entry.name, install: install), kept: true, only: there)
            }
        }
        return count
    }
}
