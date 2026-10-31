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
        /// The system gogdl syncs it as: "windows" for GOG's Windows locations, "osx" for its Mac ones.
        public var os = "windows"

        public init(name: String, template: String, os: String = "windows") {
            self.name = name; self.template = template; self.os = os
        }
    }

    /// The client id cloud storage is keyed by: the info file's, else the manifest gogdl kept
    /// (Control's info file has none; its manifest does), else GOG's latest build manifest for an
    /// install with neither (an offline installer, a gogdl install from elsewhere), remembered.
    public func clientID(for game: GOGStore.InstalledGame) -> String? {
        if let id = game.clientID, !id.isEmpty { return id }
        if let data = try? Data(contentsOf: store.installManifest(game)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = obj["clientId"] as? String { return id }
        let cacheFile = store.dir.appending(path: "client-ids.json")
        var cache = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: cacheFile))) ?? [:]
        if let id = cache[game.id] { return id }
        guard let id = try? Self.publishedClientID(productID: game.id) else { return nil }
        cache[game.id] = id
        try? JSONEncoder().encode(cache).write(to: cacheFile, options: .atomic)
        return id
    }

    /// The client id in the newest Windows build's manifest. The build list and manifests are
    /// public; a v2 manifest is zlib-compressed JSON.
    static func publishedClientID(productID: String) throws -> String? {
        let list = URL(string: "https://content-system.gog.com/products/\(productID)/os/windows/builds?generation=2")!
        guard let builds = try JSONSerialization.jsonObject(with: GOGStore.fetch(URLRequest(url: list))) as? [String: Any],
              let link = ((builds["items"] as? [[String: Any]])?.first?["link"] as? String).flatMap(URL.init(string:)) else { return nil }
        return clientID(inManifest: try GOGStore.fetch(URLRequest(url: link)))
    }

    static func clientID(inManifest data: Data) -> String? {
        // zlib = a 2-byte header, raw DEFLATE, then a checksum; Foundation's .zlib reads raw DEFLATE.
        let json = data.first == 0x78 ? (try? (data.dropFirst(2) as NSData).decompressed(using: .zlib) as Data) : data
        guard let json, let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        return obj["clientId"] as? String
    }

    /// Where the game keeps its saves, nil when it has no cloud saves. An empty list from GOG means
    /// the SDK's own storage folder, which Galaxy names __default.
    public func locations(clientID: String) throws -> [Location]? {
        let url = URL(string: "https://remote-config.gog.com/components/galaxy_client/clients/\(clientID)?component_version=2.0.45")!
        let data = try GOGStore.fetch(URLRequest(url: url))
        return Self.parseLocations(data, clientID: clientID)
    }

    /// `platform` is GOG's: "Windows", or "MacOS" for the Mac build's own locations.
    static func parseLocations(_ data: Data, clientID: String, platform: String = "Windows") -> [Location]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = (obj["content"] as? [String: Any])?[platform] as? [String: Any],
              let cloud = config["cloudStorage"] as? [String: Any], cloud["enabled"] as? Bool == true else { return nil }
        let os = platform == "MacOS" ? "osx" : "windows"
        let list = (cloud["locations"] as? [[String: Any]] ?? []).compactMap { l -> Location? in
            guard let name = l["name"] as? String, let location = l["location"] as? String else { return nil }
            return Location(name: name, template: location, os: os)
        }
        guard list.isEmpty else { return list }
        return platform == "MacOS"
            ? [Location(name: "__default", template: "<?APPLICATION_SUPPORT?>/GOG.com/Galaxy/Applications/\(clientID)/Storage/Shared/Files", os: os)]
            : [Location(name: "__default", template: "<?APPLICATION_DATA_LOCAL?>/GOG.com/Galaxy/Applications/\(clientID)/Storage/Shared/Files")]
    }

    // MARK: How a game saves

    /// How GOG syncs a game's saves, per version: the folders GOG's file sync copies, empty for a
    /// version it copies none of. Such a version saves through the game itself, which may sync
    /// its own saves with GOG's cloud through GOG's SDK (Cyberpunk 2077 on Mac), unseen here.
    public struct CloudSetup: Sendable, Equatable {
        public let windows: [Location]
        public let mac: [Location]
    }

    /// Both versions' setups, from the one remote config GOG publishes per client id.
    public func cloudSetup(clientID: String) throws -> CloudSetup {
        let url = URL(string: "https://remote-config.gog.com/components/galaxy_client/clients/\(clientID)?component_version=2.0.45")!
        return Self.parseCloudSetup(try GOGStore.fetch(URLRequest(url: url)), clientID: clientID)
    }

    static func parseCloudSetup(_ data: Data, clientID: String) -> CloudSetup {
        CloudSetup(windows: parseLocations(data, clientID: clientID) ?? [],
                   mac: parseLocations(data, clientID: clientID, platform: "MacOS") ?? [])
    }

    // MARK: The Mac build's saves

    /// Where a Mac build's saves sync: GOG's Mac locations, nil when GOG syncs none for the Mac
    /// build. A game that syncs its own saves through GOG's SDK (Cyberpunk 2077 on Mac, through
    /// comet) needs none from Highball, and a file sync beside it would fight it.
    public func macLocations(clientID: String) throws -> [Location]? {
        let url = URL(string: "https://remote-config.gog.com/components/galaxy_client/clients/\(clientID)?component_version=2.0.45")!
        return Self.parseLocations(try GOGStore.fetch(URLRequest(url: url)), clientID: clientID, platform: "MacOS")
    }

    /// A Mac location as a folder, from GOG's Mac variables.
    /// Never a whole known folder (gogdl deletes local files the cloud lacks).
    public static func resolveMac(_ template: String, installFolder: URL,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let values: [String: URL] = [
            "INSTALL": installFolder,
            "DOCUMENTS": home.appending(path: "Documents"),
            "APPLICATION_SUPPORT": home.appending(path: "Library/Application Support"),
            "LIBRARY": home.appending(path: "Library"),
            "PREFERENCES": home.appending(path: "Library/Preferences"),
            "CACHES": home.appending(path: "Library/Caches"),
        ]
        var path = template.replacingOccurrences(of: "\\", with: "/")
        guard let open = path.range(of: "<?"), let close = path.range(of: "?>", range: open.upperBound..<path.endIndex),
              open.lowerBound == path.startIndex, let base = values[String(path[open.upperBound..<close.lowerBound])] else { return nil }
        path.removeSubrange(path.startIndex..<close.upperBound)
        guard !path.contains("%"), !path.contains("<?") else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return parts.reduce(base) { $0.appending(path: $1) }
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
        /// Both sides changed since the last sync: nothing moved, the player chooses.
        case conflict
        case failed(String)
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
        return ["save-sync", folder.path, id, "--os", location.os, "--ts", timestamp, "--name", location.name, flag]
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

    /// Syncs one location. The new timestamp is kept only when something was decided.
    public func sync(_ game: GOGStore.InstalledGame, location: Location, folder: URL, direction: Direction,
                     onLine: (@Sendable (String) -> Void)? = nil) -> Outcome {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ts = timestamps()[key(game, location)] ?? "0"
        let conflict = OSAllocatedUnfairLock(initialState: false)
        let stdout = OSAllocatedUnfairLock<String?>(initialState: nil)
        let status: Int32
        do {
            // save-sync refreshes the game's own token into auth.json.
            status = try store.withAuthFile { try store.runStreaming(Self.arguments(folder: folder, id: game.id, location: location, timestamp: ts, direction: direction)) { line in
                if Self.isConflict(line) { conflict.withLock { $0 = true } }
                if let (value, rest) = Self.timestamp(in: line) {
                    stdout.withLock { $0 = value }
                    if !rest.isEmpty { onLine?(rest) }
                } else { onLine?(line) }
            } }
        } catch { return .failed(error.localizedDescription) }
        guard status == 0 else { return .failed("gogdl save-sync exited with \(status)") }
        if conflict.withLock({ $0 }) { return .conflict }
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
