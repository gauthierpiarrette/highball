import ArgumentParser
import Foundation
import HighballKit

@main
struct Highball: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "highball",
        abstract: "Highball — run Windows games on Apple Silicon. Free, open, engine-agnostic.",
        subcommands: [Config.self, Engine.self, Bottle.self, Run.self, LibraryCommand.self, Play.self, QuitCommand.self, PinCommand.self, Recipe.self, Tricks.self, Env.self, Epic.self, GOG.self, Report.self, BugReportCommand.self, Verify.self],
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
                let health = e.isComplete ? "" : "\tINCOMPLETE, missing: \(e.missingFiles.joined(separator: ", "))"
                print("\(e.id)\t\(v)\trenderers: \(renderers)\(health)")
            }
        }
    }

    struct Install: AsyncParsableCommand {
        @Argument(help: "Path to an engine manifest JSON.") var manifest: String
        @Flag(name: .customLong("accept-d3dmetal-license"), help: "Accept Apple's Game Porting Toolkit license and install D3DMetal.") var acceptD3DMetal = false

        func run() async throws {
            let m = try EngineManifest.load(from: URL(fileURLWithPath: manifest))
            guard m.runs(onMacOS: EngineManifest.currentMacOS) else {
                throw HighballError.invalid("\(m.id) needs macOS \(m.minMacOS) or newer; this Mac runs \(EngineManifest.currentMacOS)")
            }
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
    static let configuration = CommandConfiguration(abstract: "Manage bottles (Wine prefixes).", subcommands: [List.self, Create.self, Delete.self, Set.self, Kill.self, Duplicate.self, Repair.self, Ps.self])

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
            var bottle = try await BottleStore().create(name: name, engine: eng, renderer: renderer)
            if renderer != nil {   // a flag the user typed is an explicit choice (#29)
                bottle.settings.rendererExplicit = true
                try bottle.save()
            }
            print("created \(bottle.url.path)")
            if let recipe {
                var r = RecipeRunner(engine: eng, bottle: bottle)
                let notes = try await r.apply(try loadRecipe(recipe), resolve: { try? loadRecipe($0) }) { print($0) }
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
        static let configuration = CommandConfiguration(abstract: "Change a bottle setting: engine, renderer, winver, sync, hud, avx, dpi, retina on|off, dxvkasync, framegen, framegenadaptive, framegenflow, framegenperformance, framegenforcevsync, dlloverrides, keepfiles on|off, env KEY=VALUE (empty VALUE removes)")
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
            case "framegen":
                guard let m = Int(value), (1...4).contains(m) else { fail("framegen expects a multiplier 1..4 (1 = off)") }
                b.settings.frameGen = m
            case "framegenadaptive": b.settings.frameGenAdaptive = (value == "1" || value == "true")
            case "framegenperformance": b.settings.frameGenPerformance = (value == "1" || value == "true")
            case "framegenforcevsync": b.settings.frameGenForceVsync = (value == "1" || value == "true")
            case "framegenflow":
                guard let f = Int(value), (25...100).contains(f) else { fail("framegenflow expects a percentage 25..100") }
                b.settings.frameGenFlowScale = f
            case "dlloverrides":
                b.settings.dllOverrides = value
            case "keepfiles":
                // Discussion #157: Documents inside the environment (on) or linked to ~/Documents (off).
                let on = (value == "1" || value == "true" || value == "on")
                for line in try UserFolders.set(inside: on, driveC: b.driveC) { print(line) }
                b.settings.keepFilesInside = on
            case "dpi":
                guard let scale = Int(value) else { fail("dpi expects a number (96..240; 96 = 100%, 192 = 200%)") }
                b.settings.dpiScale = scale
                let eng = try EngineStore().engine(b.settings.engineID)
                try await WineRunner(engine: eng, bottle: b).setDpi(logPixels: scale, retinaAt100: b.settings.retinaAt100)
            case "retina":
                // Native Retina pixels at 100% scaling too (above 100% they are always on).
                let on = (value == "1" || value == "true" || value == "on")
                b.settings.retinaAt100 = on
                let eng = try EngineStore().engine(b.settings.engineID)
                try await WineRunner(engine: eng, bottle: b).setDpi(logPixels: b.settings.dpiScale, retinaAt100: on)
            case "env":
                guard EnvAssignment.apply(value, to: &b.settings.environment) else { fail("env expects KEY=VALUE (empty VALUE removes)") }
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

    /// What is really running in a bottle, and with which stack. Every launch bug of 2026-09-18
    /// (services booted under a setup-time environment, an installer's agent spawning the client
    /// without the renderer overlay, a sync mode adopted silently) was invisible in the launch
    /// log and obvious in the process environment. This prints that, and with --expect it fails
    /// when a program runs with a different stack than the bottle would launch it with, which
    /// is what the smokes assert after a fresh install and first Play.
    struct Ps: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the bottle's processes with the renderer, sync mode and custom variables each one actually got. --expect fails (exit 1) when a program's stack differs from the bottle's launch environment.")
        @Argument var name: String
        @Flag(name: .long, help: "Fail when any program (not Wine's plumbing) runs with a stack that differs from what the bottle would launch it with.") var expect = false
        func run() async throws {
            let b = try BottleStore().get(name)
            let eng = try EngineStore().engine(b.settings.engineID)
            let wanted = try b.environment(engine: eng)
            let wantedRenderer = SteamRestart.rendererName(ofLive: wanted)
            let custom = Array(b.settings.environment.keys).sorted()
            let root = b.url.resolvingSymlinksInPath().path
            var mismatches = 0
            let rows = ProcessTable.processes(ofPrefix: b.url).compactMap { pid -> (pid_t, String, String, String, String, String, String?)? in
                guard let info = ProcessTable.commandLineAndEnvironment(of: pid) else { return nil }
                let argv0 = info.arguments.first ?? "?"
                let exe = argv0.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? argv0
                let cwd = ProcessTable.workingDirectory(of: pid).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? ""
                let kind = ProcessTable.isPlumbing(executable: argv0, workingDirectory: cwd, prefix: root) ? "plumbing" : "program"
                let env = info.environment
                let renderer = env["WINEDLLPATH_PREPEND"] == nil && env["WINEPREFIX"] == nil ? "?" : SteamRestart.rendererName(ofLive: env)
                let sync = SyncMode(environment: env).rawValue
                let vars = custom.map { "\($0)=\(env[$0] ?? "-")" }.joined(separator: " ")
                var why: String? = nil
                if kind == "program", env["WINEPREFIX"] != nil {
                    // A program under a pinned program's folder is judged against that pin's
                    // environment (renderer and variables), which is what launched it.
                    var expected = wanted, expectedRenderer = wantedRenderer
                    if let pin = HighballKit.Bottle.pin(owning: argv0, in: b.settings.pins),
                       let e = try? b.environment(engine: eng, renderer: pin.renderer, extra: pin.environment) {
                        expected = e; expectedRenderer = SteamRestart.rendererName(ofLive: e)
                    }
                    why = SteamRestart.reason(live: env, wanted: expected, wantedRenderer: expectedRenderer, custom: custom)
                    if why != nil { mismatches += 1 }
                }
                return (pid, kind, exe, renderer, sync, vars, why)
            }
            if rows.isEmpty { print("no processes in \(name)"); return }
            for r in rows {
                print("\(r.0)\t\(r.1)\t\(r.2)\trenderer=\(r.3)\tsync=\(r.4)\(r.5.isEmpty ? "" : "\t" + r.5)\(r.6.map { "\tMISMATCH: " + $0 } ?? "")")
            }
            if expect && mismatches > 0 {
                print("\(mismatches) program\(mismatches == 1 ? "" : "s") run with a different stack than \(name) would launch them with")
                throw ExitCode(1)
            }
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
                guard let v = value.first, EnvAssignment.apply(v, to: &b.settings.pins[i].environment) else { fail("env expects KEY=VALUE (empty VALUE removes)") }
            default: fail("unknown setting \(setting) (args, renderer, env)")
            }
            try bs.update(b)
            let p = b.settings.pins[i]
            print("ok — \(p.name): args=[\(ArgumentLine.join(p.arguments))] renderer=\(p.renderer?.rawValue ?? "default") env=\(p.environment.count) vars")
        }
    }
}

