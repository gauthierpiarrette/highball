import Foundation

/// Watches directories for entries appearing, disappearing or being renamed and reports once
/// per burst, on the main queue, after a quiet period.
///
/// The launchers write their install records as files (Steam's `appmanifest_<appid>.acf`,
/// Epic's `Manifests/*.item`), so a download that starts or finishes while a launcher window
/// is open shows up in the library without relaunching the app (UX plan 0.6).
public final class DirectoryWatcher {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: DispatchWorkItem?
    private let quiet: TimeInterval
    private let onChange: () -> Void

    public init(quiet: TimeInterval = 2, onChange: @escaping () -> Void) {
        self.quiet = quiet
        self.onChange = onChange
    }

    deinit { for source in sources.values { source.cancel() } }

    /// The directories currently watched (the ones that existed at the last `watch`).
    public var watched: Set<String> { Set(sources.keys) }

    /// Replaces the watched set. A directory that does not exist yet is skipped and picked
    /// up by a later call; one already watched keeps its source, so calling this on every
    /// refresh is cheap and does not lose events.
    public func watch(_ directories: [URL]) {
        let wanted = Set(directories.map(\.path))
        for (path, source) in sources where !wanted.contains(path) {
            source.cancel()
            sources[path] = nil
        }
        for path in wanted where sources[path] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in self?.schedule() }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources[path] = source
        }
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + quiet, execute: item)
    }
}
