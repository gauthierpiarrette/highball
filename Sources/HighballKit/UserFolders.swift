import Foundation

/// The user folders Wine links to the Mac's own. wineboot makes `drive_c/users/<name>/Documents`
/// (and Desktop, Downloads, Music, Pictures, Videos) symlinks to ~/Documents and so on, so a game
/// that saves under Documents writes into the macOS folder and its saves outlive the environment.
/// Two people asked for the opposite (discussion #157): saves inside the environment, nothing
/// in ~/Documents. This swaps Documents between the two shapes, and nothing else:
///
/// - inside: the link is removed and a real folder takes its place. A folder kept by an earlier
///   switch back (`Documents (environment)`) is restored instead of starting empty. Files that
///   live in ~/Documents stay there; the game starts fresh inside, which the caption says.
/// - linked: a real folder is renamed to `Documents (environment)` (or removed when empty) and
///   the link to ~/Documents comes back. Nothing is deleted silently.
///
/// wineboot only creates the link when the path does not exist, so a real folder survives the
/// Windows setup re-running on an engine move or a repair.
public enum UserFolders {
    public static let folder = "Documents"
    public static let keptName = "Documents (environment)"

    /// What the folder is right now, so the UI can say it and a switch can be a no-op.
    public enum Shape: Equatable, Sendable { case linked(to: String), inside, missing }

    /// Every real user directory under drive_c/users: Wine's own `Public` is skipped, and so is
    /// anything that is not a directory.
    public static func userDirectories(driveC: URL) -> [URL] {
        let users = driveC.appending(path: "users", directoryHint: .isDirectory)
        let entries = (try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries.filter { url in
            url.lastPathComponent != "Public"
                && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func shape(userDirectory: URL) -> Shape {
        let path = userDirectory.appending(path: folder).path
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) { return .linked(to: target) }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return .inside }
        return .missing
    }

    /// Puts Documents in the asked shape in one user directory. `host` is the macOS Documents the
    /// link points at when going back (the same one wineboot would pick). Returns one line per
    /// change for the log, none when nothing had to move.
    @discardableResult
    public static func set(inside: Bool, userDirectory: URL, host: URL) throws -> [String] {
        let fm = FileManager.default
        let doc = userDirectory.appending(path: folder, directoryHint: .isDirectory)
        let kept = userDirectory.appending(path: keptName, directoryHint: .isDirectory)
        var notes: [String] = []
        switch (shape(userDirectory: userDirectory), inside) {
        case (.inside, true), (.linked, false):
            return []
        case (.linked, true), (.missing, true):
            if fm.fileExists(atPath: doc.path) || (try? fm.destinationOfSymbolicLink(atPath: doc.path)) != nil {
                try fm.removeItem(at: doc)
            }
            if fm.fileExists(atPath: kept.path) {
                try fm.moveItem(at: kept, to: doc)
                notes.append("\(userDirectory.lastPathComponent): Documents is inside the environment again, the folder kept from before is back")
            } else {
                try fm.createDirectory(at: doc, withIntermediateDirectories: true)
                notes.append("\(userDirectory.lastPathComponent): Documents is a folder inside the environment now; files already in \(host.path) stay there")
            }
        case (.inside, false), (.missing, false):
            if fm.fileExists(atPath: doc.path) {
                let contents = (try? fm.contentsOfDirectory(atPath: doc.path)) ?? []
                if contents.isEmpty {
                    try fm.removeItem(at: doc)
                } else {
                    if fm.fileExists(atPath: kept.path) { try fm.removeItem(at: kept) }
                    try fm.moveItem(at: doc, to: kept)
                    notes.append("\(userDirectory.lastPathComponent): the environment's Documents is kept as \(keptName)")
                }
            }
            try fm.createSymbolicLink(at: doc, withDestinationURL: host)
            notes.append("\(userDirectory.lastPathComponent): Documents links to \(host.path) again")
        }
        return notes
    }

    /// The same for every user directory of a prefix.
    @discardableResult
    public static func set(inside: Bool, driveC: URL, host: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents")) throws -> [String] {
        try userDirectories(driveC: driveC).flatMap { try set(inside: inside, userDirectory: $0, host: host) }
    }

    /// True when a user directory holds a Documents folder inside with something in it: what a
    /// deletion would take with it.
    public static func hasFilesInside(driveC: URL) -> Bool {
        userDirectories(driveC: driveC).contains { dir in
            guard shape(userDirectory: dir) == .inside else { return false }
            return !((try? FileManager.default.contentsOfDirectory(atPath: dir.appending(path: folder).path)) ?? []).isEmpty
        }
    }
}
