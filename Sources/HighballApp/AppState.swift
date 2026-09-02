import AppKit
import Foundation
import HighballKit
import Observation

@Observable @MainActor
final class AppState {
    var engines: [InstalledEngine] = []
    var bottles: [Bottle] = []
    /// Directories under bottles/ that aren't loadable bottles. Shown alongside the real
    /// ones so a bottle whose settings file is gone still has somewhere to be acted on (#38).
    var damagedBottles: [DamagedBottle] = []
    /// Bottles with a delete in flight. Their rows show it and refuse a second click.
    var deletingBottles: Set<String> = []
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
        /// The bottle that was actually launched. The alert used to edit `selectedBottle`, which
        /// `launchGame` never sets — so accepting could rewrite an unrelated bottle, or none.
        let bottleName: String
        let renderer: Renderer
        let logPath: String
    }

    var errorMessage: String?
    /// True when errorMessage describes an operation that SUCCEEDED with something left over,
    /// so the alert can say so instead of calling it a failure.
    var errorIsPartialSuccess = false

    // MARK: One Library (Phase 2)

    /// Which primary surface the detail column shows. `selectedBottle` keeps backing every
    /// bottle action and the File-menu commands; it just stopped being the router.
    enum Pane: Hashable { case library, bottles }
    var pane: Pane = .library
    var libraryItems: [LibraryItem] = []
    var libraryPlays: [String: LibraryStore.PlayRecord] = [:]
    var libraryStore: LibraryStore { LibraryStore(paths: paths) }

    func rebuildLibrary() {
        libraryItems = LibraryIndex.build(bottles: bottles, steamByBottle: gamesByBottle,
                                          epicOwned: epicOwned, epicInstalls: epicInstalls,
                                          plays: libraryPlays)
    }

    /// The verified fix recipe for a library item, if the db has one (db entry id == recipe id).
    func fixRecipe(for item: LibraryItem) -> HighballKit.Recipe? {
        guard let appid = item.steamAppID, let entry = gameDB[appid],
              let recipe = Self.recipe(entry.id), recipe.kind == .game else { return nil }
        return recipe
    }

    /// A heavy fix waiting on the user's word before Play continues (installer/winetricks
    /// class — honest prompt with the time cost instead of a silent 30-minute surprise).
    var pendingHeavyFix: (item: LibraryItem, recipe: HighballKit.Recipe)?

    /// The "never pick a bottle first" guarantee: every Play in the library resolves the
    /// item's own bottle and dispatches by source. Play also means "make it work the way
    /// the db verified it": an unapplied fix recipe whose steps are all harmless (config
    /// files, renderer — no wine processes, no installs) is applied silently first; one
    /// with heavy steps asks, with the cost stated.
    func play(_ item: LibraryItem) {
        guard let bottleName = item.bottleName,
              let bottle = bottles.first(where: { $0.name == bottleName }) else { return }
        if let recipe = fixRecipe(for: item), !bottle.settings.recipes.contains(recipe.id),
           let engine = engine(for: bottle) {
            if recipe.isAutoApplicable {
                Task { @MainActor in
                    var runner = RecipeRunner(paths: paths, engine: engine, bottle: bottle)
                    if let notes = try? await runner.apply(recipe) {
                        logLines.append("applied the \(recipe.title) fix")
                        for n in notes { logLines.append("note: \(n)") }
                    }
                    if recipe.changesLaunchEnvironment {
                        // A running Steam keeps the environment it started with; the game we are
                        // about to launch through it would never see the recipe's settings.
                        try? WineRunner(paths: paths, engine: engine, bottle: bottle).kill()
                        try? await Task.sleep(for: .seconds(2))
                        logLines.append("stopped the bottle so the new settings apply to this launch")
                    }
                    refresh()
                    let fresh = bottles.first { $0.name == bottleName } ?? runner.bottle
                    launch(item, in: fresh)
                }
                return
            }
            pendingHeavyFix = (item, recipe)
            return  // Play continues via confirmHeavyFix or skipHeavyFix
        }
        launch(item, in: bottle)
    }

    /// User confirmed the heavy fix: apply it (busy sheet shows progress), then launch.
    func confirmHeavyFix() {
        guard let (item, recipe) = pendingHeavyFix else { return }
        pendingHeavyFix = nil
        guard let bottleName = item.bottleName,
              let bottle = bottles.first(where: { $0.name == bottleName }) else { return }
        applyRecipe(recipe.id, to: bottle)
        // The user presses Play again after the install — auto-chaining a launch onto a
        // 30-minute install would fire it long after they stopped watching.
    }

    func skipHeavyFix() {
        guard let (item, _) = pendingHeavyFix else { return }
        pendingHeavyFix = nil
        guard let bottleName = item.bottleName,
              let bottle = bottles.first(where: { $0.name == bottleName }) else { return }
        launch(item, in: bottle)
    }

    private func launch(_ item: LibraryItem, in bottle: Bottle) {
        recordPlay(item)
        switch item.source {
        case .steam:
            guard let game = (gamesByBottle[bottle.name] ?? []).first(where: { $0.appid == item.steamAppID }) else { return }
            launchGame(game, in: bottle)
        case .epic:
            guard let game = epicOwned.first(where: { $0.app_name == item.epicAppName }) else { return }
            epicPlay(game, in: bottle)
        case .pin:
            guard let pin = bottle.settings.pins.first(where: { $0.id == item.pinID }) else { return }
            launch(pin: pin, in: bottle)
        }
    }

    /// Epic-only today: installs into the item's resolved bottle, else the selected one,
    /// else the first — a menu in the detail view refines it, never a modal prerequisite.
    func install(_ item: LibraryItem) {
        guard item.source == .epic,
              let game = epicOwned.first(where: { $0.app_name == item.epicAppName }) else { return }
        let target = item.bottleName.flatMap { name in bottles.first { $0.name == name } }
            ?? selectedBottle.flatMap { name in bottles.first { $0.name == name } }
            ?? bottles.first
        guard let target else { return }
        epicInstall(game, in: target)
    }

    private func recordPlay(_ item: LibraryItem) {
        libraryStore.recordPlay(id: item.id, bottle: item.bottleName)
        libraryPlays[item.id] = LibraryStore.PlayRecord(lastPlayedAt: Date(), bottle: item.bottleName)
        rebuildLibrary()
    }

    // Custom covers (Phase 3): local images only, chosen by the user.
    var coverStore: CoverStore { CoverStore(paths: paths) }
    /// Bumped when a cover changes so tiles reload their local image.
    var coverVersion = 0

    func chooseCover(for item: LibraryItem) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = String(format: L("Choose a cover image for %@"), item.title)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try coverStore.setCover(for: item.id, from: url); coverVersion += 1 }
        catch { errorIsPartialSuccess = false; errorMessage = Self.message(for: error) }
    }

    func resetCover(for item: LibraryItem) {
        coverStore.clearCover(for: item.id)
        coverVersion += 1
    }

    // Epic (via Legendary; see EpicStore)
    var epicSignedIn = false
    var epicOwned: [EpicStore.Game] = []
    /// app_name → install_path. Legendary's install state is global; which bottle a game
    /// lives in is decided by its path, via epicInstalled(_:in:). (The old Set-of-names
    /// showed Play in bottles that had no files.)
    var epicInstalls: [String: String] = [:]
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
        damagedBottles = (try? bottleStore.damaged()) ?? []
        needsOnboarding = engines.isEmpty
        rosettaInstalled = FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta/rosetta")
        // Drop a selection whose bottle is gone, not merely a nil one: a delete that threw after
        // the bottle had in fact been removed (the losing side of a race) left the selection
        // pinned to a name nothing could resolve.
        if let sel = selectedBottle, !bottles.contains(where: { $0.name == sel }) { selectedBottle = nil }
        if selectedBottle == nil { selectedBottle = bottles.first?.name }
        // Never trap on duplicate names (a Finder-duplicated bottle crashed the app at launch — issue #13).
        gamesByBottle = Dictionary(bottles.map { ($0.name, SteamLibrary.games(in: $0)) }, uniquingKeysWith: { a, _ in a })
        libraryPlays = libraryStore.load()
        rebuildLibrary()
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
        (try? engineStore.engine(bottle.settings.engineID)) ?? defaultEngine
    }

    /// The engine new bottles get and the sidebar shows: the one the bundled manifest names when
    /// it is installed, else the first installed. Without this, an engine update would leave
    /// two engines side by side and `engines.first` (alphabetical) would keep picking the old one.
    var defaultEngine: InstalledEngine? {
        EngineStore.defaultEngine(installed: engines, bundledID: Self.bundledManifestID)
    }

    static var bundledManifestID: String? {
        guard let url = bundledManifest, let m = try? EngineManifest.load(from: url) else { return nil }
        return m.id
    }

    /// The bundled manifest when it names an engine that is not installed yet while another one
    /// is: an engine update is available. New installs never see this (onboarding installs the
    /// bundled engine directly).
    var engineUpdate: EngineManifest? {
        guard !engines.isEmpty, let url = Self.bundledManifest,
              let m = try? EngineManifest.load(from: url),
              !engines.contains(where: { $0.id == m.id }) else { return nil }
        return m
    }

    /// Installs the bundled engine next to the current one, points every bottle at it, refreshes
    /// each bottle's Windows environment (wineboot), and removes the old engine directory.
    /// Licenses already accepted on the old engine carry over; the download cache makes an
    /// update cost only the components that actually changed.
    func updateEngine() {
        guard let manifest = engineUpdate, let old = defaultEngine else { return }
        let oldID = old.id
        let accepted = Set(engines.flatMap { $0.manifest.acceptedLicenses ?? [] })
        let title = String(format: L("Updating engine to %@"), manifest.id)
        runBusy(title, expected: L("usually a few minutes"),
                done: DoneState(title: L("Engine updated"), ctaTitle: nil, cta: nil)) { [self] in
            let fresh = try await engineStore.install(manifest, accepted: accepted) { name, received, total in
                Task { @MainActor in
                    let mb = { (b: Int64) in String(format: "%.0f", Double(b) / 1_048_576) }
                    if let total, total > 0 { self.stage = "Downloading \(name) — \(mb(received)) / \(mb(total)) MB" }
                    else { self.stage = "Downloading \(name) — \(mb(received)) MB" }
                }
            }
            await MainActor.run { self.appendLog("engine \(fresh.id) installed") }
            let refresh = EngineManifest.needsPrefixRefresh(from: old.manifest, to: fresh.manifest)
            for var bottle in try bottleStore.list() where bottle.settings.engineID != fresh.id {
                let runnerOld = WineRunner(paths: paths, engine: old, bottle: bottle)
                try? runnerOld.kill()
                try? await Task.sleep(for: .seconds(2))
                bottle.settings.engineID = fresh.id
                try bottle.save()
                guard refresh else {
                    await MainActor.run { self.appendLog("bottle '\(bottle.name)' moved to \(fresh.id) (same Wine, no prefix refresh needed)") }
                    continue
                }
                await MainActor.run { self.stage = String(format: L("Refreshing bottle '%@'"), bottle.name) }
                let runner = WineRunner(paths: paths, engine: fresh, bottle: bottle)
                let r = try await runner.wineboot()
                guard r.exitStatus == 0 else {
                    throw HighballError.processFailed(command: "wineboot -u", status: r.exitStatus, output: "see \(r.log.path)")
                }
                try await BottleStore.ensureWoW64(runner: runner, bottle: bottle, log: r.log)
                try? await runner.setGpuIdentity()
                try? await runner.setServiceTimeout()
                try? await runner.setKeyboardMapping(commandIsControl: bottle.settings.commandIsControl)
                await MainActor.run { self.appendLog("bottle '\(bottle.name)' moved to \(fresh.id)") }
            }
            if oldID != fresh.id { try? FileManager.default.removeItem(at: old.root) }
            await MainActor.run { self.appendLog("old engine \(oldID) removed") }
        }
    }

    /// What to put in front of the user when something throws. Interpolating an NSError dumps
    /// its domain, code, userInfo and a pointer address, with the one readable sentence buried
    /// in the middle — that is what a failed delete looked like in #38.
    static func message(for error: Error) -> String {
        if let known = error as? HighballError { return known.description }
        return (error as NSError).localizedDescription
    }

    /// Retries anything a previous purge could not remove. Free when `.trash` is empty, which
    /// is the normal case, so a leftover with a transient cause clears itself at the next launch.
    func sweepTrash() {
        let store = bottleStore
        Task.detached { store.sweepTrash() }
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
            } catch { showLog = false; errorIsPartialSuccess = false; errorMessage = Self.message(for: error) }
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
        catch { errorIsPartialSuccess = false; errorMessage = Self.message(for: error) }
    }

    func createBottle(name: String, recipeID: String?) {
        guard let engine = defaultEngine else { return }
        runBusy("Creating bottle '\(name)' — first boot takes about 90 seconds",
                done: DoneState(title: String(format: L("Bottle '%@' is ready"), name), ctaTitle: nil, cta: nil)) { [self] in
            let bottle = try await bottleStore.create(name: name, engine: engine)
            await MainActor.run { self.appendLog("bottle created") }
            if let recipeID, let recipe = Self.recipe(recipeID) {
                var runner = RecipeRunner(paths: paths, engine: engine, bottle: bottle)
                let notes = try await runner.apply(recipe) { line in Task { @MainActor in self.appendLog(line) } }
                for n in notes { await MainActor.run { self.appendLog("note: \(n)") } }
            }
            await MainActor.run { self.selectedBottle = name; self.pane = .bottles }
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
                await MainActor.run {
                    self.crashSuggestion = CrashSuggestion(program: pin.name, bottleName: bottle.name,
                                                           renderer: Renderer.suggestion(after: current),
                                                           logPath: result.log.path)
                }
            }
        }
    }

    func update(_ bottle: Bottle) {
        do { try bottleStore.update(bottle); refresh() } catch { errorIsPartialSuccess = false; errorMessage = Self.message(for: error) }
    }

    func deleteBottle(_ name: String) {
        // The row and its Delete item stay on screen for the whole operation, so without this a
        // second click started a second delete and the loser reported "missing" for a delete that
        // was in fact succeeding.
        guard !deletingBottles.contains(name) else { return }
        deletingBottles.insert(name)
        runBusy("Deleting '\(name)'", showLogSheet: false,
                cleanup: { [weak self] in self?.deletingBottles.remove(name) }) { [self] in
            let store = bottleStore
            let killer = killerFor(name)
            // Stop the bottle before anything moves: `wineserver -k` resolves the prefix by path,
            // so after the rename it exits 1 and leaves the server running. It is a synchronous
            // wineserver call that measured 2.3 s against a live server, so it belongs off the
            // main actor with the purge rather than in front of it, freezing the window.
            // A prefix can be tens of GB, and the old delete ran the whole walk on the main
            // actor — 985 ms for 20,841 entries, minutes for a big Steam bottle.
            let leftovers = try await Task.detached {
                killer?()
                return try store.delete(name)
            }.value
            await MainActor.run {
                if self.selectedBottle == name { self.selectedBottle = nil }
                guard let first = leftovers.first else { return }
                self.errorIsPartialSuccess = true
                self.errorMessage = """
                    '\(name)' is deleted and the name is free again. Some of its files are still \
                    on disk because macOS refused to remove them, starting at \(first.path) \
                    (\(first.reason)). Highball keeps them in .trash inside its data folder and \
                    tries again each time it starts.
                    """
            }
        }
    }

    /// Builds the stop-the-bottle work on the main actor (where the state lives) but hands it
    /// back as a closure, so the blocking `wineserver -k` runs wherever the caller wants it.
    private func killerFor(_ name: String) -> (@Sendable () -> Void)? {
        // A damaged bottle is not in `bottles`, and it is exactly the one whose wineserver most
        // needs stopping: nothing else has been able to touch it.
        let bottle = bottles.first { $0.name == name }
            ?? Bottle(url: paths.bottle(name),
                      settings: BottleSettings(name: name, engineID: engines.first?.id ?? ""))
        guard let engine = engine(for: bottle) else { return nil }
        let paths = paths
        return { try? WineRunner(paths: paths, engine: engine, bottle: bottle).kill() }
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
        let entry = gameDB[game.appid]
        let renderer = entry?.renderer
        // Per-game launch args ride the db (e.g. windowed for legacy CS:GO on macOS 26, #21).
        let extraArgs = entry?.effectiveLaunchArgs() ?? []
        runBusy("Running \(game.name)", showLogSheet: false) { [self] in
            let runner = WineRunner(paths: paths, engine: engine, bottle: bottle)
            let result = try await runner.start(steam, arguments: ["-silent", "-applaunch", String(game.appid)] + extraArgs, renderer: renderer) { line in
                Task { @MainActor in self.appendLog(line) }
            }
            if result.crashedEarly {
                let current = renderer ?? bottle.settings.renderer
                await MainActor.run {
                    self.crashSuggestion = CrashSuggestion(program: game.name, bottleName: bottle.name,
                                                           renderer: Renderer.suggestion(after: current),
                                                           logPath: result.log.path)
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
            // Repair is the escape hatch for a bottle whose 32-bit half never got built (#37).
            try await BottleStore.ensureWoW64(runner: runner, bottle: bottle, log: r.log)
            try? await runner.setGpuIdentity()
            try? await runner.setServiceTimeout()
            try? await runner.setKeyboardMapping(commandIsControl: bottle.settings.commandIsControl)
            await MainActor.run { self.appendLog("bottle repaired — Windows environment refreshed") }
        }
    }

    // MARK: Epic

    var epicStore: EpicStore { EpicStore(paths: paths) }

    func epicRefresh() {
        epicSignedIn = epicStore.isAuthenticated
        guard epicSignedIn else { epicOwned = []; epicInstalls = [:]; return }
        guard !epicFetchInFlight else { return }
        epicFetchInFlight = true
        epicLoading = epicOwned.isEmpty
        Task.detached { [store = epicStore] in
            let owned = (try? store.ownedGames()) ?? []
            let installed = (try? store.installedGames()) ?? []
            await MainActor.run { [weak self] in
                self?.epicOwned = owned.sorted { $0.app_title < $1.app_title }
                self?.epicInstalls = Dictionary(uniqueKeysWithValues:
                    installed.compactMap { g in g.install_path.map { (g.app_name, $0) } })
                self?.epicLoading = false
                self?.epicFetchInFlight = false
                self?.rebuildLibrary()   // Epic results arrive after refresh(); fold them in
            }
        }
    }

    /// Installed *in this bottle* — a game legendary installed into another bottle's
    /// drive_c is not playable here.
    func epicInstalled(_ appName: String, in bottle: Bottle) -> Bool {
        guard let path = epicInstalls[appName] else { return false }
        return EpicStore.isInstalled(path: path, inDriveC: bottle.driveC)
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

    // renderer nil = the bottle's own renderer (the old hardcoded .dxvk default ignored it).
    func epicPlay(_ game: EpicStore.Game, in bottle: Bottle, renderer: Renderer? = nil) {
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
                let current = renderer ?? bottle.settings.renderer
                await MainActor.run {
                    self.crashSuggestion = CrashSuggestion(program: game.app_title, bottleName: bottle.name,
                                                           renderer: Renderer.suggestion(after: current),
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
