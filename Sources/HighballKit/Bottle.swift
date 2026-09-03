import Foundation

/// Graphics backend applied to a bottle (or overridden per program).
public enum Renderer: String, Codable, CaseIterable, Sendable {
    /// Wine's own D3D-on-OpenGL. Slow; last resort.
    case wined3d
    /// D3D10/11 → Metal. Highball's default.
    case dxmt
    /// Apple's D3D11/12 → Metal. Only D3D12 path. Apple-licensed, optional download.
    case d3dmetal
    /// D3D9/10/11 → Vulkan → MoltenVK. Use for D3D9 titles.
    case dxvk

    /// Environment contributed by this renderer, given the engine that hosts it.
    public func environment(engine: InstalledEngine) throws -> [String: String] {
        var env: [String: String] = [:]
        switch self {
        case .wined3d:
            return env
        case .dxmt:
            guard let dir = engine.rendererDir("dxmt") else { throw HighballError.missing("dxmt renderer in engine \(engine.id)") }
            env["WINEDLLPATH_PREPEND"] = Self.withD9VK(dir.appending(path: "wine").path, engine: engine)
        case .d3dmetal:
            guard let dir = engine.rendererDir("d3dmetal") else { throw HighballError.missing("d3dmetal renderer in engine \(engine.id) (optional component not installed?)") }
            let external = dir.appending(path: "external").path
            env["WINEDLLPATH_PREPEND"] = Self.withD9VK(dir.appending(path: "wine").path, engine: engine)
            env["CX_D3DMETALPATH"] = external
            env["DYLD_FALLBACK_LIBRARY_PATH+"] = external
            env["DYLD_FALLBACK_FRAMEWORK_PATH+"] = external
        case .dxvk:
            // DXVK's D3D10/11 live in the "dxvk" overlay, but its D3D9 ships in a *separate*
            // "d9vk" overlay. Both dirs must be on WINEDLLPATH_PREPEND or a D3D9 title's d3d9
            // resolves to builtin wined3d, whose D3D9 lacks the DF16/DF24 shadow-depth formats
            // Source's CSM check probes — CS:GO then quits with "graphics hardware does not
            // support all features (CSM)" (#21). d9vk is required for .dxvk: a missing overlay
            // must fail loudly, never silently regress D3D9 back to wined3d.
            guard let dxvk = engine.rendererDir("dxvk") else { throw HighballError.missing("dxvk renderer in engine \(engine.id)") }
            guard let d9vk = engine.rendererDir("d9vk") else { throw HighballError.missing("d9vk (DXVK D3D9) renderer in engine \(engine.id)") }
            env["WINEDLLPATH_PREPEND"] = [d9vk.appending(path: "wine").path, dxvk.appending(path: "wine").path].joined(separator: ":")
            env["WINEDLLOVERRIDES+"] = "dxgi,d3d9,d3d10core,d3d11=n,b"
        }
        return env
    }

    /// Appends the d9vk overlay (DXVK's D3D9) to a Metal backend's DLL search path.
    ///
    /// The renderer setting chooses the D3D10/11/12 backend; D3D9 must not be collateral damage.
    /// Neither the dxmt nor the d3dmetal overlay ships a d3d9 for either architecture (d3dmetal's
    /// i386 directory is a symlink to cnc-ddraw's and holds only ddraw.dll), so without this a
    /// D3D9 title silently gets Wine's own wined3d, whose D3D9 lacks the DF16/DF24 shadow-depth
    /// formats Source's CSM check probes. Legacy CS:GO then refuses to start with "graphics
    /// hardware does not support all features (CSM)".
    ///
    /// 0.7.9 fixed this for the dxvk renderer only, leaving it live on dxmt — the DEFAULT — and
    /// on d3dmetal. Reproduced on a dxmt bottle 2026-08-30 with that exact dialog (issue #21).
    /// Appended, not prepended, so the chosen backend keeps priority for everything it does ship;
    /// d9vk contributes only d3d9.dll, so the two never collide.
    ///
    /// Degrades to the backend alone if the engine has no d9vk, rather than throwing: this is the
    /// default renderer's path, and an engine missing d9vk should still run D3D11 titles. The
    /// dxvk case keeps its hard failure, because there D3D9 is the whole point.
    private static func withD9VK(_ path: String, engine: InstalledEngine) -> String {
        guard let d9vk = engine.rendererDir("d9vk") else { return path }
        return [path, d9vk.appending(path: "wine").path].joined(separator: ":")
    }