/// The engine manifests a repo checkout ships (`spike/engine-manifest.json`, `spike/engines/*.json`),
/// found from the current directory as the recipe and database paths are. Facts they state
/// about an installed engine are adopted into it before a launch, so a CLI launch matches the
/// app's (the r11/r12 Direct3D 9 rule, highball#198). Nothing outside a checkout: no manifests.
func adoptKnownEngineFacts() {
    var urls = [URL(fileURLWithPath: "spike/engine-manifest.json")]
    if let more = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "spike/engines"), includingPropertiesForKeys: nil) {
        urls += more.filter { $0.pathExtension == "json" }
    }
    let known = urls.compactMap { try? EngineManifest.load(from: $0) }
    if !known.isEmpty { EngineStore().adoptKnownFacts(known: known) }
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
        adoptKnownEngineFacts()
        let eng = try EngineStore().engine(b.settings.engineID)
        let runner = WineRunner(engine: eng, bottle: b)
        await BottleStore.preflight(runner: runner, bottle: b) { print($0) }
        let echo: @Sendable (String) -> Void = { print($0) }
        let out: (@Sendable (String) -> Void)? = verbose ? echo : nil
        // A Steam game launched from here gets what Play gives it: the variables its recipe
        // scoped to it (highball#198), found from the -applaunch id. Anything else gets none.
        let scoped: [String: String] = {
            guard let i = arguments.firstIndex(of: "-applaunch"), i + 1 < arguments.count,
                  let appid = Int(arguments[i + 1]) else { return [:] }
            let db = GameDB(directories: GameDB.defaultDirectories())
            return b.settings.environment(forGame: db[appid]?.id)
        }()
        if !scoped.isEmpty { print("with the game's own variables: " + scoped.keys.sorted().joined(separator: ", ")) }
        let result: LaunchResult
        if let pin = b.settings.pins.first(where: { $0.name.lowercased() == program.lowercased() }) {
            var p = pin
            if let renderer { p.renderer = renderer }
            p.arguments += arguments
            p.environment.merge(scoped) { _, new in new }
            if p.path.lowercased().hasSuffix("steam/steam.exe") {
                switch WineRunner.steamInvocation(clientRunning: runner.steamIsRunning(), arguments: p.arguments) {
                case .forward:
                    print("Steam is already running in this bottle; handed it: \(p.arguments.joined(separator: " "))")
                    if let forwarded = try await runner.forwardToRunningSteam(p.arguments, onOutput: out) { result = forwarded }
                    else { result = try await runner.start(pin: p, onOutput: out) }
                case .showWindow:
                    print("Steam is already running in this bottle; asked it to show its window")
                    if let shown = try await runner.showRunningSteam(onOutput: out) { result = shown }
                    else { result = try await runner.start(pin: p, onOutput: out) }
                case .start:
                    result = try await runner.startResumingKnownSteamCrash(pin: p, onOutput: out ?? { _ in }).result
                }
            } else {
                result = try await runner.start(pin: p, onOutput: out)
            }
        } else if program.contains(":") || program.contains("\\") {
            let named = b.resolve(windowsPath: program)
            WineReparsePoint.dematerializeAlong(named, driveC: b.driveC)
            let exe = WineReparsePoint.follow(named, driveC: b.driveC) ?? named
            result = try await runner.start(exe, arguments: arguments, renderer: renderer, extraEnvironment: scoped,
                                            workingDirectory: exe.deletingLastPathComponent(),
                                            program: exe.path == named.path ? nil : program, onOutput: out)
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
        // The status Wine reports for the program becomes the CLI's, so scripts can assert on $?
        // (Scripts/test-cli-exit.sh) instead of grepping the exit= line. Wine keeps the low 8 bits
        // of the Windows code: 0 only for 0, but 3010 arrives as 194 and 256 as 1.
        throw ExitCode(result.exitStatus)
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
            let notes = try await r.apply(try loadRecipe(recipe), resolve: { try? loadRecipe($0) }) { print($0) }
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
        var env = WineRunner.joiningLiveServer(try b.environment(engine: eng, renderer: .wined3d), prefix: b.url)
        env["WINE"] = eng.wineBinary.path
        env["WINE_BIN"] = eng.wineBinary.path
        env["WINESERVER_BIN"] = eng.wineserverBinary.path
        env["WINE_BINDIR"] = eng.wineBinary.deletingLastPathComponent().path
        env["WINESERVER"] = eng.wineserverBinary.path
        env["PATH"] = "\(eng.engineDir.appending(path: "bin").path):/usr/bin:/bin:/usr/sbin:/sbin"
        // bash, as the recipe path runs it (winetricks' macOS guidance). bash drops the DYLD vars
        // under SIP like sh does, so they reach wine through WinetricksWine's script.
        env = WinetricksWine.environment(env, wine: eng.wineBinary, script: try WinetricksWine.installScript(in: HighballPaths()))
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
        adoptKnownEngineFacts()
        let eng = try EngineStore().engine(b.settings.engineID)
        var library = SteamLibrary.games(in: b).filter(\.isReady)
        if !games.isEmpty { library = library.filter { games.contains($0.appid) } }
        let db = GameDB(directories: GameDB.defaultDirectories())
        if !includeAnticheat {
            // Compliance guard: never auto-run titles with anti-cheat. Verifying those is a
            // deliberate human decision (--include-anticheat), not something a batch does.
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
                    // The game's own scoped variables ride along, as they do from Play (highball#198).
                    let o = try await verifier.run(game: game, renderer: r, runSeconds: seconds,
                                                   gameEnvironment: b.settings.environment(forGame: db[game.appid]?.id)) { print($0) }
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

struct GOG: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gog",
        abstract: "Install and play GOG games through gogdl, with comet for achievements and gogdl for cloud saves (GOG Galaxy cannot sign in under Wine).",
        subcommands: [Login.self, Auth.self, List.self, Install.self, Launch.self])

    struct Login: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the GOG sign-in URL; paste the address it ends on into 'highball gog auth'.")
        func run() async throws {
            try await GOGStore().ensureInstalled()
            print("1. Open: \(GOGStore.loginURL.absoluteString)")
            print("2. Sign in. GOG ends on a mostly blank embed.gog.com page: copy its whole address.")
            print("3. Run: highball gog auth, and paste the address when asked.")
        }
    }

    struct Auth: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Finish sign-in with the address (or the code) the login page ended on; asks for it when not given, which keeps it out of shell history.")
        @Argument var pasted: String?
        func run() async throws {
            let store = GOGStore()
            try await store.ensureInstalled()
            var text = pasted
            if text == nil {
                print("Paste the address GOG's sign-in page ended on: ", terminator: "")
                text = readLine()
            }
            let reading = GOGStore.readSignIn(text ?? "")
            guard case let .code(code) = reading else {
                switch reading {
                case .signInPage: fail("that is the sign-in page itself; log in on it, then paste the address of the page it ends on")
                case .noCode: fail("that GOG address has no code; paste the address shown right after you log in")
                default: fail("no code in that; paste the whole embed.gog.com address")
                }
            }
            try store.authenticate(code: code)
            print("signed in\(store.username.map { " as \($0)" } ?? "")")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the account's games, and where each installed one lives.")
        func run() async throws {
            let store = GOGStore()
            try await store.ensureInstalled()
            guard store.isAuthenticated else { fail("not signed in — run 'highball gog login' first") }
            var installed: [String: String] = [:]
            for b in (try? BottleStore().list()) ?? [] {
                for g in GOGStore.installedGames(driveC: b.driveC) { installed[g.id] = b.name }
            }
            for g in try await store.ownedGames() {
                let mark = installed[g.id].map { "[installed: \($0)] " } ?? ""
                print("\(mark)\(g.id)\t\(g.title)")
            }
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download a game's Windows build into a bottle (drive_c/Games) and run its GOG setup.")
        @Argument var bottle: String
        @Argument(help: "Product id from 'highball gog list'.") var id: String
        func run() async throws {
            let store = GOGStore()
            try await store.ensureInstalled()
            guard store.isAuthenticated else { fail("not signed in — run 'highball gog login' first") }
            let b = try BottleStore().get(bottle)
            let info = try store.info(id)
            let language = GOGStore.language(for: info.languages)
            if !info.dependencies.isEmpty { _ = try? store.downloadRedists(info.dependencies) { print($0) } }
            let status = try store.install(id, into: b, language: language) { line in
                if !line.contains("[PROGRESS]") || line.contains("= Progress:") { print(line) }
            }
            guard status == 0, store.downloadCompleted(id) else { fail("gogdl download did not finish (exit \(status)); run the same command to resume") }
            guard let game = GOGStore.installedGames(driveC: b.driveC).first(where: { $0.id == id }) else { fail("downloaded, but no goggame-\(id).info turned up in \(b.name)") }
            store.keepManifest(for: game)
            let eng = try EngineStore().engine(b.settings.engineID)
            let runner = WineRunner(engine: eng, bottle: b)
            try await store.runSetup(game, language: language, runner: runner,
                                     onStep: { n, total, label in print("setup \(n)/\(total): \(label)") },
                                     onFailure: { label, code in print("setup: \(label) ended with code \(code); carrying on") })
            print("installed \(game.title) into \(b.name): \(game.folder.path)")
        }
    }

    struct Launch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Launch an installed GOG game in a bottle, with comet and cloud saves unless turned off.")
        @Argument var bottle: String
        @Argument var id: String
        @Option var renderer: HighballKit.Renderer?
        @Flag(help: "Run without comet (no achievements).") var noComet = false
        @Flag(help: "Skip the cloud-save sync before and after.") var noSaves = false
        func run() async throws {
            let store = GOGStore()
            let b = try BottleStore().get(bottle)
            guard let game = GOGStore.installedGames(driveC: b.driveC).first(where: { $0.id == id }),
                  let task = game.launchTask(choice: GOGSettings.load(store).launchChoice[id]),
                  let launch = GOGStore.launch(task, in: game) else { fail("GOG game \(id) is not installed in \(b.name)") }
            let eng = try EngineStore().engine(b.settings.engineID)
            let runner = WineRunner(engine: eng, bottle: b)
            let saves = GOGSaves(store: store)
            let settings = GOGSettings.load(store)   // the game page's choices hold here too
            var folders: [(GOGSaves.Location, URL)] = []
            var inStep = Set<String>()   // locations whose saves came down: their upload needs no copy of the cloud's first
            if !noSaves, !settings.cloudSavesOff.contains(id), store.isAuthenticated, let client = saves.clientID(for: game), let locations = try? saves.locations(clientID: client) {
                folders = locations.compactMap { l in GOGSaves.resolve(l.template, game: game, driveC: b.driveC).map { (l, $0) } }
                for (l, f) in folders {
                    let outcome = saves.sync(game, location: l, folder: f, direction: .download)
                    if outcome == .synced { inStep.insert(l.name) }
                    print("saves \(l.name) down: \(Self.describe(outcome))")
                }
            }
            var comet: Process?
            if !noComet, settings.cometOff[id] == nil, store.isAuthenticated {
                if let tools = try? await store.ensureComet() { _ = try? await GOGComet.installService(from: tools.service, runner: runner) }
                let log = HighballPaths().logs.appending(path: "comet-\(id).log")
                comet = try? GOGComet(store: store).start(log: log)
                print(comet != nil ? "comet running (log \(log.path))" : "comet did not start; playing without achievements")
            }
            let result: LaunchResult
            do {
                result = try await runner.start(launch.executable, arguments: launch.arguments, renderer: renderer,
                                                workingDirectory: launch.workingDirectory)
            } catch {
                GOGComet(store: store).stop(comet)   // it would hold port 9977 and its copy of the tokens
                throw error
            }
            print("exit=\(result.exitStatus) — log: \(result.log.path)")
            // A launcher task hands over to another program in the folder and exits: the session
            // lasts while any of them runs in this bottle, so comet and the save upload wait for
            // the game itself.
            let markers = game.sessionMarkers(launching: launch.executable)
            var handedOver = false
            for _ in 0..<5 {   // the program it hands to can take a moment to appear
                if !SessionWatch.pids(ofPrefix: b.url, markers: markers).isEmpty { handedOver = true; break }
                try await Task.sleep(for: .seconds(2))
            }
            if handedOver {
                print("the game is still running (handed over from \(launch.executable.lastPathComponent)); waiting for it to close")
                while !SessionWatch.pids(ofPrefix: b.url, markers: markers).isEmpty {
                    try await Task.sleep(for: .seconds(2))
                }
            }
            GOGComet(store: store).stop(comet)
            for (l, f) in folders {
                let outcome = saves.sync(game, location: l, folder: f, direction: .upload, cloudInStep: inStep.contains(l.name))
                print("saves \(l.name) up: \(Self.describe(outcome))")
            }
        }

        static func describe(_ outcome: GOGSaves.Outcome) -> String {
            switch outcome {
            case .synced: return "synced"
            case .conflict: return "both copies changed, nothing moved; play from the app to choose which to keep"
            case .refused: return "newer saves on the other side, nothing moved"
            case .failed(let why): return "failed (\(why))"
            }
        }
    }
}

