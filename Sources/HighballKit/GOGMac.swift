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
        public let folder: URL
        /// The app to open; nil when the folder holds none Highball can find.
        public let app: URL?
        public let buildID: String?
        /// What the app's executable is built for, read once when the install is found.
        public let arch: MacBinaryArch

        /// The same game as the installed-game record the Windows paths take, so the save sync,
        /// comet's achievement lookup and the rest run unchanged. Its folder keeps the Mac build's
        /// sync history apart from a Windows copy's.
        public var asInstalledGame: InstalledGame {
            InstalledGame(id: id, title: title, folder: folder, buildID: buildID, clientID: nil, dlcIDs: [], tasks: [])
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
                return macInstalledGame(in: folder)
            }
        }
        .filter { seen.insert($0.id).inserted }
    }

    public static func macInstalledGames(in base: URL) -> [MacInstalledGame] { macInstalledGames(in: [base]) }

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
        let app = home ?? apps.first
        return MacInstalledGame(id: base.gameId, title: base.name ?? folder.lastPathComponent, folder: folder,
                                app: app, buildID: base.buildId, arch: app.map(MacBinaryArch.ofApp(at:)) ?? .unknown)
    }
}
