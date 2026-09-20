import Foundation

/// A recipe is declarative data (JSON, CC0 in gin-db) describing how to install and configure
/// a launcher or game inside a bottle. Steps run in order; each is idempotent where possible.
public struct Recipe: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case launcher, game, tweak }

    public enum Step: Codable, Sendable {
        /// Download a file (verified if sha256 given) and run it inside the bottle.
        /// `slow` is a user-facing expectation for long steps ("takes 20-40 min, can look idle");
        /// the app shows it while the step runs so nobody has to guess whether it froze (#31).
        case installer(url: URL, sha256: String?, arguments: [String], label: String, slow: String?, okExitCodes: [Int32]?)
        /// `wine reg add`.
        case registry(key: String, name: String, type: String, data: String)
        /// Run winetricks verbs (unattended). `slow` as on `installer`.
        case winetricks(verbs: [String], slow: String?)
        /// Set a persistent environment variable on the bottle.
        case environment(name: String, value: String)
        /// Set the bottle's renderer.
        case renderer(Renderer)
        /// Set the bottle's synchronization mode (none | esync | msync).
        case sync(SyncMode)
        /// Set the prefix's Windows version. Needed because winetricks verbs like dotnet48
        /// step the version during install and leave it on win7 — which broke Steam
        /// (deprecation banner) and AC for every dotnet48 user until restored.
        case winver(WindowsVersion)
        /// Write a text file inside drive_c.
        case file(path: String, contents: String)
        /// Copies one file from the engine into the environment: `from` is relative to the
        /// engine's directory and must stay inside it, `to` is relative to `drive_c`. A DLL put
        /// beside a game's executable is what its loader takes first, so this gives one game a
        /// Direct3D of its own (wined3d's d3d9 for legacy CS:GO) while the environment, and the
        /// Steam client in it, keep their graphics mode.
        /// With `asNative`, the copy loses Wine's builtin marker, so a per-application load order
        /// of `n,b` (a `registry` step under `AppDefaults\<exe>\DllOverrides`) makes the game's
        /// loader take it. A Direct3D imported by name from a DLL in the game's own `bin` folder
        /// is found there and nowhere else (legacy CS:GO's shaderapidx9.dll).
        case copy(from: String, to: String, asNative: Bool)
        /// Add a pinned program to the bottle.
        case pin(Pin)
        /// Free-text instruction the UI surfaces to the user after install.
        case note(String)
        /// A WINEDLLOVERRIDES entry the bottle keeps, e.g. "amd_ags_x64=" to disable AMD's AGS
        /// library. Appended to whatever the renderer sets, and mirrored into the prefix registry
        /// so it also reaches a game launched by an already-running Steam. This is how a game's
        /// need to avoid a vendor library ships as data instead of app code.
        case dllOverride(String)
        /// Per-app DXVK options ("csgo.exe" → dxvk.enableAsync=False…), stored on the bottle
        /// and rendered into its dxvk.conf at every DXVK launch. This is how game-specific
        /// DXVK knowledge ships as data instead of app code.
        case dxvkConfig(exe: String, options: [String: String])

        private enum CodingKeys: String, CodingKey { case type, url, sha256, arguments, label, slow, okExitCodes, key, name, value, valueType, data, verbs, renderer, sync, winver, path, contents, from, to, asNative, pin, text, exe, options }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "installer":
                self = .installer(url: try c.decode(URL.self, forKey: .url),
                                  sha256: try c.decodeIfPresent(String.self, forKey: .sha256),
                                  arguments: try c.decodeIfPresent([String].self, forKey: .arguments) ?? [],
                                  label: try c.decodeIfPresent(String.self, forKey: .label) ?? "installer",
                                  slow: try c.decodeIfPresent(String.self, forKey: .slow),
                                  okExitCodes: try c.decodeIfPresent([Int32].self, forKey: .okExitCodes))
            case "registry":
                self = .registry(key: try c.decode(String.self, forKey: .key), name: try c.decode(String.self, forKey: .name),
                                 type: try c.decodeIfPresent(String.self, forKey: .valueType) ?? "REG_DWORD", data: try c.decode(String.self, forKey: .data))
            case "winetricks": self = .winetricks(verbs: try c.decode([String].self, forKey: .verbs),
                                                  slow: try c.decodeIfPresent(String.self, forKey: .slow))
            case "environment": self = .environment(name: try c.decode(String.self, forKey: .name), value: try c.decode(String.self, forKey: .value))
            case "renderer": self = .renderer(try c.decode(Renderer.self, forKey: .renderer))
            case "sync": self = .sync(try c.decode(SyncMode.self, forKey: .sync))
            case "winver": self = .winver(try c.decode(WindowsVersion.self, forKey: .winver))
            case "file": self = .file(path: try c.decode(String.self, forKey: .path), contents: try c.decode(String.self, forKey: .contents))
            case "copy": self = .copy(from: try c.decode(String.self, forKey: .from), to: try c.decode(String.self, forKey: .to),
                                      asNative: try c.decodeIfPresent(Bool.self, forKey: .asNative) ?? false)
            case "pin": self = .pin(try c.decode(Pin.self, forKey: .pin))
            case "note": self = .note(try c.decode(String.self, forKey: .text))
            case "dlloverride": self = .dllOverride(try c.decode(String.self, forKey: .value))
            case "dxvkconfig": self = .dxvkConfig(exe: try c.decode(String.self, forKey: .exe),
                                                  options: try c.decode([String: String].self, forKey: .options))
            case let other: throw HighballError.invalid("unknown recipe step type '\(other)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .installer(url, sha256, arguments, label, slow, okExitCodes):
                try c.encode("installer", forKey: .type); try c.encode(url, forKey: .url)
                try c.encodeIfPresent(sha256, forKey: .sha256); try c.encode(arguments, forKey: .arguments); try c.encode(label, forKey: .label)
                try c.encodeIfPresent(slow, forKey: .slow)
                try c.encodeIfPresent(okExitCodes, forKey: .okExitCodes)
            case let .registry(key, name, type, data):
                try c.encode("registry", forKey: .type); try c.encode(key, forKey: .key); try c.encode(name, forKey: .name)
                try c.encode(type, forKey: .valueType); try c.encode(data, forKey: .data)
            case let .winetricks(verbs, slow):
                try c.encode("winetricks", forKey: .type); try c.encode(verbs, forKey: .verbs)
                try c.encodeIfPresent(slow, forKey: .slow)
            case let .environment(name, value): try c.encode("environment", forKey: .type); try c.encode(name, forKey: .name); try c.encode(value, forKey: .value)
            case let .renderer(r): try c.encode("renderer", forKey: .type); try c.encode(r, forKey: .renderer)
            case let .sync(m): try c.encode("sync", forKey: .type); try c.encode(m, forKey: .sync)
            case let .winver(v): try c.encode("winver", forKey: .type); try c.encode(v, forKey: .winver)
            case let .file(path, contents): try c.encode("file", forKey: .type); try c.encode(path, forKey: .path); try c.encode(contents, forKey: .contents)
            case let .copy(from, to, asNative):
                try c.encode("copy", forKey: .type); try c.encode(from, forKey: .from); try c.encode(to, forKey: .to)
                if asNative { try c.encode(true, forKey: .asNative) }
            case let .pin(p): try c.encode("pin", forKey: .type); try c.encode(p, forKey: .pin)
            case let .note(t): try c.encode("note", forKey: .type); try c.encode(t, forKey: .text)
            case let .dllOverride(v): try c.encode("dlloverride", forKey: .type); try c.encode(v, forKey: .value)
            case let .dxvkConfig(exe, options):
                try c.encode("dxvkconfig", forKey: .type); try c.encode(exe, forKey: .exe)
                try c.encode(options, forKey: .options)
            }
        }

        /// Short human description for progress display ("Step 2 of 3 — Battle.net-Setup").
        public var progressLabel: String? {
            switch self {
            case let .installer(_, _, _, label, _, _): return label
            case let .winetricks(verbs, _): return verbs.joined(separator: " ")
            case .registry: return nil
            case .environment, .renderer, .sync, .winver, .file, .copy, .pin, .note, .dxvkConfig, .dllOverride: return nil
            }
        }

        /// The step's slow-expectation text, if the recipe declared one.
        public var slowHint: String? {
            switch self {
            case let .installer(_, _, _, _, slow, _): return slow
            case let .winetricks(_, slow): return slow
            default: return nil
            }
        }

        /// Exit statuses that count as success for this step.
        ///
        /// Windows installers report success in more than one way, and the number Swift sees is
        /// twice-truncated (WiX Burn returns HRESULT_CODE, then POSIX keeps 8 bits): 3010
        /// "restart required" arrives as 194 and 1641 "restart initiated" as 105 — both are
        /// documented by Microsoft as success — and 1638 "a newer version is already installed"
        /// arrives as 102, which for a step whose job is to install that runtime means the goal
        /// is already met. Accepting these by default is deliberate: it is generic Windows
        /// knowledge, not per-app knowledge, so no recipe has to know it (issue #36, where the
        /// strict `== 0` guard aborted the VC++ recipe at step 1 of 14 and left the DLL
        /// overrides unapplied). A recipe can still widen the set for an installer with its own
        /// conventions via `okExitCodes`.
        public func accepts(exitStatus: Int32) -> Bool {
            guard case let .installer(_, _, _, _, _, okExitCodes) = self else { return exitStatus == 0 }
            return exitStatus == 0 || [102, 194, 105].contains(exitStatus)
                || (okExitCodes ?? []).contains(exitStatus)
        }

        /// True when the step is safe to run silently at Play time: touches no wine process
        /// (registry/winver spawn wine and can die on the msync mismatch, issue #32) and
        /// takes no meaningful time (installer/winetricks can take 20-40 minutes).
        public var isAutoApplicable: Bool {
            switch self {
            case .file, .copy, .renderer, .sync, .environment, .pin, .note, .dxvkConfig, .dllOverride: return true
            case .installer, .winetricks, .registry, .winver: return false
            }
        }
    }

    /// True when every step can run silently at Play time — the app then applies the recipe
    /// as part of pressing Play ("make it work like the db verified it"), no clicks needed.
    /// Recipes with heavy or wine-touching steps get an honest prompt instead.
    public var isAutoApplicable: Bool { steps.allSatisfy(\.isAutoApplicable) }

    /// False when a file a `copy` step placed is gone: the game was reinstalled or Steam put its
    /// files back, and the environment still records the recipe as applied. Play then treats the
    /// recipe as not applied, so the copy comes back before the launch (2026-09-11: CS:GO Legacy
    /// reinstalled without its d3d9.dll would have launched on the wrong Direct3D).
    public func artifactsPresent(driveC: URL) -> Bool {
        steps.allSatisfy { step in
            if case let .copy(_, to, _) = step { return FileManager.default.fileExists(atPath: driveC.appending(path: to).path) }
            return true
        }
    }

    /// True when applying the recipe changes what a launch inherits: the renderer, the sync
    /// mode or an environment variable. A Steam client that is already running keeps the
    /// environment it started with (issues #22/#25), so a Play that auto-applied such a recipe
    /// must stop the bottle first or the game it launches never sees the change. The Sims
    /// recipe's MVK_SHADOW_IMPORT=1 is the case that made this visible.
    public var changesLaunchEnvironment: Bool {
        steps.contains { step in
            switch step {
            case .renderer, .sync, .environment: return true
            default: return false
            }
        }
    }

    public struct KnownIssue: Codable, Sendable {
        public var symptom: String
        public var cause: String?
        public var fix: String?
    }

    /// A recipe the current engine cannot deliver: shown but not runnable, with the reason
    /// and an upstream tracking link. Better one honest disabled tile than an installer
    /// that hangs forever (the Rockstar case).
    public struct Blocked: Codable, Sendable {
        public var reason: String
        public var tracking: String?
    }

    /// Partially works: installable and worth trying, but with known issues. Unlike `blocked`,
    /// it does NOT stop `apply()` — the UI just flags it so the launcher grid stops presenting it
    /// as a clean "Install".
    public struct Flaky: Codable, Sendable {
        public var reason: String
    }

    public struct Verification: Codable, Sendable {
        public var date: String
        public var engine: String
        public var macos: String
        public var chip: String
        public var result: String

        public init(date: String, engine: String, macos: String, chip: String, result: String) {
            self.date = date; self.engine = engine; self.macos = macos; self.chip = chip; self.result = result
        }

        /// A recipe's lastVerified is an object, a row's is a date string. A recipe written with the
        /// row's shape must not vanish from the app: 0.9.8 shipped the Metaphor recipe as a bare
        /// date and every bundled load of it failed silently, so Play never moved the environment
        /// to the engine the recipe asks for (2026-09-12). A bare string is taken as the date.
        public init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let date = try? single.decode(String.self) {
                self.init(date: date, engine: "", macos: "", chip: "", result: "")
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(date: try c.decode(String.self, forKey: .date),
                      engine: try c.decodeIfPresent(String.self, forKey: .engine) ?? "",
                      macos: try c.decodeIfPresent(String.self, forKey: .macos) ?? "",
                      chip: try c.decodeIfPresent(String.self, forKey: .chip) ?? "",
                      result: try c.decodeIfPresent(String.self, forKey: .result) ?? "")
        }
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var requires: [String]?
    public var renderer: Renderer?
    /// The engine this recipe needs, by manifest id (the EA app needs the Wine 11 tree, #60).
    /// Highball offers that engine before applying the recipe to an environment on another Wine.
    public var engine: String?
    public var steps: [Step]
    public var knownIssues: [KnownIssue]?
    public var lastVerified: Verification?
    public var blocked: Blocked?
    /// True for a fix Play must never apply on its own: it helps some Macs and breaks others,
    /// so the page offers it under Advanced and the notes say when to try it. The first one is
    /// RaceRoom's newer Direct3D 9 layer (highball-db#60): it rendered the game for one reporter
    /// and drew it in grayscale for another. An opt-in recipe still counts as the game's fix
    /// for the page's wording and for artifact checks once applied.
    public var optIn: Bool?
    public var isOptIn: Bool { optIn ?? false }
    /// What an installed runtime leaves behind, so the Dependencies panel can tell "installed"
    /// from "our recipe ran": a file under drive_c, or a registry value in system.reg (exact
    /// match or a minimum for dword values). Any one marker satisfied means installed. Data, so
    /// a runtime a game's own prerequisite installed shows as installed too (plan Phase 0.3).
    public var installedMarkers: [InstalledMarker]?

    public struct InstalledMarker: Codable, Sendable {
        /// Path under drive_c, e.g. "windows/system32/vcruntime140.dll".
        public var file: String?
        /// Registry key under HKLM as written in system.reg, e.g.
        /// "Software\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\x64".
        public var registry: String?
        public var value: String?
        /// Exact raw value text, e.g. "dword:00000001".
        public var equals: String?
        /// Minimum for a dword value, decimal.
        public var min: Int?
    }

    /// True when any marker is present in the bottle. Recipes without markers report false; the
    /// caller still knows whether the recipe ran.
    public func isInstalled(in bottle: Bottle) -> Bool {
        guard let markers = installedMarkers, !markers.isEmpty else { return false }
        lazy var systemReg: String = (try? String(contentsOf: bottle.url.appending(path: "system.reg"), encoding: .utf8)) ?? ""
        for m in markers {
            if let f = m.file, FileManager.default.fileExists(atPath: bottle.driveC.appending(path: f).path) { return true }
            if let key = m.registry, let name = m.value, let raw = RegistryText.value(in: systemReg, key: key, name: name) {
                if let eq = m.equals { if raw.lowercased() == eq.lowercased() { return true } else { continue } }
                if let min = m.min, let n = RegistryText.dword(raw), n >= min { return true }
                if m.equals == nil, m.min == nil { return true }
            }
        }
        return false
    }
    public var flaky: Flaky?

    public static func load(from url: URL) throws -> Recipe {
        try JSONDecoder.highball.decode(Recipe.self, from: Data(contentsOf: url))
    }
}

