import Foundation

/// Backups of a game's saves, taken before a sync could replace them, stored at
/// save-backups/<game>-<location>-<install>/<date>-<mac|cloud>/. The store tools replace saves
/// wholesale (gogdl deletes whatever the other side lacks, and legendary empties the save folder
/// before a download), so anything a sync could replace is backed up first, and a failed backup
/// stops the sync. The newest `keep` backups per install and location are kept.
public struct SaveBackups: Sendable {
    public let root: URL
    static let keep = 10

    public init(root: URL) { self.root = root }

    /// The backup folder for one install and location. The install is part of the name, so a
    /// second copy of the game never rotates out the first one's backups.
    public func folder(_ name: String, install: URL) -> URL {
        // FNV-1a of the install path: short and stable across runs.
        let hash = install.standardizedFileURL.path.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        return root.appending(path: "\(name)-\(String(hash, radix: 16).prefix(8))", directoryHint: .isDirectory)
    }

    private func newBackup(in dir: URL, label: String) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        var name = "\(stamp)-\(label)", n = 1
        while FileManager.default.fileExists(atPath: dir.appending(path: name).path) { n += 1; name = "\(stamp)-\(label)-\(n)" }
        return dir.appending(path: name, directoryHint: .isDirectory)
    }

    /// Every file a sync touches. The store tools include hidden files and symlinks, and replace
    /// or delete them too.
    public static func files(in folder: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys))
        var files: [URL] = []
        while let file = walker?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: keys)
            if values?.isRegularFile == true || values?.isSymbolicLink == true { files.append(file) }
        }
        return files
    }

    /// The files in `folder` that `filter` picks, the ones a sync can replace.
    public static func files(in folder: URL, matching filter: SaveFilter) -> [URL] {
        guard !filter.isEverything else { return files(in: folder) }
        return files(in: folder).filter { filter.matches(relativePath($0, in: folder)) }
    }

    /// A file's path below `folder`, with "/" between components, as the filters see it.
    static func relativePath(_ file: URL, in folder: URL) -> String {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parts = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard parts.starts(with: base) else { return file.lastPathComponent }
        return parts.dropFirst(base.count).joined(separator: "/")
    }

    /// A summary of a folder (file count, total bytes, latest change). When it matches the last
    /// backup's, a new backup would be a duplicate.
    static func fingerprint(_ folder: URL, filter: SaveFilter = .everything) -> String {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let values = files(in: folder, matching: filter).map { try? $0.resourceValues(forKeys: keys) }
        let bytes = values.reduce(0) { $0 + ($1?.fileSize ?? 0) }
        let latest = values.compactMap { $0?.contentModificationDate?.timeIntervalSince1970 }.max() ?? 0
        return "\(values.count) \(bytes) \(latest)"
    }

    /// Stored next to the backup rather than inside it, so restoring a backup by hand never puts
    /// this file in the game's folder, where a sync would upload it with the saves.
    static func fingerprintFile(of backup: URL) -> URL {
        backup.deletingLastPathComponent().appending(path: backup.lastPathComponent + ".fingerprint")
    }

    /// Backs up the local saves before a download could replace them: the files `filter` picks,
    /// which are the ones a download replaces. Returns the newest existing backup when nothing
    /// has changed since it, or nil when there is nothing to back up. Throws if the backup fails,
    /// leaving no partial copy behind; the sync must then stop.
    @discardableResult
    public func backUpLocal(_ folder: URL, into dir: URL, filter: SaveFilter = .everything) throws -> URL? {
        let picked = Self.files(in: folder, matching: filter)
        guard !picked.isEmpty else { return nil }
        let fingerprint = Self.fingerprint(folder, filter: filter)
        if let newest = backups(in: dir).first, (try? String(contentsOf: Self.fingerprintFile(of: newest), encoding: .utf8)) == fingerprint {
            return newest
        }
        let target = try backUp(into: dir, label: "mac") { partial in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if filter.isEverything {
                try FileManager.default.copyItem(at: folder, to: partial)
            } else {
                for file in picked {
                    let destination = partial.appending(path: Self.relativePath(file, in: folder))
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: file, to: destination)
                }
            }
        }
        try? fingerprint.write(to: Self.fingerprintFile(of: target), atomically: true, encoding: .utf8)
        return target
    }

    /// Makes a new backup, filled by `fill` under a ".partial" name and renamed only once
    /// complete, so a failed backup never sits among the real ones. Then prunes to the newest
    /// `keep`, never removing this one.
    public func backUp(into dir: URL, label: String, fill: (URL) throws -> Void) throws -> URL {
        let target = newBackup(in: dir, label: label)
        let partial = dir.appending(path: target.lastPathComponent + ".partial", directoryHint: .isDirectory)
        do {
            try fill(partial)
            try FileManager.default.moveItem(at: partial, to: target)
            // A copied folder keeps the source's creation date, often years old. Date the backup
            // now so pruning keeps the newest ones.
            try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: target.path)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        // Compare by name: the same folder can appear under both /var and /private/var.
        for old in backups(in: dir).filter({ $0.lastPathComponent != target.lastPathComponent }).dropFirst(Self.keep - 1) {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: Self.fingerprintFile(of: old))
        }
        return target
    }

    /// A location's complete backups, newest first by creation date rather than by name, so a
    /// clock that was once wrong never gets today's backup pruned as the oldest.
    public func backups(in dir: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        func made(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return all.filter { !["partial", "fingerprint"].contains($0.pathExtension) }.sorted { made($0) > made($1) }
    }

    /// Puts a backup's files back into `folder`: first removes the files `filter` picks there
    /// (what a failed download may have left half written), then copies the backup's files in,
    /// keeping their dates. A nil backup means the folder held none of those files, so it ends
    /// up without them again.
    public static func restore(_ backup: URL?, into folder: URL, filter: SaveFilter) throws {
        for file in files(in: folder, matching: filter) { try FileManager.default.removeItem(at: file) }
        guard let backup else { return }
        for file in files(in: backup) {
            let destination = folder.appending(path: relativePath(file, in: backup))
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: destination)
        }
    }
}

/// Which files in a save folder belong to the saves, from a game's CloudIncludeList and
/// CloudExcludeList, matched the way legendary 0.21.0 does (utils/savegame_helper.py
/// `_filename_matches`): a pattern ending in "/" matches a path starting with it, any pattern
/// matches a path ending with it, and "*" wildcards match as Python's fnmatch does, across "/"
/// too. With an include list, only matching files count; an exclude list then removes some.
public struct SaveFilter: Sendable, Equatable {
    public let include: [String]?
    public let exclude: [String]?

    public init(include: [String]?, exclude: [String]?) { self.include = include; self.exclude = exclude }
    public static let everything = SaveFilter(include: nil, exclude: nil)

    /// legendary splits the attributes on "," without trimming, and so does this.
    public init(includeList: String?, excludeList: String?) {
        self.init(include: includeList.map { $0.components(separatedBy: ",") },
                  exclude: excludeList.map { $0.components(separatedBy: ",") })
    }

    var isEverything: Bool { (include ?? []).isEmpty && (exclude ?? []).isEmpty }

    public func matches(_ path: String) -> Bool {
        if let include, !include.isEmpty, !Self.matches(path, include) { return false }
        if let exclude, !exclude.isEmpty, Self.matches(path, exclude) { return false }
        return true
    }

    static func matches(_ path: String, _ patterns: [String]) -> Bool {
        patterns.contains { pattern in
            (pattern.hasSuffix("/") && path.hasPrefix(pattern)) || path.hasSuffix(pattern)
                || fnmatch(pattern, path, 0) == 0
        }
    }
}
