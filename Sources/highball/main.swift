import ArgumentParser
import Foundation
import HighballKit

@main
struct Highball: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "highball",
        abstract: "Highball — run Windows games on Apple Silicon. Free, open, engine-agnostic.",
        subcommands: [Engine.self, Bottle.self, Run.self, Recipe.self, Tricks.self, Env.self, Report.self, Verify.self],
        defaultSubcommand: nil
    )
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// MARK: - gin engine

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
                let renderers = HighballKit.Renderer.allCases.filter { $0 == .wined3d || e.rendererDir($0.rawValue) != nil }.map(\.rawValue).joined(separator: ",")
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
                print("  \(name): \(got)/\(total ?? 0) bytes")
            }
            print("installed \(engine.id) at \(engine.root.path)")
            print("wine: \(try engine.wineVersion())")
        }
    }
}

// MARK: - gin bottle

struct Bottle: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Manage bottles (Wine prefixes).", subcommands: [List.self, Create.self, Delete.self, Set.self, Kill.self])

    struct List: AsyncParsableCommand {
        func run() async throws {
            let bottles = try BottleStore().list()
            if bottles.isEmpty { print("no bottles"); return }
            for b in bottles {
                print("\(b.name)\tengine=\(b.settings.engineID)\trenderer=\(b.settings.renderer.rawValue)\tpins=\(b.settings.pins.count)\trecipes=\(b.settings.recipes.joined(separator: ","))")
            }
        }
    }

    struct Create: AsyncParsableCommand {
        @Argument var name: String
        @Option(help: "Engine id (default: first installed).") var engine: String?
        @Option(help: "Renderer: wined3d|dxmt|d3dmetal|dxvk") var renderer: HighballKit.Renderer = .dxmt
        @Option(help: "Apply this recipe after creation (id or path).") var recipe: String?

        func run() async throws {
            let store = EngineStore()
            let eng = try engine.map { try store.engine($0) } ?? store.installedEngines().first
            guard let eng else { fail("no engine installed") }
            print("creating bottle '\(name)' with \(eng.id) (wineboot takes ~90 s the first time)…")
            let bottle = try await BottleStore().create(name: name, engine: eng, renderer: renderer)
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
        func run() async throws { try BottleStore().delete(name); print("deleted \(name)") }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change a bottle setting: renderer, winver, sync, hud, avx, env KEY=VALUE")
        @Argument var name: String
        @Argument var setting: String
        @Argument var value: String

        func run() async throws {
            let bs = BottleStore()
            var b = try bs.get(name)
            switch setting {
            case "renderer": guard let r = HighballKit.Renderer(rawValue: value) else { fail("bad renderer") }; b.settings.renderer = r
            case "winver":
                guard let v = WindowsVersion(rawValue: value) else { fail("bad winver") }
                b.settings.windowsVersion = v
                let eng = try EngineStore().engine(b.settings.engineID)
                try await WineRunner(engine: eng, bottle: b).setWindowsVersion(v)
            case "sync": guard let s = SyncMode(rawValue: value) else { fail("bad sync") }; b.settings.sync = s
            case "hud": b.settings.metalHUD = (value == "1" || value == "true")
            case "avx": b.settings.advertiseAVX = (value == "1" || value == "true")
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

    struct Kill: AsyncParsableCommand {
        @Argument var name: String
        func run() async throws {
            let b = try BottleStore().get(name)
            let eng = try EngineStore().engine(b.settings.engineID)
            try WineRunner(engine: eng, bottle: b).kill()
            print("wineserver -k sent")
        }
    }
}

// MARK: - gin run

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
        let echo: @Sendable (String) -> Void = { print($0) }
        let out: (@Sendable (String) -> Void)? = verbose ? echo : nil
        let result: LaunchResult
        if let pin = b.settings.pins.first(where: { $0.name.lowercased() == program.lowercased() }) {
            var p = pin
            if let renderer { p.renderer = renderer }
            p.arguments += arguments
            result = try await runner.start(pin: p, onOutput: out)
        } else {
            let exe = program.contains(":") || program.contains("\\") ? b.resolve(windowsPath: program) : URL(fileURLWithPath: program)
            result = try await runner.start(exe, arguments: arguments, renderer: renderer, onOutput: out)
        }
        print("exit=\(result.exitStatus) after \(Int(result.duration))s — log: \(result.log.path)")
        if result.crashedEarly { print("hint: exited within 10 s; try another renderer (--renderer dxmt|d3dmetal|dxvk|wined3d)") }
    }
}

// MARK: - gin recipe

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

// MARK: - gin env

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
        env["WINESERVER"] = eng.wineserverBinary.path
        env["PATH"] = "\(eng.engineDir.appending(path: "bin").path):/usr/bin:/bin:/usr/sbin:/sbin"
        let out = try Shell.capture("/bin/sh", [wt.path, "--unattended"] + verbs, env: env)
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
    throw HighballError.missing("recipe \(idOrPath)")
}

extension HighballKit.Renderer: ExpressibleByArgument {}
