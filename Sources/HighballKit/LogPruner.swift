import Foundation

/// Keeps Highball's log directory bounded. One file per launch under `fixme-all` is small, but
/// a week of investigations with debug channels on left 3.8 GB behind (2026-09-04), and nobody
/// prunes a directory they never open. The policy is pure so it can be tested; `prune` applies it.
public enum LogPruner {
    public struct Entry: Equatable, Sendable {
        public let url: URL
        public let size: Int64
        public let modified: Date
        public init(url: URL, size: Int64, modified: Date) { self.url = url; self.size = size; self.modified = modified }
    }

    /// Files that never go: the verifier's results are the database's provenance.
    static let keepAlways: Set<String> = ["verify-results.jsonl"]

    /// Deletes, in order: anything older than `keepDays` beyond the newest `keepNewest` files,
    /// then the oldest of what remains until the total is at most `maxTotalBytes`. The size rule
    /// spares only the newest `protectNewest` files, so a handful of huge traces cannot hide
    /// behind the age rule's allowance; the log a user is about to attach still exists.
    public static func plan(_ entries: [Entry], now: Date = Date(), keepDays: Int = 14,
                            maxTotalBytes: Int64 = 300 * 1024 * 1024, keepNewest: Int = 50, protectNewest: Int = 5) -> [URL] {
        let candidates = entries.filter { !keepAlways.contains($0.url.lastPathComponent) }
            .sorted { $0.modified > $1.modified }          // newest first
        var remove: [URL] = []
        var kept: [Entry] = []
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        for (i, e) in candidates.enumerated() {
            if i >= keepNewest && e.modified < cutoff { remove.append(e.url) } else { kept.append(e) }
        }
        var total = kept.reduce(Int64(0)) { $0 + $1.size }
        for e in kept.reversed() where total > maxTotalBytes {   // oldest first
            guard let idx = kept.firstIndex(of: e), idx >= protectNewest else { break }
            remove.append(e.url); total -= e.size
        }
        return remove
    }

    /// Applies `plan` to a directory. Errors on single files are ignored: a log held open by a
    /// running process is simply pruned next time.
    @discardableResult
    public static func prune(directory: URL, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return 0 }
        let entries: [Entry] = urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  v.isRegularFile == true else { return nil }
            return Entry(url: url, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast)
        }
        let doomed = plan(entries, now: now)
        for url in doomed { try? fm.removeItem(at: url) }
        return doomed.count
    }
}
