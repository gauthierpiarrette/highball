import ArgumentParser
import Foundation
import HighballKit

@main
struct Highball: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "highball",
        abstract: "Highball — run Windows games on Apple Silicon. Free, open, engine-agnostic.",
        subcommands: [Engine.self, Bottle.self, Run.self, PinCommand.self, Recipe.self, Tricks.self, Env.self, Epic.self, Report.self, BugReportCommand.self, Verify.self],
        defaultSubcommand: nil
    )
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// MARK: - highball engine

struct Engine: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Manage engines (Wine + renderers).", subcommands: [List.self, Install.self, Accept.self])

    struct Accept: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Accept a license for an installed engine (e.g. apple-gptk-license-2023-08-17 to enable D3DMetal).")
        @Argument var engine: String
        @Argument var license: String
        func run() async throws {
            let store = EngineStore()
            let e = try store.accept(license: license, engine: store.engine(engine))
            print("accepted \(license) for \(e.id); renderers now: \(HighballKit.Renderer.allCases.filter { $0 == .wined3d || e.rendererDir($0.rawValue) != nil }.map(\.rawValue).joined(separator: ","))")
        }
    }

    struct List: AsyncParsableCommand {
        func run() async throws {
            let engines = try EngineStore().installedEngines()
            if engines.isEmpty { print("no engines installed — try: highball engine install spike/engine-manifest.json"); return }
            for e in engines {
                let v = (try? e.wineVersion()) ?? "?"
                let renderers = HighballKit.Renderer.allCases.compactMap { r -> String? in
                    switch r.availability(in: e) {
                    case .available: return r.rawValue
                    case .needsLicence: return "\(r.rawValue) (licence not accepted)"
                    case .notShipped: return nil
                    }
                }.joined(separator: ",")
                print("\(e.id)\t\(v)\trenderers: \(renderers)")
            }
        }
    }

    struct Install: AsyncParsableCommand {
        @Argument(help: "Path to an engine manifest JSON.") var manifest: String
        @Flag(name: .customLong("accept-d3dmetal-license"), help: "Accept Apple's Game Porting Toolkit license and install D3DMetal.") var acceptD3DMetal = false

        func run() async throws {
            let m = try EngineManifest.load(from: URL(fileURLWithPath: manifest))
            print("installing \(m.id): \(m.displayName)")
            var accepted: Set<String> = []
            if acceptD3DMetal { accepted.insert("apple-gptk-license-2023-08-17") }
            let engine = try await EngineStore().install(m, accepted: accepted) { name, got, total in
                let t = total ?? 0
                let mb = { (b: Int64) in String(format: "%.0f", Double(b) / 1_048_576) }
                // \r keeps one live-updating line per component; newline when it completes.
                print("\r  \(name): \(mb(got))\(t > 0 ? " / \(mb(t))" : "") MB", terminator: t > 0 && got >= t ? "\n" : "")
                fflush(stdout)
            }
            print("installed \(engine.id) at \(engine.root.path)")
            print("wine: \(try engine.wineVersion())")
        }
    }
}

// MARK: - highball bottle