    /// The backend to offer after `current` failed on launch, cycling through the Metal-backed
    /// options. Direct3D 9 no longer constrains this: `withD9VK` attaches DXVK's d3d9 to every
    /// renderer, so switching backend can't drop D3D9 support the way it could before 0.7.17.
    public static func suggestion(after current: Renderer) -> Renderer {
        switch current {
        case .dxmt: return .d3dmetal
        case .d3dmetal: return .dxvk
        case .dxvk, .wined3d: return .dxmt
        }
    }
}

public enum WindowsVersion: String, Codable, CaseIterable, Sendable {
    case win7, win8, win81, win10, win11
}

public enum SyncMode: String, Codable, CaseIterable, Sendable {
    case none, esync, msync

    /// The mode a Wine environment selects: msync wins, then esync, else none.
    public init(environment env: [String: String]) {
        if env["WINEMSYNC"] == "1" { self = .msync }
        else if env["WINEESYNC"] == "1" { self = .esync }
        else { self = .none }
    }

    /// The two variables that select this mode. Both are always set: Wine treats an unset
    /// WINEMSYNC as on for msync-capable builds, so "off" has to be explicit.
    public var environment: [String: String] {
        switch self {
        case .none: return ["WINEMSYNC": "0", "WINEESYNC": "0"]
        case .esync: return ["WINEMSYNC": "0", "WINEESYNC": "1"]
        case .msync: return ["WINEMSYNC": "1", "WINEESYNC": "0"]
        }
    }
}

/// A pinned program inside a bottle.
public struct Pin: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID = UUID()
    public var name: String
    /// Path relative to the bottle's `drive_c`, or an absolute unix path (leading `/`)
    /// for programs that live outside the bottle — preinstalled games on the Mac side,
    /// which Wine reaches through its Z: drive.
    public var path: String
    public var arguments: [String] = []
    public var environment: [String: String] = [:]
    public var renderer: Renderer? = nil

    public init(name: String, path: String, arguments: [String] = [], environment: [String: String] = [:], renderer: Renderer? = nil) {
        self.name = name; self.path = path; self.arguments = arguments; self.environment = environment; self.renderer = renderer
    }

    /// Where the pin's executable actually lives for a given bottle.
    public func executableURL(driveC: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : driveC.appending(path: path)
    }

    /// How to store a picked file's location in a pin: drive_c-relative when the file is
    /// inside the bottle, absolute otherwise. (Storing just a filename was the 0.7.x bug
    /// that made "Run and add to Programs" produce dead entries for outside-the-bottle exes.)
    public static func storagePath(for url: URL, driveC: URL) -> String {
        let prefix = driveC.path.hasSuffix("/") ? driveC.path : driveC.path + "/"
        // Case-insensitive: macOS APFS is case-insensitive by default, so a dropped URL's
        // casing can differ from the canonical bottles path. A case-sensitive match there
        // would wrongly store an absolute path for an in-bottle file.
        if url.path.lowercased().hasPrefix(prefix.lowercased()) {
            return String(url.path.dropFirst(prefix.count))
        }
        return url.path
    }

    enum CodingKeys: String, CodingKey { case id, name, path, arguments, environment, renderer }

    /// Lenient decode: hand-written recipe pins may omit id/arguments/environment.
    /// (The synthesized decoder treats defaulted non-optionals as required keys.)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        renderer = try c.decodeIfPresent(Renderer.self, forKey: .renderer)
    }
}

