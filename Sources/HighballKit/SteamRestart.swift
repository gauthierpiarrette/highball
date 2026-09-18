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
    /// `wanted`, in words for the log, or nil when it can. The renderer overlay path, the sync mode
    /// and the inherited per-process toggles matter; everything else in the environment is per-launch noise.
    /// Per-process settings the game inherits from the client and cannot change afterwards.
    static let inherited: [(String, String)] = [("ROSETTA_ADVERTISE_AVX", "AVX advertised"), ("MTL_HUD_ENABLED", "the Metal HUD"),
                                                ("CX_FWD_COMPAT_GL_CTX", "forward-compatible OpenGL contexts")]

    /// What became of the running client before a launch.
    public enum Outcome: Equatable {
        /// No client runs; the launch cold-starts one with its own environment.
        case noClient
        /// The running client serves the launch as asked.
        case serves
        /// The client was cold-restarted; why, for the log.
        case restarted(String)
        /// The client does not match but a game is still open in the environment, so it stays,
        /// and the launch gets the client's stack. `live` names the client's renderer.
        case kept(String, live: String)
    }

    /// The renderer a running client was started with, read off its overlay path: each entry is
    /// `<...>/<renderer>/wine`, under `frameworks/renderer/` or `renderers/`. "wined3d" when it
    /// has no overlay. The d9vk entry rides along with every renderer and names none.
    /// Whether a prefix process belongs to the Steam client itself: the client, its browser
    /// helpers, its service and its overlay. Games the client started are not in this list,
    /// which is the point: stopping the client must never take a running game with it.
    public static func isClientProcess(argv0: String) -> Bool {
        let name = argv0.replacingOccurrences(of: "\\", with: "/").lowercased().split(separator: "/").last.map(String.init) ?? ""
        return ["steam.exe", "steamwebhelper.exe", "steamservice.exe", "steamerrorreporter.exe", "steamerrorreporter64.exe", "gameoverlayui.exe"].contains(name)
    }

    /// "off", or the multiplier ("2x"). Pacing, flow scale and the rest still count as a
    /// difference in `reason`; the words only name the multiplier.
    static func frameGenerationName(of env: [String: String]) -> String {
        guard let m = env["LSFGM_MULTIPLIER"], m != "1" else { return "off" }
        return "\(m)x"
    }

    public static func rendererName(ofLive env: [String: String]) -> String {
        let dirs = (env["WINEDLLPATH_PREPEND"] ?? "").split(separator: ":").compactMap { entry -> String? in
            let parts = entry.split(separator: "/")
            return parts.count >= 2 && parts.last == "wine" ? String(parts[parts.count - 2]) : nil
        }
        for name in ["d3dmetal", "dxmt", "vkd3d", "dxvk"] where dirs.contains(name) { return name }
        return "wined3d"
    }

    /// `custom` names the variables the environment sets on its own, from its settings or a
    /// recipe; each one the game inherits from the client, so a value that differs from the
    /// client's restarts it too (highball#136: CX_FWD_COMPAT_GL_CTX set while Steam ran, and
    /// -applaunch handed the game to the old client without it).
    public static func reason(live: [String: String], wanted: [String: String], wantedRenderer: String, custom: [String] = []) -> String? {
        var reasons: [String] = []
        if live["WINEDLLPATH_PREPEND"] != wanted["WINEDLLPATH_PREPEND"] {
            reasons.append("it runs with a different renderer than \(wantedRenderer)")
        }
        let liveSync = SyncMode(environment: live), wantedSync = SyncMode(environment: wanted)
        if liveSync != wantedSync {
            reasons.append("it runs with sync \(liveSync.rawValue) and the game wants \(wantedSync.rawValue)")
        }
        // Rosetta reads these at process start and the game inherits them from the client, so a
        // toggle flipped while the client runs would otherwise never reach the game while the
        // settings page says it is on (highball-db#48, Hogwarts Legacy crashed on the "AVX" run).
        for (key, what) in inherited where (live[key] == "1") != (wanted[key] == "1") {
            reasons.append("it runs with \(what) \(live[key] == "1" ? "on" : "off") and the game wants it \(wanted[key] == "1" ? "on" : "off")")
        }
        // Frame generation is a family of LSFGM_ variables the shim reads when the game starts,
        // so a toggle flipped while the client runs would otherwise leave the game where the
        // client was (highball#109 follow-up). Any difference in the family restarts the client.
        let liveFrameGen = live.filter { $0.key.hasPrefix("LSFGM_") }, wantedFrameGen = wanted.filter { $0.key.hasPrefix("LSFGM_") }
        if liveFrameGen != wantedFrameGen {
            reasons.append("it runs with frame generation \(frameGenerationName(of: live)) and the game wants \(frameGenerationName(of: wanted))")
        }
        for key in custom.sorted() where !inherited.contains(where: { $0.0 == key }) && live[key] != wanted[key] {
            switch (live[key], wanted[key]) {
            case (nil, let want?): reasons.append("it runs without \(key)=\(want)")
            case (let have?, nil): reasons.append("it runs with \(key)=\(have) and the game does not set it")
            case (let have?, let want?): reasons.append("it runs with \(key)=\(have) and the game wants \(want)")
            case (nil, nil): break
            }
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

    /// Whether the running Steam client can serve a launch with `renderer`, restarting it when
    /// it cannot (see `SteamRestart`), so the launch that follows starts a fresh client with the
    /// right environment. Never while a game runs in the bottle (`mayRestart` false, or a prefix
    /// process working in a game folder): a wrong environment beats killing someone's game. That
    /// case comes back as `.kept` so the caller can say so; silently launching under the client's
    /// stack cost highball-db#48 six rounds, the game ran on DXMT while every log said D3DMetal.
    public func restartSteamIfMismatched(renderer: Renderer?, mayRestart: Bool = true) async throws -> SteamRestart.Outcome {
        guard let live = runningSteamEnvironment() else { return .noClient }
        let wanted = try bottle.environment(engine: engine, renderer: renderer)
        guard let why = SteamRestart.reason(live: live, wanted: wanted,
                                            wantedRenderer: (renderer ?? bottle.settings.renderer).rawValue,
                                            custom: Array(bottle.settings.environment.keys)) else { return .serves }
        if !mayRestart || steamGameIsRunning() { return .kept(why, live: SteamRestart.rendererName(ofLive: live)) }
        try await stopSteam()
        return .restarted(why)
    }

    /// Stops the Steam client and nothing else. Until 2026-09-18 this killed the whole
    /// wineserver, which took every other program running in the environment down with the
    /// client (highball#152: launching a second program ended the first). Steam's own
    /// `-shutdown` closes the client cleanly; when it does not go within thirty seconds, its
    /// processes alone are signalled. Games and other programs keep running throughout.
    public func stopSteam() async throws {
        let steam = bottle.driveC.appending(path: "Program Files (x86)/Steam/steam.exe")
        _ = try? await run([steam.path, "-shutdown"], renderer: nil, label: "steam-shutdown")
        for _ in 0..<300 where runningSteamEnvironment() != nil { try await Task.sleep(for: .milliseconds(100)) }
        guard runningSteamEnvironment() != nil else { return }
        let clientPIDs = ProcessTable.processes(ofPrefix: bottle.url).filter { pid in
            guard let first = ProcessTable.commandLineAndEnvironment(of: pid)?.arguments.first else { return false }
            return SteamRestart.isClientProcess(argv0: first)
        }
        for pid in clientPIDs { Darwin.kill(pid, SIGTERM) }
        for _ in 0..<50 where runningSteamEnvironment() != nil { try await Task.sleep(for: .milliseconds(100)) }
        for pid in clientPIDs where Darwin.kill(pid, 0) == 0 { Darwin.kill(pid, SIGKILL) }
        for _ in 0..<20 where runningSteamEnvironment() != nil { try await Task.sleep(for: .milliseconds(100)) }
    }
}