// MARK: - highball library / play (highball#432)

/// The library as the app builds it, read from disk: the environments' Steam games, installed and
/// owned, Steam for Mac's installs, Battle.net's installs, the GOG games in the environments, the
/// programs added by hand, and with `epic` the Epic account's games, which asks legendary, and the
/// GOG games' names and covers, which may ask GOG's database. Not-installed games are homed as the app homes them (AppState's
/// defaultBottle: the Games environment, else the first with Steam, else the first).
func currentLibrary(paths: HighballPaths, epic: Bool) -> [LibraryItem] {
    let bottles = (try? BottleStore(paths: paths).list()) ?? []
    let steam = Dictionary(bottles.map { ($0.name, SteamLibrary.games(in: $0)) }, uniquingKeysWith: { a, _ in a })
    let owned = Dictionary(bottles.map { ($0.name, SteamOwnedLibrary.games(in: $0)) }, uniquingKeysWith: { a, _ in a })
    var epicOwned: [EpicStore.Game] = [], epicInstalls: [String: String] = [:]
    let store = EpicStore(paths: paths)
    if epic, store.isAuthenticated {
        epicOwned = (try? store.ownedGames()) ?? []
        epicInstalls = EpicStore.installMap((try? store.installedGames()) ?? [])
    }
    let hasSteam = { (b: HighballKit.Bottle) in
        FileManager.default.fileExists(atPath: b.driveC.appending(path: "Program Files (x86)/Steam/steam.exe").path)
    }
    let home = bottles.first { $0.name == "Games" } ?? bottles.first(where: hasSteam) ?? bottles.first
    let battleNet = Dictionary(bottles.map { ($0.name, BattleNetLibrary.games(in: $0)) }, uniquingKeysWith: { a, _ in a })
    // GOG as the app reads it: installs from disk, and the launch choices that decide which
    // programs added by hand its tiles stand for, so both list the same ids.
    let gogStore = GOGStore(paths: paths)
    let gogInstalled = Dictionary(bottles.map { ($0.name, GOGStore.installedGames(driveC: $0.driveC)) }, uniquingKeysWith: { a, _ in a })
    let gogGames = epic ? Set(gogInstalled.values.joined().map(\.id)).sorted().compactMap { gogStore.game($0) } : []
    return LibraryIndex.build(bottles: bottles, steamByBottle: steam, steamOwnedByBottle: owned,
                              macInstalled: MacSteam.installedGames(), epicOwned: epicOwned, epicInstalls: epicInstalls,
                              gogGames: gogGames, gogInstalledByBottle: gogInstalled,
                              gogLaunchChoice: GOGSettings.load(gogStore).launchChoice,
                              battleNetByBottle: battleNet,
                              plays: LibraryStore(paths: paths).load(), defaultBottle: home?.name,
                              pinExists: { b, pin in FileManager.default.fileExists(atPath: pin.executableURL(driveC: b.driveC).path) })
}

