import Foundation

/// The wine winetricks starts. winetricks runs under /bin/bash, and with SIP on macOS drops every
/// DYLD_* variable before bash starts, so each wine process winetricks started had no library path.
/// The Wine 10 engines find their libraries without one and never showed it. The Wine 11 engines
/// open FreeType by name through that path, so every winetricks install on them ran without fonts.
/// A player's .NET 4.8 install on r23 printed that error over a thousand times while it crashed in
/// a loop until the Mac stopped answering (highball#241). On the M4 the same install finished on
/// r23 and r25 even without fonts (1,758 and 586 of those errors, no crash), so the loop's own
/// cause is not settled. Measured on the M4, 2026-10-23: one `cmd /c echo` on
/// x64-crossover26.3-r25 printed "cannot find the FreeType font library" 12 times started through
/// /bin/sh, and never when the variable reached wine.
///
/// The library paths travel under other names, and a small script puts them back right before it
/// starts the engine's wine: a variable the script sets itself reaches its child, since SIP only
/// drops the ones a protected program inherits.
public enum WinetricksWine {
    /// What a launch hands wine and winetricks lost on the way.
    static let carried = ["DYLD_FALLBACK_LIBRARY_PATH", "DYLD_FALLBACK_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"]
    static let keptPrefix = "HB_KEEP_"

    static let script = """
    #!/bin/sh
    # Highball: winetricks runs under /bin/bash, where SIP drops the DYLD_* variables. Put the
    # engine's library paths back, then start the engine's wine.
    for name in \(carried.joined(separator: " ")); do
      eval "value=\\${\(keptPrefix)$name-}"
      if [ -n "$value" ]; then export "$name=$value"; fi
    done
    exec "$HB_WINE" "$@"

    """

    /// The script, written under Highball's tools folder when it is missing or out of date.
    public static func installScript(in paths: HighballPaths) throws -> URL {
        let dir = paths.home.appending(path: "tools/winetricks-wine", directoryHint: .isDirectory)
        // Named wine in a folder of its own, so winetricks' name-based guesses (wine64 beside wine) still read it as wine.
        let file = dir.appending(path: "wine")
        let fm = FileManager.default
        if (try? String(contentsOf: file, encoding: .utf8)) != script {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(script.utf8).write(to: file, options: .atomic)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// The environment for a winetricks run: WINE is the script, HB_WINE the engine's wine, and each
    /// library path is also under its HB_KEEP_ name. WINE_BIN stays the engine's wine, which
    /// winetricks only reads to tell the binary's architecture.
    public static func environment(_ env: [String: String], wine: URL, script: URL) -> [String: String] {
        var out = env
        for name in carried { if let value = env[name] { out[keptPrefix + name] = value } }
        out["HB_WINE"] = wine.path
        out["WINE"] = script.path
        return out
    }

    /// `path` with Highball's tool folders in front. winetricks shells out to cabextract for
    /// Microsoft's cabinet installers (the core fonts among them) and macOS does not ship it, so
    /// the app bundles one under Resources/tools (highball#96). HIGHBALL_TOOLS names another
    /// directory, for the CLI. Shared by recipes and `highball tricks`, whose PATH once lacked it
    /// and failed every verb that needs cabextract (db#941).
    public static func pathWithTools(_ path: String?) -> String? {
        let tools = [ProcessInfo.processInfo.environment["HIGHBALL_TOOLS"].map { URL(fileURLWithPath: $0) },
                     Bundle.main.resourceURL?.appending(path: "tools", directoryHint: .isDirectory)]
            .compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !tools.isEmpty else { return path }
        return (tools.map(\.path) + [path ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
    }
}
