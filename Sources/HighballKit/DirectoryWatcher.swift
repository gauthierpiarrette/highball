import Foundation

/// Watches directories for entries appearing, disappearing or being renamed and reports once
/// per burst, on the main queue, after a quiet period.
///
/// The launchers write their install records as files (Steam's `appmanifest_<appid>.acf`,
/// Epic's `Manifests/*.item`), so a download that starts or finishes while a launcher window
/// is open shows up in the library without relaunching the app (UX plan 0.6).
public final class DirectoryWatcher {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var targets: Set<String> = []
    private var waitingFor: [String: Set<String>] = [:]
    private var pending: DispatchWorkItem?
    private let quiet: TimeInterval
    private var changed: Set<String> = []
    private let onChange: (Set<String>) -> Void

    public init(quiet: TimeInterval = 2, onChange: @escaping (Set<String>) -> Void) {
        self.quiet = quiet
        self.onChange = onChange
    }

    deinit { for source in sources.values { source.cancel() } }

    /// The requested directories that existed at the last `watch`.
    public var watched: Set<String> { targets.intersection(sources.keys) }

    /// Replaces the watched set, keeping open sources for unchanged directories. Follow the
    /// closest existing ancestor of each missing target so we can arm it when it appears.
    public func watch(_ directories: [URL]) {
        targets = Set(directories.map(\.path))
        armTargets()
    }

    private func armTargets() {
        waitingFor.removeAll()
        var wanted: Set<String> = []
        for target in targets {
            var directory = URL(fileURLWithPath: target, isDirectory: true)
            while !Self.isDirectory(directory.path) {
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
            wanted.insert(directory.path)
            if directory.path != target { waitingFor[directory.path, default: []].insert(target) }
        }
        for (path, source) in sources where !wanted.contains(path) {
            source.cancel()
            sources[path] = nil
        }
        // A watched directory that was deleted and recreated (Steam's first update rebuilds
        // its folders) leaves the source on the old inode, where nothing ever happens again:
        // the library then misses every later install until a relaunch. Compare inodes and
        // reopen such a source.
        for (path, source) in sources where wanted.contains(path) {
            var onDisk = stat(), held = stat()
            let same = stat(path, &onDisk) == 0 && fstat(Int32(source.handle), &held) == 0
                && onDisk.st_ino == held.st_ino && onDisk.st_dev == held.st_dev
            if !same { source.cancel(); sources[path] = nil }
        }
        for path in wanted where sources[path] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .revoke], queue: .main)
            source.setEventHandler { [weak self] in self?.directoryChanged(path) }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources[path] = source
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func directoryChanged(_ path: String) {
        var invalidated: Set<String> = targets.contains(path) ? [path] : []
        let replaced = sources[path]?.data.intersection([.delete, .rename, .revoke]).isEmpty == false
        if replaced || waitingFor[path] != nil {
            let wasWatched = watched
            armTargets()
            invalidated.formUnion(watched.subtracting(wasWatched))
        }
        guard !invalidated.isEmpty else { return }
        changed.formUnion(invalidated)
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = self.changed.intersection(self.targets)
            self.changed.removeAll()
            self.pending = nil
            if !paths.isEmpty { self.onChange(paths) }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + quiet, execute: item)
    }
}
