import Foundation

/// Copies of a game's saves taken before a sync could replace them, in the Highball folder:
/// save-backups/<game>-<location>-<install>/<date>-<mac|cloud>/. Store tools replace saves
/// wholesale (gogdl deletes what the other side lacks, legendary empties the folder before a
/// download), so whatever a sync could replace is copied first, and a failed copy stops the sync.
/// The newest `keep` copies per install and location stay.
public struct SaveBackups: Sendable {
    public let root: URL
    static let keep = 10

    public init(root: URL) { self.root = root }

    /// One install's backups of one location: the install is in the name, so a second copy of the
    /// game never rotates out the first one's backups.
    public func folder(_ name: String, install: URL) -> URL {
        // FNV-1a over the install's path: short, and the same from one run to the next.
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

    /// Every file a sync sees: hidden files and links too, which the store tools replace or delete.
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

    /// What a folder holds, in brief (files, bytes, latest change): two equal mean a new copy would
    /// only repeat the last one.
    static func fingerprint(_ folder: URL) -> String {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let values = files(in: folder).map { try? $0.resourceValues(forKeys: keys) }
        let bytes = values.reduce(0) { $0 + ($1?.fileSize ?? 0) }
        let latest = values.compactMap { $0?.contentModificationDate?.timeIntervalSince1970 }.max() ?? 0
        return "\(values.count) \(bytes) \(latest)"
    }

    /// Beside a copy, not in it: a copy restored by hand never carries it into the game's folder,
    /// where a sync would upload it with the saves.
    static func fingerprintFile(of backup: URL) -> URL {
        backup.deletingLastPathComponent().appending(path: backup.lastPathComponent + ".fingerprint")
    }

    /// A copy of the saves on the Mac, before a download could replace them: the newest copy when
    /// nothing changed since it, nil when there is nothing to copy. Throws when the copy fails, and
    /// leaves no half copy behind: then nothing may replace them.
    @discardableResult
    public func backUpLocal(_ folder: URL, into dir: URL) throws -> URL? {
        guard !Self.files(in: folder).isEmpty else { return nil }
        let fingerprint = Self.fingerprint(folder)
        if let newest = backups(in: dir).first, (try? String(contentsOf: Self.fingerprintFile(of: newest), encoding: .utf8)) == fingerprint {
            return newest
        }
        let target = try backUp(into: dir, label: "mac") { partial in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: folder, to: partial)
        }
        try? fingerprint.write(to: Self.fingerprintFile(of: target), atomically: true, encoding: .utf8)
        return target
    }

    /// A new copy, filled by `fill` under a ".partial" name and given its own name only once
    /// complete, so a failed copy never sits among the real ones; then the newest `keep` stay,
    /// never this one.
    public func backUp(into dir: URL, label: String, fill: (URL) throws -> Void) throws -> URL {
        let target = newBackup(in: dir, label: label)
        let partial = dir.appending(path: target.lastPathComponent + ".partial", directoryHint: .isDirectory)
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
        for old in backups(in: dir).filter({ $0.lastPathComponent != target.lastPathComponent }).dropFirst(Self.keep - 1) {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: Self.fingerprintFile(of: old))
        }
        return target
    }

    /// A location's complete backups, newest first by when they were made (not by name: a Mac
    /// whose clock was wrong once must not prune today's copy as the oldest).
    public func backups(in dir: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        func made(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return all.filter { !["partial", "fingerprint"].contains($0.pathExtension) }.sorted { made($0) > made($1) }
    }
}
