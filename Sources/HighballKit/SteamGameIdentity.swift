import Foundation

/// The native macOS bundle for a Steam game on an engine that supports game identity.
public enum SteamGameIdentity {
    /// Write the mapping before Steam Play. The running client reads it when it creates the child.
    public static func prepare(_ game: SteamGame, in bottle: Bottle, engine: InstalledEngine) throws {
        guard engine.manifest.nativeGameIdentity == true, !engine.manifest.isNativeARM64, game.appid > 0,
              let steamRoot = SteamLibrary.steamRoot(of: bottle), !game.installdir.isEmpty else { return }
        let root = bottle.url.appending(path: "highball-identities", directoryHint: .isDirectory)
        let key = "steam-\(game.appid)"
        let map = root.appending(path: key + ".paths")
        let fm = FileManager.default
        if fm.fileExists(atPath: map.path) { try fm.removeItem(at: map) }
        let cache = steamRoot.appending(path: "appcache/appinfo.vdf")
        let info = try SteamAppInfo.read(cache, only: [game.appid])[game.appid]
        let folder = game.installFolder ?? steamRoot.appending(path: "steamapps/common/\(game.installdir)")
        let paths = launchPaths(info?.windowsLaunchExecutables ?? [], in: folder)
        guard !paths.isEmpty else { return }
        // Dock labels a running app by its bundle filename. Keep the ID in the parent folder.
        let bundleName = MacAppStub.appName(for: game.name) + ".app"
        let app = root.appending(path: key, directoryHint: .isDirectory)
            .appending(path: bundleName, directoryHint: .isDirectory)
            .appending(path: "Contents", directoryHint: .isDirectory)
        let macOS = app.appending(path: "MacOS", directoryHint: .isDirectory)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        let unix = engine.engineDir.appending(path: "lib/wine/\(engine.manifest.unixLibDir)")
        let loader = macOS.appending(path: "wine")
        let engineLoader = unix.appending(path: "wine")
        if !fm.contentsEqual(atPath: loader.path, andPath: engineLoader.path) {
            if fm.fileExists(atPath: loader.path) { try fm.removeItem(at: loader) }
            try fm.copyItem(at: engineLoader, to: loader)
        }
        let ntdll = macOS.appending(path: "ntdll.so")
        let engineNTDLL = unix.appending(path: "ntdll.so")
        let linked = try? fm.destinationOfSymbolicLink(atPath: ntdll.path)
        if linked != engineNTDLL.path {
            if linked != nil || fm.fileExists(atPath: ntdll.path) { try fm.removeItem(at: ntdll) }
            try fm.createSymbolicLink(at: ntdll, withDestinationURL: engineNTDLL)
        }
        var plist: [String: String] = [
            "CFBundleExecutable": "wine", "CFBundleIdentifier": "app.highball.game.steam.\(game.appid)",
            "CFBundleName": game.name, "CFBundleDisplayName": game.name,
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "LSApplicationCategoryType": "public.app-category.games",
            "NSMicrophoneUsageDescription": "This Windows game can use the microphone for voice chat.",
            "NSLocalNetworkUsageDescription": "This Windows game can use the local network for multiplayer."
        ]
        let resources = app.appending(path: "Resources", directoryHint: .isDirectory)
        let icon = resources.appending(path: "GameIcon.icns")
        if !fm.fileExists(atPath: icon.path),
           let png = paths.lazy.compactMap({ PEIcon.png(from: URL(fileURLWithPath: $0)) }).first {
            let input = root.appending(path: UUID().uuidString + ".png")
            defer { try? fm.removeItem(at: input) }
            try? fm.createDirectory(at: resources, withIntermediateDirectories: true)
            if (try? png.write(to: input, options: .atomic)) != nil {
                try? MacAppStub.makeIcon(from: input, to: icon)
            }
        }
        if fm.fileExists(atPath: icon.path) { plist["CFBundleIconFile"] = icon.lastPathComponent }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appending(path: "Info.plist"), options: .atomic)
        try (([bundleName] + paths).joined(separator: "\n") + "\n").write(to: map, atomically: true, encoding: .utf8)
    }

    static func launchPaths(_ names: [String], in folder: URL) -> [String] {
        let base = folder.resolvingSymlinksInPath().standardizedFileURL
        return Set(names.compactMap { name -> String? in
            let relative = name.replacingOccurrences(of: "\\", with: "/")
            guard relative.lowercased().hasSuffix(".exe"), !relative.hasPrefix("/"), !relative.contains(":"),
                  !relative.split(separator: "/").contains("..") else { return nil }
            let candidate = base.appending(path: relative).resolvingSymlinksInPath().standardizedFileURL.path
            var directory: ObjCBool = false
            guard candidate.hasPrefix(base.path + "/"), candidate.utf8.count < Int(PATH_MAX),
                  !candidate.contains("\n"), !candidate.contains("\r"),
                  FileManager.default.fileExists(atPath: candidate, isDirectory: &directory),
                  !directory.boolValue else { return nil }
            return candidate
        }).sorted()
    }
}
