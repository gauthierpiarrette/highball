import Foundation

/// The Mac Steam app's own installs, read from its appmanifests the same way a bottle's are:
/// `~/Library/Application Support/Steam/steamapps` plus every library folder it lists in
/// `libraryfolders.vdf` (an external drive, say). Read only.
///
/// A game installed there is played through Steam for Mac with `steam://run/<appid>`, and one
/// that isn't is handed to it with `steam://install/<appid>`, both opened with the Steam for Mac
/// app itself rather than whatever handles the scheme.
public enum MacSteam {
    public static let bundleID = "com.valvesoftware.steam"

    /// Steam for Mac among the apps that open steam:// URLs, or nil when only something else
    /// does: environments made before winemenubuilder was switched off can still have a
    /// Wine-made Steam wrapper in ~/Applications/Wine registered for the scheme.
    public static func app(among handlers: [URL],
                           bundleID: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }) -> URL? {
        handlers.first { bundleID($0) == Self.bundleID }
    }

    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Steam")
    }

    /// Every `steamapps` folder the Mac client installs into, the default one first.
    public static func steamappsDirectories(root: URL = root) -> [URL] {
        var libraries = [root.standardizedFileURL]
        if let text = try? String(contentsOf: root.appending(path: "steamapps/libraryfolders.vdf"), encoding: .utf8) {
            let pattern = #/"path"\s+"((?:\\.|[^"\\])*)"/#
            for match in text.matches(of: pattern) {
                let path = String(match.1).replacingOccurrences(of: #"\\"#, with: #"\"#)
                    .replacingOccurrences(of: #"\""#, with: "\"")
                let url = URL(fileURLWithPath: path).standardizedFileURL
                if !libraries.contains(url) { libraries.append(url) }
            }
        }
        return libraries.map { $0.appending(path: "steamapps") }
    }

    /// Games fully installed by Steam for Mac. Nothing when it isn't installed or signed in.
    public static func installedGames(root: URL = root) -> [SteamGame] {
        var seen = Set<Int>()
        return steamappsDirectories(root: root)
            .flatMap { dir in
                // Resolved first, as SteamLibrary.games does: a symlinked steamapps lists as nothing.
                ((try? FileManager.default.contentsOfDirectory(at: dir.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf" }
            }
            .compactMap { SteamLibrary.parseManifest($0) }
            // A manifest the Windows client wrote is that client's game, not a Mac install (a shared
            // library folder lists both).
            .filter { $0.isReady && !$0.installedByWindowsSteam && $0.appid != 228980 && seen.insert($0.appid).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
