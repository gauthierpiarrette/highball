import AppKit
import Foundation
import HighballKit
import Observation

@Observable @MainActor
final class AppState {
    var engines: [InstalledEngine] = []
    var bottles: [Bottle] = []
    var selectedBottle: String?
    var gamesByBottle: [String: [SteamGame]] = [:]
    var gameDB = GameDB(directories: [])

    // Long-running work
    var busy = false
    var busyTitle = ""
    var stage = ""
    var logLines: [String] = []
    var showLog = false
    // Onboarding legibility (#31): a first-time user should never have to guess whether
    // something is working, finished, or stuck.
    var stageHint = ""                  // recipe-declared "slow step, this is normal" text
    var busyStartedAt: Date?            // drives the "running for N min" row
    var busyExpected: String?           // human duration ("usually 20–40 minutes")
    var lastOutputAt: Date?             // liveness: when the task last produced output
    var doneState: DoneState?           // explicit success panel with an optional next step
    struct DoneState {
        var title: String
        var ctaTitle: String?
        var cta: (() -> Void)?
    }
    var requestCreateBottle = false     // engine-done CTA → ContentView opens the sheet

    // Onboarding
    var rosettaInstalled = true
    var needsOnboarding = false
    var showGPTKLicense = false
    var gptkLicenseText = ""

    // Crash follow-up
    var crashSuggestion: CrashSuggestion?
    struct CrashSuggestion: Identifiable {
        let id = UUID()
        let program: String
        let renderer: Renderer
        let logPath: String
    }

    var errorMessage: String?

    // Epic (via Legendary; see EpicStore)
    var epicSignedIn = false
    var epicOwned: [EpicStore.Game] = []
    var epicInstalled: Set<String> = []
    var epicLoading = false
    private var epicFetchInFlight = false
    var showEpicSignIn = false

    /// A Windows program awaiting the run/pin choice (from drag-drop, the File menu, or the button).
    var pendingRun: URL?

    func chooseProgramToRun() {
        let panel = NSOpenPanel()
        panel.title = L("Choose a Windows program")
        panel.allowedContentTypes = [.exe, .msi, .bat].compactMap { $0 }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { pendingRun = url }
    }

    let paths = HighballPaths()
    var engineStore: EngineStore { EngineStore(paths: paths) }
    var bottleStore: BottleStore { BottleStore(paths: paths) }

    func refresh() {
        engines = (try? engineStore.installedEngines()) ?? []
        bottles = (try? bottleStore.list()) ?? []
        needsOnboarding = engines.isEmpty
        rosettaInstalled = FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta/rosetta")
        if selectedBottle == nil { selectedBottle = bottles.first?.name }
        // Never trap on duplicate names (a Finder-duplicated bottle crashed the app at launch — issue #13).
        gamesByBottle = Dictionary(bottles.map { ($0.name, SteamLibrary.games(in: $0)) }, uniquingKeysWith: { a, _ in a })
        epicRefresh()
        if gameDB.byAppID.isEmpty {
            var dirs: [URL] = []
            if let res = Bundle.main.resourceURL { dirs.append(res.appending(path: "db-games")) }
            if let root = Self.repoRoot {
                dirs.append(root.deletingLastPathComponent().appending(path: "highball-db/db/games"))
            }
            gameDB = GameDB(directories: dirs)
        }
    }

    func engine(for bottle: Bottle) -> InstalledEngine? {
        (try? engineStore.engine(bottle.settings.engineID)) ?? engines.first
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
        lastOutputAt = Date()
        if let s = ProgressParser.stage(for: line) {
            stage = s
            if s.hasPrefix("Step ") { stageHint = "" }  // a new step retires the old hint
        }
        // Recipe slow-hints ("[dotnet48] hint: takes 20-40 min…") ride the same log stream.
        if let h = ProgressParser.hint(for: line) { stageHint = h }
    }

    private func runBusy(_ title: String, expected: String? = nil, showLogSheet: Bool = true,
                         done: DoneState? = nil, cleanup: (() -> Void)? = nil,
                         _ work: @escaping () async throws -> Void) {
        busy = true; busyTitle = title; stage = ""; stageHint = ""; logLines = []; showLog = showLogSheet
        busyStartedAt = Date(); busyExpected = expected; lastOutputAt = nil; doneState = nil
        Task {
            // On failure, dismiss the log sheet ourselves: SwiftUI defers the error alert
            // until the sheet closes, so a stuck sheet showed "Done" over a failed install
            // and hid the alert until the user clicked Close (issues #27/#28).
            do {
                try await work()
                doneState = done ?? DoneState(title: L("Done"), ctaTitle: nil, cta: nil)
            } catch { showLog = false; errorMessage = "\(error)" }
            cleanup?()
            busy = false
            refresh()
        }
    }

