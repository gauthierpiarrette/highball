import Foundation

/// The processors a Mac program is built for, read from its Mach-O header: whether a Mac build
/// runs here natively, through Rosetta, or not at all (32-bit, which macOS stopped running with
/// Catalina). A store's "has a Mac version" says none of this; the downloaded file does.
public enum MacBinaryArch: Equatable, Sendable {
    /// Apple silicon, alone or in a universal build.
    case native
    /// Intel only: runs on Apple silicon through Rosetta.
    case intelOnly
    /// 32-bit only: does not run on current macOS.
    case only32Bit
    case unknown

    /// An app's, from its bundle's executable; a folder is searched for the app inside it.
    public static func ofApp(at url: URL) -> MacBinaryArch {
        let app = url.pathExtension == "app" ? url
            : ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).first { $0.pathExtension == "app" }
        guard let app, let exe = Bundle(url: app)?.executableURL else { return .unknown }
        return read(exe)
    }

    public static func read(_ executable: URL) -> MacBinaryArch {
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return .unknown }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count >= 8 else { return .unknown }
        func be32(_ offset: Int) -> UInt32 { head[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func le32(_ offset: Int) -> UInt32 { head[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        let arm64: UInt32 = 0x0100_000C, x86_64: UInt32 = 0x0100_0007
        var cpus: [UInt32] = []
        switch be32(0) {
        case 0xCAFE_BABE, 0xCAFE_BABF:   // universal: big-endian list of slices
            let count = Int(be32(4)), stride = be32(0) == 0xCAFE_BABE ? 20 : 32
            for i in 0..<min(count, 16) where 8 + i * stride + 4 <= head.count { cpus.append(be32(8 + i * stride)) }
        default:
            switch le32(0) {
            case 0xFEED_FACF: cpus = [le32(4)]          // 64-bit
            case 0xFEED_FACE: return .only32Bit         // 32-bit
            default: return .unknown
            }
        }
        if cpus.contains(arm64) { return .native }
        if cpus.contains(x86_64) { return .intelOnly }
        return cpus.isEmpty ? .unknown : .only32Bit
    }
}

extension GOGStore {
    /// A game's Mac build, installed by gogdl outside every environment: no Wine, no bottle.
    public struct MacInstalledGame: Sendable, Equatable {
        public let id: String
        public let title: String
        /// The game's own place on disk, what the Trash takes: its app when goggame-<id>.info
        /// sits inside one, else the folder holding the info (Galaxy's layout). Never the searched
        /// folder around an app, which can hold other apps.
        public let folder: URL
        /// The app to open; nil when the folder holds none Highball can find.
        public let app: URL?
        public let buildID: String?
        /// What the app's executable is built for, read once when the install is found.
        public let arch: MacBinaryArch
        /// The info file's client id, which cloud saves and comet's achievements are keyed by.
        public var clientID: String? = nil
        /// The info file's play tasks, what Galaxy's Play button runs.
        public var tasks: [PlayTask] = []
        /// The DLC installed with it: the other info files beside the game's own whose root game is
        /// this one.
        public var dlcIDs: [String] = []
        /// What Move to the Trash takes (GOGStore.macTrashTarget), worked out when the install is
        /// found, off the main actor, since it reads other apps' info files. Nil: nothing is moved.
        public var trashTarget: URL? = nil

        /// The same game as the installed-game record the Windows paths take, so the save sync,
        /// comet's achievement lookup and the rest run unchanged. Its folder keeps the Mac build's
        /// sync history apart from a Windows copy's.
        public var asInstalledGame: InstalledGame {
            InstalledGame(id: id, title: title, folder: folder, buildID: buildID, clientID: clientID, dlcIDs: dlcIDs, tasks: tasks)
        }
    }

    /// Where Mac builds go: an Applications folder Spotlight and Launchpad already look in, the
    /// player's own so nothing asks for an administrator.
    public static var macGamesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Highball Games", directoryHint: .isDirectory)
    }

    /// Downloads a game's Mac build into the Mac games folder.
    @discardableResult
    public func installMac(_ id: String, language: String, control: LegendaryControl? = nil,
                           onLine: (@Sendable (String) -> Void)? = nil) throws -> Int32 {
        let base = Self.macGamesDir
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // As for a Windows install: a manifest after this download is this download's. The
        // Windows install keeps its own copy beside its files (keepManifest), which updates use.
        try? FileManager.default.removeItem(at: manifest(id))
        return try runStreaming(Self.downloadArguments(id: id, into: base.path, support: supportDir(id).path, language: language,
                                                       update: false, platform: "osx"),
                                control: control, onLine: onLine)
    }

    /// Where GOG Mac builds are looked for: Highball's own folder first, then the Applications
    /// folders GOG Galaxy for Mac and GOG's Mac installers put games in (Cyberpunk 2077 in
    /// /Applications/Cyberpunk 2077).
    public static var macSearchFolders: [URL] {
        [macGamesDir, URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)]
    }

    /// Every GOG Mac build in those folders, one per game (the first folder's when two hold it):
    /// an app gogdl put there itself (Samorost 1's Mac build is `Samorost 1.app`, its
    /// goggame-<id>.info in Contents/Resources), or a folder holding the info at its top, in its
    /// own Contents/Resources beside the app (Galaxy's layout), or inside its app. A download in
    /// progress is skipped. Only folder listings: no app is opened to find out.
    public static func macInstalledGames(in bases: [URL] = macSearchFolders) -> [MacInstalledGame] {
        let fm = FileManager.default
        var seen = Set<String>()
        // A searched folder inside another (Highball Games inside ~/Applications) is never a game:
        // read as one, its Trash button would take every game in it.
        let searched = Set(bases.map { $0.standardizedFileURL.path })
        return bases.flatMap { base -> [MacInstalledGame] in
            let folders = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            return folders.compactMap { folder in
                guard !searched.contains(folder.standardizedFileURL.path),
                      (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      !fm.fileExists(atPath: folder.appending(path: ".gogdl-resume").path) else { return nil }
                guard var game = macInstalledGame(in: folder) else { return nil }
                game.trashTarget = macTrashTarget(for: game, searched: bases)
                return game
            }
        }
        .filter { seen.insert($0.id).inserted }
    }

    static func macInstalledGame(in folder: URL) -> MacInstalledGame? {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let apps = folder.pathExtension == "app" ? [folder]
            : top.filter { $0.pathExtension == "app" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let places = (folder.pathExtension == "app" ? [] : [folder, folder.appending(path: "Contents/Resources")])
            + apps.map { $0.appending(path: "Contents/Resources") }
        let infos: [(InfoFile, URL?)] = places.flatMap { place -> [(InfoFile, URL?)] in
            let files = ((try? fm.contentsOfDirectory(at: place, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("goggame-") && $0.pathExtension == "info" }
            let inApp = place.deletingLastPathComponent().deletingLastPathComponent()
            let app = inApp.pathExtension == "app" ? inApp : nil
            return files.compactMap { file in (try? JSONDecoder().decode(InfoFile.self, from: Data(contentsOf: file))).map { ($0, app) } }
        }
        guard let (base, home) = infos.first(where: { $0.0.rootGameId == nil || $0.0.rootGameId == $0.0.gameId }) else { return nil }
        // The info inside an app makes that app the game's folder, as the folder holding it in
        // its own Contents/Resources is in Galaxy's layout: the searched folder around it may hold
        // other apps (/Applications/Games), and the Trash, sizes and save paths go by this one.
        let own = home ?? folder
        let tasks = base.playTasks ?? []
        // Beside several apps, the one the game's primary play task names (what Galaxy's Play
        // opens), not the first by name; none named, the first.
        let app = home ?? taskApp(tasks, in: own, among: apps) ?? apps.first
        let named = home.map { $0.deletingPathExtension().lastPathComponent } ?? folder.lastPathComponent
        // DLC sits beside the game's own info and names it as its root. Only the same place's: a
        // folder of apps holds other games' infos, each its own root.
        let dlcs = infos.filter { $0.1 == home && $0.0.gameId != base.gameId && $0.0.rootGameId == base.gameId }.map { $0.0.gameId }.sorted()
        return MacInstalledGame(id: base.gameId, title: base.name ?? named, folder: own,
                                app: app, buildID: base.buildId, arch: app.map(MacBinaryArch.ofApp(at:)) ?? .unknown,
                                clientID: base.clientId, tasks: tasks, dlcIDs: dlcs)
    }

    /// What the Trash takes for a Mac build: the game's own folder (MacInstalledGame.folder), its
    /// app or the folder holding its info. Never a folder Mac builds are looked for in, nor one
    /// holding such a folder, nor the root, nor a folder holding another game's app (Galaxy's
    /// layout with a second game put beside the first): those hold other games. Nil then.
    public static func macTrashTarget(for game: MacInstalledGame, searched: [URL] = macSearchFolders) -> URL? {
        let folder = game.folder.standardizedFileURL.path
        guard folder != "/" else { return nil }
        let held = searched.map { $0.standardizedFileURL.path }
        guard !held.contains(where: { $0 == folder || $0.hasPrefix(folder + "/") }) else { return nil }
        return holdsOtherGames(game.folder, besides: game.id) ? nil : game.folder
    }

    /// Whether a folder holds another game's app: an app straight inside it whose goggame info
    /// names a different game. The game's own DLC, whose info names it as root, does not count.
    public static func holdsOtherGames(_ folder: URL, besides gameID: String) -> Bool {
        let fm = FileManager.default
        let apps = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "app" }
        return apps.contains { app in
            ((try? fm.contentsOfDirectory(at: app.appending(path: "Contents/Resources"), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("goggame-") && $0.pathExtension == "info" }
                .compactMap { try? JSONDecoder().decode(InfoFile.self, from: Data(contentsOf: $0)) }
                .contains { ($0.rootGameId ?? $0.gameId) != gameID }
        }
    }

    /// The app among `apps` that the primary play task (else the first file task) points at or
    /// into, its path read from `folder` as gogdl and Galaxy read it. Compared with links resolved
    /// on both sides (/var is /private/var, a games folder can be a link), from the folder down,
    /// since the task's own file may not exist yet.
    static func taskApp(_ tasks: [PlayTask], in folder: URL, among apps: [URL]) -> URL? {
        guard let path = (tasks.first { $0.isPrimary == true && $0.isFile } ?? tasks.first { $0.isFile })?.path else { return nil }
        let target = resolve(path, in: folder.resolvingSymlinksInPath()).standardizedFileURL.path
        return apps.first { app in
            let root = app.resolvingSymlinksInPath().standardizedFileURL.path
            return target == root || target.hasPrefix(root + "/")
        }
    }
}

/// A Mac game's processes, seen from outside: what tells it is still running once the process
/// Highball started has quit. A launcher that hands over to the game exits at once, so its exit
/// alone is not the game's end.
public enum MacGameWatch {
    /// Whether an executable runs from inside a game's app or folder, by the kernel's path of it.
    /// Pure, so it is tested without processes.
    public static func runs(executable: String, from folder: String) -> Bool {
        let root = folder.hasSuffix("/") ? folder : folder + "/"
        return executable.hasPrefix(root)
    }

    /// The processes running an executable from inside the folder, never Highball itself. The
    /// kernel reports where an executable really is, so the folder counts as written, with its
    /// links resolved, and through each link straight inside it (an app linked into the folder
    /// runs from where the link points).
    public static func processes(runningFrom folder: URL) -> [pid_t] {
        let written = folder.standardizedFileURL.path
        let roots = Set([written, ProcessTable.canonical(written)] + linkTargets(in: folder))
        let own = getpid()
        return ProcessTable.allPIDs().filter { pid in
            pid != own && executablePath(of: pid).map { path in roots.contains { runs(executable: path, from: $0) } } == true
        }
    }

    /// Where the apps linked straight inside a folder are, resolved. Only apps: a link to a
    /// folder of other things would count everything in it as the game.
    static func linkTargets(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
            .map { ProcessTable.canonical($0.path) }
            .filter { $0.hasSuffix(".app") }
    }

    /// The executable a process runs, or nil when it cannot be read (not ours, gone).
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// Once the process Highball started has quit: waits while anything else runs from the
    /// game's folder, and, when that process quit within `quickExit` seconds of starting (a
    /// launcher), up to `grace` seconds for its successor to appear, since one opened through
    /// Launch Services may show up after the launcher is gone. Whether another process ran.
    @discardableResult
    public static func waitForHandover(from folder: URL, ranFor: TimeInterval, quickExit: TimeInterval = 30,
                                       grace: TimeInterval = 10, interval: TimeInterval = 2,
                                       running: (URL) -> [pid_t] = MacGameWatch.processes(runningFrom:)) async -> Bool {
        var deadline = Date().addingTimeInterval(ranFor < quickExit ? grace : 0)
        var handedOver = false
        while true {
            if !running(folder).isEmpty {
                handedOver = true
                deadline = Date()
            } else if Date() >= deadline {
                return handedOver
            }
            try? await Task.sleep(for: .seconds(interval))
        }
    }
}
