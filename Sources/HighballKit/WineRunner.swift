import Foundation

public struct LaunchResult: Sendable {
    public let exitStatus: Int32
    public let duration: TimeInterval
    public let log: URL
    /// Heuristic: exited non-zero (or at all) within 10 s of launch. The app uses this to suggest another renderer.
    public var crashedEarly: Bool { duration < 10 && exitStatus != 0 }
}

/// Launches Wine processes for a bottle and captures their output to `logs/`.
public struct WineRunner: Sendable {
    public let paths: HighballPaths
    public let engine: InstalledEngine
    public let bottle: Bottle

    public init(paths: HighballPaths = HighballPaths(), engine: InstalledEngine, bottle: Bottle) {
        self.paths = paths
        self.engine = engine
        self.bottle = bottle
    }

    /// Windows installer exit codes arrive twice-truncated: WiX Burn returns HRESULT_CODE
    /// (low 16 bits, so 0x80070666 → 1638) and POSIX keeps only the low 8 (1638 → 102).
    /// Without this note a log reads "exit=102", which means nothing to anyone.
    static func exitCodeNote(for status: Int32) -> String {
        switch status {
        case 102: return " (Windows 1638: a newer version is already installed)"
        case 194: return " (Windows 3010: success, restart required)"
        case 105: return " (Windows 1641: success, restart initiated)"
        default: return ""
        }
    }

