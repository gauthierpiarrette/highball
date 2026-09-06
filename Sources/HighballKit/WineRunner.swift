import Foundation

public struct LaunchResult: Sendable {
    public let exitStatus: Int32
    public let duration: TimeInterval
    public let log: URL
    /// Set when the launch ran with a different graphics mode than the bottle asked for (#61);
    /// the same sentence is in the log header.
    public var note: String? = nil
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
        restoreMscoreeFirst: Bool = true,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> LaunchResult {
        try paths.ensure()
        // A boot that died halfway would leave the bottle's real .NET shim set aside (see
        // setAsideForeignMscoree); put it back before anything runs in this prefix. The boot
        // itself is the one launch that must not, since it just set the file aside on purpose.
        if restoreMscoreeFirst { Self.restoreMscoree(bottle: bottle) }
        // DXVK reads its options from the generated conf (async toggle + per-game profiles like
        // [csgo.exe], issue #21) — refresh it before the spawn. Every renderer but wined3d gets
        // DXVK's d3d9 attached, so every one of them needs the conf, not just .dxvk.
        // A bottle set to a renderer its engine cannot run degrades to one it can (#61); the
        // note goes in the header and to the caller so the substitution is never silent.
        let resolved = try bottle.effectiveRenderer(requested: renderer, engine: engine)
        if resolved.renderer != .wined3d { try? bottle.writeDxvkConfig() }
        var env = try bottle.environment(engine: engine, renderer: renderer, extra: extraEnvironment)
        // Wine fixes the sync mode when the prefix's wineserver starts; a process started with a
        // different one dies at msync_init before doing anything (issue #32: a registry write
        // "succeeding" in 0 s while a Steam window, cold-started with sync off, was open). So a
        // launch that joins a running server takes that server's mode, whatever the bottle or
        // the caller asked for; the bottle's setting applies to the next cold start. The header
        // below records the adoption ("bottle asks ...").
        if let live = ProcessTable.liveServerSync(forPrefix: bottle.url), live != SyncMode(environment: env) {
            env.merge(live.environment) { $1 }
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let logURL = Self.uniqueLogURL(in: paths.logs, named: "\(stamp)-\(bottle.name)-\(label ?? args.first ?? "wine")")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        var header = Self.launchHeader(engine: engine, bottle: bottle,
                                       renderer: resolved.renderer, env: env, args: args)
        if let note = resolved.note {
            header += "# note: \(note)\n"
            onOutput?("note: \(note)")
        }
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
        let status: Int32 = await withTaskCancellationHandler {
          await withCheckedContinuation { cont in
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
        } onCancel: {
            // The busy op was stopped: end the process so the wait returns instead of hanging
            // on a wineboot/installer that ignores its parent (review #12).
            process.terminate()
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
        return LaunchResult(exitStatus: status, duration: duration, log: logURL, note: resolved.note)
    }

    /// Runs the executable directly under `wine` (not `start /unix`) so the process stays attached and
    /// everything it and its children print lands in the log. The call returns when the program exits.
    @discardableResult
    public func start(_ executable: URL, arguments: [String] = [], renderer: Renderer? = nil, extraEnvironment: [String: String] = [:], workingDirectory: URL? = nil, onOutput: (@Sendable (String) -> Void)? = nil) async throws -> LaunchResult {
        await syncDllOverridesRegistry()
        await syncKeyboardRegistry()
        return try await run([executable.path] + arguments, renderer: renderer, extraEnvironment: extraEnvironment, label: executable.lastPathComponent, workingDirectory: workingDirectory, onOutput: onOutput)
    }

    /// Runs the pinned program, honouring its own renderer/env/args.
    @discardableResult
    public func start(pin: Pin, extraEnvironment: [String: String] = [:], onOutput: (@Sendable (String) -> Void)? = nil) async throws -> LaunchResult {
        // A path behind a Windows junction the installer made (EA app) exists only once the
        // junction stub is turned into a host symlink; do that before judging it missing.
        let exe = WineReparsePoint.resolve(pin.executableURL(driveC: bottle.driveC), driveC: bottle.driveC)
            ?? pin.executableURL(driveC: bottle.driveC)
        // A pin whose target no longer exists otherwise dies deep in Wine with an opaque
        // c0000135 ("failed to open"). Catch it here with a message the user can act on.
        // Pins written before 0.7.6 stored only a filename, so old entries resolve to a
        // drive_c-root path that isn't there (issue #23).
        guard FileManager.default.fileExists(atPath: exe.path) else {
            throw HighballError.invalid("\(pin.name) points at \(pin.path), which isn't there. If this was added by an older Highball, remove it and drag the program in again.")
        }
        let env = pin.environment.merging(extraEnvironment) { $1 }
        // A pin's own mode is a preference recorded by a recipe or a person, not a demand: when
        // this engine cannot run it, the environment's mode applies (and degrades in turn if it
        // must), with a note, rather than a launch that dies before Wine (#61).
        var renderer = pin.renderer
        if let wanted = renderer, let why = wanted.unavailableReason(in: engine) {
            onOutput?("note: \(pin.name) asks for \(Renderer.displayName(wanted)), but \(why) Using the environment's mode.")
            renderer = nil
        }
        // cwd = the exe's folder, as a Windows shortcut would — games with relative asset paths need it.
        return try await start(exe, arguments: pin.arguments, renderer: renderer, extraEnvironment: env,
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
    /// Suffix of a `mscoree.dll` set aside for the duration of a `wineboot` run.
    public static let asideSuffix = ".highball-wineboot"

    /// The bottle's two `mscoree.dll` copies and the engine builtin each would be on a Wine-made
    /// prefix, as (bottle file, engine file) pairs.
    static func mscoreePairs(engine: InstalledEngine, bottle: Bottle) -> [(URL, URL)] {
        [("windows/system32/mscoree.dll", "lib/wine/x86_64-windows/mscoree.dll"),
         ("windows/syswow64/mscoree.dll", "lib/wine/i386-windows/mscoree.dll")].map {
            (bottle.driveC.appending(path: $0.0), engine.engineDir.appending(path: $0.1))
        }
    }

    /// Whether the bottle carries Microsoft's .NET shim rather than Wine's `mscoree.dll`, which
    /// is what the dotnet48 recipe leaves behind. A Wine-made prefix holds byte copies of the
    /// engine builtins, so a size mismatch on either copy is the tell.
    public static func hasForeignMscoree(engine: InstalledEngine, bottle: Bottle) -> Bool {
        mscoreePairs(engine: engine, bottle: bottle).contains { pair in
            guard let a = try? FileManager.default.attributesOfItem(atPath: pair.0.path)[.size] as? UInt64,
                  let b = try? FileManager.default.attributesOfItem(atPath: pair.1.path)[.size] as? UInt64 else { return false }
            return a != b
        }
    }

    /// Moves a foreign `mscoree.dll` (both halves) aside for a boot; `restoreMscoree` puts it back.
    ///
    /// `wineboot -u` re-runs wine.inf's setup sections, which call `DllRegisterServer` on a fixed
    /// list of DLLs, `mscoree.dll` among them. In a bottle where the dotnet48 recipe installed
    /// Microsoft's .NET Framework that file is the real .NET shim, the registry marks it native,
    /// and the shim's registration loads the CLR and never returns under wow64: wineboot waits
    /// on the 32-bit rundll32 forever. Reproduced 2026-09-03 on the Gaming bottle (real .NET 4.8
    /// + Steam): Repair and the engine-update wineboot hang at `do_register_dll ... mscoree.dll`,
    /// on two engines, with and without leftover processes. Fresh bottles boot fine.
    ///
    /// The tools one would reach for first do not work. A `mscoree=b` override makes Wine's
    /// mscoree register, which calls `mscorwks.DllRegisterServerInternal`; the real mscorwks
    /// has no such export and Wine aborts the process into a debugger. A `mscoree=d` override is
    /// honoured by the 64-bit half and ignored by 32-bit processes under wow64 (the trace shows
    /// them loading the real file as native regardless). And wineboot's inf comes from ntdll's
    /// own data directory, so a filtered wine.inf cannot be pointed at through `WINEDATADIR`.
    ///
    /// With the file absent, both halves fail to load it (the native-only override rules out a
    /// builtin fallback), setupapi records one `could not load` and continues, and the boot
    /// completes: 15 s where it used to hang. The inf's fake-DLL step drops Wine's mscoree into
    /// the gap meanwhile, which is why the restore overwrites rather than checks. The real
    /// installer already registered the runtime, so skipping that one entry loses nothing.
    public static func setAsideForeignMscoree(engine: InstalledEngine, bottle: Bottle) throws -> Bool {
        guard hasForeignMscoree(engine: engine, bottle: bottle) else { return false }
        for (file, _) in mscoreePairs(engine: engine, bottle: bottle) where FileManager.default.fileExists(atPath: file.path) {
            let aside = URL(fileURLWithPath: file.path + asideSuffix)
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: file, to: aside)
        }
        return true
    }

    /// Puts back any `mscoree.dll` set aside by `setAsideForeignMscoree`, overwriting whatever the
    /// boot left in its place. Safe to call when nothing is aside. Also run before every launch,
    /// so a boot that died halfway (crash, force quit) cannot leave the bottle without its .NET.
    public static func restoreMscoree(bottle: Bottle) {
        for dir in ["windows/system32", "windows/syswow64"] {
            let file = bottle.driveC.appending(path: "\(dir)/mscoree.dll")
            let aside = URL(fileURLWithPath: file.path + asideSuffix)
            guard FileManager.default.fileExists(atPath: aside.path) else { continue }
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.moveItem(at: aside, to: file)
        }
    }

    public func wineboot(force: Bool = false) async throws -> LaunchResult {
        let aside = try Self.setAsideForeignMscoree(engine: engine, bottle: bottle)
        defer { if aside { Self.restoreMscoree(bottle: bottle) } }
        return try await run(["wineboot", force ? "-fu" : "-u"], renderer: .wined3d, label: "wineboot",
                             restoreMscoreeFirst: false)
    }

    /// Stops the bottle: asks the server to kill its clients, waits for the server to go, then
    /// ends whatever is still attached to the prefix. Returns the process ids it had to end
    /// itself, which is normally none (see `ProcessTable` for why it is not always none).
    @discardableResult
    /// Whether a Steam client already runs in this bottle, by its command line.
    public func steamIsRunning() -> Bool { Self.steamIsRunning(inPrefix: bottle.url) }

    /// Pure: does a command line's program name end in steam.exe (Windows or Unix separators).
    public static func isSteamExecutable(_ argv0: String) -> Bool {
        argv0.replacingOccurrences(of: "\\", with: "/").lowercased().hasSuffix("/steam.exe")
    }

    /// If a Steam client is already running in the bottle, asks it to show its window and
    /// returns that launch; nil when no client runs (the caller then starts one).
    ///
    /// After a game launch (`steam -silent -applaunch`) the silent client stays up. Starting
    /// steam.exe again then only forwards to that instance and exits: no window, no error,
    /// a dead button (issue #33). `steam://open/main` forwarded the same way makes the running
    /// instance open its window, without restarting the wineserver under a game that may still
    /// be running. Verified 2026-09-03: silent instance, open/main, Steam window up in seconds.
    public func showRunningSteam(onOutput: (@Sendable (String) -> Void)? = nil) async throws -> LaunchResult? {
        guard steamIsRunning() else { return nil }
        let steam = bottle.driveC.appending(path: "Program Files (x86)/Steam/steam.exe")
        return try await start(steam, arguments: ["steam://open/main"], onOutput: onOutput)
    }

    public func kill() throws -> [pid_t] {
        let env = try bottle.environment(engine: engine, renderer: .wined3d)
        // `-k` fails when no server holds the lock, which is exactly the crashed-server case
        // the reaper below exists for, so its failure must not end the stop early.
        try? Shell.run(engine.wineserverBinary.path, ["-k"], env: env)
        // `wineserver -w` blocks until the server has released its lock. Bounded: a wedged
        // server must not turn a Stop into a hang, the reaper below covers that case too.
        let waiter = Process()
        waiter.executableURL = engine.wineserverBinary
        waiter.arguments = ["-w"]
        waiter.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        try? waiter.run()
        let deadline = Date().addingTimeInterval(10)
        while waiter.isRunning && Date() < deadline { usleep(100_000) }
        if waiter.isRunning { waiter.terminate() }
        let leftovers = ProcessTable.processes(ofPrefix: bottle.url)
        ProcessTable.terminate(leftovers)
        return leftovers
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
        markSynced { $0.dllOverridesSynced = current }
    }

    /// Records a "last mirrored into the prefix registry" marker. Re-reads from disk rather than
    /// saving `bottle`, which is a snapshot taken when the runner was built: saving it whole also
    /// rewrites every other setting as it stood then, so a second sync in the same launch would
    /// revert the marker the first one just wrote.
    private func markSynced(_ apply: (inout BottleSettings) -> Void) {
        guard var fresh = try? Bottle.load(bottle.url) else { return }
        apply(&fresh.settings)
        try? fresh.save()
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

    /// Wine's Mac driver leaves the Command keys acting as Alt, so Cmd+C / Cmd+V reach Windows
    /// apps as Alt+C / Alt+V — nothing pastes and macOS beeps. Mapping Command to Ctrl fixes
    /// copy/paste everywhere (Steam's login and store pages are the common report).
    ///
    /// Option must be mapped to Alt in the same breath: with both Command keys taken, winemac.drv
    /// itself warns "there is no way to send an Alt key to Windows applications", which would break
    /// Alt-driven game bindings. The four values move together or not at all.
    ///
    /// Pure so the mapping is unit-tested without touching a prefix.
    public static func keyboardRegistry(commandIsControl: Bool) -> [(name: String, data: String)] {
        // Mac Driver settings are REG_SZ "y"/"n", not DWORD — a DWORD 1 is read as absent and the
        // mapping silently stays off, which is exactly how this was first shipped and had to be fixed.
        let on = commandIsControl ? "y" : "n"
        return [
            ("LeftCommandIsCtrl", on), ("RightCommandIsCtrl", on),
            ("LeftOptionIsAlt", on), ("RightOptionIsAlt", on),
        ]
    }

    /// Applies the Command→Ctrl mapping when it differs from what the prefix already has, so an
    /// existing bottle picks it up on its next launch and the settings toggle takes effect without
    /// a Repair. Same shape as syncDllOverridesRegistry.
    public func syncKeyboardRegistry() async {
        let current = bottle.settings.commandIsControl
        guard current != bottle.settings.commandIsControlSynced else { return }
        guard (try? await setKeyboardMapping(commandIsControl: current)) != nil else { return }
        var copy = bottle
        copy.settings.commandIsControlSynced = current
        try? copy.save()
    }

    public func setKeyboardMapping(commandIsControl: Bool) async throws {
        for v in Self.keyboardRegistry(commandIsControl: commandIsControl) {
            try await regAdd(key: #"HKCU\Software\Wine\Mac Driver"#, name: v.name,
                             type: "REG_SZ", data: v.data)
        }
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