struct Bottle: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Manage bottles (Wine prefixes).", subcommands: [List.self, Create.self, Delete.self, Set.self, Kill.self, Duplicate.self, Repair.self])

    struct List: AsyncParsableCommand {
        func run() async throws {
            let store = BottleStore()
            let bottles = try store.list()
            let damaged = (try? store.damaged()) ?? []
            if bottles.isEmpty && damaged.isEmpty { print("no bottles"); return }
            for b in bottles {
                print("\(b.name)\tengine=\(b.settings.engineID)\trenderer=\(b.settings.renderer.rawValue)\tpins=\(b.settings.pins.count)\trecipes=\(b.settings.recipes.joined(separator: ","))")
            }
            // A folder that isn't a loadable bottle used to be silently skipped, which is how a
            // half-deleted bottle became invisible and unreachable (#38).
            for d in damaged { print("\(d.name)\tDAMAGED — \(d.reason) (delete it to free the name)") }
        }
    }

    struct Create: AsyncParsableCommand {
        @Argument var name: String
        @Option(help: "Engine id (default: newest installed).") var engine: String?
        @Option(help: "Renderer: wined3d|dxmt|d3dmetal|dxvk (explicit choice; recipes won't override it)") var renderer: HighballKit.Renderer?
        @Option(help: "Apply this recipe after creation (id or path).") var recipe: String?

        func run() async throws {
            let store = EngineStore()
            let eng = try engine.map { try store.engine($0) } ?? EngineStore.defaultEngine(installed: store.installedEngines(), bundledID: nil)
            guard let eng else { fail("no engine installed") }
            print("creating bottle '\(name)' with \(eng.id) (wineboot takes ~90 s the first time)…")
            var bottle = try await BottleStore().create(name: name, engine: eng, renderer: renderer ?? .dxmt)
            if renderer != nil {   // a flag the user typed is an explicit choice (#29)
                bottle.settings.rendererExplicit = true
                try bottle.save()
            }
            print("created \(bottle.url.path)")
            if let recipe {
                var r = RecipeRunner(engine: eng, bottle: bottle)
                let notes = try await r.apply(try loadRecipe(recipe)) { print($0) }
                for n in notes { print("note: \(n)") }
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        @Argument var name: String
        func run() async throws {
            let store = BottleStore()
            // Stop the bottle first, like every other subcommand that touches a prefix. The
            // kill resolves the prefix by path, so it has to happen before the move.
            if let b = try? store.get(name), let eng = try? EngineStore().engine(b.settings.engineID) {
                try? WineRunner(engine: eng, bottle: b).kill()
            }
            let leftovers = try store.delete(name)
            print("deleted \(name)")
            for failure in leftovers { print("left behind: \(failure)") }
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change a bottle setting: engine, renderer, winver, sync, hud, avx, dpi, dxvkasync, dlloverrides, env KEY=VALUE")
        @Argument var name: String
        @Argument var setting: String
        @Argument var value: String

        func run() async throws {
            let bs = BottleStore()
            var b = try bs.get(name)
            switch setting {
            case "engine":
                // Point the bottle at another installed engine. Run `bottle repair` afterwards only
                // if the Wine build changed (a component-only engine, like r1's MoltenVK, needs none).
                guard let eng = try? EngineStore().engine(value) else { fail("engine '\(value)' is not installed") }
                b.settings.engineID = eng.id
            case "renderer":
                guard let r = HighballKit.Renderer(rawValue: value) else { fail("bad renderer") }
                b.settings.renderer = r
                b.settings.rendererExplicit = true   // recipes must not clobber this (#29)
            case "winver":
                guard let v = WindowsVersion(rawValue: value) else { fail("bad winver") }
                b.settings.windowsVersion = v
                let eng = try EngineStore().engine(b.settings.engineID)
                try await WineRunner(engine: eng, bottle: b).setWindowsVersion(v)
            case "sync": guard let s = SyncMode(rawValue: value) else { fail("bad sync") }; b.settings.sync = s
            case "hud": b.settings.metalHUD = (value == "1" || value == "true")
            case "avx": b.settings.advertiseAVX = (value == "1" || value == "true")
            case "dxvkasync": b.settings.dxvkAsync = (value == "1" || value == "true")
            case "dlloverrides":
                b.settings.dllOverrides = value
            case "dpi":
                guard let scale = Int(value) else { fail("dpi expects a number (96..240; 96 = 100%, 192 = 200%)") }
                b.settings.dpiScale = scale
                let eng = try EngineStore().engine(b.settings.engineID)
                try await WineRunner(engine: eng, bottle: b).setDpi(logPixels: scale)
            case "env":
                let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { fail("env expects KEY=VALUE") }
                b.settings.environment[parts[0]] = parts[1]
            default: fail("unknown setting \(setting)")
            }
            try bs.update(b)
            print("ok")
        }
    }

    struct Duplicate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Copy a bottle (stops it first so the copy is consistent).")
        @Argument var name: String
        @Argument(help: "Name for the copy (default: '<name> copy').") var newName: String?
        func run() async throws {
            let bs = BottleStore()
            let b = try bs.get(name)
            let eng = try EngineStore().engine(b.settings.engineID)
            try? WineRunner(engine: eng, bottle: b).kill()
            try? await Task.sleep(for: .seconds(1))
            let copy = try bs.duplicate(name, as: newName)
            print("duplicated '\(name)' → '\(copy.name)'")
        }
    }

    struct Repair: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Re-run the Windows first boot (wineboot -u) to refresh a bottle.")
        @Argument var name: String
        func run() async throws {
            let b = try BottleStore().get(name)
            let eng = try EngineStore().engine(b.settings.engineID)
            let runner = WineRunner(engine: eng, bottle: b)
            try? runner.kill()
            try? await Task.sleep(for: .seconds(2))
            // The same sequence the app's Repair and an engine switch use, 32-bit check included
            // (#37): wineboot exits 0 even when it skipped building syswow64.
            try await BottleStore.refreshPrefix(runner: runner, bottle: b)
            print("repaired \(name)")
        }
    }

    struct Kill: AsyncParsableCommand {
        @Argument var name: String
        func run() async throws {
            let b = try BottleStore().get(name)
            let eng = try EngineStore().engine(b.settings.engineID)
            let ended = try WineRunner(engine: eng, bottle: b).kill()
            print(ended.isEmpty ? "stopped \(name)" : "stopped \(name), ended \(ended.count) leftover process\(ended.count == 1 ? "" : "es") the server did not")
        }
    }
}