    // MARK: Actions

    func installDefaultEngine(acceptGPTK: Bool) {
        guard let manifestURL = Self.bundledManifest else {
            errorMessage = "No engine manifest found. Reinstall Highball."; return
        }
        runBusy("Installing engine — about 500 MB of verified downloads",
                expected: L("usually 5–15 minutes"),
                done: DoneState(title: L("Engine ready"), ctaTitle: L("Create your first bottle"),
                                cta: { [weak self] in self?.requestCreateBottle = true })) { [self] in
            let manifest = try EngineManifest.load(from: manifestURL)
            var accepted: Set<String> = []
            if acceptGPTK { accepted.insert("apple-gptk-license-2023-08-17") }
            _ = try await engineStore.install(manifest, accepted: accepted) { name, received, total in
                Task { @MainActor in
                    let mb = { (b: Int64) in String(format: "%.0f", Double(b) / 1_048_576) }
                    if let total, total > 0 {
                        self.stage = "Downloading \(name) — \(mb(received)) / \(mb(total)) MB"
                        if received >= total { self.appendLog("downloaded \(name) — verifying and unpacking…") }
                    } else {
                        self.stage = "Downloading \(name) — \(mb(received)) MB"
                    }
                }
            }
            await MainActor.run { self.appendLog("engine installed") }
        }
    }

    func acceptGPTK(engine: InstalledEngine) {
        do { _ = try engineStore.accept(license: "apple-gptk-license-2023-08-17", engine: engine); refresh() }
        catch { errorMessage = "\(error)" }
    }

    func createBottle(name: String, recipeID: String?) {
        guard let engine = engines.first else { return }
        runBusy("Creating bottle '\(name)' — first boot takes about 90 seconds",
                done: DoneState(title: String(format: L("Bottle '%@' is ready"), name), ctaTitle: nil, cta: nil)) { [self] in
            let bottle = try await bottleStore.create(name: name, engine: engine)
            await MainActor.run { self.appendLog("bottle created") }
            if let recipeID, let recipe = Self.recipe(recipeID) {
                var runner = RecipeRunner(paths: paths, engine: engine, bottle: bottle)
                let notes = try await runner.apply(recipe) { line in Task { @MainActor in self.appendLog(line) } }
                for n in notes { await MainActor.run { self.appendLog("note: \(n)") } }
            }
            await MainActor.run { self.selectedBottle = name }
        }
    }

    func applyRecipe(_ id: String, to bottle: Bottle) {
        guard let engine = engine(for: bottle), let recipe = Self.recipe(id) else { return }
        runBusy("Installing \(recipe.title)",
                done: DoneState(title: String(format: L("%@ installed"), recipe.title), ctaTitle: nil, cta: nil)) { [self] in
            var runner = RecipeRunner(paths: paths, engine: engine, bottle: bottle)
            let notes = try await runner.apply(recipe) { line in Task { @MainActor in self.appendLog(line) } }
            for n in notes { await MainActor.run { self.appendLog("note: \(n)") } }
        }
    }

    /// Steam's own UI (CEF) hangs under msync/esync, and Wine's sync mode is fixed when the
    /// prefix's wineserver starts. So the Steam window gets a cold start with sync forced off,
    /// while games keep the bottle's (faster) sync. See recipes/launchers/steam.json.
    private func isSteamUI(_ pin: Pin) -> Bool {
        pin.path.lowercased().hasSuffix("steam/steam.exe")
    }

    /// Pins whose launch session is still active — a second click would kill and restart the
    /// wineserver under the live session (issue #13's crash sequence), so it's refused instead.
    private var launchingPins: Set<UUID> = []