/// Everything Highball started, ended in one go: what a frontend runs when it closes (highball#432),
/// since it knows games by id and has no idea which environment holds which. Every environment
/// with a live Wine server is stopped the way Stop all processes does it, then the app is asked
/// to quit, as Quit in its menu would. Nothing outside Highball's environments is touched.
struct QuitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quit",
        abstract: "Stop every program running in Highball's environments, Steam included, and quit Highball.",
        discussion: "For frontends such as ES-DE on exit. --keep-app leaves the Highball app open.")
    @Flag(help: "Stop the environments but leave the Highball app running.") var keepApp = false

    func run() async throws {
        let paths = HighballPaths()
        let engines = EngineStore(paths: paths)
        for b in (try? BottleStore(paths: paths).list()) ?? [] where ProcessTable.liveServer(forPrefix: b.url) != nil {
            guard let eng = try? engines.engine(b.settings.engineID) else { continue }
            _ = try? WineRunner(paths: paths, engine: eng, bottle: b).kill()
            print("stopped \(b.name)")
        }
        guard !keepApp else { return }
        let quit = Process()
        quit.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        quit.arguments = ["-e", "if application id \"app.highball.Highball\" is running then tell application id \"app.highball.Highball\" to quit"]
        try? quit.run()
        quit.waitUntilExit()
    }
}

