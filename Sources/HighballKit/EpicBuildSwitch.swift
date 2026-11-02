import Foundation

/// Replacing an Epic game's installed build with its other one (Windows to Mac, or back).
///
/// legendary keeps one build per game and, for a game it has a record of, always installs that
/// record's platform, so the old record has to go before the new build can be installed. Only
/// the record goes first, kept aside beforehand (EpicStore.saveRecord): the old files stay on disk
/// until the new build is fully in, so a Stop, a failed download, legendary falling back to the
/// old platform, or Highball quitting midway puts the old record back from disk and the game is
/// as it was. The old files are deleted last.
public enum EpicBuildSwitch {
    public struct Steps {
        /// Epic has the new build for this account. Asked before anything changes.
        public var hasNewBuild: () async throws -> Bool
        /// Drops legendary's record of the old build, keeping its files; nil when no build is
        /// installed (a plain install).
        public var dropOldRecord: (() async throws -> Void)?
        public var install: () async throws -> Void
        public var restoreOldRecord: () async throws -> Void
        public var deleteOldFiles: () async throws -> Void

        public init(hasNewBuild: @escaping () async throws -> Bool, dropOldRecord: (() async throws -> Void)?,
                    install: @escaping () async throws -> Void, restoreOldRecord: @escaping () async throws -> Void,
                    deleteOldFiles: @escaping () async throws -> Void) {
            self.hasNewBuild = hasNewBuild; self.dropOldRecord = dropOldRecord; self.install = install
            self.restoreOldRecord = restoreOldRecord; self.deleteOldFiles = deleteOldFiles
        }
    }

    public enum Failure: Error, Equatable { case noNewBuild }

    /// Runs the steps in order. A Stop before the old record is dropped changes nothing; after
    /// it, the record is put back. The install's error is rethrown once that is done.
    public static func run(_ steps: Steps) async throws {
        guard try await steps.hasNewBuild() else { throw Failure.noNewBuild }
        try Task.checkCancellation()
        guard let drop = steps.dropOldRecord else { try await steps.install(); return }
        try await drop()
        do {
            try Task.checkCancellation()
            try await steps.install()
        } catch {
            try await steps.restoreOldRecord()
            throw error
        }
        try await steps.deleteOldFiles()
    }

    /// Whether an old build's folder may be deleted: strictly inside one of the folders Highball
    /// installs into, never one of them itself or anything outside. Compared with links resolved
    /// and without case, as the Mac's disks are.
    public static func isSafeToDelete(_ folder: URL, roots: [URL]) -> Bool {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        return roots.contains { root in
            let r = root.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
            return path.hasPrefix(r.hasSuffix("/") ? r : r + "/") && path.count > r.count + 1
        }
    }
}

// MARK: The old record, kept aside

extension EpicStore {
    /// Where a switch keeps the old build's record while it runs, one folder per game: legendary's
    /// installed.json entries for it and the manifests they name. A folder still there when
    /// Highball opens is a switch that never finished (quit mid-download), and its undo is
    /// completed then (restoreSavedRecord).
    var switchesFolder: URL { paths.home.appending(path: "epic-switch", directoryHint: .isDirectory) }

    private func savedRecordFolder(_ appName: String) -> URL {
        switchesFolder.appending(path: Self.cleanFilename(appName), directoryHint: .isDirectory)
    }

