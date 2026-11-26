import Foundation

/// A burst can skip the other stores only when every path belongs exclusively to Windows Steam.
public struct InstallWatchDirectories {
    public let directories: [URL]
    private let windowsSteamOnly: Set<String>

    public init(windowsSteam: [URL], other: [URL]) {
        let steamPaths = Set(windowsSteam.map { $0.resolvingSymlinksInPath().path })
        let otherPaths = Set(other.map { $0.resolvingSymlinksInPath().path })
        windowsSteamOnly = steamPaths.subtracting(otherPaths)
        directories = steamPaths.union(otherPaths).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func affectsOnlyWindowsSteam(_ paths: Set<String>) -> Bool {
        !paths.isEmpty && paths.isSubset(of: windowsSteamOnly)
    }
}