    func launch(pin: Pin, in bottle: Bottle) {
        guard let engine = engine(for: bottle) else { return }
        guard !launchingPins.contains(pin.id) else {
            errorMessage = "\(pin.name) is already starting or running. If its window never appeared, use Stop all processes on the bottle, then try again."
            return
        }
        launchingPins.insert(pin.id)
        // Steam's very first launch bootstraps its client for 15–25 minutes and looks frozen the
        // whole time (#31, #9). Detect it (no CEF dir yet) and show the progress sheet with honest
        // expectations instead of launching silently into what reads as a hang.
        let steamFirstBoot = isSteamUI(pin) && !FileManager.default.fileExists(
            atPath: bottle.driveC.appending(path: "Program Files (x86)/Steam/bin/cef").path)
        runBusy(steamFirstBoot ? L("Starting Steam for the first time — it downloads and unpacks its own client") : "Running \(pin.name)",
                expected: steamFirstBoot ? L("usually 15–25 minutes; long quiet stretches are normal") : nil,
                showLogSheet: steamFirstBoot,
                cleanup: { [weak self] in self?.launchingPins.remove(pin.id) }) { [self] in
            let runner = WineRunner(paths: paths, engine: engine, bottle: bottle)
            var extra = [String: String]()
            if isSteamUI(pin), bottle.settings.sync != SyncMode.none {
                try? runner.kill()                      // restart the wineserver so sync=none takes effect
                try? await Task.sleep(for: .seconds(2))
                extra = ["WINEMSYNC": "0", "WINEESYNC": "0"]
            }
            let result: LaunchResult
            if isSteamUI(pin) {
                let (r, resumed) = try await runner.startResumingKnownSteamCrash(pin: pin, extraEnvironment: extra) { line in
                    Task { @MainActor in
                        self.appendLog(line)
                        if line.contains("relaunching so it resumes") {
                            self.stage = L("Steam crashed at a known spot — relaunching to resume the update")
                        }
                    }
                }
                result = r
                if resumed { await MainActor.run { self.appendLog("resumed after the known crash") } }
            } else {
                result = try await runner.start(pin: pin, extraEnvironment: extra) { line in Task { @MainActor in self.appendLog(line) } }
            }
            if result.crashedEarly {
                let current = pin.renderer ?? bottle.settings.renderer
                let next: Renderer = current == .dxmt ? .d3dmetal : (current == .d3dmetal ? .dxvk : .dxmt)
                await MainActor.run {
                    self.crashSuggestion = CrashSuggestion(program: pin.name, renderer: next, logPath: result.log.path)
                }
            }
        }
    }

    func update(_ bottle: Bottle) {
        do { try bottleStore.update(bottle); refresh() } catch { errorMessage = "\(error)" }
    }

    func deleteBottle(_ name: String) {
        killBottleNamed(name)
        do { try bottleStore.delete(name); if selectedBottle == name { selectedBottle = nil }; refresh() }
        catch { errorMessage = "\(error)" }
    }

    private func killBottleNamed(_ name: String) {
        if let bottle = bottles.first(where: { $0.name == name }) { killBottle(bottle) }
    }

    func removePin(_ pin: Pin, from bottle: Bottle) {
        var copy = bottle
        copy.settings.pins.removeAll { $0.id == pin.id }
        update(copy)
    }

    /// Replace a pin wholesale (program settings sheet: arguments, environment, renderer).
    func updatePin(_ pin: Pin, in bottle: Bottle) {
        var copy = bottle
        if let i = copy.settings.pins.firstIndex(where: { $0.id == pin.id }) {
            copy.settings.pins[i] = pin
            update(copy)
        }
    }

    func setPinRenderer(_ renderer: Renderer?, pin: Pin, in bottle: Bottle) {
        var copy = bottle
        if let i = copy.settings.pins.firstIndex(where: { $0.id == pin.id }) {
            copy.settings.pins[i].renderer = renderer
            update(copy)
        }
    }

    /// Launch a Steam game by appid through the bottle's Steam client.
    func launchGame(_ game: SteamGame, in bottle: Bottle) {
        guard let engine = engine(for: bottle) else { return }
        let steam = bottle.driveC.appending(path: "Program Files (x86)/Steam/steam.exe")
        let renderer = gameDB[game.appid]?.renderer
        runBusy("Running \(game.name)", showLogSheet: false) { [self] in
            let runner = WineRunner(paths: paths, engine: engine, bottle: bottle)
            let result = try await runner.start(steam, arguments: ["-silent", "-applaunch", String(game.appid)], renderer: renderer) { line in
                Task { @MainActor in self.appendLog(line) }
            }
            if result.crashedEarly {
                let current = renderer ?? bottle.settings.renderer
                let next: Renderer = current == .dxmt ? .d3dmetal : (current == .d3dmetal ? .dxvk : .dxmt)
                await MainActor.run {
                    self.crashSuggestion = CrashSuggestion(program: game.name, renderer: next, logPath: result.log.path)
                }
            }
        }
    }

