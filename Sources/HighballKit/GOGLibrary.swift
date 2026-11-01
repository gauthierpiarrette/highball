import Foundation

// MARK: The owned library

extension GOGStore {
    /// A game the account owns, as the library shows it. GOG's own tall art is 342×482 at every
    /// source (gamesdb's vertical_cover, the store's boxArtImage), soft on a cover tile. GOG's
    /// database also names the same game's Steam release, and where it does the cover is Steam's
    /// 600×900 capsule, the art Highball shows for Steam games, and the compatibility database is
    /// matched by that Steam id, so a GOG copy gets the row, verdict and fix the Steam copy has.
    public struct Game: Codable, Sendable, Equatable {
        public let id: String
        public let title: String
        /// The Steam app id of the same game in GOG's database, nil when it has none.
        public let steamAppID: Int?
        public let gogVerticalCover: URL?
        public let gogWide: URL?
        /// gamesdb lists macOS among the release's systems; every GOG purchase includes each
        /// system's build. nil in an entry cached before this was read: looked up again.
        public let listsMac: Bool?

        public init(id: String, title: String, steamAppID: Int? = nil, gogVerticalCover: URL? = nil, gogWide: URL? = nil,
                    listsMac: Bool? = nil) {
            self.id = id; self.title = title; self.steamAppID = steamAppID
            self.gogVerticalCover = gogVerticalCover; self.gogWide = gogWide; self.listsMac = listsMac
        }

