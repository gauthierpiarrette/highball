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
        /// Add a pinned program to the bottle.
        case pin(Pin)
        /// Free-text instruction the UI surfaces to the user after install.
        case note(String)
        /// Per-app DXVK options ("csgo.exe" → dxvk.enableAsync=False…), stored on the bottle
        /// and rendered into its dxvk.conf at every DXVK launch. This is how game-specific
        /// DXVK knowledge ships as data instead of app code.
        case dxvkConfig(exe: String, options: [String: String])

        private enum CodingKeys: String, CodingKey { case type, url, sha256, arguments, label, slow, okExitCodes, key, name, value, valueType, data, verbs, renderer, sync, winver, path, contents, pin, text, exe, options }

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
            case "pin": self = .pin(try c.decode(Pin.self, forKey: .pin))
            case "note": self = .note(try c.decode(String.self, forKey: .text))
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
            case let .pin(p): try c.encode("pin", forKey: .type); try c.encode(p, forKey: .pin)
            case let .note(t): try c.encode("note", forKey: .type); try c.encode(t, forKey: .text)
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
            case .environment, .renderer, .sync, .winver, .file, .pin, .note, .dxvkConfig: return nil
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
            case .file, .renderer, .sync, .environment, .pin, .note, .dxvkConfig: return true
            case .installer, .winetricks, .registry, .winver: return false
            }
        }
    }

    /// True when every step can run silently at Play time — the app then applies the recipe
    /// as part of pressing Play ("make it work like the db verified it"), no clicks needed.
    /// Recipes with heavy or wine-touching steps get an honest prompt instead.
    public var isAutoApplicable: Bool { steps.allSatisfy(\.isAutoApplicable) }

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
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var requires: [String]?
    public var renderer: Renderer?
    public var steps: [Step]
    public var knownIssues: [KnownIssue]?
    public var lastVerified: Verification?
    public var blocked: Blocked?
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

    /// The renderer a recipe may set, or nil when the user's explicit choice must stand (#29).
    public static func rendererToApply(recipeRenderer: Renderer?, settings: BottleSettings) -> Renderer? {
        guard let r = recipeRenderer, !settings.rendererExplicit else { return nil }
        return r
    }

    /// Runs every step. Returns the notes the UI should show afterwards.
    public mutating func apply(_ recipe: Recipe, log: (@Sendable (String) -> Void)? = nil) async throws -> [String] {
        if let b = recipe.blocked {
            var msg = "'\(recipe.title)' is blocked on this engine: \(b.reason)"
            if let t = b.tracking { msg += " Tracked at \(t)" }
            throw HighballError.invalid(msg)
        }
        var notes: [String] = []
        // A recipe's renderer is a default, never an override: an explicit user choice wins
        // (issue #29 — the Steam recipe silently reset a d3dmetal bottle to dxmt).
        if let r = recipe.renderer {
            if let applied = Self.rendererToApply(recipeRenderer: r, settings: bottle.settings) {
                bottle.settings.renderer = applied
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
                let result = try await runner.run(wineArgs, renderer: .wined3d, label: label, onOutput: log)
                guard step.accepts(exitStatus: result.exitStatus) else {
                    throw HighballError.processFailed(command: label, status: result.exitStatus,
                                                      output: WineRunner.exitCodeNote(for: result.exitStatus).isEmpty
                                                        ? "see \(result.log.path)"
                                                        : "\(WineRunner.exitCodeNote(for: result.exitStatus))\nsee \(result.log.path)")
                }
                if result.exitStatus != 0 {
                    log?("[\(recipe.id)] \(label) exited with \(result.exitStatus)\(WineRunner.exitCodeNote(for: result.exitStatus)) — treating as done")
                }
            case let .registry(key, name, type, data):
                try await runner.regAdd(key: key, name: name, type: type, data: data)
            case let .winetricks(verbs, _):
                guard let wt = engine.winetricks else { throw HighballError.missing("winetricks in engine \(engine.id)") }
                // WINE_BIN/WINESERVER_BIN/WINE_BINDIR are winetricks' own overrides for setups where
                // its binary detection fails; without them dotnet48 and friends abort on this engine
                // (verified 2026-08-25, issue #16). bash rather than sh for the same reason winetricks
                // documents on macOS.
                let env = try bottle.environment(engine: engine, renderer: .wined3d, extra: [
                    "WINE": engine.wineBinary.path,
                    "WINESERVER": engine.wineserverBinary.path,
                    "WINE_BIN": engine.wineBinary.path,
                    "WINESERVER_BIN": engine.wineserverBinary.path,
                    "WINE_BINDIR": engine.wineBinary.deletingLastPathComponent().path,
                ])
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
            case let .pin(p):
                if !bottle.settings.pins.contains(where: { $0.path == p.path }) { bottle.settings.pins.append(p) }
            case let .note(t):
                notes.append(t)
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