struct LibraryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "library",
        abstract: "List the library's games with the ids `highball play` takes.",
        discussion: "One game per line, tab-separated: id, name, environment, and installed, installed on Mac or not installed.")
    @Flag(help: "Only the games that can be played now.") var installed = false
    @Flag(help: "Print JSON instead of lines.") var json = false

    func run() async throws {
        let paths = HighballPaths()
        let names = NameStore(paths: paths).names()
        let entries = currentLibrary(paths: paths, epic: true)
            .filter { !installed || $0.installedAnywhere }
            .map { LibraryListing.entry($0, title: NameStore.name(for: $0.id, in: names) ?? $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if json {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try enc.encode(entries), as: UTF8.self))
        } else {
            for entry in entries { print(LibraryListing.line(entry)) }
        }
    }
}

struct Play: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start a library game through the Highball app, as its Play button does.",
        discussion: """
            The id is one `highball library` lists: steam:<appid>, epic:<app name>, gog:<product id>, \
            pin:<environment>:<uuid> or battlenet:<product code>, and launcher:<id> opens a launcher. Highball starts it with \
            the game's own settings and stays in the background, the way a game's Mac app does. \
            With --wait the command returns once the game has quit, for frontends such as ES-DE, \
            and Highball and Steam keep running. It follows the games Highball runs in its \
            environments, so a game Steam for Mac starts ends the wait only at --start-timeout.
            """)
    @Argument(help: "The game's library id.") var id: String
    @Flag(help: "Return only once the game has quit.") var wait = false
    @Option(help: "With --wait, how many seconds the game has to start before the command gives up.") var startTimeout: Int = 600

    func run() async throws {
        guard let target = PlayLink.Target(libraryID: id) else {
            fail("\(id) is not a library id. `highball library` lists them: steam:<appid>, epic:<app name>, gog:<product id>, pin:<environment>:<uuid>, battlenet:<product code>.")
        }
        let paths = HighballPaths()
        // A typo fails here and now, not as an alert in the app and a wait that never ends.
        switch target {
        case .launcher:
            break
        case let .epic(name):
            let store = EpicStore(paths: paths)
            guard store.isAuthenticated, EpicStore.installMap((try? store.installedGames()) ?? [])[name] != nil else {
                fail("\(id) is not an installed Epic game in this Highball. `highball library --installed` lists what can be played.")
            }
        case .steam, .gog, .pin, .battlenet:
            guard currentLibrary(paths: paths, epic: false).contains(where: { $0.id == target.libraryID }) else {
                fail("\(id) is not in this Highball's library. `highball library` lists the ids.")
            }
        }
        // The link the game's Mac app opens, with this install's token, so the app starts it
        // without asking; -g keeps Highball behind the game (MacAppStub.launchScript).
        let url = PlayLink.url(for: target, token: PlayLink.token(in: paths))
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g"] + (enclosingApp().map { ["-a", $0.path] } ?? []) + [url.absoluteString]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else { fail("macOS could not open the Highball app (open exited with \(open.terminationStatus))") }
        guard wait else { return }
        if case .launcher = target { return }   // a launcher is not a game the app follows

        let started = Date()
        var phase = PlayWait.Phase.starting
        while true {
            try await Task.sleep(for: .seconds(2))
            switch PlayWait.step(phase, id: target.libraryID, running: RunningGames.current(paths: paths),
                                 waited: Date().timeIntervalSince(started), startTimeout: TimeInterval(startTimeout)) {
            case .keepWaiting(let next): phase = next
            case .ended: return
            case .neverStarted: fail("\(id) did not start within \(startTimeout) s. Highball may be asking something in its window.")
            }
        }
    }

    /// The Highball app this command ships in, so it starts games in that app and not in another
    /// copy macOS knows; nil for a build from source, which uses the app registered for highball://.
    private func enclosingApp() -> URL? {
        var url = Bundle.main.executableURL?.resolvingSymlinksInPath()
        while let current = url, current.path != "/" {
            if current.pathExtension == "app" { return current }
            url = current.deletingLastPathComponent()
        }
        return nil
    }
}

