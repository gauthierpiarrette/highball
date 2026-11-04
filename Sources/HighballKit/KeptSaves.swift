import Foundation

/// When Highball first installed (or set up) a game in an environment and when it updated it, so
/// an uninstall can tell the files the game wrote from the ones the installer and the patches put
/// down. GOG keeps it next to its setup marker (GOGStore.InstallHistory), Epic next to its own
/// (EpicSaves.historyFile).
public struct GameInstallHistory: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable {
        public let start: Date
        public let end: Date
        public init(start: Date, end: Date) { self.start = start; self.end = end }
    }
    public var firstSetup: Date?
    public var updates: [Window] = []

    public init(firstSetup: Date? = nil, updates: [Window] = []) { self.firstSetup = firstSetup; self.updates = updates }

    /// Written by the game: changed after the first setup, and not while an update ran.
    public func isGameWritten(_ changed: Date) -> Bool {
        guard let firstSetup, changed > firstSetup else { return false }
        return !updates.contains { $0.start <= changed && changed <= $0.end }
    }

    public static func read(_ url: URL) -> GameInstallHistory? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(GameInstallHistory.self, from: $0) }
    }

    public func write(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// What an uninstall kept of a game's saves, so installing it again can put them back (GOG and
/// Epic).
public struct KeptSaves: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// What `path` is relative to.
        public enum Place: String, Codable, Sendable {
            /// The game's folder, as GOG writes every entry (no place stored).
            case game
            /// The environment's folder: an Epic save folder elsewhere in it.
            case environment
            /// Nothing: an absolute path, such as a Mac folder an environment links to.
            case absolute
        }
        /// The location's name, or the game-folder copy's.
        public let name: String
        /// Where its files sat, relative to `place`; empty for that folder itself.
        public let path: String
        public let backup: URL
        public var place: Place? = nil

        public init(name: String, path: String, backup: URL, place: Place? = nil) {
            self.name = name; self.path = path; self.backup = backup; self.place = place
        }

        /// Where `folder` is recorded from: below the game's folder, else below the environment,
        /// else as it is.
        public init(name: String, folder: URL, backup: URL, install: URL, environment: URL?) {
            func below(_ root: URL) -> String? {
                let path = folder.standardizedFileURL.path, base = root.standardizedFileURL.path
                if path == base { return "" }
                return path.hasPrefix(base + "/") ? SaveBackups.relativePath(folder, in: root) : nil
            }
            if let path = below(install) {
                self.init(name: name, path: path, backup: backup, place: .game)
            } else if let environment, let path = below(environment) {
                self.init(name: name, path: path, backup: backup, place: .environment)
            } else {
                self.init(name: name, path: folder.standardizedFileURL.path, backup: backup, place: .absolute)
            }
        }

        /// Where the files go back in a new install.
        public func folder(install: URL, environment: URL?) -> URL? {
            func below(_ root: URL) -> URL { path.isEmpty ? root : root.appending(path: path) }
            switch place ?? .game {
            case .game: return below(install)
            case .environment: return environment.map(below)
            case .absolute: return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
    }
    public var date: Date
    public var entries: [Entry]
    /// Install folders already asked, whatever the answer: never asked again.
    public var asked: [String]

    public init(date: Date, entries: [Entry], asked: [String]) { self.date = date; self.entries = entries; self.asked = asked }
}

/// Every game's kept saves for one store, by game id, in one file (gog/kept-saves.json,
/// epic-kept-saves.json).
public struct KeptSavesFile: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func all() -> [String: KeptSaves] {
        (try? JSONDecoder().decode([String: KeptSaves].self, from: Data(contentsOf: url))) ?? [:]
    }

    private static let lock = NSLock()
    public func update(_ change: (inout [String: KeptSaves]) -> Void) {
        Self.lock.withLock {
            var all = all()
            change(&all)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(all).write(to: url, options: .atomic)
        }
    }

    /// Remembers what an uninstall kept of a game in place of what an earlier one kept: a location
    /// this one had nothing for never brings back an older copy, and keeping nothing offers
    /// nothing. `otherInstalls` (copies of the game still installed elsewhere) are never asked:
    /// they still have their own saves.
    public func keep(_ entries: [KeptSaves.Entry], for id: String, otherInstalls: [URL]) {
        update { all in
            all[id] = entries.isEmpty ? nil : KeptSaves(date: Date(), entries: entries, asked: otherInstalls.map(\.standardizedFileURL.path))
        }
    }

    /// The install was asked about putting saves back: it is not asked again.
    public func markAsked(_ id: String, install: URL) {
        update { $0[id]?.asked.append(install.standardizedFileURL.path) }
    }

    /// Kept saves this install hasn't been asked about, from what all() read.
    public static func toOffer(_ kept: KeptSaves?, install: URL) -> KeptSaves? {
        guard let kept, !kept.asked.contains(install.standardizedFileURL.path) else { return nil }
        return kept
    }
}

extension SaveBackups {
    /// The files under `folder` the game wrote, by the install's history, links counted by what
    /// they point at. Throws for a folder inside it that can't be read.
    public static func files(in folder: URL, writtenPer history: GameInstallHistory) throws -> [URL] {
        try walk(folder).filter { file in
            let changed = try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return history.isGameWritten(changed ?? .distantPast)
        }
    }

    /// How many files a backup holds and their size, for the log.
    public static func contents(of backup: URL) -> (files: Int, bytes: Int64) {
        let all = files(in: backup)
        let bytes = all.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return (all.count, bytes)
    }

    /// Whether a save folder may be deleted with its game, for a player who asked for that: with
    /// links followed, it lies inside the environment's drive_c (an environment's Documents is
    /// often a link to the Mac's own, whose folders are the Mac's), and it neither holds nor sits
    /// inside any of `sparing` (Highball's save-backups, the game's folder).
    public static func mayDelete(_ folder: URL, driveC: URL, sparing: [URL]) -> Bool {
        func path(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        func overlap(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") }
        let real = path(folder)
        return real.hasPrefix(path(driveC) + "/") && !sparing.map(path).contains { overlap(real, $0) }
    }

    /// Puts a kept backup's files back into `target`, each to the same place below it, through a
    /// link as the store tools write. `backUpFirst` is handed the files already there before any
    /// is replaced, so a newer one is never lost. `redate` dates the copies now (a game-folder
    /// copy, so the next uninstall counts them as the game's). Returns how many files were put
    /// back; throws, having put back what it had, when a copy fails.
    public static func putBack(_ backup: URL, into target: URL, redate: Bool, backUpFirst: ([URL]) throws -> Void) throws -> Int {
        let files = try walk(backup).map { ($0, relativePath($0, in: backup)) }
        let there = files.map { target.appending(path: $0.1) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !there.isEmpty { try backUpFirst(there) }
        for (file, path) in files {
            let copy = target.appending(path: path).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
            try FileManager.default.copyItem(at: file, to: copy)
            if redate { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: copy.path) }
        }
        return files.count
    }
}
