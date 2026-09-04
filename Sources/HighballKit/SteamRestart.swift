import Foundation

/// Whether a running Steam client can serve a launch, or has to be cold-started first.
///
/// `steam -applaunch` only forwards to a client that is already running, and the game then
/// inherits that client's environment, not the launch's: a Steam window opened from the tile
/// runs with sync off (its CEF workaround) and with whatever renderer the bottle had at the
/// time, so a game launched from the library afterwards would run without msync, or under the
/// wrong renderer, while its log header claims otherwise (UX plan 0.6, issue #54).
public enum SteamRestart {
    /// Pure: why the running client (environment `live`) cannot serve a launch that needs
    /// `wanted`, in words for the log, or nil when it can. Only the renderer overlay path and
    /// the sync mode matter; everything else in the environment is per-launch noise.
    public static func reason(live: [String: String], wanted: [String: String], wantedRenderer: String) -> String? {
        var reasons: [String] = []
        if live["WINEDLLPATH_PREPEND"] != wanted["WINEDLLPATH_PREPEND"] {
            reasons.append("it runs with a different renderer than \(wantedRenderer)")
        }
        let liveSync = SyncMode(environment: live), wantedSync = SyncMode(environment: wanted)
        if liveSync != wantedSync {
            reasons.append("it runs with sync \(liveSync.rawValue) and the game wants \(wantedSync.rawValue)")
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }
}

extension WineRunner {
    /// Whether a Steam client runs in the prefix, by its command line. Static so the app can
    /// poll every bottle without resolving engines.
    public static func steamIsRunning(inPrefix prefix: URL) -> Bool {
        ProcessTable.processes(ofPrefix: prefix).contains { pid in
            guard let first = ProcessTable.commandLineAndEnvironment(of: pid)?.arguments.first else { return false }
            return isSteamExecutable(first)
        }
    }

    /// The environment of the bottle's running Steam client, nil when none runs (or the
    /// kernel would not show it, which it does for Wine's processes).
    public func runningSteamEnvironment() -> [String: String]? {
        for pid in ProcessTable.processes(ofPrefix: bottle.url) {
            guard let info = ProcessTable.commandLineAndEnvironment(of: pid),
                  let first = info.arguments.first, Self.isSteamExecutable(first) else { continue }
            return info.environment
        }
        return nil
    }

    /// Whether a Steam game is running in the bottle: a prefix process working inside a
    /// steamapps/common folder. Sessions the app started are a subset; a game launched from
    /// the Steam window itself counts too.
    public func steamGameIsRunning() -> Bool {
        ProcessTable.processes(ofPrefix: bottle.url).contains { pid in
            guard let cwd = ProcessTable.workingDirectory(of: pid) else { return false }
            return cwd.range(of: "/steamapps/common/", options: .caseInsensitive) != nil
        }
    }

    /// Cold-starts the bottle when its running Steam client could not serve a launch with
    /// `renderer` (see `SteamRestart`), so the launch that follows starts a fresh client with
    /// the right environment. Never while a game runs in the bottle: a wrong environment
    /// beats killing someone's game. Returns the reason for the log, nil when nothing was done.
    public func restartSteamIfMismatched(renderer: Renderer?) async throws -> String? {
        guard let live = runningSteamEnvironment() else { return nil }
        let wanted = try bottle.environment(engine: engine, renderer: renderer)
        guard let why = SteamRestart.reason(live: live, wanted: wanted,
                                            wantedRenderer: (renderer ?? bottle.settings.renderer).rawValue),
              !steamGameIsRunning() else { return nil }
        try kill()
        // `kill` waits for the server; give the client's own exit a moment too, so the launch
        // that follows does not forward to a client on its way out.
        for _ in 0..<50 where runningSteamEnvironment() != nil { try await Task.sleep(for: .milliseconds(100)) }
        return why
    }
}