struct BugReportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bugreport", abstract: "Print a pre-filled GitHub bug-report URL (system info + newest log tail).")
    func run() async throws {
        print(BugReport.url(version: "CLI").absoluteString)
    }
}

extension HighballKit.Renderer: ExpressibleByArgument {}


struct Config: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Where Highball keeps engines and environments (#24): `config` shows it, `config home <folder>` moves there, `config home --default` goes back.")
    @Argument(help: "'home' to change the location.") var setting: String?
    @Argument(help: "A folder Highball can keep data in, or --default.") var value: String?
    @Flag(name: .customLong("default"), help: "Back to ~/Library/Application Support/Highball.") var useDefault = false

    func run() async throws {
        let paths = HighballPaths()
        guard let setting else {
            print("home: \(paths.home.path)\(HighballPaths.configuredHome() == nil ? " (default)" : " (chosen)")")
            if let missing = paths.unavailableConfiguredHome { print("chosen location not available right now: \(missing.path); running on the default meanwhile") }
            return
        }
        guard setting == "home" else { throw ValidationError("unknown setting \(setting); only 'home'") }
        if useDefault {
            let target = HighballPaths.defaultHome
            if paths.home.standardizedFileURL != target.standardizedFileURL, paths.hasData {
                print("moving data back to \(target.path)…"); try moveHomePrinting(from: paths.home, to: target)
            }
            try HighballPaths.setConfiguredHome(nil); print("home: \(target.path) (default)"); return
        }
        guard let value else { throw ValidationError("usage: highball config home <folder> | --default") }
        let target = URL(fileURLWithPath: value, isDirectory: true)
        if let why = HighballPaths.locationProblem(target) { throw ValidationError(why) }
        if let warning = HighballPaths.locationWarning(target) { print("warning: \(warning)") }
        if paths.hasData, target.standardizedFileURL != paths.home.standardizedFileURL {
            print("moving engines, environments and downloads to \(target.path)…")
            try moveHomePrinting(from: paths.home, to: target)
        }
        try HighballPaths.setConfiguredHome(target)
        print("home: \(target.path). Relaunch the Highball app to use it.")
    }
}

private func moveHomePrinting(from source: URL, to target: URL) throws {
    var last = ""
    try HomeMove.move(from: source, to: target) { name, _, _ in
        if name != last { last = name; print("  \(name)") }
    }
}