/// One-line editing of a pin's argument list. Double quotes group words; backslash
/// escapes only a following quote (so Windows paths like C:\Games pass through
/// untouched); everything else is literal.
public enum ArgumentLine {
    public static func split(_ line: String) -> [String] {
        var args: [String] = []
        var cur = ""
        var inQuotes = false
        var started = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            let next = line.index(after: i)
            if ch == "\\", next < line.endIndex, line[next] == "\"" {
                cur.append("\""); started = true
                i = line.index(after: next)
                continue
            }
            if ch == "\"" {
                inQuotes.toggle(); started = true
            } else if (ch == " " || ch == "\t") && !inQuotes {
                if started { args.append(cur); cur = ""; started = false }
            } else {
                cur.append(ch); started = true
            }
            i = next
        }
        if started { args.append(cur) }
        return args
    }

    public static func join(_ args: [String]) -> String {
        args.map { a in
            if a.isEmpty { return "\"\"" }
            let escaped = a.replacingOccurrences(of: "\"", with: "\\\"")
            let needsQuotes = a.contains(" ") || a.contains("\t")
            return needsQuotes ? "\"\(escaped)\"" : escaped
        }.joined(separator: " ")
    }
}

/// Persisted as `<bottle>/bottle.json` (older bottles: `gin.json`, still read as a fallback).
public struct BottleSettings: Codable, Sendable {
    /// 2: dxvkAsync no longer defaults on. Bottles written at 1 are migrated off once on load.
    public var formatVersion: Int = 2
    public var name: String
    public var engineID: String
    public var renderer: Renderer = .dxmt
    /// True once the user explicitly chose a renderer (settings picker, CLI set/create flag).
    /// Recipes then keep their hands off it: a launcher recipe silently replacing an explicit
    /// choice cost a debugging session (issue #29, the AC-on-DXMT black screen).
    public var rendererExplicit: Bool = false
    public var windowsVersion: WindowsVersion = .win10
    public var sync: SyncMode = .msync
    public var metalHUD: Bool = false
    public var advertiseAVX: Bool = false
    /// DXVK async pipeline compilation. Off, and deliberately so.
    ///
    /// The name oversells it: on a pipeline miss it does not compile in the background and draw
    /// later, it SKIPS THE DRAW and presents the frame without that geometry. Upstream DXVK has
    /// refused the patch twice, naming multiplayer explicitly, and refused it even as an
    /// off-by-default option; the fork that carries it tells users not to report bugs with it
    /// enabled, and warns it may be risky in multiplayer. The engine's own built-in default is
    /// off, so writing True was an active opt-in for every game, not stock behaviour.
    ///
    /// It was on for every game from 0.3.0, arriving as a trailing clause in a commit about sync
    /// modes, and it has never been measured to help here: 16 alternated Unigine Heaven runs
    /// through d9vk on an M1 Pro gave −0.1%, p = 0.43. Turn it on per game with a recipe
    /// dxvkconfig step if a title ever demonstrates a win.
    public var dxvkAsync: Bool = false
    /// Cap the frame rate (0 = uncapped). Applied per renderer (DXVK_FRAME_RATE / DXMT_CONFIG).
    public var fpsCap: Int = 0
    /// Map the Mac Command keys to Windows Ctrl, so Cmd+C/Cmd+V/Cmd+A do what a Mac user expects
    /// inside Windows apps. Wine's default leaves Command as Alt, which is why pasting into Steam
    /// beeps instead of pasting. Option is mapped to Alt alongside it — without that, mapping both
    /// Command keys leaves no way to send Alt at all (winemac.drv warns about exactly this).
    public var commandIsControl: Bool = true
    /// The commandIsControl value last mirrored into the prefix registry. Bottles created before
    /// this setting existed carry nil, so the first launch after updating applies it — otherwise a
    /// user would have to know to press Repair, which is exactly the discoverability problem this
    /// setting exists to fix.
    public var commandIsControlSynced: Bool?
    /// Windows UI scale as a DPI value (LogPixels): 96 = 100% (1x), up to 240 = 250%. Above 96 the
    /// Mac driver switches to native Retina pixels so the scaled UI stays crisp. Applied to the prefix
    /// registry on change. Supersedes the old on/off retinaMode (which was just 96 / 192).
    public var dpiScale: Int = 96
    /// Extra WINEDLLOVERRIDES entries, e.g. "version=n,b" for Cyber Engine Tweaks. Appended to
    /// whatever the renderer sets, semicolon separated.
    public var dllOverrides: String = ""
    /// Per-app DXVK options (exe → key/value), set by recipe `dxvkconfig` steps and rendered
    /// into dxvk.conf at every DXVK launch. Data-driven successor to hardcoded [exe] sections.
    public var dxvkAppConfig: [String: [String: String]] = [:]
    /// The dllOverrides value last mirrored into the prefix registry. The env var only reaches
    /// process trees Highball spawns itself; a game started by an already-running Steam client
    /// inherits Steam's environment from before the setting changed and never sees it
    /// (issues #22/#25). Launches re-mirror when this differs from dllOverrides.
    public var dllOverridesSynced: String?
    public var environment: [String: String] = [:]
    public var pins: [Pin] = []
    public var recipes: [String] = []
    public var created: Date = Date()

