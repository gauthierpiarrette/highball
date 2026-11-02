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
            var installed = (try? Self.readInstalled(configDir)) ?? [:]
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