// MARK: - highball run

// MARK: - highball pin

struct PinCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pin",
        abstract: "Per-program settings: persistent launch arguments, environment, renderer.",
        subcommands: [List.self, Add.self, Set.self])

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pin a program: a Windows path, a unix path (preinstalled games anywhere on disk), or a drive_c-relative path.")
        @Argument var bottle: String
        @Argument var name: String
        @Argument var path: String

        func run() async throws {
            let bs = BottleStore()
            var b = try bs.get(bottle)
            guard !b.settings.pins.contains(where: { $0.name.lowercased() == name.lowercased() }) else {
                fail("a pin named '\(name)' already exists in \(b.name)")
            }
            let url: URL
            if path.contains(":") || path.contains("\\") {
                url = b.resolve(windowsPath: path)
            } else if path.hasPrefix("/") || path.hasPrefix("~") {
                url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            } else {
                url = b.driveC.appending(path: path)
            }
            guard FileManager.default.fileExists(atPath: url.path) else { fail("no file at \(url.path)") }
            let pin = Pin(name: name, path: Pin.storagePath(for: url, driveC: b.driveC))
            b.settings.pins.append(pin)
            try bs.update(b)
            print("pinned \(name) -> \(pin.path)")
        }
    }

    struct List: AsyncParsableCommand {
        @Argument var bottle: String
        func run() async throws {
            let b = try BottleStore().get(bottle)
            if b.settings.pins.isEmpty { print("no pins in \(b.name)"); return }
            for p in b.settings.pins {
                var extras: [String] = []
                if !p.arguments.isEmpty { extras.append("args=\(ArgumentLine.join(p.arguments))") }
                if !p.environment.isEmpty { extras.append("env=" + p.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")) }
                if let r = p.renderer { extras.append("renderer=\(r.rawValue)") }
                print("\(p.name)\t\(p.path)" + (extras.isEmpty ? "" : "\t" + extras.joined(separator: "\t")))
            }
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change a pin setting: args (rest of line), renderer (name or default), env KEY=VALUE (VALUE empty removes).")
        @Argument var bottle: String
        @Argument var pin: String
        @Argument var setting: String
        @Argument(parsing: .remaining) var value: [String] = []

        func run() async throws {
            let bs = BottleStore()
            var b = try bs.get(bottle)
            guard let i = b.settings.pins.firstIndex(where: { $0.name.lowercased() == pin.lowercased() }) else {
                fail("no pin '\(pin)' in \(b.name) (pins: \(b.settings.pins.map(\.name).joined(separator: ", ")))")
            }
            switch setting {
            case "args":
                b.settings.pins[i].arguments = value.count == 1 ? ArgumentLine.split(value[0]) : value
            case "renderer":
                guard let v = value.first else { fail("renderer expects a value or 'default'") }
                if v == "default" || v == "none" { b.settings.pins[i].renderer = nil }
                else if let r = HighballKit.Renderer(rawValue: v) { b.settings.pins[i].renderer = r }
                else { fail("bad renderer \(v)") }
            case "env":
                guard let v = value.first else { fail("env expects KEY=VALUE") }
                let parts = v.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { fail("env expects KEY=VALUE") }
                if parts[1].isEmpty { b.settings.pins[i].environment.removeValue(forKey: parts[0]) }
                else { b.settings.pins[i].environment[parts[0]] = parts[1] }
            default: fail("unknown setting \(setting) (args, renderer, env)")
            }
            try bs.update(b)
            let p = b.settings.pins[i]
            print("ok — \(p.name): args=[\(ArgumentLine.join(p.arguments))] renderer=\(p.renderer?.rawValue ?? "default") env=\(p.environment.count) vars")
        }
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a program in a bottle: a pin name, a Windows path, or a Unix path.")
    @Argument var bottle: String
    @Argument var program: String
    @Argument(parsing: .remaining, help: "Arguments for the program; put them after `--`.") var arguments: [String] = []
    @Option var renderer: HighballKit.Renderer?
    @Flag(help: "Print wine output to the terminal as well as the log.") var verbose = false

    func run() async throws {
        let b = try BottleStore().get(bottle)
        let eng = try EngineStore().engine(b.settings.engineID)
        let runner = WineRunner(engine: eng, bottle: b)
        await BottleStore.preflight(runner: runner, bottle: b) { print($0) }
        let echo: @Sendable (String) -> Void = { print($0) }
        let out: (@Sendable (String) -> Void)? = verbose ? echo : nil
        let result: LaunchResult
        if let pin = b.settings.pins.first(where: { $0.name.lowercased() == program.lowercased() }) {
            var p = pin
            if let renderer { p.renderer = renderer }
            p.arguments += arguments
            if p.path.lowercased().hasSuffix("steam/steam.exe") {
                if let shown = try await runner.showRunningSteam(onOutput: out) {
                    print("Steam is already running in this bottle; asked it to show its window")
                    result = shown
                } else {
                    result = try await runner.startResumingKnownSteamCrash(pin: p, onOutput: out ?? { _ in }).result
                }
            } else {
                result = try await runner.start(pin: p, onOutput: out)
            }
        } else if program.contains(":") || program.contains("\\") {
            let exe = WineReparsePoint.resolve(b.resolve(windowsPath: program), driveC: b.driveC) ?? b.resolve(windowsPath: program)
            result = try await runner.start(exe, arguments: arguments, renderer: renderer,
                                            workingDirectory: exe.deletingLastPathComponent(), onOutput: out)
        } else if FileManager.default.fileExists(atPath: program) {
            let exe = URL(fileURLWithPath: program)
            result = try await runner.start(exe, arguments: arguments, renderer: renderer,
                                            workingDirectory: exe.deletingLastPathComponent(), onOutput: out)
        } else {
            // Not a pin, not a Windows path, not a local file: let Wine resolve it (cmd, dxdiag,
            // notepad, anything on the Windows PATH) instead of failing on a made-up unix path.
            if !b.settings.pins.isEmpty {
                print("note: '\(program)' is not a pin of this bottle (pins: \(b.settings.pins.map(\.name).joined(separator: ", "))) — passing it to Wine as a program name")
            }
            result = try await runner.run([program] + arguments, renderer: renderer, label: program, onOutput: out)
        }
        if let note = result.note { print("note: \(note)") }
        print("exit=\(result.exitStatus) after \(Int(result.duration))s — log: \(result.log.path)")
        if result.crashedEarly {
            // A sync-mode mismatch with the running wineserver kills the process before it does
            // anything (issue #32); it has nothing to do with renderers, so say what it is.
            if let log = try? String(contentsOf: result.log, encoding: .utf8), log.contains("msync_init") || log.contains("esync_init") {
                print("hint: died joining the bottle's running wineserver with a different sync mode; stop the bottle (highball bottle kill \(b.name)) and retry")
            } else {
                print("hint: exited within 10 s; try another renderer (--renderer dxmt|d3dmetal|dxvk|wined3d)")
            }
        }
    }
}

// MARK: - highball recipe

struct Recipe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Apply a recipe to a bottle.", subcommands: [Apply.self, Show.self])

    struct Apply: AsyncParsableCommand {
        @Argument var bottle: String
        @Argument(help: "Recipe id (looked up in ./recipes/**) or path to a JSON file.") var recipe: String
        func run() async throws {
            let b = try BottleStore().get(bottle)
            let eng = try EngineStore().engine(b.settings.engineID)
            var r = RecipeRunner(engine: eng, bottle: b)
            let notes = try await r.apply(try loadRecipe(recipe)) { print($0) }
            for n in notes { print("note: \(n)") }
        }
    }

    struct Show: AsyncParsableCommand {
        @Argument var recipe: String
        func run() async throws {
            let r = try loadRecipe(recipe)
            print("\(r.id) (\(r.kind.rawValue)) — \(r.title)")
            for (i, s) in r.steps.enumerated() { print("  \(i + 1). \(s)") }
            if let v = r.lastVerified { print("  verified \(v.date) on \(v.engine) / macOS \(v.macos) / \(v.chip): \(v.result)") }
        }
    }
}

// MARK: - highball env

struct Env: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the environment Gin would use for a bottle (for debugging or a terminal session).")
    @Argument var bottle: String
    @Option var renderer: HighballKit.Renderer?
    func run() async throws {
        let b = try BottleStore().get(bottle)
        let eng = try EngineStore().engine(b.settings.engineID)
        let env = try b.environment(engine: eng, renderer: renderer)
        for (k, v) in env.sorted(by: { $0.key < $1.key }) { print("export \(k)=\"\(v)\"") }
        print("export PATH=\"\(eng.engineDir.appending(path: "bin").path):$PATH\"")
    }
}

// MARK: - highball tricks

struct Tricks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run winetricks verbs in a bottle (unattended).")
    @Argument var bottle: String
    @Argument(parsing: .remaining) var verbs: [String]
    func run() async throws {
        let b = try BottleStore().get(bottle)
        let eng = try EngineStore().engine(b.settings.engineID)
        guard let wt = eng.winetricks else { fail("winetricks not installed in engine \(eng.id)") }
        var env = try b.environment(engine: eng, renderer: .wined3d)
        env["WINE"] = eng.wineBinary.path
        env["WINE_BIN"] = eng.wineBinary.path
        env["WINESERVER_BIN"] = eng.wineserverBinary.path
        env["WINE_BINDIR"] = eng.wineBinary.deletingLastPathComponent().path
        env["WINESERVER"] = eng.wineserverBinary.path
        env["PATH"] = "\(eng.engineDir.appending(path: "bin").path):/usr/bin:/bin:/usr/sbin:/sbin"
        // bash, not sh: same as the recipe path — winetricks' macOS guidance, and sh strips
        // the DYLD vars winetricks' children need (issue #16 fix said "both paths"; this one lagged).
        let out = try Shell.capture("/bin/bash", [wt.path, "--unattended"] + verbs, env: env)
        print(out.split(separator: "\n").suffix(12).joined(separator: "\n"))
    }
}