    public init(name: String, engineID: String) {
        self.name = name
        self.engineID = engineID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        name = try c.decode(String.self, forKey: .name)
        engineID = try c.decode(String.self, forKey: .engineID)
        renderer = try c.decodeIfPresent(Renderer.self, forKey: .renderer) ?? .dxmt
        rendererExplicit = try c.decodeIfPresent(Bool.self, forKey: .rendererExplicit) ?? false
        dxvkAppConfig = try c.decodeIfPresent([String: [String: String]].self, forKey: .dxvkAppConfig) ?? [:]
        windowsVersion = try c.decodeIfPresent(WindowsVersion.self, forKey: .windowsVersion) ?? .win10
        sync = try c.decodeIfPresent(SyncMode.self, forKey: .sync) ?? .msync
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
        advertiseAVX = try c.decodeIfPresent(Bool.self, forKey: .advertiseAVX) ?? false
        dxvkAsync = try c.decodeIfPresent(Bool.self, forKey: .dxvkAsync) ?? false
        fpsCap = try c.decodeIfPresent(Int.self, forKey: .fpsCap) ?? 0
        // dpiScale supersedes the old retinaMode toggle (on == 200% == LogPixels 192).
        if let dpi = try c.decodeIfPresent(Int.self, forKey: .dpiScale) {
            dpiScale = dpi
        } else {
            let legacyRetina = (try? decoder.container(keyedBy: LegacyCodingKeys.self)
                .decodeIfPresent(Bool.self, forKey: .retinaMode)) ?? nil
            dpiScale = legacyRetina == true ? 192 : 96
        }
        dllOverrides = try c.decodeIfPresent(String.self, forKey: .dllOverrides) ?? ""
        dllOverridesSynced = try c.decodeIfPresent(String.self, forKey: .dllOverridesSynced)
        commandIsControl = try c.decodeIfPresent(Bool.self, forKey: .commandIsControl) ?? true
        commandIsControlSynced = try c.decodeIfPresent(Bool.self, forKey: .commandIsControlSynced)
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        pins = try c.decodeIfPresent([Pin].self, forKey: .pins) ?? []
        recipes = try c.decodeIfPresent([String].self, forKey: .recipes) ?? []
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()

        // Every bottle written before format 2 carries dxvkAsync: true because that was the
        // default, not because anyone chose it — there is no explicit-choice flag for it the way
        // rendererExplicit exists for the renderer. Switch those off once and stamp the version,
        // so a user who deliberately turns it back on keeps it.
        if formatVersion < 2 {
            dxvkAsync = false
            formatVersion = 2
        }
    }

    /// Legacy key for migrating pre-dpiScale bottles that stored `retinaMode`.
    private enum LegacyCodingKeys: String, CodingKey { case retinaMode }
}

public struct Bottle: Sendable {
    public let url: URL
    public var settings: BottleSettings

    public var name: String { settings.name }
    public var driveC: URL { url.appending(path: "drive_c", directoryHint: .isDirectory) }
    public var settingsURL: URL { url.appending(path: "bottle.json") }

    public init(url: URL, settings: BottleSettings) {
        self.url = url
        self.settings = settings
    }

    public static func load(_ url: URL) throws -> Bottle {
        let modern = url.appending(path: "bottle.json")
        let legacy = url.appending(path: "gin.json")
        let file = FileManager.default.fileExists(atPath: modern.path) ? modern : legacy
        let data = try Data(contentsOf: file)
        let settings = try JSONDecoder.highball.decode(BottleSettings.self, from: data)
        return Bottle(url: url, settings: settings)
    }

    public func save() throws {
        try JSONEncoder.highball.encode(settings).write(to: settingsURL, options: .atomic)
    }