    /// Handle an .exe/.msi dropped on a bottle: run it (installer) inside the bottle.
    func runDropped(_ url: URL, in bottle: Bottle, andPin: Bool) {
        guard let engine = engine(for: bottle) else { return }
        runBusy("Running \(url.lastPathComponent)") { [self] in
            let runner = WineRunner(paths: paths, engine: engine, bottle: bottle)
            let ext = url.pathExtension.lowercased()
            let isMSI = ext == "msi"
            let args = isMSI ? ["msiexec", "/i", url.path] : [url.path]
            // Installers get the boring reliable backend; a game exe gets the bottle's
            // real renderer and runs from its own folder so relative asset paths work.
            let renderer: Renderer? = (ext == "exe") ? nil : .wined3d
            _ = try await runner.run(args, renderer: renderer, label: url.lastPathComponent,
                                     workingDirectory: url.deletingLastPathComponent()) { line in
                Task { @MainActor in self.appendLog(line) }
            }
            if andPin {
                await MainActor.run {
                    var copy = bottle
                    copy.settings.pins.append(Pin(name: url.deletingPathExtension().lastPathComponent,
                                                  path: Pin.storagePath(for: url, driveC: bottle.driveC)))
                    self.update(copy)
                }
            }
        }
    }

    func duplicateBottle(_ bottle: Bottle) {
        runBusy("Duplicating '\(bottle.name)'", showLogSheet: false) { [self] in
            killBottle(bottle)   // flush registry files before copying
            try? await Task.sleep(for: .seconds(1))
            let store = bottleStore, name = bottle.name
            // The copy can be many GB — keep it off the main thread.
            let copy = try await Task.detached { try store.duplicate(name) }.value
            await MainActor.run { self.selectedBottle = copy.name }
        }
    }

    func repairBottle(_ bottle: Bottle) {
        guard let engine = engine(for: bottle) else { return }
        runBusy("Repairing '\(bottle.name)' — re-running the Windows first boot") { [self] in
            let runner = WineRunner(paths: paths, engine: engine, bottle: bottle)
            try? runner.kill()
            try? await Task.sleep(for: .seconds(2))
            let r = try await runner.wineboot()
            guard r.exitStatus == 0 else {
                throw HighballError.processFailed(command: "wineboot -u", status: r.exitStatus, output: "see \(r.log.path)")
            }
            try? await runner.setGpuIdentity()
            try? await runner.setServiceTimeout()
            await MainActor.run { self.appendLog("bottle repaired — Windows environment refreshed") }
        }
    }

    // MARK: Epic

    var epicStore: EpicStore { EpicStore(paths: paths) }

    func epicRefresh() {
        epicSignedIn = epicStore.isAuthenticated
        guard epicSignedIn else { epicOwned = []; epicInstalled = []; return }
        guard !epicFetchInFlight else { return }
        epicFetchInFlight = true
        epicLoading = epicOwned.isEmpty
        Task.detached { [store = epicStore] in
            let owned = (try? store.ownedGames()) ?? []
            let installed = (try? store.installedAppNames()) ?? []
            await MainActor.run { [weak self] in
                self?.epicOwned = owned.sorted { $0.app_title < $1.app_title }
                self?.epicInstalled = installed
                self?.epicLoading = false
                self?.epicFetchInFlight = false
            }
        }
    }

    func epicSignIn(code: String) {
        runBusy("Connecting your Epic account", showLogSheet: false) { [self] in
            let store = epicStore
            _ = try await store.ensureInstalled()
            try await Task.detached { try store.authenticate(code: code) }.value
            await MainActor.run { self.epicRefresh() }
        }
    }

    func epicInstall(_ game: EpicStore.Game, in bottle: Bottle) {
        runBusy("Installing \(game.app_title)") { [self] in
            let store = epicStore
            let status = try await Task.detached {
                try store.install(game.app_name, into: bottle) { line in
                    Task { @MainActor in self.appendLog(line) }
                }
            }.value
            guard status == 0 else {
                throw HighballError.processFailed(command: "epic install", status: status, output: "see the log above")
            }
            await MainActor.run { self.epicRefresh() }
        }
    }

