import Foundation

/// Replacing an Epic game's installed build with its other one (Windows to Mac, or back).
///
/// legendary keeps one build per game and, for a game it has a record of, always installs that
/// record's platform, so the old record has to go before the new build can be installed. Only
/// the record goes first: the old files stay on disk until the new build is fully in, so a Stop,
/// a failed download, or legendary falling back to the old platform puts the old record back
/// (`legendary import`) and the game is as it was. The old files are deleted last.
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