    /// Environment for running something in this bottle: engine base + bottle settings + renderer + extras.
    /// Keys ending in `+` are appended to an existing value with `:` (paths) or `;` (WINEDLLOVERRIDES).
    public func environment(engine: InstalledEngine, renderer: Renderer? = nil, extra: [String: String] = [:]) throws -> [String: String] {
        var env = engine.baseEnvironment()
        env["WINEPREFIX"] = url.path
        env["WINEDEBUG"] = "fixme-all"
        // Explicit 0s matter: Steam's CEF webhelper hangs under msync/esync on Wine 10 (see recipes/launchers/steam.json).
        switch settings.sync {
        case .none: env["WINEMSYNC"] = "0"; env["WINEESYNC"] = "0"
        case .esync: env["WINEESYNC"] = "1"; env["WINEMSYNC"] = "0"
        case .msync: env["WINEMSYNC"] = "1"; env["WINEESYNC"] = "0"
        }
        if settings.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        if settings.advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        let r = renderer ?? settings.renderer
        // The async toggle travels in the generated dxvk.conf, NOT the DXVK_ASYNC env var:
        // the async fork reads `env == "1" || config.enableAsync`, so an env 1 can never be
        // overridden for a single game, while the conf's [csgo.exe] section can (issue #21).
        // WineRunner writes the file before each dxvk launch.
        // Every renderer but wined3d now reaches DXVK's d3d9 (see withD9VK), so the config and
        // the per-process log must follow it. Gating these on `== .dxvk` left D3D9 titles on a
        // dxmt or d3dmetal bottle running DXVK with no per-game profile and no log at all.
        if r != .wined3d {
            env["DXVK_CONFIG_FILE"] = Self.dxvkConfigWindowsPath
            // DXVK also writes a per-process <exe>_d3d9.log naming the backend, the config it
            // read and the device it got. Pointing it inside the bottle gives Highball the one
            // artifact that survives a game started by a launcher client Highball did not spawn —
            // the case where the game has no wine log of its own at all (issue #21).
            env["DXVK_LOG_PATH"] = Self.dxvkLogWindowsPath
        }
        if settings.fpsCap > 0 {
            switch r {
            case .dxvk: env["DXVK_FRAME_RATE"] = String(settings.fpsCap)
            case .dxmt: env["DXMT_CONFIG"] = "d3d11.preferredMaxFrameRate=\(settings.fpsCap);"
            default: break
            }
        }
        if !settings.dllOverrides.isEmpty { merge(&env, ["WINEDLLOVERRIDES+": settings.dllOverrides]) }
        merge(&env, settings.environment)
        merge(&env, try (renderer ?? settings.renderer).environment(engine: engine))
        merge(&env, extra)
        return env
    }

    /// Windows path of the generated DXVK config inside the prefix.
    public static let dxvkConfigWindowsPath = #"C:\highball\dxvk.conf"#
    /// Unix location of the same file.
    public var dxvkConfigURL: URL { driveC.appending(path: "highball/dxvk.conf") }
    /// Windows path DXVK writes its per-process logs to, and its Unix location.
    public static let dxvkLogWindowsPath = #"C:\highball\logs"#
    public var dxvkLogURL: URL { driveC.appending(path: "highball/logs") }

