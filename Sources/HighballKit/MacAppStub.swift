import Foundation

/// "Make a Mac app": a real, tiny app bundle in ~/Applications/Highball named after the game,
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

    public static func infoPlist(appName: String, bundleID: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleExecutable</key><string>launch</string>
          <key>CFBundleIdentifier</key><string>\(bundleID)</string>
          <key>CFBundleName</key><string>\(appName)</string>
          <key>CFBundleDisplayName</key><string>\(appName)</string>
          <key>CFBundlePackageType</key><string>APPL</string>
          <key>CFBundleShortVersionString</key><string>1.0</string>
          <key>CFBundleVersion</key><string>1</string>
          <key>CFBundleIconFile</key><string>icon</string>
          <key>LSMinimumSystemVersion</key><string>14.0</string>
          <key>LSUIElement</key><true/>
        </dict></plist>
        """
    }

    /// The launcher: opens the play URL and exits. `open` hands the URL to Highball whether it
    /// is running or not; `-g` keeps Highball in the background so the game, not the library,
    /// is what comes to the front (issue #53).
    public static func launchScript(url: URL) -> String {
        "#!/bin/sh\nexec /usr/bin/open -g \"\(url.absoluteString)\"\n"
    }

    public static func bundleID(for libraryID: String) -> String {
        let safe = libraryID.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return "app.highball.stub.\(safe)"
    }

    /// Writes (or rewrites) the bundle and returns its location. `cover` is any image file; it
    /// becomes the icon when sips and iconutil can convert it, and the stub still works without.
    @discardableResult
    public static func write(title: String, libraryID: String, url: URL, cover: URL?) throws -> URL {
        let fm = FileManager.default
        let name = appName(for: title)
        let app = folder().appending(path: "\(name).app", directoryHint: .isDirectory)
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        try? fm.removeItem(at: app)
        try fm.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
        try infoPlist(appName: name, bundleID: bundleID(for: libraryID)).write(to: contents.appending(path: "Info.plist"), atomically: true, encoding: .utf8)
        let script = contents.appending(path: "MacOS/launch")
        try launchScript(url: url).write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        if let cover { try? makeIcon(from: cover, to: contents.appending(path: "Resources/icon.icns")) }
        // Ad-hoc signature: a stable identity for macOS, no certificate needed for a local file.
        _ = try? Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return app
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