    func epicPlay(_ game: EpicStore.Game, in bottle: Bottle, renderer: Renderer? = .dxvk) {
        guard let engine = engine(for: bottle) else { return }
        runBusy("Running \(game.app_title)", showLogSheet: false) { [self] in
            let store = epicStore
            // Fresh single-use token, fetched off the main thread right before launch.
            let info = try await Task.detached { try store.launchInfo(game.app_name) }.value
            let runner = WineRunner(paths: paths, engine: engine, bottle: bottle)
            let result = try await runner.start(info.executable, arguments: info.arguments,
                                                renderer: renderer, extraEnvironment: info.environment,
                                                workingDirectory: info.workingDirectory) { line in
                Task { @MainActor in self.appendLog(line) }
            }
            if result.crashedEarly {
                await MainActor.run {
                    self.crashSuggestion = CrashSuggestion(program: game.app_title,
                                                          renderer: renderer == .dxvk ? .d3dmetal : .dxvk,
                                                          logPath: result.log.path)
                }
            }
        }
    }

    func setDpi(_ scale: Int, in bottle: Bottle) {
        guard let engine = engine(for: bottle) else { return }
        var copy = bottle
        copy.settings.dpiScale = scale
        update(copy)
        runBusy("Applying display scaling", showLogSheet: false) { [self] in
            try await WineRunner(paths: paths, engine: engine, bottle: copy).setDpi(logPixels: scale)
        }
    }

    func killBottle(_ bottle: Bottle) {
        guard let engine = engine(for: bottle) else { return }
        try? WineRunner(paths: paths, engine: engine, bottle: bottle).kill()
    }

    /// True while any Wine process from any bottle is alive. Every Wine process (wineserver,
    /// preloaders, services) runs from the engines directory, so its path in `ps` is the marker.
    func wineProcessesRunning() -> Bool {
        guard let ps = try? Shell.capture("/bin/ps", ["axww"]) else { return false }
        return ps.contains(paths.engines.path)
    }

    /// Stop every bottle's wineserver (and with it all Windows processes).
    func killAllBottles() {
        for bottle in bottles { killBottle(bottle) }
    }

    func loadGPTKLicense() {
        for candidate in [Self.repoRoot?.appending(path: "spike/d3dmetal-license.txt"),
                          Bundle.main.url(forResource: "d3dmetal-license", withExtension: "txt")].compactMap({ $0 }) {
            if let text = try? String(contentsOf: candidate, encoding: .utf8) { gptkLicenseText = text; return }
        }
        gptkLicenseText = "License text unavailable locally. Read it at github.com/Gcenx/game-porting-toolkit (License.pdf) before accepting."
    }

    // MARK: Resource lookup (repo checkout or app bundle)

    static var repoRoot: URL? {
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appending(path: "spike/engine-manifest.json").path) { return dir }
            dir.deleteLastPathComponent()
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: cwd.appending(path: "spike/engine-manifest.json").path) { return cwd }
        return nil
    }

    static var bundledManifest: URL? {
        Bundle.main.url(forResource: "engine-manifest", withExtension: "json")
            ?? repoRoot?.appending(path: "spike/engine-manifest.json")
    }

    /// All bundled dependency ("tweak") recipes, for the Dependencies section in bottle settings.
    static func tweakRecipes() -> [HighballKit.Recipe] {
        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL { dirs.append(res) }
        if let root = repoRoot { dirs.append(root.deletingLastPathComponent().appending(path: "highball-db/recipes/tweaks")) }
        var out: [String: HighballKit.Recipe] = [:]
        for dir in dirs {
            for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "json" {
                if let r = try? HighballKit.Recipe.load(from: url), r.kind == .tweak, out[r.id] == nil { out[r.id] = r }
            }
        }
        return out.values.sorted { $0.title < $1.title }
    }

    static func recipe(_ id: String) -> HighballKit.Recipe? {
        if let url = Bundle.main.url(forResource: id, withExtension: "json"),
           let r = try? HighballKit.Recipe.load(from: url) { return r }
        guard let root = repoRoot else { return nil }
        for base in [root.appending(path: "recipes"), root.deletingLastPathComponent().appending(path: "highball-db/recipes")] {
            for sub in ["launchers", "games", "tweaks"] {
                let url = base.appending(path: "\(sub)/\(id).json")
                if let r = try? HighballKit.Recipe.load(from: url) { return r }
            }
        }
        return nil
    }

    static let launcherRecipes = ["steam", "epic-games", "battle-net", "gog-galaxy", "ea-app", "ubisoft-connect", "rockstar"]
}

import UniformTypeIdentifiers

extension UTType {
    static let exe = UTType(filenameExtension: "exe")
    static let msi = UTType(filenameExtension: "msi")
    static let bat = UTType(filenameExtension: "bat")
}
