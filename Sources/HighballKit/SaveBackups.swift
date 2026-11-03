import CryptoKit
import Darwin
import Foundation

/// Backups of a game's saves, taken before a sync could replace them, stored at
/// save-backups/<game>-<location>-<install>/<date>-<kind>[-kept]/. The store tools replace saves
/// wholesale (gogdl deletes whatever the other side lacks, and legendary empties the save folder
/// before a download), so anything a sync could replace is backed up first, and a failed backup
/// stops the sync.
///
/// Backups come in two kinds, the Mac's saves and a cloud's, and each kind rotates on its own: the
/// newest `keep` of each stay. Kept backups (made before an uninstall, or before the player picked
/// a side in a conflict) and pinned ones (a download's, until it is done or undone) are never
/// pruned. A backup identical to the newest of its kind is not made again.
public struct SaveBackups: Sendable {
    public let root: URL
    static let keep = 10

    public init(root: URL) { self.root = root }

    /// What a backup holds: the Mac's saves or a cloud's.
    public enum Kind: String, Sendable { case mac, cloud }

    /// The backup folder for one install and location. The install is part of the name (sync
    /// history is per install too), so a second copy of the game never rotates out the first
    /// one's backups.
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

    /// Backups are named <date>-<kind>[-kept].
    public static func kind(of backup: URL) -> Kind? {
        let name = backup.lastPathComponent
        return name.contains("-cloud") ? .cloud : name.contains("-mac") ? .mac : nil
    }
    public static func isKept(_ backup: URL) -> Bool { backup.lastPathComponent.contains("-kept") }

    // MARK: Files

    /// Every file a sync touches, as the store tools walk a folder: hidden files too, and into a
    /// linked folder (gogdl's os.path.isdir and legendary's os.walk follow links). A folder
    /// reached twice through links is walked once. Throws for a folder inside it that can't be
    /// read; one that isn't there holds nothing.
    static func walk(_ folder: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        var files: [URL] = [], walked = Set<String>()
        func walk(_ dir: URL) throws {
            guard walked.insert(dir.resolvingSymlinksInPath().path).inserted else { return }
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() {
                let item = dir.appending(path: name)
                var isFolder: ObjCBool = false
                if FileManager.default.fileExists(atPath: item.path, isDirectory: &isFolder), isFolder.boolValue { try walk(item) } else { files.append(item) }
            }
        }
        try walk(folder)
        return files
    }

    public static func files(in folder: URL) -> [URL] { (try? walk(folder)) ?? [] }

    /// The files in `folder` that `filter` picks, the ones a sync can replace.
    public static func files(in folder: URL, matching filter: SaveFilter) -> [URL] {
        guard !filter.isEverything else { return files(in: folder) }
        return files(in: folder).filter { filter.matches(relativePath($0, in: folder)) }
    }