// MARK: - highball verify

struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Automated compatibility runs: launch installed Steam games under one or more renderers, detect crashes and black screens, and record provenance-complete verdicts. Keep the display awake.")
    @Argument var bottle: String
    @Option(parsing: .upToNextOption, help: "Steam appids to test (default: every installed, ready game).") var games: [Int] = []
    @Option(parsing: .upToNextOption, help: "Renderers to test (default: dxvk dxmt d3dmetal if available).") var renderers: [HighballKit.Renderer] = []
    @Option(help: "Observation seconds per run.") var seconds: Int = 90
    @Flag(help: "Also test titles with known anti-cheat (skipped by default: automated runs of AC games are needless account risk).") var includeAnticheat = false

    func run() async throws {
        let b = try BottleStore().get(bottle)
        let eng = try EngineStore().engine(b.settings.engineID)
        var library = SteamLibrary.games(in: b).filter(\.isReady)
        if !games.isEmpty { library = library.filter { games.contains($0.appid) } }
        if !includeAnticheat {
            // Compliance guard: never auto-run titles with anti-cheat. Verifying those is a
            // deliberate human decision (--include-anticheat), not something a batch does.
            let db = GameDB(directories: GameDB.defaultDirectories())
            let skipped = library.filter { db[$0.appid]?.anticheat != nil || db[$0.appid]?.isBlocked == true }
            if !skipped.isEmpty { print("skipping (anti-cheat): " + skipped.map(\.name).joined(separator: ", ")) }
            library.removeAll { db[$0.appid]?.anticheat != nil || db[$0.appid]?.isBlocked == true }
        }
        if library.isEmpty { fail("no installed games matched") }
        var rs = renderers
        if rs.isEmpty {
            rs = [.dxvk, .dxmt]
            if eng.rendererDir("d3dmetal") != nil { rs.append(.d3dmetal) }
        }
        print("verifying \(library.count) game(s) × \(rs.map(\.rawValue).joined(separator: ",")) — \(seconds)s each; display must stay awake")
        let verifier = Verifier(engine: eng, bottle: b)
        var results: [VerifyOutcome] = []
        for game in library {
            for r in rs {
                do {
                    let o = try await verifier.run(game: game, renderer: r, runSeconds: seconds) { print($0) }
                    results.append(o)
                } catch { print("[\(game.name)] \(r.rawValue): error \(error)") }
            }
        }
        print("\n=== results (also in logs/verify-results.jsonl) ===")
        for o in results { print([o.title, o.renderer.rawValue, o.verdict.rawValue, "\(o.secondsAlive)s"].joined(separator: "  ")) }
        print("\nSubmit interesting rows with: highball report \(bottle) \"<title>\" --rating N --notes \"…\"")
    }
}