    /// A log URL that cannot overwrite an existing one. The ISO 8601 stamp is second-resolution
    /// and `createFile` truncates, so two launches inside the same second used to destroy one
    /// another's log — routine during Repair, which fires reg, reg and wineboot back to back.
    /// The name is also flattened: `label` falls back to `args.first`, which can be a full path.
    static func uniqueLogURL(in directory: URL, named name: String) -> URL {
        let flat = name.replacingOccurrences(of: "/", with: "_")
        let base = directory.appending(path: "\(flat).log")
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        for n in 2...99 {
            let candidate = directory.appending(path: "\(flat)-\(n).log")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return base
    }

    /// What the process will really synchronize with, which is not always the bottle's setting:
    /// a pin's own environment is merged LAST and wins, and Steam's pin persists
    /// WINEMSYNC=0/WINEESYNC=0 so its interface stays responsive. Every game launched from that
    /// Steam window therefore inherits sync-off whatever the bottle says — the reason "try
    /// sync=none" was a no-op in issue #21 and the reporter's negative result meant nothing.
    static func effectiveSync(env: [String: String], settings: BottleSettings) -> String {
        let actual: SyncMode
        if env["WINEMSYNC"] == "1" { actual = .msync }
        else if env["WINEESYNC"] == "1" { actual = .esync }
        else { actual = SyncMode.none }
        return actual == settings.sync ? actual.rawValue : "\(actual.rawValue) (bottle asks \(settings.sync.rawValue))"
    }

    /// The log's opening block. Beyond the command line it records the few settings that decide
    /// which graphics and synchronization stack the process actually got.
    ///
    /// Allowlisted on purpose, never the whole environment: this text is pre-filled into a public
    /// GitHub issue, and a bottle's env can hold personal paths or tokens. Without it a report
    /// cannot separate "the config was never delivered" from "the config was delivered and did
    /// not help", which is exactly where issue #21 stalled for two rounds.
    static func launchHeader(engine: InstalledEngine, bottle: Bottle, renderer: Renderer,
                             env: [String: String], args: [String]) -> String {
        var out = "# gin \(engine.id) bottle=\(bottle.name) renderer=\(renderer)\n"
        out += "# wine \(args.joined(separator: " "))\n"
        out += "# sync=\(Self.effectiveSync(env: env, settings: bottle.settings))"
        out += " winver=\(bottle.settings.windowsVersion.rawValue) dpi=\(bottle.settings.dpiScale)"
        out += " dxvkAsync=\(bottle.settings.dxvkAsync)\n"
        for key in ["WINEDLLPATH_PREPEND", "WINEDLLOVERRIDES", "DXVK_CONFIG_FILE", "DXVK_LOG_PATH"] {
            if let value = env[key] { out += "# \(key)=\(value)\n" }
        }
        // The generated dxvk.conf decides per-game behaviour, so quote it rather than making the
        // reader ask for a second file that Repair may already have rewritten.
        if env["DXVK_CONFIG_FILE"] != nil,
           let conf = try? String(contentsOf: bottle.dxvkConfigURL, encoding: .utf8) {
            out += conf.split(separator: "\n").map { "#   \($0)\n" }.joined()
        }
        return out
    }

    /// Runs `wine <args>` and waits. `onOutput` receives each line of combined stdout/stderr.
    @discardableResult
    public func run(
        _ args: [String],
        renderer: Renderer? = nil,
        extraEnvironment: [String: String] = [:],
        label: String? = nil,
        workingDirectory: URL? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> LaunchResult {
        try paths.ensure()
        // DXVK reads its options from the generated conf (async toggle + per-game profiles like
        // [csgo.exe], issue #21) — refresh it before the spawn. Every renderer but wined3d gets
        // DXVK's d3d9 attached, so every one of them needs the conf, not just .dxvk.
        if (renderer ?? bottle.settings.renderer) != .wined3d { try? bottle.writeDxvkConfig() }
        let env = try bottle.environment(engine: engine, renderer: renderer, extra: extraEnvironment)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let logURL = Self.uniqueLogURL(in: paths.logs, named: "\(stamp)-\(bottle.name)-\(label ?? args.first ?? "wine")")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        let header = Self.launchHeader(engine: engine, bottle: bottle,
                                       renderer: renderer ?? bottle.settings.renderer, env: env, args: args)
        logHandle.write(Data(header.utf8))

        let process = Process()
        process.executableURL = engine.wineBinary
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        // drive_c only exists after the first wineboot — fall back to the bottle root on fresh prefixes.
        process.currentDirectoryURL = workingDirectory
            ?? (FileManager.default.fileExists(atPath: bottle.driveC.path) ? bottle.driveC : bottle.url)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let start = Date()
        do { try process.run() } catch { try? logHandle.close(); throw error }

        let reader = pipe.fileHandleForReading
        // The exit code used to be computed and thrown away: a failed install produced a log
        // shape-identical to a successful one, so user-submitted reports were undiagnosable
        // (issue #36 cost two research passes to answer). It is now a footer, written below.
        let status: Int32 = await withCheckedContinuation { cont in
            process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
            // Drain on a background thread. The drain is the log handle's SOLE owner: it closes it
            // only after EOF. Closing from the main flow raced the last writes — FileHandle's
            // legacy write raises an ObjC exception on a closed handle, uncaught on this thread,
            // and aborted the whole app (issues #13/#15, crash report confirmed). The throwing
            // write(contentsOf:) can't raise; a failed log write is dropped, never fatal.
            DispatchQueue.global(qos: .utility).async {
                var buffer = Data()
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    try? logHandle.write(contentsOf: chunk)
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: buffer[..<nl], as: UTF8.self)
                        buffer.removeSubrange(...nl)
                        onOutput?(line)
                    }
                }
                if !buffer.isEmpty { onOutput?(String(decoding: buffer, as: UTF8.self)) }
                try? logHandle.close()
            }
        }
        let duration = Date().timeIntervalSince(start)
        // Footer with the exit code. Written here, not in the drain: the drain blocks on
        // availableData until every write end of the pipe closes, and wineserver outlives the
        // process, so EOF often never arrives — a footer written there would never appear
        // (measured). A second handle is safe because the process has already exited, so the
        // drain has nothing left to write; the throwing write can't raise on a closed handle.
        let footer = "# exit=\(status)\(Self.exitCodeNote(for: status)) after \(Int(duration))s\n"
        if let tail = try? FileHandle(forWritingTo: logURL) {
            _ = try? tail.seekToEnd()
            try? tail.write(contentsOf: Data(footer.utf8))
            try? tail.close()
        }
        onOutput?(footer.trimmingCharacters(in: .newlines))
        return LaunchResult(exitStatus: status, duration: duration, log: logURL)
    }

    /// Runs the executable directly under `wine` (not `start /unix`) so the process stays attached and
    /// everything it and its children print lands in the log. The call returns when the program exits.
    @discardableResult
    public func start(_ executable: URL, arguments: [String] = [], renderer: Renderer? = nil, extraEnvironment: [String: String] = [:], workingDirectory: URL? = nil, onOutput: (@Sendable (String) -> Void)? = nil) async throws -> LaunchResult {
        await syncDllOverridesRegistry()
        return try await run([executable.path] + arguments, renderer: renderer, extraEnvironment: extraEnvironment, label: executable.lastPathComponent, workingDirectory: workingDirectory, onOutput: onOutput)
    }

    /// Runs the pinned program, honouring its own renderer/env/args.
    @discardableResult
    public func start(pin: Pin, extraEnvironment: [String: String] = [:], onOutput: (@Sendable (String) -> Void)? = nil) async throws -> LaunchResult {
        let exe = pin.executableURL(driveC: bottle.driveC)
        // A pin whose target no longer exists otherwise dies deep in Wine with an opaque
        // c0000135 ("failed to open"). Catch it here with a message the user can act on.
        // Pins written before 0.7.6 stored only a filename, so old entries resolve to a
        // drive_c-root path that isn't there (issue #23).
        guard FileManager.default.fileExists(atPath: exe.path) else {
            throw HighballError.invalid("\(pin.name) points at \(pin.path), which isn't there. If this was added by an older Highball, remove it and drag the program in again.")
        }
        let env = pin.environment.merging(extraEnvironment) { $1 }
        // cwd = the exe's folder, as a Windows shortcut would — games with relative asset paths need it.
        return try await start(exe, arguments: pin.arguments, renderer: pin.renderer, extraEnvironment: env,
                               workingDirectory: exe.deletingLastPathComponent(), onOutput: onOutput)
    }

    /// Steam's first self-update sometimes dies at a known Wine WoW64 spot and resumes cleanly
    /// on relaunch (see recipes/launchers/steam.json knownIssues). Launches the pin and, if that
    /// crash marker appears in the output, relaunches once so the update continues by itself.
    public func startResumingKnownSteamCrash(pin: Pin, extraEnvironment: [String: String] = [:], onOutput: (@Sendable (String) -> Void)? = nil) async throws -> (result: LaunchResult, resumed: Bool) {
        let collector = Collector()
        let tap: @Sendable (String) -> Void = { line in collector.append(line); onOutput?(line) }
        var result = try await start(pin: pin, extraEnvironment: extraEnvironment, onOutput: tap)
        guard collector.lines.contains(where: { $0.contains("nested exception on signal stack") }) else {
            return (result, false)
        }
        onOutput?("Steam's updater hit a known Wine crash — relaunching so it resumes…")
        try? await Task.sleep(for: .seconds(3))
        result = try await start(pin: pin, extraEnvironment: extraEnvironment, onOutput: onOutput)
        return (result, true)
    }

    /// `force` adds -f: re-runs the inf installs even when the prefix looks current, which is
    /// how a prefix missing its 32-bit half gets a second chance (issue #37).
    public func wineboot(force: Bool = false) async throws -> LaunchResult {
        try await run(["wineboot", force ? "-fu" : "-u"], renderer: .wined3d, label: "wineboot")
    }

    public func kill() throws {
        let env = try bottle.environment(engine: engine, renderer: .wined3d)
        try Shell.run(engine.wineserverBinary.path, ["-k"], env: env)
    }

    // MARK: Registry helpers

    public func regAdd(key: String, name: String, type: String, data: String) async throws {
        _ = try await run(["reg", "add", key, "/v", name, "/t", type, "/d", data, "/f"], renderer: .wined3d, label: "reg")
    }

    public func regDelete(key: String, name: String) async throws {
        _ = try await run(["reg", "delete", key, "/v", name, "/f"], renderer: .wined3d, label: "reg")
    }

    public func regQuery(key: String, name: String) async throws -> String? {
        var lines: [String] = []
        let collector = Collector()
        _ = try await run(["reg", "query", key, "/v", name], renderer: .wined3d, label: "reg") { collector.append($0) }
        lines = collector.lines
        guard let line = lines.first(where: { $0.contains("REG_") }) else { return nil }
        return line.split(whereSeparator: \.isWhitespace).last.map(String.init)
    }

    /// Parses a WINEDLLOVERRIDES-style string ("version=n,b;dxgi,d3d9=n") into per-dll registry
    /// entries. Anything that isn't override syntax (pasted Proton launch options, quotes, spaces)
    /// is skipped: the env var still carries the raw string, only the registry mirror filters.
    /// Pure so it's unit-tested without a prefix.
    public static func parseDllOverrides(_ overrides: String) -> [(name: String, order: String)] {
        var entries: [(String, String)] = []
        for entry in overrides.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let order = parts[1].trimmingCharacters(in: .whitespaces)
            // n / b / native / builtin, optionally comma-paired; empty or d = disabled.
            guard order.range(of: "^((n|b|native|builtin)(,(n|b|native|builtin))?|d|disabled)?$", options: .regularExpression) != nil else { continue }
            for rawName in parts[0].split(separator: ",") {
                var name = rawName.trimmingCharacters(in: .whitespaces).lowercased()
                if name.hasSuffix(".dll") { name = String(name.dropLast(4)) }
                guard !name.isEmpty, name.range(of: "^[a-z0-9_.+-]+$", options: .regularExpression) != nil else { continue }
                entries.append((name, order))
            }
        }
        return entries
    }

    static let dllOverridesKey = #"HKCU\Software\Wine\DllOverrides"#

    /// Mirrors the bottle's DLL-overrides field into the prefix registry. The env var reaches only
    /// process trees Highball spawns itself; a game launched through an already-running Steam client
    /// inherits Steam's environment from before the setting changed and never sees the override, so
    /// mods like Cyber Engine Tweaks stay silent (issues #22/#25). Every new Wine process reads this
    /// registry key live, no matter who spawned it. No-ops unless the field changed since the last
    /// successful sync; on failure the marker stays stale so the next launch retries.
    public func syncDllOverridesRegistry() async {
        let current = bottle.settings.dllOverrides
        guard current != (bottle.settings.dllOverridesSynced ?? "") else { return }
        let entries = Self.parseDllOverrides(current)
        let previous = Self.parseDllOverrides(bottle.settings.dllOverridesSynced ?? "")
        let names = Set(entries.map(\.name))
        // Removals are best-effort: a value that's already gone makes reg exit non-zero anyway.
        for old in previous where !names.contains(old.name) {
            try? await regDelete(key: Self.dllOverridesKey, name: old.name)
        }
        var allAdded = true
        for entry in entries {
            let status = try? await run(["reg", "add", Self.dllOverridesKey, "/v", entry.name, "/t", "REG_SZ", "/d", entry.order, "/f"],
                                        renderer: .wined3d, label: "reg").exitStatus
            if status != 0 { allAdded = false }
        }
        guard allAdded else { return }
        var copy = bottle
        copy.settings.dllOverridesSynced = current
        try? copy.save()
    }

    /// Windows UI scaling. LogPixels is the Windows system DPI (96 = 100%, 240 = 250%): DPI-aware
    /// apps and launchers follow it, though many full-screen games set their own render resolution and
    /// ignore it. At 96 the Mac driver renders at 1x; above that it switches to native Retina pixels
    /// (crisper, ~4x GPU work at native res) so the scaled UI stays sharp. Clamped to the 96..240 range
    /// Wine accepts. Pure so the mapping is unit-tested without touching a prefix.
    public static func dpiRegistry(for logPixels: Int) -> (retinaMode: String, logPixels: Int) {
        let clamped = min(max(logPixels, 96), 240)
        return (clamped > 96 ? "y" : "n", clamped)
    }

    public func setDpi(logPixels: Int) async throws {
        let v = Self.dpiRegistry(for: logPixels)
        try await regAdd(key: #"HKCU\Software\Wine\Mac Driver"#, name: "RetinaMode", type: "REG_SZ", data: v.retinaMode)
        try await regAdd(key: #"HKCU\Control Panel\Desktop"#, name: "LogPixels", type: "REG_DWORD", data: String(v.logPixels))
    }

    /// Wine's fallback D3D reports a fake NVIDIA GPU (GeForce 8800 GTX class) when it can't
    /// recognize the Apple driver, which makes some games demand NVAPI and die. Pin an AMD
    /// identity instead. The pair MUST exist in Wine's GPU table or the override is silently
    /// discarded ("Invalid GPU override" in winediag): 0x1002:0x73bf is Radeon RX 6800/6900 XT,
    /// present in Wine 10's table. Applied at bottle creation and by Repair.
    /// AMD RX 6800/6900 XT. Regression-tested: changing this to a pair absent from Wine's
    /// GPU table silently reverts bottles to the fake-NVIDIA identity (the 0.7.1 bug).
    public static let gpuIdentity: (vendor: Int, device: Int) = (0x1002, 0x73bf)

    /// Windows services translated cold by Rosetta can take 20+ seconds to reach RUNNING;
    /// upstream Wine's SCM gives up after 10. CrossOver quadruples the timeout in code
    /// (CW HACK 20218, for the Rockstar service); upstream honors this registry override.
    /// 60 s ceiling, no cost when services start fast. Applied at bottle creation and Repair.
    public static let servicesPipeTimeoutMs = 60000

    public func setServiceTimeout() async throws {
        try await regAdd(key: #"HKLM\System\CurrentControlSet\Control"#, name: "ServicesPipeTimeout",
                         type: "REG_SZ", data: String(Self.servicesPipeTimeoutMs))
    }

    public func setGpuIdentity() async throws {
        try await regAdd(key: #"HKCU\Software\Wine\Direct3D"#, name: "VideoPciVendorID", type: "REG_DWORD", data: String(Self.gpuIdentity.vendor))
        try await regAdd(key: #"HKCU\Software\Wine\Direct3D"#, name: "VideoPciDeviceID", type: "REG_DWORD", data: String(Self.gpuIdentity.device))
    }

    public func setWindowsVersion(_ v: WindowsVersion) async throws {
        _ = try await run(["winecfg", "-v", v.rawValue], renderer: .wined3d, label: "winecfg")
    }
}

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