        public var artworkTall: URL? {
            steamAppID.map { URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\($0)/library_600x900.jpg")! } ?? gogVerticalCover
        }
        public var artworkWide: URL? {
            steamAppID.map { URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\($0)/header.jpg")! } ?? gogWide
        }
    }

    /// What gamesdb says about one release, kept between refreshes: a library of hundreds of games
    /// is one request per game the first time and none after, until the entry is a week old.
    struct CachedRelease: Codable {
        var game: Game?          // nil: not a game the library shows (DLC, hidden, movie)
        var fetched: Date
    }

    var libraryCacheFile: URL { dir.appending(path: "library.json") }

    /// Games the account owns. Pages through galaxy-library's releases (the list Galaxy itself
    /// reads) and looks each one up in gamesdb, keeping games and mods it marks visible in the
    /// library, the filter Heroic uses: DLC and hidden entries stay out.
    public func ownedGames() async throws -> [Game] {
        let creds = try credentials()
        var releases: [(id: String, certificate: String?)] = []
        var page: String?
        repeat {
            var url = URLComponents(string: "https://galaxy-library.gog.com/users/\(creds.userID)/releases")!
            if let page { url.queryItems = [URLQueryItem(name: "page_token", value: page)] }
            var request = URLRequest(url: url.url!)
            request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
            let data = try await Self.fetch(async: request)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            for item in obj["items"] as? [[String: Any]] ?? [] {
                guard item["platform_id"] as? String == "gog", let id = item["external_id"] as? String else { continue }
                if let owned = item["owned"] as? Bool, !owned { continue }
                releases.append((id, item["certificate"] as? String))
            }
            page = (obj["next_page_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        } while page != nil

        var cache = (try? JSONDecoder.highball.decode([String: CachedRelease].self, from: Data(contentsOf: libraryCacheFile))) ?? [:]
        let stale = Date().addingTimeInterval(-7 * 86_400)
        // Entries from before the systems were read are looked up again, once.
        let missing = releases.filter { (cache[$0.id]?.fetched ?? .distantPast) < stale || cache[$0.id]?.game.map { $0.listsMac == nil } == true }
        try await withThrowingTaskGroup(of: (String, CachedRelease?).self) { group in
            var next = missing.makeIterator()
            func add() -> Bool {
                guard let r = next.next() else { return false }
                group.addTask { (r.id, try? await Self.release(r.id, certificate: r.certificate, token: creds.accessToken)) }
                return true
            }
            for _ in 0..<8 where add() {}
            while let (id, entry) = try await group.next() {
                if let entry { cache[id] = entry }
                _ = add()
            }
        }
        secureDirectory()
        try? JSONEncoder.highball.encode(cache).write(to: libraryCacheFile, options: .atomic)
        let owned = Set(releases.map(\.id))
        return cache.filter { owned.contains($0.key) }.compactMap(\.value.game)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func releaseRequest(_ id: String, certificate: String?, token: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://gamesdb.gog.com/platforms/gog/external_releases/\(id)")!)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let certificate { request.setValue(certificate, forHTTPHeaderField: "X-GOG-Library-Cert") }
        return request
    }

    static func release(_ id: String, certificate: String?, token: String?) async throws -> CachedRelease {
        CachedRelease(game: parseRelease(id: id, data: try await fetch(async: releaseRequest(id, certificate: certificate, token: token))), fetched: Date())
    }

    /// One gamesdb release as a library game, nil for anything the library does not show.
    static func parseRelease(id: String, data: Data) -> Game? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let game = obj["game"] as? [String: Any] else { return nil }
        let type = (obj["type"] as? String) ?? (game["type"] as? String) ?? "game"
        guard type == "game" || type == "mod", (game["visible_in_library"] as? Bool) ?? true else { return nil }
        func text(_ any: Any?) -> String? { ((any as? [String: Any])?["*"] as? String)?.trimmingCharacters(in: .whitespaces) }
        guard let title = text(obj["title"]) ?? text(game["title"]), !title.isEmpty else { return nil }
        // gamesdb image URLs carry {formatter} (a size suffix; empty is the original) and {ext}.
        func image(_ key: String) -> URL? {
            guard let format = (game[key] as? [String: Any])?["url_format"] as? String else { return nil }
            return URL(string: format.replacingOccurrences(of: "{formatter}", with: "").replacingOccurrences(of: "{ext}", with: "jpg"))
        }
        let steam = (game["releases"] as? [[String: Any]] ?? [])
            .first { $0["platform_id"] as? String == "steam" }
            .flatMap { ($0["external_id"] as? String).flatMap(Int.init) }
        let systems = (obj["supported_operating_systems"] as? [[String: Any]] ?? []).compactMap { $0["slug"] as? String }
        return Game(id: id, title: title, steamAppID: steam,
                    gogVerticalCover: image("vertical_cover"), gogWide: image("horizontal_artwork") ?? image("background"),
                    listsMac: systems.contains("osx"))
    }

    /// Looks up games the account may not list (an installed game from an offline installer while
    /// signed out): gamesdb answers without a token.
    public func game(_ id: String) -> Game? {
        if let cached = (try? JSONDecoder.highball.decode([String: CachedRelease].self, from: Data(contentsOf: libraryCacheFile)))?[id],
           cached.fetched > Date().addingTimeInterval(-7 * 86_400) {
            return cached.game
        }
        return (try? Self.fetch(Self.releaseRequest(id, certificate: nil, token: nil))).flatMap { Self.parseRelease(id: id, data: $0) }
    }
}

// MARK: Installed games, read from disk

extension GOGStore {
    /// A launch task from goggame-<id>.info, what Galaxy's Play button runs.
    public struct PlayTask: Codable, Sendable, Equatable {
        public let name: String?
        public let type: String?
        public let path: String?
        public let arguments: String?
        public let workingDir: String?
        public let category: String?
        public let isPrimary: Bool?
        public let isHidden: Bool?

        public init(name: String? = nil, type: String? = "FileTask", path: String?, arguments: String? = nil,
                    workingDir: String? = nil, category: String? = "game", isPrimary: Bool? = nil, isHidden: Bool? = nil) {
            self.name = name; self.type = type; self.path = path; self.arguments = arguments; self.workingDir = workingDir
            self.category = category; self.isPrimary = isPrimary; self.isHidden = isHidden
        }

        var isFile: Bool { (type ?? "FileTask") == "FileTask" && !(path ?? "").isEmpty }
    }

    struct InfoFile: Codable {
        let gameId: String
        let rootGameId: String?
        let name: String?
        let buildId: String?
        let clientId: String?
        let playTasks: [PlayTask]?
    }

    /// A GOG game installed in an environment.
    public struct InstalledGame: Sendable, Equatable {
        public let id: String
        public let title: String
        public let folder: URL
        public let buildID: String?
        public let clientID: String?
        public let dlcIDs: [String]
        public let tasks: [PlayTask]

        /// The tasks a player can choose between: visible files that are not a manual (Heroic's
        /// rule), offered only when there are at least two.
        public var launchChoices: [PlayTask] {
            let visible = tasks.filter { $0.isFile && $0.isHidden != true && $0.category != "document" }
            return visible.count >= 2 ? visible : []
        }

        /// What Play runs: the chosen task when there is one, else the primary task, which is
        /// what Galaxy and gogdl run, else the first file task.
        public func launchTask(choice: Int? = nil) -> PlayTask? {
            if let choice, launchChoices.indices.contains(choice) { return launchChoices[choice] }
            return tasks.first { $0.isPrimary == true && $0.isFile } ?? tasks.first { $0.isFile }
        }

        /// What tells the game is still running: the name of every program in its folder, since a
        /// GOG launch task is often a launcher that hands over to another .exe beside it and exits
        /// (Control.exe starts Control_DX11.exe), and Wine shows a process by its file name only.
        /// Uninstallers, bundled runtime installers and generic helpers (crash reporters, setup and
        /// settings tools, updaters) are left out: their names are common enough to match another
        /// game's process. The program Play started always counts.
        public func sessionMarkers(launching executable: URL) -> [String] {
            let skip = ["__redist", "_commonredist", "redist", "directx", "vcredist", "support"]
            var names: Set<String> = []
            let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = items?.nextObject() as? URL {
                let name = url.lastPathComponent.lowercased()
                if skip.contains(name) || (items?.level ?? 0) >= 4 { items?.skipDescendants() }
                guard name.hasSuffix(".exe"), !name.hasPrefix("unins"),
                      !["crash", "setup", "config", "launcher", "redist", "update", "report"].contains(where: name.contains),
                      name != "start.exe" else { continue }
                names.insert(url.lastPathComponent)
            }
            names.formUnion(SessionWatch.markers(executable: executable))   // what Play started, whatever its name or place
            return names.sorted()
        }
    }

    /// The folders GOG installs land in: Highball's own (gogdl, like Epic), and the defaults of
    /// GOG's offline installers and of Galaxy.
    public static func installRoots(driveC: URL) -> [URL] {
        ["Games", "GOG Games", "Program Files (x86)/GOG Galaxy/Games", "Program Files/GOG Galaxy/Games"]
            .map { driveC.appending(path: $0, directoryHint: .isDirectory) }
    }

    /// Every GOG game installed in the environment: a folder directly under an install root that
    /// holds goggame-<id>.info files. The base game is the file whose id is its own root id; the
    /// others are its DLC. A folder gogdl is still downloading into (.gogdl-resume) is skipped.
    public static func installedGames(driveC: URL) -> [InstalledGame] {
        let fm = FileManager.default
        var games: [InstalledGame] = []
        for root in installRoots(driveC: driveC) {
            let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if fm.fileExists(atPath: folder.appending(path: ".gogdl-resume").path) { continue }
                if let game = installedGame(in: folder) { games.append(game) }
            }
        }
        return games
    }

    static func installedGame(in folder: URL) -> InstalledGame? {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("goggame-") && $0.pathExtension == "info" }
        let infos = files.compactMap { try? JSONDecoder().decode(InfoFile.self, from: Data(contentsOf: $0)) }
        guard let base = infos.first(where: { $0.rootGameId == nil || $0.rootGameId == $0.gameId }) else { return nil }
        let dlcs = infos.filter { $0.gameId != base.gameId && ($0.rootGameId ?? base.gameId) == base.gameId }.map(\.gameId).sorted()
        return InstalledGame(id: base.gameId, title: base.name ?? folder.lastPathComponent, folder: folder,
                             buildID: base.buildId, clientID: base.clientId, dlcIDs: dlcs, tasks: base.playTasks ?? [])
    }

    /// The executable, arguments and working folder a task names, resolved the way gogdl's launch
    /// does: Windows separators become Unix ones, an argument string is split like a shell would,
    /// the working folder defaults to the game's, and a name whose case differs on disk is found.
    public static func launch(_ task: PlayTask, in game: InstalledGame) -> (executable: URL, arguments: [String], workingDirectory: URL)? {
        guard task.isFile, let path = task.path else { return nil }
        let exe = resolve(path, in: game.folder)
        let args = task.arguments.map { ArgumentLine.split($0.replacingOccurrences(of: "\\", with: "/")) } ?? []
        let work = (task.workingDir ?? "").isEmpty ? game.folder : resolve(task.workingDir!, in: game.folder)
        return (exe, args, work)
    }

    /// A relative path from an info file under `folder`, matched case-insensitively component by
    /// component when the exact spelling is not on disk.
    static func resolve(_ relative: String, in folder: URL) -> URL {
        let parts = relative.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        var url = folder
        for part in parts {
            let exact = url.appending(path: part)
            if FileManager.default.fileExists(atPath: exact.path) { url = exact; continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            url = url.appending(path: names.first { $0.caseInsensitiveCompare(part) == .orderedSame } ?? part)
        }
        return url
    }
}

// MARK: Installing, updating, removing

extension GOGStore {
    var manifestsDir: URL { dir.appending(path: "heroic_gogdl/manifests", directoryHint: .isDirectory) }
    /// The manifest gogdl reads and writes: one per game id for the whole Highball home.
    func manifest(_ id: String) -> URL { manifestsDir.appending(path: id) }
    /// Each install's own copy, beside its files. A game can sit in several environments, at
    /// different builds; gogdl knows one manifest per game, so the install's copy is what Highball
    /// trusts (update, setup, the page's Version) and it goes into gogdl's place before gogdl
    /// patches that install. Uninstalling removes it with the folder.
    func installManifest(_ game: InstalledGame) -> URL { game.folder.appending(path: ".highball-gogdl-manifest") }
    func supportDir(_ id: String) -> URL { dir.appending(path: "support/\(id)", directoryHint: .isDirectory) }
    var redistDir: URL { dir.appending(path: "redist", directoryHint: .isDirectory) }

    /// What `gogdl info` says before a download: the folder it will make, the languages, the size
    /// and the Windows runtimes the game lists.
    public struct DownloadInfo: Sendable {
        public let folderName: String?
        public let languages: [String]
        public let downloadSize: Int64?
        public let diskSize: Int64?
        public let buildID: String?
        public let dependencies: [String]
    }

    /// `platform` is gogdl's: "windows", or "osx" for a Mac build (GOGMac).
    public func info(_ id: String, platform: String = "windows") throws -> DownloadInfo {
        let out = try capture(["info", id, "--os", platform])
        guard let start = out.firstIndex(of: "{"),
              let obj = try JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any] else {
            throw HighballError.failed(platform == "osx" ? "GOG has no Mac download for this game that gogdl can read."
                                       : "GOG has no Windows download for this game that gogdl can read.")
        }
        return Self.parseInfo(obj)
    }

    /// gogdl's `size` holds the files every language shares under "*" and each language's own
    /// beside it ("en-US"); a download is "*" plus the language installed. Samorost 1's Mac build:
    /// 44 bytes shared, 68 MB in English.
    static func parseInfo(_ obj: [String: Any], preferred: [String] = Locale.preferredLanguages) -> DownloadInfo {
        let languages = obj["languages"] as? [String] ?? []
        let sizes = obj["size"] as? [String: Any] ?? [:]
        let parts = ["*", language(for: languages, preferred: preferred)].compactMap { sizes[$0] as? [String: Any] }
        func total(_ key: String) -> Int64? {
            let values = parts.compactMap { ($0[key] as? NSNumber)?.int64Value }
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        return DownloadInfo(folderName: obj["folder_name"] as? String, languages: languages,
                            downloadSize: total("download_size"), diskSize: total("disk_size"),
                            buildID: obj["buildId"] as? String, dependencies: obj["dependencies"] as? [String] ?? [])
    }

    /// The language to install: the first of the Mac's preferred languages the game has, else
    /// English, else the game's first. GOG names them "en-US", Macs "en-US" or "en".
    public static func language(for available: [String], preferred: [String] = Locale.preferredLanguages) -> String {
        for wanted in preferred {
            if let exact = available.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) { return exact }
            let base = wanted.split(separator: "-").first.map(String.init) ?? wanted
            if let close = available.first(where: { $0.lowercased().hasPrefix(base.lowercased() + "-") || $0.lowercased() == base.lowercased() }) { return close }
        }
        return available.first { $0.hasPrefix("en") } ?? available.first ?? "en-US"
    }

    /// gogdl appends the game's own folder name to `--path` for a download, and takes the game's
    /// folder itself for an update. DLC comes along: what the account owns installs with the game.
    static func downloadArguments(id: String, into base: String, support: String, language: String, update: Bool,
                                  platform: String = "windows") -> [String] {
        [update ? "update" : "download", id, "--platform", platform, "--path", base,
         "--support", support, "--with-dlcs", "--lang", language]
    }

    /// Downloads a game's Windows build into the environment's Games folder. Returns the folder.
    @discardableResult
    public func install(_ id: String, into bottle: Bottle, language: String, control: LegendaryControl? = nil,
                        onLine: (@Sendable (String) -> Void)? = nil) throws -> Int32 {
        let base = bottle.driveC.appending(path: "Games", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Another environment's install of this game left gogdl's manifest behind (its own copy
        // stays beside it): cleared, so a manifest after this download is this download's.
        try? FileManager.default.removeItem(at: manifest(id))
        return try runStreaming(Self.downloadArguments(id: id, into: base.path, support: supportDir(id).path, language: language, update: false),
                                control: control, onLine: onLine)
    }

    /// Brings an installed game to GOG's newest build. gogdl patches against the manifest it kept
    /// from the download, so only games gogdl installed can update here.
    @discardableResult
    public func update(_ game: InstalledGame, language: String, control: LegendaryControl? = nil,
                       onLine: (@Sendable (String) -> Void)? = nil) throws -> Int32 {
        // gogdl patches against its manifest: this install's, not another environment's build.
        try? FileManager.default.removeItem(at: manifest(game.id))
        try FileManager.default.copyItem(at: installManifest(game), to: manifest(game.id))
        return try runStreaming(Self.downloadArguments(id: game.id, into: game.folder.path, support: supportDir(game.id).path, language: language, update: true),
                         control: control, onLine: onLine)
    }

    /// gogdl downloaded this install and Highball kept its manifest: it can update the game and
    /// knows the setup it needs. An offline installer's game has none, and its installer did the setup.
    public func hasManifest(_ game: InstalledGame) -> Bool { FileManager.default.fileExists(atPath: installManifest(game).path) }

    /// An install gogdl made before installs kept their own manifest: takes gogdl's when it
    /// describes this very build (same build id as the install's info file), once.
    public func adoptManifest(for game: InstalledGame) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: installManifest(game).path), let build = game.buildID,
              let data = try? Data(contentsOf: manifest(game.id)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["buildId"] as? String == build else { return }
        try? fm.copyItem(at: manifest(game.id), to: installManifest(game))
    }

    /// After a finished download or update: keeps gogdl's manifest beside the install it describes.
    public func keepManifest(for game: InstalledGame) {
        try? FileManager.default.removeItem(at: installManifest(game))
        try? FileManager.default.copyItem(at: manifest(game.id), to: installManifest(game))
    }

    /// gogdl prints `= Progress: 12.34 123456/999999, Running for: …` about once a second: the
    /// bytes written so far and the total on disk. Nil for any other line.
    public static func progress(inGogdlLine line: String) -> (written: Int64, total: Int64)? {
        guard let r = line.range(of: "= Progress: ") else { return nil }
        let fields = line[r.upperBound...].split(separator: " ")
        guard fields.count >= 2 else { return nil }
        let pair = fields[1].split(separator: "/")
        guard pair.count == 2, let written = Int64(pair[0]), let total = Int64(pair[1].trimmingCharacters(in: CharacterSet(charactersIn: ","))) else { return nil }
        return (written, total)
    }

    /// A line that explains why a download stopped, as a sentence for the player. Nil otherwise.
    public static func installFailure(_ line: String) -> String? {
        if line.contains("Not enough disk space") {
            return "This Mac doesn't have enough free space for the game. Free some space, then press Install again."
        }
        if line.contains("doesn't support content system api") {
            return "GOG has no Galaxy-style Windows download for this game, so it can't be installed from here. Its offline installer from gog.com still works: download it from your GOG library and drop it on Highball."
        }
        guard let r = line.range(of: "] ERROR: ") ?? line.range(of: "] CRITICAL: ") else { return nil }
        let message = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return message.isEmpty ? nil : "GOG's downloader stopped with this message. \(message)"
    }

    /// gogdl can end a download that failed partway with status 0 and no manifest (its executor
    /// returns "cancelled" on a fatal error), so a finished install is one whose manifest exists.
    public func downloadCompleted(_ id: String) -> Bool { FileManager.default.fileExists(atPath: manifest(id).path) }

    /// Forgets what gogdl kept about a game once no environment holds it any more, so it never
    /// tries to patch a game that is not there. While another install remains, its state stays.
    public func forget(_ id: String, otherInstallsRemain: Bool) {
        guard !otherInstallsRemain else { return }
        try? FileManager.default.removeItem(at: manifest(id))
        try? FileManager.default.removeItem(at: supportDir(id))
    }
}

// MARK: First-run setup (what GOG's installer would have done)

extension GOGStore {
    /// One program to run in the environment after a download, in order.
    public struct SetupStep: Sendable, Equatable {
        public let label: String
        /// The program to run; nil runs Wine's own msiexec with the arguments (an .msi runtime).
        public let executable: URL?
        public let arguments: [String]
        public let workingDirectory: URL

        public var command: [String] { [executable?.path ?? "msiexec"] + arguments }
    }

    /// Runs what GOG's installer would have, in the environment: the runtimes the game lists,
    /// then its install scripts, then the marker that says this build has had its setup. A step
    /// that fails is reported and the next one runs; nothing here stops the game from being
    /// played, which is how Galaxy behaves when a runtime is already newer. Shared by the app
    /// and the CLI.
    public func runSetup(_ game: InstalledGame, language: String, runner: WineRunner,
                         onStep: (_ number: Int, _ of: Int, _ label: String) async -> Void = { _, _, _ in },
                         onLine: (@Sendable (String) -> Void)? = nil,
                         onFailure: (_ label: String, _ exitCode: Int32) async -> Void = { _, _ in }) async throws {
        let needed = dependencies(of: game)
        if needed.contains(where: { $0 != "ISI" }) {
            let store = self
            _ = try? await Task.detached { try store.downloadRedists(needed, onLine: onLine) }.value
        }
        let steps = setupSteps(for: game, language: language)
        for (n, step) in steps.enumerated() {
            try Task.checkCancellation()
            await onStep(n + 1, steps.count, step.label)
            let result = try? await runner.run(step.command, renderer: .wined3d, label: "gog-setup-\(game.id)",
                                               workingDirectory: step.workingDirectory, onOutput: onLine)
            if let code = result?.exitStatus, code != 0 { await onFailure(step.label, code) }
        }
        Self.markSetupDone(for: game, driveC: runner.bottle.driveC)
    }

    /// The Windows runtimes a game's manifest lists, plus ISI (GOG's ScriptInterpreter), which
    /// runs a game's install scripts.
    public func dependencies(of game: InstalledGame) -> [String] {
        guard let data = try? Data(contentsOf: installManifest(game)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let deps = obj["dependencies"] as? [String] { return deps }
        // v1 manifests list them per depot.
        let products = (obj["product"] as? [String: Any])?["depots"] as? [[String: Any]] ?? []
        return products.compactMap { $0["redist"] as? String }
    }

    /// Fetches the shared runtimes into the Highball home (once, shared by every game).
    @discardableResult
    public func downloadRedists(_ ids: [String], onLine: (@Sendable (String) -> Void)? = nil) throws -> Int32 {
        try FileManager.default.createDirectory(at: redistDir, withIntermediateDirectories: true)
        return try runStreaming(["redist", "--ids", (["ISI"] + ids).joined(separator: ","), "--path", redistDir.path], onLine: onLine)
    }

    /// What GOG's own installer would have run, in Heroic's order: each runtime the game lists,
    /// with the silent arguments GOG's repository gives it, then the game's install scripts
    /// (ScriptInterpreter for a v2 manifest that asks for it, else each product's own setup
    /// program). Paths stay Unix paths; Wine maps them through Z:.
    public func setupSteps(for game: InstalledGame, language: String) -> [SetupStep] {
        guard let data = try? Data(contentsOf: installManifest(game)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var steps: [SetupStep] = []
        let repo = (try? Data(contentsOf: redistDir.appending(path: ".gogdl-redist-manifest")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let depots = repo?["depots"] as? [[String: Any]] ?? []
        for dep in dependencies(of: game) where dep != "ISI" {
            guard let depot = depots.first(where: { $0["dependencyId"] as? String == dep }),
                  let exe = depot["executable"] as? [String: Any], let path = exe["path"] as? String, !path.isEmpty else { continue }
            let file = redistDir.appending(path: path)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var args = ArgumentLine.split(exe["arguments"] as? String ?? "")
            var executable: URL? = file
            if dep == "PHYSXLEGACY" { args = ["/i", file.path] + args + ["/qb"]; executable = nil }
            steps.append(SetupStep(label: depot["readableName"] as? String ?? dep, executable: executable,
                                   arguments: args, workingDirectory: redistDir))
        }
        let languageName = Locale(identifier: "en").localizedString(forLanguageCode: String(language.prefix(2))) ?? "English"
        let common = ["/VERYSILENT", "/DIR=\(game.folder.path)", "/galaxyclient", "/buildId=\(game.buildID ?? "")",
                      "/versionName=\(obj["versionName"] as? String ?? "")", "/lang-code=\(language)",
                      "/nodesktopshorctut", "/nodesktopshortcut"]
        let products = (obj["products"] as? [[String: Any]] ?? []).compactMap { p -> (id: String, temp: String?)? in
            guard let id = p["productId"] as? String else { return nil }
            return (id, p["temp_executable"] as? String)
        }.filter { $0.id == game.id || game.dlcIDs.contains($0.id) }
        let isi = redistDir.appending(path: "__redist/ISI/scriptinterpreter.exe")
        if obj["scriptInterpreter"] as? Bool == true, FileManager.default.fileExists(atPath: isi.path) {
            for p in products {
                steps.append(SetupStep(label: "GOG install script", executable: isi,
                                       arguments: common + ["/Language=\(languageName)", "/LANG=\(languageName)", "/ProductId=\(p.id)",
                                                            "/supportDir=\(supportDir(game.id).path)"],
                                       workingDirectory: game.folder))
            }
        } else {
            for p in products {
                guard let temp = p.temp, !temp.isEmpty else { continue }
                let exe = supportDir(game.id).appending(path: "\(game.id)/\(p.id)/\(temp)")
                guard FileManager.default.fileExists(atPath: exe.path) else { continue }
                steps.append(SetupStep(label: "GOG install script", executable: exe,
                                       arguments: common + ["/Language=\(languageName.lowercased())", "/LANG=\(languageName.lowercased())", "/ProductId=\(p.id)"],
                                       workingDirectory: game.folder))
            }
        }
        return steps
    }

    /// Setup has run for this build in this environment. A marker in the environment, so another
    /// environment holding the same game runs its own, and an update runs it again.
    public static func setupMarker(for game: InstalledGame, driveC: URL) -> URL {
        driveC.appending(path: "highball/gog-setup/\(game.id)")
    }
    public static func setupDone(for game: InstalledGame, driveC: URL) -> Bool {
        (try? String(contentsOf: setupMarker(for: game, driveC: driveC), encoding: .utf8)) == (game.buildID ?? "")
    }
    public static func markSetupDone(for game: InstalledGame, driveC: URL) {
        let url = setupMarker(for: game, driveC: driveC)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (game.buildID ?? "").write(to: url, atomically: true, encoding: .utf8)
    }
}