    /// Keeps legendary's record of an installed build aside before a switch drops it: the game's
    /// entry in installed.json, its DLC's (which share its folder, and which legendary's uninstall
    /// drops with it), and the manifest files those entries name. Read from disk, no network.
    public func saveRecord(_ appName: String) throws {
        let installed = try Self.readInstalled(configDir)
        guard let game = installed[appName] as? [String: Any] else {
            throw HighballError.failed("legendary has no record of \(appName) to keep")
        }
        let path = game["install_path"] as? String
        let entries = installed.filter { key, value in
            key == appName || (path != nil && (value as? [String: Any])?["install_path"] as? String == path)
        }
        let folder = savedRecordFolder(appName), fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder.appending(path: "manifests"), withIntermediateDirectories: true)
        for name in entries.compactMap({ Self.manifestNames($0.key, entry: $0.value as? [String: Any] ?? [:]) }).joined() {
            let file = configDir.appending(path: "manifests/\(name)")
            if fm.fileExists(atPath: file.path) { try fm.copyItem(at: file, to: folder.appending(path: "manifests/\(name)")) }
        }
        // Written last: a folder without it was never finished, before anything was dropped.
        try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]).write(to: folder.appending(path: "record.json"), options: .atomic)
    }

    /// Puts a kept record back into legendary's installed.json and manifests folder, directly, with
    /// no network and no legendary run, under legendary's own lock on installed.json. Nothing is
    /// written while legendary records the game already (the new build finished, or the old
    /// record was never dropped). The kept copy is then removed. Whether the record went back.
    @discardableResult
    public func restoreSavedRecord(_ appName: String) throws -> Bool {
        let folder = savedRecordFolder(appName), fm = FileManager.default
        guard let data = try? Data(contentsOf: folder.appending(path: "record.json")),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            try? fm.removeItem(at: folder)
            return false
        }
        let restored = try Self.withInstalledLock(configDir) { () throws -> Bool in
            // No installed.json is legendary with no games; one that cannot be read is not written over.
            var installed = try Self.readInstalledIfThere(configDir) ?? [:]
            guard installed[appName] == nil else { return false }
            let manifests = configDir.appending(path: "manifests", directoryHint: .isDirectory)
            try fm.createDirectory(at: manifests, withIntermediateDirectories: true)
            for file in (try? fm.contentsOfDirectory(at: folder.appending(path: "manifests"), includingPropertiesForKeys: nil)) ?? [] {
                let target = manifests.appending(path: file.lastPathComponent)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: file, to: target)
            }
            installed.merge(entries) { $1 }
            try JSONSerialization.data(withJSONObject: installed, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                .write(to: configDir.appending(path: "installed.json"), options: .atomic)
            return true
        }
        try? fm.removeItem(at: folder)
        return restored
    }

    /// Where the old build of a switch still in flight was installed, from its kept record.
    public func savedInstallPath(_ appName: String) -> String? {
        guard let data = try? Data(contentsOf: savedRecordFolder(appName).appending(path: "record.json")),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (entries[appName] as? [String: Any])?["install_path"] as? String
    }

    /// Forgets a kept record once the new build is in.
    public func discardSavedRecord(_ appName: String) {
        try? FileManager.default.removeItem(at: savedRecordFolder(appName))
    }

    /// The games whose switch never finished: a kept record is still there.
    public func switchesInFlight() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: switchesFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "record.json").path) }
            .map(\.lastPathComponent).sorted()
    }

    /// installed.json, or nil when legendary has none yet. Throws when it is there and cannot be read.
    static func readInstalledIfThere(_ configDir: URL) throws -> [String: Any]? {
        let file = configDir.appending(path: "installed.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try readInstalled(configDir)
    }

    static func readInstalled(_ configDir: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: configDir.appending(path: "installed.json"))
        guard let installed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HighballError.failed("legendary's installed.json is not a list of games")
        }
        return installed
    }

    /// The names legendary 0.21.0 gives an entry's manifest (LGDLFS._get_manifest_filename): with
    /// the platform, or the older form without it, which it falls back to.
    static func manifestNames(_ appName: String, entry: [String: Any]) -> [String] {
        guard let version = entry["version"] as? String else { return [] }
        let platform = entry["platform"] as? String ?? "Windows"
        return ["\(appName)_\(platform)_\(version)", "\(appName)_\(version)"].map { cleanFilename($0) + ".manifest" }
    }

    /// legendary's clean_filename: the characters a file name cannot hold, dropped.
    static func cleanFilename(_ name: String) -> String { name.filter { !"<>:\"/\\|?*".contains($0) } }

    /// Runs `body` holding legendary's lock on its install data (installed.json.lock, the
    /// filelock flock every legendary takes before it changes installed.json), so a legendary
    /// still running cannot write over what is put back. Throws when one holds it.
    static func withInstalledLock<T>(_ configDir: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let fd = open(configDir.appending(path: "installed.json.lock").path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw HighballError.failed("could not open legendary's install lock") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw HighballError.failed("legendary is running and holds its install data")
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

// MARK: Finishing a switch, and the old build's files

extension EpicStore {
    /// What launch found for a switch Highball quit in the middle of (switchesInFlight).
    public enum UnfinishedSwitch: Equatable, Sendable {
        /// legendary had no record of the game: the old build's record went back.
        case restored
        /// legendary records the new build in another folder: the old build's files are to go
        /// (deleteOldBuild), from this folder. The kept record stays until they have.
        case deleteOldBuild(String)
        /// legendary still records the old build where it was (Highball quit before its record
        /// was dropped), or nothing was kept: the kept copy is dropped and nothing else changes.
        case leftAsItWas
        /// installed.json could not be read: nothing was changed, and the next launch tries again.
        case unreadable
    }

    /// Completes a switch Highball quit in the middle of, from legendary's installed.json read
    /// directly (no legendary run). The old files are named for deletion only when legendary
    /// records the game in a different folder than the kept record's, so a build still installed
    /// is never taken for a leftover.
    public func finishSwitch(_ appName: String) throws -> UnfinishedSwitch {
        let installed: [String: Any]
        do { installed = try Self.readInstalledIfThere(configDir) ?? [:] } catch { return .unreadable }
        guard let current = installed[appName] as? [String: Any] else {
            return try restoreSavedRecord(appName) ? .restored : .leftAsItWas
        }
        if let old = savedInstallPath(appName), let now = current["install_path"] as? String,
           !Self.samePath(old, now) {
            return .deleteOldBuild(old)
        }
        discardSavedRecord(appName)
        return .leftAsItWas
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        func norm(_ p: String) -> String {
            URL(fileURLWithPath: p, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        }
        return norm(a) == norm(b)
    }

    /// How deleting an old build's files went.
    public enum OldBuildDeletion: Equatable, Sendable {
        /// The files the old build's manifests list were deleted, then the folders left empty.
        /// `failed`, the listed files that were there and could not be deleted.
        case deleted(files: Int, failed: Int)
        /// The folder is not inside one of Highball's game folders: nothing was deleted.
        case outsideGameFolders
        /// legendary could not list the old build's files: nothing was deleted.
        case noFileList(String)
    }

    /// Deletes an old build's files once a switch is done, the way legendary's own uninstall does
    /// (lfs/utils.py delete_filelist): only the files the old build's manifests list, from the
    /// copies the switch kept (saveRecord), read offline by `legendary list-files --manifest`,
    /// then the folders that leaves empty, the build's folder last. Saves, settings and mods the
    /// game wrote beside its files stay. Nothing is deleted outside Highball's game folders
    /// (EpicBuildSwitch.isSafeToDelete) or when the list cannot be had. The kept record goes
    /// afterwards either way.
    public func deleteOldBuild(_ appName: String, at oldPath: String, roots: [URL]) -> OldBuildDeletion {
        defer { discardSavedRecord(appName) }
        let folder = URL(fileURLWithPath: oldPath, isDirectory: true)
        guard EpicBuildSwitch.isSafeToDelete(folder, roots: roots) else { return .outsideGameFolders }
        let files: [String]
        do { files = try oldBuildFiles(appName) } catch { return .noFileList(error.localizedDescription) }
        let (deleted, failed) = Self.deleteFileList(files, in: folder)
        return .deleted(files: deleted, failed: failed)
    }

    /// The files the kept manifests of a switch's old build list: the game's and those of its DLC
    /// sharing its folder. Throws without the game's own manifest or when legendary fails.
    func oldBuildFiles(_ appName: String) throws -> [String] {
        let folder = savedRecordFolder(appName)
        guard let data = try? Data(contentsOf: folder.appending(path: "record.json")),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw HighballError.failed("no kept record of \(appName)'s old build")
        }
        func manifest(_ app: String) -> URL? {
            Self.manifestNames(app, entry: entries[app] as? [String: Any] ?? [:])
                .map { folder.appending(path: "manifests/\($0)") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard let own = manifest(appName) else { throw HighballError.failed("the old build's manifest was not kept") }
        var files: [String] = []
        for file in [own] + entries.keys.filter({ $0 != appName }).sorted().compactMap(manifest) {
            files += try Self.manifestFilenames(capture(["list-files", "--manifest", file.path, "--json"]))
        }
        return files
    }

    /// The `filename`s of `legendary list-files --json`.
    static func manifestFilenames(_ json: String) throws -> [String] {
        guard let list = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else {
            throw HighballError.failed("legendary list-files did not print a list")
        }
        return list.compactMap { $0["filename"] as? String }
    }

    /// legendary's delete_filelist with its delete_root_directory: each listed file is deleted
    /// (found without case, as legendary's case_insensitive_file_search does), then every folder
    /// the list names and the build's folder itself, deepest first, each only when empty. A name
    /// that would leave the folder is skipped. The files deleted and the ones that could not be.
    static func deleteFileList(_ filenames: [String], in folder: URL) -> (deleted: Int, failed: Int) {
        let fm = FileManager.default
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        var deleted = 0, failed = 0
        var dirs = Set<String>()
        for name in filenames {
            let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
                .filter { $0 != "." }
            guard !parts.isEmpty, !parts.contains("..") else { continue }
            for i in 1..<parts.count { dirs.insert(parts[..<i].joined(separator: "/")) }
            guard let file = findIgnoringCase(parts, in: root) else { continue }
            let parent = file.deletingLastPathComponent().resolvingSymlinksInPath().path.lowercased()
            let base = root.path.lowercased()
            guard parent == base || parent.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { continue }
            do { try fm.removeItem(at: file); deleted += 1 } catch { failed += 1 }
        }
        for dir in dirs.sorted(by: { $0.count > $1.count }) {
            if let url = findIgnoringCase(dir.split(separator: "/").map(String.init), in: root) { rmdir(url.path) }
        }
        rmdir(root.path)
        return (deleted, failed)
    }

    /// A path under `root` matched one name at a time, exactly first, then without case.
    private static func findIgnoringCase(_ parts: [String], in root: URL) -> URL? {
        let fm = FileManager.default
        var url = root
        for part in parts {
            let exact = url.appending(path: part)
            if (try? exact.checkResourceIsReachable()) == true || (try? fm.destinationOfSymbolicLink(atPath: exact.path)) != nil {
                url = exact; continue
            }
            guard let match = (try? fm.contentsOfDirectory(atPath: url.path))?.first(where: { $0.lowercased() == part.lowercased() })
            else { return nil }
            url = url.appending(path: match)
        }
        return url
    }
}
