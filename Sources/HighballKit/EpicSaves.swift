import Foundation
import os

/// Epic cloud saves, through legendary's `sync-saves`, before and after a Windows Epic game plays.
///
/// legendary decides by age alone: whichever of the newest local file and the newest cloud save is
/// newer wins, with no notion of both having changed (legendary/cli.py `sync_saves`). A download
/// empties the save folder first (`download_saves(clean_dir=True)`); an upload adds a save to
/// Epic's cloud, which keeps the earlier ones. So here:
/// - the folder legendary resolves (from the game's CloudSaveFolder, inside the environment's
///   registry) is copied before any download (SaveBackups), and a failed copy stops it;
/// - a download over saves changed since Highball last synced them is a conflict, asked, never
///   decided by age;
/// - an upload needs no copy: the cloud keeps what it had.
/// legendary runs with `-y` (it would otherwise stop at a question with no terminal to answer)
/// and `--accept-path` (to take the path it resolved).
public struct EpicSaves: Sendable {
    public let store: EpicStore
    public init(store: EpicStore) { self.store = store }

    public enum Direction: Sendable { case download, upload, forceDownload, forceUpload }

    public enum Outcome: Sendable, Equatable {
        case synced
        /// Saves changed on the Mac since the last sync, and the cloud has newer ones: nothing
        /// moved, the player chooses.
        case conflict
        case failed(String)
    }

    /// What legendary found, from its log; nil when it said nothing about this game (no cloud
    /// saves, or no save folder it could resolve).
    public enum State: Sendable, Equatable { case nothing, inStep, cloudNewer, localNewer }

    static func state(in lines: [String]) -> State? {
        for line in lines {
            if line.contains("No cloud or local savegame found") { return .nothing }
            if line.contains("is up to date") { return .inStep }
            if line.contains("Cloud save for"), line.contains("is newer") { return .cloudNewer }
            if line.contains("Local save for"), line.contains("is newer") { return .localNewer }
        }
        return nil
    }

    /// legendary's lines for something it could not do and carried on past.
    static func isFailure(_ line: String) -> Bool { line.contains(" ERROR: ") || line.contains(" CRITICAL: ") }

    static func arguments(app: String, direction: Direction?) -> [String] {
        let flags: [String]
        switch direction {
        case nil: flags = ["--skip-upload", "--skip-download"]   // only resolve the folder and compare
        case .download?: flags = ["--skip-upload"]
        case .upload?: flags = ["--skip-download"]
        case .forceDownload?: flags = ["--force-download"]
        case .forceUpload?: flags = ["--force-upload"]
        }
        return ["sync-saves", app, "-y", "--accept-path"] + flags
    }

    /// Whether the game's catalog item names a cloud save folder for Windows, from the metadata
    /// legendary keeps (metadata/<app>.json customAttributes.CloudSaveFolder).
    public func supportsCloudSaves(_ app: String) -> Bool {
        let file = store.configDir.appending(path: "metadata/\(app).json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let attributes = (obj["metadata"] as? [String: Any])?["customAttributes"] as? [String: Any],
              let folder = (attributes["CloudSaveFolder"] as? [String: Any])?["value"] as? String else { return false }
        return !folder.isEmpty
    }

    // MARK: Sync

    /// Copies kept before a download (SaveBackups), beside GOG's.
    public var backups: SaveBackups { SaveBackups(root: store.configDir.deletingLastPathComponent().appending(path: "save-backups", directoryHint: .isDirectory)) }

    var lastSyncsFile: URL { store.configDir.deletingLastPathComponent().appending(path: "epic-saves.json") }

    /// When each install's saves were last in step with the cloud: per install, like GOG's.
    func lastSyncs() -> [String: Date] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Date].self, from: Data(contentsOf: lastSyncsFile))) ?? [:]
    }

    private static let lastSyncsLock = NSLock()
    private func noteSynced(_ key: String) {
        Self.lastSyncsLock.withLock {
            var all = lastSyncs()
            all[key] = Date()
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            try? encoder.encode(all).write(to: lastSyncsFile, options: .atomic)
        }
    }

    /// Syncs a Windows Epic game's saves. `prefix` is the environment it is installed in, which
    /// legendary reads to resolve the save folder; `install` keys the backups and sync history.
    public func sync(_ app: String, install: URL, prefix: URL, direction: Direction,
                     onLine: (@Sendable (String) -> Void)? = nil) -> Outcome {
        let key = "\(app)@\(install.standardizedFileURL.path)"
        let environment = ["WINEPREFIX": prefix.path]
        // First, only where the saves are and which side is newer: nothing moves.
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let checked: Int32
        do {
            checked = try store.runStreaming(Self.arguments(app: app, direction: nil), environment: environment) { line in
                lines.withLock { $0.append(line) }
                onLine?(line)
            }
        } catch { return .failed(error.localizedDescription) }
        let log = lines.withLock { $0 }
        guard checked == 0, !log.contains(where: Self.isFailure) else { return .failed("legendary could not compare the saves") }
        guard let state = Self.state(in: log) else { return .failed("legendary found no save folder for this game") }
        guard let folder = (try? store.installedGames())?.first(where: { $0.app_name == app })?.save_path.map({ URL(fileURLWithPath: $0) })
        else { return .failed("legendary kept no save folder for this game") }

        let downloads: Bool
        switch Self.decide(state, direction: direction, lastChange: Self.latestChange(in: folder), lastSync: lastSyncs()[key]) {
        case .inStep: noteSynced(key); return .synced
        case .leave: return .synced
        case .conflict: return .conflict
        case .transfer(let download): downloads = download
        }
        if downloads {
            do { try backups.backUpLocal(folder, into: backups.folder("epic-\(app)", install: install)) } catch {
                return .failed("the saves could not be backed up first (\(error.localizedDescription)), so nothing was synced")
            }
        }
        let failed = OSAllocatedUnfairLock(initialState: false)
        let status: Int32
        do {
            status = try store.runStreaming(Self.arguments(app: app, direction: direction), environment: environment) { line in
                if Self.isFailure(line) { failed.withLock { $0 = true } }
                onLine?(line)
            }
        } catch { return .failed(error.localizedDescription) }
        guard status == 0, !failed.withLock({ $0 }) else { return .failed("legendary sync-saves did not finish (status \(status))") }
        noteSynced(key)
        return .synced
    }

    enum Decision: Equatable { case inStep, leave, conflict, transfer(download: Bool) }

    /// What a sync does once legendary has compared the two sides. A download over saves changed
    /// here since the last sync (or never synced) is a conflict: legendary would let the newer
    /// side win and empty the folder. Newer here before Play, or newer in the cloud after the
    /// game, is left for the other direction to take.
    static func decide(_ state: State, direction: Direction, lastChange: Date?, lastSync: Date?) -> Decision {
        switch direction {
        case .forceDownload: return .transfer(download: true)
        case .forceUpload: return .transfer(download: false)
        case .download:
            if state == .nothing || state == .inStep { return .inStep }
            guard state == .cloudNewer else { return .leave }
            let changedHere = lastChange.map { change in lastSync.map { change > $0.addingTimeInterval(60) } ?? true } ?? false
            return changedHere ? .conflict : .transfer(download: true)
        case .upload:
            if state == .nothing || state == .inStep { return .inStep }
            return state == .localNewer ? .transfer(download: false) : .leave
        }
    }

    /// The newest change among a folder's files, nil when it holds none.
    static func latestChange(in folder: URL) -> Date? {
        SaveBackups.files(in: folder).compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }
}