    /// Contents of the per-bottle dxvk.conf. The global line carries the bottle's async
    /// toggle. The [csgo.exe] section is the issue #21 profile: legacy CS:GO (32-bit D3D9)
    /// froze at map-load "Initializing game data" on defaults. Async compile off there
    /// (the d9vk fork's own wrapper never enables async; the first map load's pipeline
    /// burst is exactly the freeze point), 2 GB reported texture memory (DXVK's standard
    /// 32-bit address-space mitigation, cf. its built-in Vampire profile), and a Radeon
    /// device id to pair with the AMD vendor id DXVK's built-in csgo profile already
    /// forces. Later lines win, so the section must follow the global.
    ///
    /// Two of those three are unvalidated, and the device id's stated reason was wrong.
    /// It read "so the game's dxsupport.cfg picks a concrete GPU profile instead of
    /// unknown-device failsafe". 0x73BF is a 2019 Navi part; in the only Source
    /// dxsupport.cfg on hand (Portal's, which knows no id above 0x9715) it falls into
    /// `"ATI Unknown"` — VendorID 0x1002, MinDeviceID 0x0000, MaxDeviceID 0xffff,
    /// MakeMeLast 1 — which IS the failsafe bucket, the opposite of the claim. CS:GO
    /// ships its own newer dxsupport.cfg that may well know the part, and nobody has
    /// checked, so the honest status is unverified rather than disproven. The 2 GB cap
    /// has never been validated either: measured on an M1 Pro, a Source D3D9 map load
    /// took 11.1 s with and without it. Both stay because they are individually
    /// defensible, not because they are known to help. Do not restate the old rationale.
    public static func dxvkConfig(async: Bool, appConfig: [String: [String: String]] = [:]) -> String {
        // FALLBACK, kept deliberately (do not delete yet): legacy CS:GO can only be started
        // from Steam's own launch-option chooser, so it never passes the app's Play-gate and a
        // bottle without the counter-strike-2 recipe still needs these values. Re-confirmed
        // 2026-08-30: even with the csgo_legacy beta branch selected, `steam -applaunch 730`
        // starts cs2.exe, because -applaunch cannot answer the chooser ("LaunchApp waiting for
        // user response" in Steam's own log) and takes the default option.
        // NOTE: async is NOT the cause of the #21 map-load freeze. The logs show this config
        // reaching csgo.exe exactly as designed and the game froze anyway. These values stay
        // because each is individually sound, not because they fixed it. The same knowledge
        // (recipe dxvkconfig step); recipe-set values OVERRIDE this fallback. Remove after
        // a deprecation window once recipe coverage is the norm.
        let csgoFallback = ["dxvk.enableAsync": "False", "d3d9.maxAvailableMemory": "2048",
                            "d3d9.customDeviceId": "73BF"]
        var merged = appConfig
        merged["csgo.exe"] = csgoFallback.merging(merged["csgo.exe"] ?? [:]) { _, recipe in recipe }

        var out = """
        # Written by Highball before each DXVK launch — edits here are overwritten.
        # The bottle's "DXVK async shader compilation" toggle sets the global line;
        # per-app sections come from recipe dxvkconfig steps (plus the csgo fallback).
        dxvk.enableAsync = \(async ? "True" : "False")

        """
        for exe in merged.keys.sorted() {
            out += "\n[\(exe)]\n"
            for key in merged[exe]!.keys.sorted() {
                out += "\(key) = \(merged[exe]![key]!)\n"
            }
        }
        return out
    }

    /// Writes the generated dxvk.conf into the prefix (idempotent, compare-then-write).
    public func writeDxvkConfig() throws {
        let dir = dxvkConfigURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // DXVK only writes its per-process log if the directory exists.
        try FileManager.default.createDirectory(at: dxvkLogURL, withIntermediateDirectories: true)
        let content = Self.dxvkConfig(async: settings.dxvkAsync, appConfig: settings.dxvkAppConfig)
        if (try? String(contentsOf: dxvkConfigURL, encoding: .utf8)) != content {
            try content.write(to: dxvkConfigURL, atomically: true, encoding: .utf8)
        }
    }

    private func merge(_ env: inout [String: String], _ add: [String: String]) {
        for (k, v) in add {
            if k.hasSuffix("+") {
                let key = String(k.dropLast())
                let sep = key == "WINEDLLOVERRIDES" ? ";" : ":"
                env[key] = [v, env[key]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: sep)
            } else {
                env[k] = v
            }
        }
    }

    /// Convert a Windows path like `C:\Program Files (x86)\Steam\steam.exe` to a file URL inside the bottle.
    public func resolve(windowsPath: String) -> URL {
        var p = windowsPath
        if p.lowercased().hasPrefix("z:") {
            // Wine maps Z:\ to the unix root — hand back the real absolute path.
            let rest = String(p.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")
            return URL(fileURLWithPath: rest.isEmpty ? "/" : rest)
        }
        if p.lowercased().hasPrefix("c:") { p = String(p.dropFirst(2)) }
        p = p.replacingOccurrences(of: "\\", with: "/")
        if p.hasPrefix("/") { p.removeFirst() }
        return driveC.appending(path: p)
    }
}

extension JSONEncoder {
    static var highball: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var highball: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
