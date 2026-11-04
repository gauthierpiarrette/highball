import Foundation

/// The game saves an environment holds, kept when the environment is deleted. Games save under
/// the Windows user's folders in drive_c/users/<name>: Saved Games, Documents (My Games), and
/// AppData's Roaming, Local and LocalLow. Deleting the environment took all of them with it.
///
/// - Documents counts only when it is a folder inside the environment. The usual link to the
///   Mac's Documents survives the delete anyway, and is never walked into.
/// - Caches, temp files, logs and crash dumps are left out by name, and so are the Steam
///   client's and Windows' own folders under AppData/Local: bulk, not saves.
/// - A link inside these folders is copied as what it points at, because games write through
///   them. A link to nothing is skipped, a link out of the environment is never followed (it
///   could lead into the Mac's home folders), and a folder reached twice is copied once.
public enum EnvironmentSaves {
    /// The save folders under a Windows user's directory.
    public static let folders = ["Saved Games", "Documents", "AppData/Roaming", "AppData/Local", "AppData/LocalLow"]
    /// Folder names left out wherever they appear, compared lowercased.
    public static let skippedNames: Set<String> = [
        "cache", "caches", "temp", "tmp", "htmlcache", "shadercache", "gpucache", "d3dscache",
        "crashpad", "crashdumps", "logs",
    ]
    /// Folder names left out directly under AppData/Local, compared lowercased.
    public static let skippedInLocal: Set<String> = ["steam", "microsoft"]

    /// One folder or file to keep. `path` is where it goes in the copy, starting with the user name.
    public struct Entry: Equatable, Sendable {
        public let source: URL
        public let path: String
        public let isDirectory: Bool
        public let bytes: Int64
    }

    /// Everything a copy of the saves takes, folders before what they hold.
    public static func entries(environment: URL) -> [Entry] {
        guard let root = realPath(environment) else { return [] }
        let driveC = URL(fileURLWithPath: root).appending(path: "drive_c", directoryHint: .isDirectory)
        var visited = Set<String>()
        var out: [Entry] = []
        for user in UserFolders.userDirectories(driveC: driveC) {
            for folder in folders {
                let url = user.appending(path: folder)
                if folder == UserFolders.folder, UserFolders.shape(userDirectory: user) != .inside { continue }
                guard let real = inside(url, root: root) else { continue }
                walk(real, path: "\(user.lastPathComponent)/\(folder)", inLocal: folder == "AppData/Local",
                     root: root, visited: &visited, into: &out)
            }
        }
        return out
    }

    /// The size of the copy, in bytes.
    public static func bytes(environment: URL) -> Int64 {
        entries(environment: environment).reduce(0) { $0 + $1.bytes }
    }

    /// Copies the saves into `backups/environments/<name>-<date>`, filled under a `.partial` name
    /// and renamed when complete, so the folder is either whole or absent. Returns the folder and
    /// the bytes copied, or nil when the environment holds no saved file at all.
    public static func keep(environment: URL, name: String, backups: URL, date: Date = Date()) throws -> (folder: URL, bytes: Int64)? {
        let all = entries(environment: environment)
        guard all.contains(where: { !$0.isDirectory }) else { return nil }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let parent = backups.appending(path: "environments", directoryHint: .isDirectory)
        let folder = parent.appending(path: "\(name)-\(stamp.string(from: date))", directoryHint: .isDirectory)
        let partial = parent.appending(path: folder.lastPathComponent + ".partial", directoryHint: .isDirectory)
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: partial)
            try fm.createDirectory(at: partial, withIntermediateDirectories: true)
            for entry in all {
                let dest = partial.appending(path: entry.path)
                if entry.isDirectory {
                    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                } else {
                    try fm.copyItem(at: entry.source, to: dest)
                }
            }
            try fm.moveItem(at: partial, to: folder)
        } catch {
            try? fm.removeItem(at: partial)
            throw HighballError.failed("Highball could not keep a copy of the saves of '\(name)', so the environment was not deleted: \(error.localizedDescription)")
        }
        return (folder, all.reduce(0) { $0 + $1.bytes })
    }

    private static func walk(_ dir: String, path: String, inLocal: Bool, root: String,
                             visited: inout Set<String>, into out: inout [Entry]) {
        guard visited.insert(dir).inserted else { return }
        let fm = FileManager.default
        out.append(Entry(source: URL(fileURLWithPath: dir), path: path, isDirectory: true, bytes: 0))
        for name in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() {
            guard let real = inside(URL(fileURLWithPath: dir).appending(path: name), root: root) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: real, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let lower = name.lowercased()
                if skippedNames.contains(lower) || (inLocal && skippedInLocal.contains(lower)) { continue }
                walk(real, path: "\(path)/\(name)", inLocal: false, root: root, visited: &visited, into: &out)
            } else {
                let size = ((try? fm.attributesOfItem(atPath: real))?[.size] as? NSNumber)?.int64Value ?? 0
                out.append(Entry(source: URL(fileURLWithPath: real), path: "\(path)/\(name)", isDirectory: false, bytes: size))
            }
        }
    }

    /// The real path of `url` with every link resolved, or nil when it leads to nothing or out
    /// of the environment.
    private static func inside(_ url: URL, root: String) -> String? {
        guard let real = realPath(url), real == root || real.hasPrefix(root + "/") else { return nil }
        return real
    }

    private static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