// MARK: - highball report

struct Report: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate a compatibility report and open a pre-filled GitHub issue.")
    @Argument var bottle: String
    @Argument(help: "What you ran (game or launcher name).") var title: String
    @Option(help: "Rating 1-5.") var rating: Int = 3
    @Option(help: "Free-text notes.") var notes: String = ""
    @Flag(help: "Print the issue URL instead of opening the browser.") var printOnly = false

    func run() async throws {
        let b = try BottleStore().get(bottle)
        let hw = (try? Shell.capture("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown"
        let os = (try? Shell.capture("/usr/bin/sw_vers", ["-productVersion"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown"
        let body = """
        ### Compatibility report
        | field | value |
        |---|---|
        | title | \(title) |
        | rating | \(rating)/5 |
        | chip | \(hw) |
        | macOS | \(os) |
        | engine | \(b.settings.engineID) |
        | renderer | \(b.settings.renderer.rawValue) |
        | sync | \(b.settings.sync.rawValue) |

        \(notes)
        """
        var comps = URLComponents(string: "https://github.com/\(HighballKit.reportRepo)/issues/new")!
        comps.queryItems = [
            .init(name: "labels", value: "report"),
            .init(name: "title", value: "[report] \(title) — \(rating)/5"),
            .init(name: "body", value: body),
        ]
        let url = comps.url!
        if printOnly { print(url.absoluteString) } else {
            try Shell.run("/usr/bin/open", [url.absoluteString])
            print("opened issue form in browser")
        }
    }
}

// MARK: - helpers

func loadRecipe(_ idOrPath: String) throws -> HighballKit.Recipe {
    if idOrPath.hasSuffix(".json") { return try HighballKit.Recipe.load(from: URL(fileURLWithPath: idOrPath)) }
    // Recipes live in the highball-db repo; search a sibling checkout and the legacy in-repo path.
    let roots = ["../highball-db/recipes", "recipes"]
    let candidates = roots.flatMap { root in
        ["launchers", "games", "tweaks"].map { URL(fileURLWithPath: "\(root)/\($0)/\(idOrPath).json") }
    }
    for c in candidates where FileManager.default.fileExists(atPath: c.path) { return try HighballKit.Recipe.load(from: c) }
    throw HighballError.missing("""
        recipe '\(idOrPath)'. Recipes live in the highball-db repo (CC0). Either:
          git clone https://github.com/gauthierpiarrette/highball-db ../highball-db
        and re-run from this directory, or pass a path to a recipe .json directly.
        (The Highball app bundles the recipes — this only affects CLI builds from source.)
        """)
}

struct Epic: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install and launch Epic games through Legendary (bypasses the Epic launcher's broken install flow).",
        subcommands: [Login.self, Auth.self, List.self, Install.self, Launch.self])

    struct Login: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the Epic sign-in URL; paste the code it gives you into 'highball epic auth <code>'.")
        func run() async throws {
            let store = EpicStore()
            _ = try await store.ensureInstalled()
            print("1. Open: \(EpicStore.loginURL.absoluteString)")
            print("2. Sign in with your Epic account; the page shows an authorizationCode.")
            print("3. Run: highball epic auth <that code>")
        }
    }

    struct Auth: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Finish sign-in with the code from the login page.")
        @Argument var code: String
        func run() async throws {
            let store = EpicStore()
            _ = try await store.ensureInstalled()
            try store.authenticate(code: code)
            print(store.isAuthenticated ? "signed in" : "sign-in did not complete — try 'highball epic login' again")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the account's games (Windows builds).")
        func run() async throws {
            let store = EpicStore()
            _ = try await store.ensureInstalled()
            guard store.isAuthenticated else { fail("not signed in — run 'highball epic login' first") }
            // Flat account view: show where each installed game lives, since legendary's
            // install state is global but the files belong to one bottle.
            let installed = Dictionary(uniqueKeysWithValues:
                ((try? store.installedGames()) ?? []).compactMap { g in g.install_path.map { (g.app_name, $0) } })
            for g in try store.ownedGames().sorted(by: { $0.app_title < $1.app_title }) {
                let mark = installed[g.app_name].map { "[installed: \(($0 as NSString).abbreviatingWithTildeInPath)] " } ?? ""
                print("\(mark)\(g.app_name)\t\(g.app_title)")
            }
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install a game's Windows build into a bottle (drive_c/Games).")
        @Argument var bottle: String
        @Argument(help: "App name from 'highball epic list'.") var app: String
        func run() async throws {
            let store = EpicStore()
            _ = try await store.ensureInstalled()
            guard store.isAuthenticated else { fail("not signed in — run 'highball epic login' first") }
            let b = try BottleStore().get(bottle)
            let status = try store.install(app, into: b) { print($0) }
            guard status == 0 else { fail("legendary install exited with \(status)") }
            print("installed \(app) into \(b.name)")
        }
    }

    struct Launch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Launch an installed Epic game in a bottle through Wine.")
        @Argument var bottle: String
        @Argument var app: String
        @Option var renderer: HighballKit.Renderer?
        @Flag(help: "Skip Epic online auth (for games that allow offline play).") var offline = false
        func run() async throws {
            let store = EpicStore()
            _ = try await store.ensureInstalled()
            let b = try BottleStore().get(bottle)
            let eng = try EngineStore().engine(b.settings.engineID)
            let info = try store.launchInfo(app, offline: offline)
            let runner = WineRunner(engine: eng, bottle: b)
            let result = try await runner.start(info.executable, arguments: info.arguments,
                                                renderer: renderer, extraEnvironment: info.environment,
                                                workingDirectory: info.workingDirectory)
            print("exit=\(result.exitStatus) — log: \(result.log.path)")
        }
    }
}

struct BugReportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bugreport", abstract: "Print a pre-filled GitHub bug-report URL (system info + newest log tail).")
    func run() async throws {
        print(BugReport.url(version: "CLI").absoluteString)
    }
}

extension HighballKit.Renderer: ExpressibleByArgument {}