    /// A file's path below `folder`, with "/" between components, as the filters and the store
    /// tools name it: by the path walked, not where a link leads.
    static func relativePath(_ file: URL, in folder: URL) -> String {
        String(file.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
    }

    // MARK: Fingerprints

    /// A digest of a folder's files (those `filter` picks): each one's path, size and last change.
    /// When it matches a backup's, a new backup would be a duplicate.
    public static func fingerprint(_ folder: URL, filter: SaveFilter = .everything) -> String {
        fingerprint(folder, files: files(in: folder, matching: filter))
    }

    /// The same digest of some of `folder`'s files, as walk names them.
    public static func fingerprint(_ folder: URL, files chosen: [URL]) -> String {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let lines = chosen.map { file -> String in
            let values = try? file.resolvingSymlinksInPath().resourceValues(forKeys: keys)
            return "\(relativePath(file, in: folder))\t\(values?.fileSize ?? 0)\t\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return "mac " + digest(lines)
    }

    public static func digest(_ lines: [String]) -> String {
        SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Stored next to the backup rather than inside it, so restoring a backup by hand never puts
    /// this file in the game's folder, where a sync would upload it with the saves.
    public static func fingerprintFile(of backup: URL) -> URL {
        backup.deletingLastPathComponent().appending(path: backup.lastPathComponent + ".fingerprint")
    }

    // MARK: Making backups

    /// The newest backup of that kind when it holds exactly `fingerprint`. A kept backup asked
    /// for when the match isn't kept yet turns the match into a kept one instead of copying again.
    public func reuse(in dir: URL, kind: Kind, fingerprint: String, kept: Bool) -> URL? {
        guard let newest = backups(in: dir).first(where: { Self.kind(of: $0) == kind }),
              (try? String(contentsOf: Self.fingerprintFile(of: newest), encoding: .utf8)) == fingerprint else { return nil }
        guard kept, !Self.isKept(newest) else { return newest }
        let promoted = dir.appending(path: newest.lastPathComponent + "-kept", directoryHint: .isDirectory)
        guard (try? FileManager.default.moveItem(at: newest, to: promoted)) != nil else { return nil }
        try? FileManager.default.moveItem(at: Self.fingerprintFile(of: newest), to: Self.fingerprintFile(of: promoted))
        try? FileManager.default.moveItem(at: Self.pinFile(of: newest), to: Self.pinFile(of: promoted))
        return promoted
    }

    /// Backs up the local saves before something could replace or delete them: the files `filter`
    /// picks, which are the ones a download replaces. Returns the newest Mac backup when nothing
    /// has changed since it, or nil when there is nothing to back up. `kept` backups are never
    /// pruned. `only` limits it to some of the folder's files, as walk names them (`filter` still
    /// applies). Throws if the backup fails, leaving no partial copy behind; the caller must then
    /// stop.
    @discardableResult
    public func backUpLocal(_ folder: URL, into dir: URL, filter: SaveFilter = .everything, kept: Bool = false,
                            only: [URL]? = nil) throws -> URL? {
        // A folder that can't be read fails the copy: its saves would go uncopied.
        let picked = try (only ?? Self.walk(folder)).filter { filter.isEverything || filter.matches(Self.relativePath($0, in: folder)) }
        guard !picked.isEmpty else { return nil }
        let fingerprint = Self.fingerprint(folder, files: picked)
        if let same = reuse(in: dir, kind: .mac, fingerprint: fingerprint, kept: kept) { return same }
        return try backUp(into: dir, kind: .mac, kept: kept, fingerprint: fingerprint) { partial in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // What a link points at, not the link: the tools write through it, so a download
            // replaces the file it points to. A link to nothing holds nothing to keep.
            for file in picked {
                let source = file.resolvingSymlinksInPath()
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let destination = partial.appending(path: Self.relativePath(file, in: folder))
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: destination)
            }
            return nil
        }
    }

    /// Makes a new backup of `kind`, filled by `fill` under a ".partial" name and renamed only once
    /// complete, so a failed backup never sits among the real ones. `fingerprint`, when known, is
    /// stored beside it (`fill` may also return one it learned while filling). Then prunes that
    /// kind's backups to the newest `keep`, never removing this one, a kept one or a pinned one.
    public func backUp(into dir: URL, kind: Kind, kept: Bool, fingerprint: String? = nil,
                       fill: (URL) throws -> String?) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        removeStalePartials(in: dir)
        let target = newBackup(in: dir, label: kept ? "\(kind.rawValue)-kept" : kind.rawValue)
        let partial = dir.appending(path: target.lastPathComponent + ".partial", directoryHint: .isDirectory)
        let learned: String?
        do {
            learned = try fill(partial)
            try FileManager.default.moveItem(at: partial, to: target)
            // A copied folder keeps the source's creation date, often years old. Date the backup
            // now so pruning keeps the newest ones.
            try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: target.path)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        if let value = fingerprint ?? learned {
            try? value.write(to: Self.fingerprintFile(of: target), atomically: true, encoding: .utf8)
        }
        // Compare by name: the same folder can appear under both /var and /private/var.
        let rotating = backups(in: dir).filter {
            $0.lastPathComponent != target.lastPathComponent && Self.kind(of: $0) == kind && !Self.isKept($0) && !Self.isPinned($0)
        }
        for old in rotating.dropFirst(Self.keep - 1) {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: Self.fingerprintFile(of: old))
        }
        return target
    }

    /// A backup left half-filled by a crash or a forced quit: older than an hour, so no sync
    /// running now is still filling it.
    private func removeStalePartials(in dir: URL) {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for partial in all where partial.pathExtension == "partial" {
            let made = (try? partial.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if made < Date().addingTimeInterval(-3600) { try? FileManager.default.removeItem(at: partial) }
        }
    }

    /// A location's complete backups, newest first by creation date rather than by name, so a
    /// clock that was once wrong never gets today's backup pruned as the oldest.
    public func backups(in dir: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        func made(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return all.filter { !["partial", "fingerprint", "pinned"].contains($0.pathExtension) }.sorted { made($0) > made($1) }
    }

    // MARK: Pins and restoring

    /// A pinned backup is never pruned: a download pins its backup until it is done or undone, so
    /// the copy it may need to put back is still there however many backups are made meanwhile.
    static func pinFile(of backup: URL) -> URL {
        backup.deletingLastPathComponent().appending(path: backup.lastPathComponent + ".pinned")
    }
    public static func isPinned(_ backup: URL) -> Bool { FileManager.default.fileExists(atPath: pinFile(of: backup).path) }
    public static func pin(_ backup: URL) throws { try Data().write(to: pinFile(of: backup)) }
    public static func unpin(_ backup: URL) { try? FileManager.default.removeItem(at: pinFile(of: backup)) }

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
