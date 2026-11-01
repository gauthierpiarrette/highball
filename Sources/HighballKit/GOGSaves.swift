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
        /// Another of the game's locations has a name that starts with this one's (saves and
        /// saves_profiles). gogdl picks a location's cloud files by that prefix alone (saves.py,
        /// is_in_our_dir), so it also lists the other one's, asks for them under this name, and
        /// logs "Downloading file failed" for each, naming no file: here that line says nothing
        /// about this location's own files.
        public var sharesItsPrefix = false
    }

    /// The client id cloud storage is keyed by: the info file's, else the manifest gogdl kept
    /// (Control's info file has none; its manifest does), else GOG's latest build manifest for an
    /// install with neither (an offline installer, a gogdl install from elsewhere), remembered.
    /// Nil when the game has none: GOG's own manifest names none (Beyond Good & Evil's), and gogdl
    /// cannot sync such a game either. Throws when GOG could not be asked, which says nothing.
    public func clientID(for game: GOGStore.InstalledGame) throws -> String? {
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

    /// The client id in the newest Windows build's manifest, nil when GOG has none for the game
    /// (no Windows build, or a manifest that names none). The build list and manifests are public;
    /// a v2 manifest is zlib-compressed JSON. Throws when either cannot be fetched or read.
    static func publishedClientID(productID: String) throws -> String? {
        let list = URL(string: "https://content-system.gog.com/products/\(productID)/os/windows/builds?generation=2")!
        guard let link = try newestBuild(inBuildList: GOGStore.fetch(URLRequest(url: list))) else { return nil }
        return try clientID(inPublishedManifest: GOGStore.fetch(URLRequest(url: link)))
    }

    /// The newest build's manifest address, nil for a game with no build for Windows.
    static func newestBuild(inBuildList data: Data) throws -> URL? {
        guard let builds = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = builds["items"] as? [[String: Any]] else { throw HighballError.invalid("GOG's build list could not be read") }
        guard let newest = items.first else { return nil }
        guard let link = (newest["link"] as? String).flatMap(URL.init(string:)) else { throw HighballError.invalid("GOG's build list names no manifest") }
        return link
    }

    /// A manifest GOG served: its client id, nil when it names none. Throws when it cannot be read,
    /// as that is no answer.
    static func clientID(inPublishedManifest data: Data) throws -> String? {
        guard let obj = manifestObject(data) else { throw HighballError.invalid("GOG's build manifest could not be read") }
        return obj["clientId"] as? String
    }

    static func clientID(inManifest data: Data) -> String? { manifestObject(data)?["clientId"] as? String }

    private static func manifestObject(_ data: Data) -> [String: Any]? {
        // zlib = a 2-byte header, raw DEFLATE, then a checksum; Foundation's .zlib reads raw DEFLATE.
        let json = data.first == 0x78 ? (try? (data.dropFirst(2) as NSData).decompressed(using: .zlib) as Data) : data
        guard let json, let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        return obj
    }

    /// Where the game keeps its cloud saves: none for a game with no client id or with cloud saves
    /// off, both answers from GOG. Throws when GOG could not be asked: then nobody can say.
    public func cloudLocations(for game: GOGStore.InstalledGame) throws -> [Location] {
        guard let client = try clientID(for: game) else { return [] }
        return try locations(clientID: client) ?? []
    }

    /// Where the game keeps its saves, nil when it has no cloud saves. An empty list from GOG means
    /// the SDK's own storage folder, which Galaxy names __default.
    public func locations(clientID: String) throws -> [Location]? {
        let url = URL(string: "https://remote-config.gog.com/components/galaxy_client/clients/\(clientID)?component_version=2.0.45")!
        let data = try GOGStore.fetch(URLRequest(url: url))
        return Self.parseLocations(data, clientID: clientID)
    }

    static func parseLocations(_ data: Data, clientID: String) -> [Location]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = (obj["content"] as? [String: Any])?["Windows"] as? [String: Any],
              let cloud = windows["cloudStorage"] as? [String: Any], cloud["enabled"] as? Bool == true else { return nil }
        let named = (cloud["locations"] as? [[String: Any]] ?? []).compactMap { l -> Location? in
            guard let name = l["name"] as? String, let location = l["location"] as? String else { return nil }
            return Location(name: name, template: location)
        }
        let list = named.map { l in
            Location(name: l.name, template: l.template,
                     sharesItsPrefix: named.contains { $0.name != l.name && $0.name.hasPrefix(l.name) })
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

    // MARK: Sync

    public enum Direction: Sendable { case download, upload, forceDownload, forceUpload }

    public enum Outcome: Sendable, Equatable {
        case synced
        /// Both sides changed since the last sync, or neither was synced before and both hold saves:
        /// nothing moved, the player chooses.
        case conflict
        /// gogdl refused the one direction asked for (newer files on the other side): nothing moved.
        case refused
        case failed(String)
    }

    // MARK: Never losing a save

    /// Copies of saves taken before a sync could replace them, in the Highball folder:
    /// save-backups/<game id>-<location>-<install>/<date>-<mac|cloud>/. gogdl replaces both ways,
    /// and deletes what the other side lacks: a download deletes local files the cloud lacks, an
    /// upload cloud files the Mac lacks. The newest `keep` copies per install and location stay.
    public var backupsDir: URL { store.dir.deletingLastPathComponent().appending(path: "save-backups", directoryHint: .isDirectory) }
    static let keep = 10

    /// One install's backups of one location: the install is in the name, as sync history is kept
    /// per install, so a second copy of the game never rotates out the first one's backups.
    func backupsFolder(_ game: GOGStore.InstalledGame, _ location: Location) -> URL {
        // FNV-1a over the install's path: short, and the same from one run to the next.
        let hash = game.folder.standardizedFileURL.path.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        return backupsDir.appending(path: "\(game.id)-\(location.name)-\(String(hash, radix: 16).prefix(8))", directoryHint: .isDirectory)
    }

    private func newBackup(in dir: URL, label: String) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        var name = "\(stamp)-\(label)", n = 1
        while FileManager.default.fileExists(atPath: dir.appending(path: name).path) { n += 1; name = "\(stamp)-\(label)-\(n)" }
        return dir.appending(path: name, directoryHint: .isDirectory)
    }

    /// Every file a sync sees: gogdl lists hidden files and links too, and replaces or deletes them.
    static func files(in folder: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys))
        var files: [URL] = []
        while let file = walker?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: keys)
            if values?.isRegularFile == true || values?.isSymbolicLink == true { files.append(file) }
        }
        return files
    }

    /// What a folder holds, in brief (files, bytes, latest change): two equal mean a new copy would
    /// only repeat the last one.
    static func fingerprint(_ folder: URL) -> String {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let values = files(in: folder).map { try? $0.resourceValues(forKeys: keys) }
        let bytes = values.reduce(0) { $0 + ($1?.fileSize ?? 0) }
        let latest = values.compactMap { $0?.contentModificationDate?.timeIntervalSince1970 }.max() ?? 0
        return "\(values.count) \(bytes) \(latest)"
    }


    /// A copy of the saves on the Mac, before a download could replace them: the newest copy when
    /// nothing changed since it, nil when there is nothing to copy. Throws when the copy fails, and
    /// leaves no half copy behind: then nothing may replace them.
    @discardableResult
    public func backUpLocal(_ game: GOGStore.InstalledGame, location: Location, folder: URL) throws -> URL? {
        guard !Self.files(in: folder).isEmpty else { return nil }
        let dir = backupsFolder(game, location)
        let fingerprint = Self.fingerprint(folder)
        if let newest = backups(in: dir).first, (try? String(contentsOf: Self.fingerprintFile(of: newest), encoding: .utf8)) == fingerprint {
            return newest
        }
        let target = try finish(newBackup(in: dir, label: "mac")) { partial in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: folder, to: partial)
        }
        try? fingerprint.write(to: Self.fingerprintFile(of: target), atomically: true, encoding: .utf8)
        return target
    }

    /// Beside a copy, not in it: a copy restored by hand never carries it into the game's folder,
    /// where gogdl would upload it with the saves.
    static func fingerprintFile(of backup: URL) -> URL {
        backup.deletingLastPathComponent().appending(path: backup.lastPathComponent + ".fingerprint")
    }

    /// A copy of GOG's cloud saves, before an upload could replace them: gogdl downloads the cloud
    /// into a fresh folder of the backups (with nothing there, it only downloads), which touches
    /// neither the cloud nor the game's folder. A file it fails to fetch fails the whole copy, as
    /// gogdl itself still exits 0. Throws when it fails: then nothing may replace the cloud's.
    @discardableResult
    public func backUpCloud(_ game: GOGStore.InstalledGame, location: Location) throws -> URL {
        let dir = backupsFolder(game, location)
        return try finish(newBackup(in: dir, label: "cloud")) { partial in
            try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
            let failed = OSAllocatedUnfairLock(initialState: false)
            let status = try store.withAuthFile {
                try store.runStreaming(Self.arguments(folder: partial, id: game.id, location: location, timestamp: "0", direction: .forceDownload)) { line in
                    if Self.isFailure(line, location: location) { failed.withLock { $0 = true } }
                }
            }
            guard status == 0, !failed.withLock({ $0 }) else {
                throw HighballError.failed("gogdl could not copy all of GOG's cloud saves (status \(status))")
            }
        }
    }

    /// gogdl's lines for a file it could not move, or an error it logs and carries on past. Its
    /// "Downloading file failed" names no file, so for a location whose name another one's starts
    /// with it may be one of the other location's files, asked for at the wrong path, and does
    /// not count (the other location's own sync fetches those).
    static func isFailure(_ line: String, location: Location) -> Bool {
        if line.contains("Downloading file failed") { return !location.sharesItsPrefix }
        return line.contains(" ERROR: ")
    }

    /// Fills a backup under a ".partial" name and gives it its own name only once complete, so a
    /// failed copy never sits among the real ones; then keeps the newest `keep`, never this one.
    private func finish(_ target: URL, fill: (URL) throws -> Void) throws -> URL {
        let partial = target.deletingLastPathComponent().appending(path: target.lastPathComponent + ".partial", directoryHint: .isDirectory)
        do {
            try fill(partial)
            try FileManager.default.moveItem(at: partial, to: target)
            // A copied folder keeps its source's creation date, often years old: the copy is
            // dated now, so the newest copies are the ones kept.
            try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: target.path)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        // By name: the same folder can be listed under /var and /private/var.
        for old in backups(in: target.deletingLastPathComponent()).filter({ $0.lastPathComponent != target.lastPathComponent }).dropFirst(Self.keep - 1) {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: Self.fingerprintFile(of: old))
        }
        return target
    }

    /// A location's complete backups, newest first by when they were made (not by name: a Mac
    /// whose clock was wrong once must not prune today's copy as the oldest).
    func backups(in dir: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        func made(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return all.filter { !["partial", "fingerprint"].contains($0.pathExtension) }.sorted { made($0) > made($1) }
    }

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

    /// Per install, not per game: the same game in two environments has two sets of saves, each
    /// with its own last sync.
    func key(_ game: GOGStore.InstalledGame, _ location: Location) -> String {
        "\(game.id).\(location.name)@\(game.folder.standardizedFileURL.path)"
    }

    static func arguments(folder: URL, id: String, location: Location, timestamp: String, direction: Direction) -> [String] {
        let flag: String
        switch direction {
        case .download: flag = "--skip-upload"
        case .upload: flag = "--skip-download"
        case .forceDownload: flag = "--force-download"
        case .forceUpload: flag = "--force-upload"
        }
        return ["save-sync", folder.path, id, "--os", "windows", "--ts", timestamp, "--name", location.name, flag]
    }

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

    /// gogdl's line for refusing the direction asked for ("Refused to download files, newer files
    /// locally"): it moved nothing.
    static func isRefusal(_ line: String) -> Bool { line.contains("Refused to") }

    /// Syncs one location. The new timestamp is kept only when something was decided.
    public func sync(_ game: GOGStore.InstalledGame, location: Location, folder: URL, direction: Direction,
                     onLine: (@Sendable (String) -> Void)? = nil) -> Outcome {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ts = timestamps()[key(game, location)] ?? "0"
        // Whatever a sync could replace or delete is copied first, and a failed copy stops it. An
        // upload copies the cloud even after a session whose saves came down first: a download
        // brings only cloud files newer than the last sync, so one older than it and missing on
        // the Mac stays in the cloud alone, and the upload deletes it.
        do {
            switch direction {
            case .download, .forceDownload: try backUpLocal(game, location: location, folder: folder)
            case .upload, .forceUpload: try backUpCloud(game, location: location)
            }
        } catch {
            return .failed("the saves could not be backed up first (\(error.localizedDescription)), so nothing was synced")
        }
        let conflict = OSAllocatedUnfairLock(initialState: false)
        let refused = OSAllocatedUnfairLock(initialState: false)
        let failed = OSAllocatedUnfairLock(initialState: false)
        let stdout = OSAllocatedUnfairLock<String?>(initialState: nil)
        let status: Int32
        do {
            // save-sync refreshes the game's own token into auth.json.
            status = try store.withAuthFile { try store.runStreaming(Self.arguments(folder: folder, id: game.id, location: location, timestamp: ts, direction: direction)) { line in
                if Self.isConflict(line) { conflict.withLock { $0 = true } }
                if Self.isRefusal(line) { refused.withLock { $0 = true } }
                if Self.isFailure(line, location: location) { failed.withLock { $0 = true } }
                if let (value, rest) = Self.timestamp(in: line) {
                    stdout.withLock { $0 = value }
                    if !rest.isEmpty { onLine?(rest) }
                } else { onLine?(line) }
            } }
        } catch { return .failed(error.localizedDescription) }
        guard status == 0 else { return .failed("gogdl save-sync exited with \(status)") }
        // gogdl exits 0 after a file it could not move, and still prints a new timestamp: kept,
        // that timestamp would hide the file from the next sync, so it is not.
        if failed.withLock({ $0 }) { return .failed("gogdl could not move every file") }
        if conflict.withLock({ $0 }) { return .conflict }
        if refused.withLock({ $0 }) { return .refused }
        if let new = stdout.withLock({ $0 }) {
            updateTimestamps { $0[key(game, location)] = new }
        }
        return .synced
    }

    /// Forgets an install's sync history (uninstall), so a reinstall starts by asking the cloud.
    /// Other environments' copies of the game keep theirs.
    public func forget(_ game: GOGStore.InstalledGame) {
        let suffix = "@\(game.folder.standardizedFileURL.path)"
        updateTimestamps { all in all = all.filter { !($0.key.hasPrefix(game.id + ".") && $0.key.hasSuffix(suffix)) } }
    }
}
