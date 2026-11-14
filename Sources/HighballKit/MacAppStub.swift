import Foundation

/// "Make a Mac app": a real, tiny app bundle in the chosen folder, named after the game,
/// with its cover as the icon, whose only job is to open one play URL and exit. Locally created,
/// ad-hoc signed with the system's codesign, so it has a stable identity and no quarantine flag.
/// Nothing touches the Dock's preferences: the person drags it there like any app (UX plan §3.9).
public enum MacAppStub {
    public static func folder() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Highball", directoryHint: .isDirectory)
    }

    /// A file-system-safe app name from a title ("Portal 2" -> "Portal 2", "Half-Life: Alyx" -> "Half-Life Alyx").
    public static func appName(for title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "[/:\\\\]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Highball game" : String(cleaned.prefix(60))
    }

    public static func infoPlist(appName: String, bundleID: String, libraryID: String? = nil) -> String {
        func xml(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let owner = libraryID.map { "<key>HighballShortcutLibraryID</key><string>\(xml($0))</string>" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleExecutable</key><string>launch</string>
          <key>CFBundleIdentifier</key><string>\(xml(bundleID))</string>
          <key>CFBundleName</key><string>\(xml(appName))</string>
          <key>CFBundleDisplayName</key><string>\(xml(appName))</string>
          <key>CFBundlePackageType</key><string>APPL</string>
          <key>CFBundleShortVersionString</key><string>1.0</string>
          <key>CFBundleVersion</key><string>1</string>
          <key>CFBundleIconFile</key><string>icon</string>
          <key>LSMinimumSystemVersion</key><string>14.0</string>
          <key>LSUIElement</key><true/>
          \(owner)
        </dict></plist>
        """
    }

    /// The launcher: opens the play URL and exits. `open` hands the URL to Highball whether it
    /// is running or not; `-g` keeps Highball in the background so the game, not the library,
    /// is what comes to the front (issue #53).
    public static func launchScript(url: URL, application: URL? = nil) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let app = application.map { " -a " + quote($0.path) } ?? ""
        return "#!/bin/sh\nexec /usr/bin/open -g\(app) \(quote(url.absoluteString))\n"
    }

    public static func bundleID(for libraryID: String) -> String {
        let safe = libraryID.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return "app.highball.stub.\(safe)"
    }

    /// Find our shortcut by the exact target, even after the game's name changes.
    public static func existing(libraryID: String, in folder: URL) -> URL? {
        let apps = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        return apps.first { owns($0, libraryID: libraryID) }
    }

    private static func owns(_ app: URL, libraryID: String) -> Bool {
        guard app.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink == false,
              let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == bundleID(for: libraryID),
              plist["CFBundleExecutable"] as? String == "launch" else { return false }
        if let owner = plist["HighballShortcutLibraryID"] as? String { return owner == libraryID }
        // Old stubs lack the exact ID in their plist. The bundle ID alone is lossy.
        guard let script = try? String(contentsOf: app.appending(path: "Contents/MacOS/launch"), encoding: .utf8),
              let link = script.split(separator: "\"").dropFirst().first.flatMap({ URL(string: String($0)) }) else { return false }
        return PlayLink.parse(link)?.target.libraryID == libraryID
    }

    public static func remove(libraryID: String, in folder: URL) throws {
        guard let app = existing(libraryID: libraryID, in: folder) else { return }
        try FileManager.default.trashItem(at: app, resultingItemURL: nil)
    }

    public static func write(title: String, libraryID: String, url: URL, cover: URL?, icon: URL? = nil,
                             in folder: URL, application: URL? = nil) throws -> URL {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if folder.standardizedFileURL.path == Self.folder().standardizedFileURL.path {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: folder])
        }
        let name = appName(for: title)
        let existing = existing(libraryID: libraryID, in: folder)
        var destination = folder.appending(path: "\(name).app", directoryHint: .isDirectory)
        if let existing { destination = existing }
        else {
            var n = 2
            while fm.fileExists(atPath: destination.path) || (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil {
                destination = folder.appending(path: "\(name) \(n).app", directoryHint: .isDirectory)
                n += 1
            }
        }
        let staging = folder.appending(path: ".highball-shortcut-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let app = staging.appending(path: destination.lastPathComponent, directoryHint: .isDirectory)
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        try fm.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
        try infoPlist(appName: name, bundleID: bundleID(for: libraryID), libraryID: libraryID).write(to: contents.appending(path: "Info.plist"), atomically: true, encoding: .utf8)
        let script = contents.appending(path: "MacOS/launch")
        try launchScript(url: url, application: application).write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        // The program's own icon when it has one (item 8), else the cover cropped square.
        if let icon { try? makeIcon(from: icon, to: contents.appending(path: "Resources/icon.icns")) }
        else if let cover { try? makeIcon(from: cover, to: contents.appending(path: "Resources/icon.icns")) }
        // Ad-hoc signature: a stable identity for macOS, no certificate needed for a local file.
        try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        if existing != nil {
            guard owns(destination, libraryID: libraryID) else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: destination])
            }
            _ = try fm.replaceItemAt(destination, withItemAt: app, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: app, to: destination)
        }
        return destination
    }

    /// Cover to .icns through the system's own tools; a square crop at 512 and the standard set.
    static func makeIcon(from cover: URL, to icns: URL) throws {
        let work = FileManager.default.temporaryDirectory.appending(path: "hb-icon-\(UUID().uuidString)")
        let iconset = work.appending(path: "icon.iconset", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let base = work.appending(path: "base.png")
        try Shell.run("/usr/bin/sips", ["-s", "format", "png", "-Z", "1024", cover.path, "--out", base.path])
        // Square it: sips crops from the center when both dimensions are given.
        try Shell.run("/usr/bin/sips", ["-c", "1024", "1024", base.path, "--out", base.path])
        for (size, name) in [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
                             (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
                             (512, "icon_512x512"), (1024, "icon_512x512@2x")] {
            try Shell.run("/usr/bin/sips", ["-z", String(size), String(size), base.path, "--out", iconset.appending(path: "\(name).png").path])
        }
        try Shell.run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path])
    }
}