/// Applies a recipe to a bottle.
public struct RecipeRunner: Sendable {
    public let paths: HighballPaths
    public let engine: InstalledEngine
    public var bottle: Bottle
    public let store: EngineStore

    public init(paths: HighballPaths = HighballPaths(), engine: InstalledEngine, bottle: Bottle) {
        self.paths = paths; self.engine = engine; self.bottle = bottle; self.store = EngineStore(paths: paths)
    }

    /// The file a `copy` step reads, or nil when `from` is absolute, climbs out of the engine
    /// with `..`, or does not exist. Recipes are data from the database, so a step must not be
    /// able to read anything but the engine it was written for.
    /// Wine stamps its builtin PE DLLs with "Wine builtin DLL" at offset 0x40; blanking it makes
    /// the loader treat the file as native, which is what a per-application `n,b` order selects.
    static func withoutBuiltinMarker(_ data: Data) -> Data {
        let marker = Data("Wine builtin DLL\0".utf8)
        guard data.count >= 0x40 + marker.count, data[0x40..<0x40 + marker.count] == marker else { return data }
        var out = data; out.replaceSubrange(0x40..<0x40 + marker.count, with: Data(count: marker.count)); return out
    }

    public static func copySource(engineRoot: URL, _ from: String) -> URL? {
        guard !from.hasPrefix("/"), !from.split(separator: "/").contains("..") else { return nil }
        let url = engineRoot.appending(path: from).standardizedFileURL
        guard url.path.hasPrefix(engineRoot.standardizedFileURL.path + "/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return url
    }

    /// The renderer a recipe may set, or nil when the user's explicit choice must stand (#29) or
    /// the bottle's engine cannot run it (#61: a fix recipe set D3DMetal on a bottle whose engine
    /// had no licence accepted for it, and every later launch in that bottle died before Wine).
    public static func rendererToApply(recipeRenderer: Renderer?, settings: BottleSettings, available: Bool = true) -> Renderer? {
        guard let r = recipeRenderer, !settings.rendererExplicit, available else { return nil }
        return r
    }

    /// The processes an installer left behind: those that appeared during the step, and only
    /// when the environment was idle before it. A busy environment gets none, because a new
    /// pid there may belong to the running program, not the installer. Plumbing that appeared
    /// (the server and the Windows services the installer's own launch booted on a cold
    /// prefix) is never a leftover: ending those by signal is what printed "wineserver crashed"
    /// in the middle of the VC++ install on nightly-e2e (#160); the environment reset after
    /// the step stops them properly. Pure, for the tests.
    public static func installerLeftovers(before: Set<pid_t>, after: [pid_t], wasIdle: Bool,
                                          isPlumbing: (pid_t) -> Bool = { _ in false }) -> [pid_t] {
        guard wasIdle else { return [] }
        return after.filter { !before.contains($0) && !isPlumbing($0) }
    }

    /// How long an installer's helpers get to finish on their own before they count as
    /// leftovers. A bootstrapper's parent exits while its engine keeps installing: the VC++
    /// redistributable returned 0 after 8 s with its Burn engine still writing the x64 runtime,
    /// and ending it then left the runtime half installed (nightly-e2e 2026-09-19, #160). The
    /// leftovers this exists for, Battle.net's Agent and Rockstar's service, never exit, so
    /// they are ended once the minute is up.
    public static let installerGrace: TimeInterval = 60

    /// Runs every step. Returns the notes the UI should show afterwards.
    public mutating func apply(_ recipe: Recipe,
                               resolve: (@Sendable (String) -> Recipe?)? = nil,
                               log: (@Sendable (String) -> Void)? = nil) async throws -> [String] {
        if let b = recipe.blocked {
            var msg = "'\(recipe.title)' is blocked on this engine: \(b.reason)"
            if let t = b.tracking { msg += " Tracked at \(t)" }
            throw HighballError.invalid(msg)
        }
        var notes: [String] = []
        // Dependencies first. A recipe that declares requires: ["steam", "dotnet48"] means the game
        // does not work without .NET, and until 2026-09-10 that field was read by nothing: pressing
        // Play launched Assetto Corsa without .NET and it died with "Configuration system failed to
        // initialize", while the recipe's only mention of it was a note telling the owner to go and
        // install it themselves. Only tweaks are applied here; a launcher in `requires` is a
        // statement about where the game comes from, not something to install on its behalf.
        for id in recipe.requires ?? [] where !bottle.settings.recipes.contains(id) {
            guard let dep = resolve?(id), dep.kind == .tweak else { continue }
            log?("[\(recipe.id)] needs \(dep.id) first")
            notes += try await apply(dep, resolve: resolve, log: log)
        }
        // A recipe's renderer is a default, never an override: an explicit user choice wins
        // (issue #29 — the Steam recipe silently reset a d3dmetal bottle to dxmt).
        if let r = recipe.renderer {
            let why = r.unavailableReason(in: engine)
            if let applied = Self.rendererToApply(recipeRenderer: r, settings: bottle.settings, available: why == nil) {
                bottle.settings.renderer = applied
            } else if let why {
                notes.append("Kept this bottle's renderer (\(bottle.settings.renderer.rawValue)); the recipe suggests \(r.rawValue): \(why)")
            } else {
                notes.append("Kept this bottle's renderer (\(bottle.settings.renderer.rawValue)); the recipe suggests \(r.rawValue).")
            }
        }
        for (i, step) in recipe.steps.enumerated() {
            // The app parses these two lines into its progress display (#31): the step line
            // becomes the stage, the hint line the "this is slow, don't worry" text under it.
            if let desc = step.progressLabel {
                log?("[\(recipe.id)] step \(i + 1)/\(recipe.steps.count) — \(desc)")
            } else {
                log?("[\(recipe.id)] step \(i + 1)/\(recipe.steps.count)")
            }
            if let slow = step.slowHint { log?("[\(recipe.id)] hint: \(slow)") }
            let runner = WineRunner(paths: paths, engine: engine, bottle: bottle)
            switch step {
            case let .installer(url, sha256, arguments, label, _, _):
                let component = EngineManifest.Component(kind: "installer", url: url, sha256: sha256 ?? "", size: nil, license: nil, optional: nil, acceptance: nil, extract: nil, note: nil, version: nil)
                let file: URL
                if sha256 != nil {
                    file = try await store.download(component, name: label)
                } else {
                    file = try await downloadUnverified(url)
                }
                let isMSI = file.pathExtension.lowercased() == "msi" || url.lastPathComponent.lowercased().contains(".msi")
                let wineArgs = isMSI ? ["msiexec", "/i", file.path, "/qn"] + arguments : [file.path] + arguments
                let before = Set(ProcessTable.processes(ofPrefix: bottle.url))
                let wasIdle = ProcessTable.isIdle(prefix: bottle.url)
                let result = try await runner.run(wineArgs, renderer: .wined3d, label: label, onOutput: log)
                // An installer must not leave processes behind. Battle.net's setup leaves its
                // Agent running and Rockstar's starts its service, both under the setup-time
                // environment (no renderer overlay, the sync mode the first boot had), and the
                // first Play then hands the real client to that agent, which spawns it with the
                // stale stack (measured 2026-09-18: the Battle.net client ran with WINEMSYNC=1
                // and no WINEDLLPATH_PREPEND under a DXMT pin). Ending them here, and the server
                // with them when nothing else runs, makes the next launch a cold start with the
                // recipe's final settings.
                // Only when nothing a person started was running before the installer: a pid that
                // is new since then can otherwise be a running game's own child (a launcher it
                // spawned, a crash handler), and a pid difference cannot tell the two apart. In
                // that case the leftovers stay, and the note says so.
                let prefix = bottle.url
                let currentLeftovers = {
                    Self.installerLeftovers(before: before, after: ProcessTable.processes(ofPrefix: prefix), wasIdle: wasIdle,
                                            isPlumbing: { ProcessTable.isPlumbing($0, prefix: prefix) })
                }
                var leftovers = currentLeftovers()
                if !leftovers.isEmpty {
                    // Helpers still finishing the install get a grace period first (see installerGrace).
                    let started = Date()
                    let deadline = started.addingTimeInterval(Self.installerGrace)
                    while !leftovers.isEmpty, Date() < deadline {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        leftovers = currentLeftovers()
                    }
                    let waited = Int(Date().timeIntervalSince(started))
                    if waited > 0 { log?("[\(recipe.id)] waited \(waited) s for the installer's helpers to finish") }
                }
                if !leftovers.isEmpty {
                    ProcessTable.terminate(leftovers)
                    log?("[\(recipe.id)] ended \(leftovers.count) process\(leftovers.count == 1 ? "" : "es") the installer left running")
                } else if !wasIdle {
                    log?("[\(recipe.id)] a program was running before the installer, so anything it left running stays; stop the environment before the next launch if it misbehaves")
                }
                if wasIdle, ProcessTable.isIdle(prefix: bottle.url), ProcessTable.liveServer(forPrefix: bottle.url) != nil {
                    _ = try? runner.kill()
                    log?("[\(recipe.id)] stopped the environment so the next launch starts it with the recipe's settings")
                }
                guard step.accepts(exitStatus: result.exitStatus) else {
                    throw HighballError.processFailed(command: label, status: result.exitStatus,
                                                      output: WineRunner.exitCodeNote(for: result.exitStatus).isEmpty
                                                        ? "see \(result.log.path)"
                                                        : "\(WineRunner.exitCodeNote(for: result.exitStatus))\nsee \(result.log.path)")
                }
                if result.exitStatus != 0 {
                    log?("[\(recipe.id)] \(label) exited with \(result.exitStatus)\(WineRunner.exitCodeNote(for: result.exitStatus)) — treating as done")
                }
                // Junctions the installer made (EA app: EA Desktop\EA Desktop → a versioned folder)
                // are stubs nothing follows until they are host symlinks.
                for link in WineReparsePoint.materializeTree(under: bottle.driveC, driveC: bottle.driveC) {
                    log?("[\(recipe.id)] linked \(link.lastPathComponent) (a Windows junction the installer made, as a symlink)")
                }
            case let .registry(key, name, type, data):
                try await runner.regAdd(key: key, name: name, type: type, data: data)
            case let .winetricks(verbs, _):
                guard let wt = engine.winetricks else { throw HighballError.missing("winetricks in engine \(engine.id)") }
                // WINE_BIN/WINESERVER_BIN/WINE_BINDIR are winetricks' own overrides for setups where
                // its binary detection fails; without them dotnet48 and friends abort on this engine
                // (verified 2026-08-25, issue #16). bash rather than sh for the same reason winetricks
                // documents on macOS.
                var env = try bottle.environment(engine: engine, renderer: .wined3d, extra: [
                    "WINE": engine.wineBinary.path,
                    "WINESERVER": engine.wineserverBinary.path,
                    "WINE_BIN": engine.wineBinary.path,
                    "WINESERVER_BIN": engine.wineserverBinary.path,
                    "WINE_BINDIR": engine.wineBinary.deletingLastPathComponent().path,
                ])
                // winetricks shells out to cabextract for Microsoft's cabinet installers (the core
                // fonts among them) and macOS does not ship it, so the app bundles one under
                // Resources/tools (highball#96). HIGHBALL_TOOLS names another directory, for the CLI.
                let tools = [ProcessInfo.processInfo.environment["HIGHBALL_TOOLS"].map { URL(fileURLWithPath: $0) },
                             Bundle.main.resourceURL?.appending(path: "tools", directoryHint: .isDirectory)]
                    .compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
                if !tools.isEmpty {
                    env["PATH"] = (tools.map(\.path) + [env["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
                }
                try Shell.run("/bin/bash", [wt.path, "--unattended"] + verbs, env: env)
            case let .environment(name, value):
                bottle.settings.environment[name] = value
            case let .renderer(r):
                bottle.settings.renderer = r
            case let .sync(m):
                bottle.settings.sync = m
            case let .winver(v):
                bottle.settings.windowsVersion = v
                try await runner.setWindowsVersion(v)
            case let .file(path, contents):
                let url = bottle.driveC.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
            case let .copy(from, to, asNative):
                guard let source = Self.copySource(engineRoot: engine.root, from) else {
                    throw HighballError.invalid("copy step: '\(from)' is not a file inside the engine")
                }
                let dest = bottle.driveC.appending(path: to)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                if asNative {
                    try Self.withoutBuiltinMarker(Data(contentsOf: source)).write(to: dest)
                } else {
                    try FileManager.default.copyItem(at: source, to: dest)
                }
                log?("copied \(source.lastPathComponent) from the engine to \(to)\(asNative ? " as a native DLL" : "")")
            case let .pin(p):
                if !bottle.settings.pins.contains(where: { $0.path == p.path }) { bottle.settings.pins.append(p) }
            case let .note(t):
                notes.append(t)
            case let .dllOverride(v):
                // Semicolon separated, and idempotent: a recipe re-run must not stack duplicates.
                var parts = bottle.settings.dllOverrides.split(separator: ";").map(String.init)
                if !parts.contains(v) { parts.append(v) }
                bottle.settings.dllOverrides = parts.joined(separator: ";")
            case let .dxvkConfig(exe, options):
                bottle.settings.dxvkAppConfig[exe] = options
            }
        }
        if !bottle.settings.recipes.contains(recipe.id) { bottle.settings.recipes.append(recipe.id) }
        try bottle.save()
        return notes
    }

    private func downloadUnverified(_ url: URL) async throws -> URL {
        try paths.ensure()
        let dest = paths.downloads.appending(path: url.lastPathComponent)
        // Same stall protection as engine downloads: URLSession.shared's 7-day resource timeout
        // let a dead CDN connection hang a recipe forever (GOG installer, 2026-08-25).
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let (tmp, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HighballError.invalid("HTTP \(http.statusCode) for \(url)")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}

public extension Recipe {
    /// The engine to offer before applying this recipe to an environment on `current`: the
    /// manifest the recipe names unless `current` already satisfies it (the same engine, or a
    /// later revision of the same Wine build, since revisions are cumulative), or the app does
    /// not know the manifest. Same Wine is not enough on its own: r7 adds a builtin DLL r6
    /// lacks, and a bottle on r6 needs the offer.
    func engineToOffer(current: EngineManifest, known: [EngineManifest]) -> EngineManifest? {
        guard let id = engine, let wanted = known.first(where: { $0.id == id }) else { return nil }
        return EngineManifest.satisfies(current: current, wanted: wanted) ? nil : wanted
    }

    /// The engine this recipe names when no manifest this build ships carries it and the
    /// environment is not already on it: the fix reached the database before the Highball
    /// that ships its engine (The Last Flame's r11 pin, highball#99, landed while 0.9.32 was
    /// the stable). Play tells the owner to update instead of launching on the current engine
    /// as if the recipe had never asked. Nil when the recipe names no engine.
    func engineUnknown(current: EngineManifest, known: [EngineManifest]) -> String? {
        guard let id = engine, current.id != id, !known.contains(where: { $0.id == id }) else { return nil }
        return id
    }
}
