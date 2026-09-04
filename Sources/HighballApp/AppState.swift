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
        /// No done row: a session or the Steam row took over from the busy operation.
        var silent = false
        static let handedOff = DoneState(title: "", ctaTitle: nil, cta: nil, silent: true)
    }
    // The activity strip (UX plan 0.5): what the busy operation can show beyond its title.
    struct Transfer: Equatable { var received: Int64; var total: Int64? }
    var busyProgress: Transfer?         // bytes of the current download, for the bar
    var transferRate: Double?           // measured bytes per second, never a prediction
    /// How a busy operation can be stopped, and what stopping does. A download stops cleanly
    /// (the partial file stays); a launch stops by ending the bottle's processes.
    enum BusyStop {
        case cancelTask(label: String)
        case killBottle(Bottle, label: String)
        /// A Windows step (installer, recipe) cannot stop cleanly: the bottle is ended and the
        /// repair path runs right after, and the button says so (UX plan §3.3).
        case killBottleThenRepair(Bottle, label: String)
        var label: String {
            switch self {
            case .cancelTask(let l), .killBottle(_, let l), .killBottleThenRepair(_, let l): return l
            }
        }
        var stoppedTitle: String {
            switch self {
            case .cancelTask: return L("Stopped. Nothing already downloaded is lost.")
            case .killBottle: return L("Stopped.")
            case .killBottleThenRepair: return L("Stopped. Repairing the bottle so nothing half-installed stays behind.")
            }
        }
        var bottleToRepair: Bottle? {
            if case .killBottleThenRepair(let b, _) = self { return b }
            return nil
        }
    }
    var busyStop: BusyStop?
    @ObservationIgnored private var busyTask: Task<Void, Never>?
    @ObservationIgnored private var transferSamples: [ActivityText.Sample] = []
    @ObservationIgnored private var stopRequested = false
    var requestCreateBottle = false     // engine-done CTA → ContentView opens the sheet

    // Onboarding
    var rosettaInstalled = true
    var needsOnboarding = false
    var showGPTKLicense = false
    var gptkLicenseText = ""

    // Crash follow-up
    var crashSuggestion: CrashSuggestion?
    struct CrashSuggestion {
        let program: String
        /// The bottle that was actually launched. The alert used to edit `selectedBottle`, which
        /// `launchGame` never sets — so accepting could rewrite an unrelated bottle, or none.
        let bottleName: String
        /// The renderer to offer next.
        let renderer: Renderer
        let logPath: String
        /// The renderer the program actually ran under, and how long it lived: the facts the
        /// alert can state as detected.
        var current: Renderer
        var seconds: Int
        /// Another installed engine to offer as the second way out, when there is one.
        var alternateEngine: InstalledEngine? = nil
    }

    /// The engine the crash alert offers next to the renderer suggestion, if another one is installed.
    func alternateEngine(for bottle: Bottle) -> InstalledEngine? {
        EngineStore.alternateEngine(for: bottle.settings.engineID, installed: engines, defaultID: defaultEngine?.id)
    }

    var errorMessage: String?
    /// The recovery the error alert shows (headline, meaning, one button) and what its button
    /// runs. Set together with errorMessage, which keeps the raw text for the details view.
    var errorRecovery: Recovery?
    var errorRetry: (() -> Void)?
    var errorBottle: Bottle?
    var showErrorDetails = false

    /// The one place failures are put in front of the user: the recovery sentences on the alert,
    /// the raw description behind Details, and the retry the button runs when the recovery
    /// says so. `bottle` lets a Repair recovery know what to repair.
    func fail(_ error: Error, retry: (() -> Void)? = nil, bottle: Bottle? = nil) {
        errorIsPartialSuccess = false
        errorRecovery = Recovery.describe(error)
        errorRetry = retry
        errorBottle = bottle
        errorMessage = Self.message(for: error)
        errorDetailsText = errorMessage ?? ""
    }
    /// The raw description of the last failure, for the Details sheet.
    var errorDetailsText = ""
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
        catch { fail(error) }
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

    private var prunedLogsThisRun = false

    /// Re-reads the launchers' install records when they change (a download starting or
    /// finishing in an open Steam window), so the library follows without a relaunch.
    @ObservationIgnored private var installWatcher: DirectoryWatcher?

    /// The directories whose entries change when a game is installed or removed: Steam's
    /// steamapps (appmanifest files) and the folder Epic installs land in.
    private func installDirectories(of bottle: Bottle) -> [URL] {
        var dirs = [bottle.driveC.appending(path: "Games")]
        if let root = SteamLibrary.steamRoot(of: bottle) { dirs.append(root.appending(path: "steamapps")) }
        return dirs
    }

    /// The cheap part of `refresh`: installed games only. Runs on every install-record change,
    /// so it must not spawn per call beyond legendary's install list, and never touches the
    /// directories it watches.
    func refreshInstalledGames() {
        let games = Dictionary(bottles.map { ($0.name, SteamLibrary.games(in: $0)) }, uniquingKeysWith: { a, _ in a })
        if games != gamesByBottle { gamesByBottle = games; rebuildLibrary() }
        guard epicSignedIn, !epicFetchInFlight else { return }
        Task.detached { [store = epicStore] in
            let installed = (try? store.installedGames()) ?? []
            await MainActor.run { [weak self] in
                let installs = Dictionary(uniqueKeysWithValues: installed.compactMap { g in g.install_path.map { (g.app_name, $0) } })
                guard let self, installs != self.epicInstalls else { return }
                self.epicInstalls = installs
                self.rebuildLibrary()
            }
        }
    }

    func refresh() {
        if !prunedLogsThisRun {
            prunedLogsThisRun = true
            let n = LogPruner.prune(directory: paths.logs)
            if n > 0 { appendLog("pruned \(n) old log file(s)") }
        }
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
        if installWatcher == nil { installWatcher = DirectoryWatcher { [weak self] in self?.refreshInstalledGames() } }
        installWatcher?.watch(bottles.flatMap(installDirectories))
        startSteamClientWatch()
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
    /// it is installed, else the newest installed (numeric-aware id order). Without this, an
    /// engine update would leave two engines side by side and `engines.first` would keep
    /// picking the old one.
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

    /// Installs the bundled engine next to the current one. Bottles move to it only when the Wine
    /// build is unchanged (a component-only update, like r1's MoltenVK): nothing to re-run, nothing
    /// that can regress. When the Wine build differs, every bottle stays on its engine and the
    /// old engine stays installed as long as any bottle runs on it; the owner switches a bottle
    /// from its settings, one at a time, and can switch back. New bottles get the new engine.
    /// Licenses already accepted on the old engine carry over; the download cache makes an
    /// update cost only the components that actually changed.
    func updateEngine() {
        guard let manifest = engineUpdate, let old = defaultEngine else { return }
        let oldID = old.id
        let accepted = Set(engines.flatMap { $0.manifest.acceptedLicenses ?? [] })
        let title = String(format: L("Updating engine to %@"), manifest.id)
        runBusy(title, expected: L("usually a few minutes"),
                done: DoneState(title: L("Engine updated"), ctaTitle: nil, cta: nil),
                stop: .cancelTask(label: L("Stop"))) { [self] in
            let fresh = try await engineStore.install(manifest, accepted: accepted) { name, received, total in
                Task { @MainActor in self.reportDownload(name, received: received, total: total) }
            }
            await MainActor.run { self.appendLog("engine \(fresh.id) installed") }
            let sameWine = !EngineManifest.needsPrefixRefresh(from: old.manifest, to: fresh.manifest)
            for var bottle in try bottleStore.list() where bottle.settings.engineID != fresh.id {
                guard sameWine else {
                    await MainActor.run { self.appendLog("bottle '\(bottle.name)' stays on \(bottle.settings.engineID): the new engine has a different Wine build; switch it from the bottle's settings when you want") }
                    continue
                }
                let runnerOld = WineRunner(paths: paths, engine: old, bottle: bottle)
                try? runnerOld.kill()
                try? await Task.sleep(for: .seconds(2))
                bottle.settings.engineID = fresh.id
                try bottle.save()
                await MainActor.run { self.appendLog("bottle '\(bottle.name)' moved to \(fresh.id) (same Wine, no prefix refresh needed)") }
            }
            let referenced = Set(try bottleStore.list().map(\.settings.engineID))
            let installed = try engineStore.installedEngines()
            let offered = Set(Self.knownManifests.map(\.id))
            for stale in EngineStore.unreferencedEngines(installed: installed, referencedIDs: referenced, defaultID: fresh.id, keep: offered) {
                try? FileManager.default.removeItem(at: stale.root)
                await MainActor.run { self.appendLog("old engine \(stale.id) removed (no bottle uses it)") }
            }
            if referenced.contains(oldID) {
                await MainActor.run { self.appendLog("engine \(oldID) kept: bottles still run on it") }
            }
        }
    }

    /// Moves one bottle to another installed engine, on its owner's request. Re-runs the Windows
    /// first boot only when the Wine build differs (the same rule as an engine update), then the
    /// per-bottle setup that boot resets. Switching back is the same call the other way.
    func moveBottle(_ bottle: Bottle, to target: InstalledEngine) {
        guard bottle.settings.engineID != target.id, !busy else { return }
        let title = String(format: L("Moving '%@' to %@"), bottle.name, target.id)
        runBusy(title, expected: L("a minute or two when the Windows setup re-runs"),
                done: DoneState(title: L("Engine switched"), ctaTitle: nil, cta: nil)) { [self] in
            try await performMove(bottle, to: target)
        }
    }

    /// The move itself, shared by the two entry points and run inside their single busy sheet.
    /// The bottle is re-read from disk right before the write: the caller's copy may be minutes
    /// old (an engine download ran in between) and saving it would revert edits made meanwhile.
    /// The source engine is resolved strictly: when its directory is gone, nothing is known
    /// about the Wine that built the prefix, so the prefix is refreshed.
    private func performMove(_ stale: Bottle, to target: InstalledEngine) async throws {
        guard var bottle = try? bottleStore.get(stale.name) else { throw HighballError.invalid("bottle '\(stale.name)' no longer exists") }
        guard bottle.settings.engineID != target.id else { return }
        let source = try? engineStore.engine(bottle.settings.engineID)
        if let source {
            let runnerOld = WineRunner(paths: paths, engine: source, bottle: bottle)
            try? runnerOld.kill()
            try? await Task.sleep(for: .seconds(2))
        }
        bottle.settings.engineID = target.id
        try bottle.save()
        guard EngineManifest.needsPrefixRefresh(from: source?.manifest, to: target.manifest) else {
            await MainActor.run { self.appendLog("bottle '\(bottle.name)' moved to \(target.id) (same Wine, no prefix refresh needed)") }
            return
        }
        await MainActor.run { self.stage = String(format: L("Refreshing bottle '%@'"), bottle.name) }
        let runner = WineRunner(paths: paths, engine: target, bottle: bottle)
        try await BottleStore.refreshPrefix(runner: runner, bottle: bottle)
        await MainActor.run { self.appendLog("bottle '\(bottle.name)' moved to \(target.id)") }
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

    /// Runs one long operation on the activity strip. The strip is the surface: the log sheet
    /// opens only from its Details button (or `showLogSheet` for the rare case that needs it).
    private func runBusy(_ title: String, expected: String? = nil, showLogSheet: Bool = false,
                         done: DoneState? = nil, stop: BusyStop? = nil, cleanup: (() -> Void)? = nil,
                         _ work: @escaping () async throws -> Void) {
        // One busy operation at a time: a second call would reset the sheet's state under the
        // first and end it early when the second finishes (found in review, 2026-09-04).
        guard !busy else { return }
        busy = true; busyTitle = title; stage = ""; stageHint = ""; logLines = []; showLog = showLogSheet
        busyStartedAt = Date(); busyExpected = expected; lastOutputAt = nil; doneState = nil
        busyStop = stop; busyProgress = nil; transferRate = nil; transferSamples = []; stopRequested = false
        busyTask = Task {
            // On failure, dismiss the log sheet ourselves: SwiftUI defers the error alert
            // until the sheet closes, so a stuck sheet showed "Done" over a failed install
            // and hid the alert until the user clicked Close (issues #27/#28).
            do {
                try await work()
                let d = done ?? DoneState(title: L("Done"), ctaTitle: nil, cta: nil)
                doneState = d.silent ? nil : d
            } catch {
                showLog = false
                if stopRequested || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    // The user stopped it: a result, not a failure, and no alert.
                    doneState = DoneState(title: stop?.stoppedTitle ?? L("Stopped."), ctaTitle: nil, cta: nil)
                    appendLog("stopped by the user")
                } else {
                    // A retry is the same operation with the same closure; the sheet's own state
                    // resets when runBusy starts again.
                    fail(error, retry: { [weak self] in self?.runBusy(title, expected: expected, showLogSheet: showLogSheet, done: done, stop: stop, cleanup: cleanup, work) })
                }
            }
            cleanup?()
            let repairAfterStop = stopRequested ? stop?.bottleToRepair : nil
            busy = false; busyStop = nil; busyProgress = nil; transferRate = nil; busyTask = nil
            refresh()
            if let bottle = repairAfterStop, let fresh = bottles.first(where: { $0.name == bottle.name }) {
                repairBottle(fresh)
            }
        }
    }

    /// The strip's Stop button. What it does depends on the operation (see `BusyStop`); the
    /// operation's own error path then reads as "stopped", never as a failure.
    func stopBusy() {
        guard busy, let stop = busyStop else { return }
        stopRequested = true
        switch stop {
        case .cancelTask:
            busyTask?.cancel()
        case .killBottle(let bottle, _), .killBottleThenRepair(let bottle, _):
            if let engine = engine(for: bottle) { try? WineRunner(paths: paths, engine: engine, bottle: bottle).kill() }
            busyTask?.cancel()
        }
    }

    /// Feeds the strip from a component download: a plain stage, moving bytes, a measured rate.
    private func reportDownload(_ name: String, received: Int64, total: Int64?) {
        let total = (total ?? 0) > 0 ? total : nil
        if let last = transferSamples.last, received < last.bytes { transferSamples = [] }   // next component
        transferSamples.append(.init(bytes: received, at: Date()))
        if transferSamples.count > 40 { transferSamples.removeFirst(transferSamples.count - 40) }
        transferRate = ActivityText.rate(transferSamples)
        busyProgress = Transfer(received: received, total: total)
        stage = String(format: L("Downloading %@"), name)
        if let total, received >= total {
            appendLog("downloaded \(name) — verifying and unpacking…")
            busyProgress = nil; transferRate = nil; transferSamples = []
        }
    }

    // MARK: Actions

    func installDefaultEngine(acceptGPTK: Bool) {
        guard let manifestURL = Self.bundledManifest else {
            errorMessage = "No engine manifest found. Reinstall Highball."; return
        }
        runBusy(L("Downloading the Windows engine"),
                expected: L("usually 5–15 minutes"),
                done: DoneState(title: L("Engine ready"), ctaTitle: L("Create your first bottle"),
                                cta: { [weak self] in self?.requestCreateBottle = true }),
                stop: .cancelTask(label: L("Stop"))) { [self] in
            let manifest = try EngineManifest.load(from: manifestURL)
            var accepted: Set<String> = []
            if acceptGPTK { accepted.insert("apple-gptk-license-2023-08-17") }
            _ = try await engineStore.install(manifest, accepted: accepted) { name, received, total in
                Task { @MainActor in self.reportDownload(name, received: received, total: total) }
            }
            await MainActor.run { self.appendLog("engine installed") }
        }
    }

    func acceptGPTK(engine: InstalledEngine) {
        do { _ = try engineStore.accept(license: "apple-gptk-license-2023-08-17", engine: engine); refresh() }
        catch { fail(error) }
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
                done: DoneState(title: String(format: L("%@ installed"), recipe.title), ctaTitle: nil, cta: nil),
                stop: .killBottleThenRepair(bottle, label: L("Stop and repair"))) { [self] in
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

    // MARK: Play from outside the app (UX plan §3.9)

    /// A play request that arrived without this install's token: confirm before running.
    var pendingPlayLink: LibraryItem?

    func open(url: URL) {
        guard let request = PlayLink.parse(url) else { return }
        refresh()
        guard let item = libraryItems.first(where: { $0.id == request.target.libraryID }) else {
            fail(HighballError.failed("That game is not in this Highball's library."))
            return
        }
        if request.token == PlayLink.token(in: paths) { play(item) } else { pendingPlayLink = item }
    }

    /// Writes the game's Mac app into ~/Applications/Highball and reveals it.
    func makeMacApp(for item: LibraryItem) {
        guard let target = PlayLink.target(for: item) else { return }
        let url = PlayLink.url(for: target, token: PlayLink.token(in: paths))
        let cover = coverStore.coverURL(for: item.id) ?? item.artworkTall
        do {
            let app = try MacAppStub.write(title: item.title, libraryID: item.id, url: url, cover: cover)
            appendLog("made \(app.lastPathComponent) in ~/Applications/Highball")
            NSWorkspace.shared.activateFileViewerSelecting([app])
        } catch { fail(error) }
    }

    // MARK: Steam clients (UX plan §3.3, issue #33)

    /// Bottles with a Steam client running right now. A client left behind by a game launch is
    /// invisible otherwise, and a new steam.exe only forwards to it (#33); the strip shows it
    /// with Show and Quit.
    var steamClients: Set<String> = []
    @ObservationIgnored private var steamClientWatch: Task<Void, Never>?

    private func startSteamClientWatch() {
        guard steamClientWatch == nil else { return }
        steamClientWatch = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let bottles = await MainActor.run { [self] in self.bottles }
                let running = Set(bottles.filter { WineRunner.steamIsRunning(inPrefix: $0.url) }.map(\.name))
                await MainActor.run { [self] in if self.steamClients != running { self.steamClients = running } }
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    /// Brings the bottle's Steam window forward (the running client is asked to show it; with
    /// none running this is a normal Steam start).
    func showSteam(in bottle: Bottle) {
        let steam = bottle.driveC.appending(path: "Program Files (x86)/Steam/steam.exe")
        launch(pin: Pin(name: "Steam", path: Pin.storagePath(for: steam, driveC: bottle.driveC)), in: bottle)
    }

    /// Whether a game the app knows about runs in the bottle: Quit on the Steam row hides then.
    func sessionRuns(in bottle: Bottle) -> Bool { runningSessions.contains { $0.bottleName == bottle.name } }

    // MARK: Sessions (UX plan 0.6)

    /// Games running right now, from their processes. The library shows them and offers Stop;
    /// nothing here blocks the app while a game runs.
    var runningSessions: [GameSession] = []
    /// The last session that ended, for the post-play prompt to come.
    var lastEndedSession: SessionRecord?
    /// A finished session worth asking about: at least a minute of play (a shorter one is a
    /// crash, and the early-exit alert already covers that). The strip asks once; Not now clears it.
    var postPlay: SessionRecord?

    /// Opens highball-db's report form prefilled from the session. The rating is theirs to give.
    func reportPlay(_ record: SessionRecord) {
        let engine = bottles.first { $0.name == record.bottle }?.settings.engineID ?? "?"
        NSWorkspace.shared.open(PlayReport.url(title: record.title, appid: record.appid, renderer: record.renderer,
                                               chip: Machine.chip(), macos: Machine.macOSVersion(), engine: engine,
                                               minutes: record.seconds / 60))
        postPlay = nil
    }
    private var sessionWatchers: [UUID: Task<Void, Never>] = [:]

    func session(forAppID appid: Int) -> GameSession? { runningSessions.first { $0.appid == appid } }

    private func beginSession(_ session: GameSession) {
        runningSessions.append(session)
        appendLog("\(session.title) is running")
        sessionWatchers[session.id] = Task { [weak self] in
            // A game that is gone for two consecutive checks has ended; one miss can be a
            // process table read racing a restart (some games relaunch themselves once).
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if SessionWatch.isAlive(markers: session.markers, ps: SessionWatch.currentProcessList()) { misses = 0; continue }
                misses += 1
                if misses >= 2 { break }
            }
            await MainActor.run { self?.endSession(session, reason: "ended") }
        }
    }

    private func endSession(_ session: GameSession, reason: String) {
        guard runningSessions.contains(session) else { return }
        runningSessions.removeAll { $0.id == session.id }
        sessionWatchers[session.id]?.cancel()
        sessionWatchers[session.id] = nil
        let record = SessionRecord(title: session.title, bottle: session.bottleName, appid: session.appid,
                                   started: session.started, ended: Date(), reason: reason, renderer: session.renderer)
        SessionWatch.append(record, to: paths.logs)
        lastEndedSession = record
        if record.seconds >= 60 { postPlay = record }
        appendLog("\(session.title) \(reason) after \(record.seconds / 60) min")
    }

    /// Ends the game's own processes and leaves Steam and the server running, so the next
    /// Play needs no cold start.
    func stopSession(_ session: GameSession) {
        guard let bottle = bottles.first(where: { $0.name == session.bottleName }) else { return }
        let pids = SessionWatch.pids(ofPrefix: bottle.url, markers: session.markers)
        _ = ProcessTable.terminate(pids)
        endSession(session, reason: "stopped")
    }

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
        let cef = bottle.driveC.appending(path: "Program Files (x86)/Steam/bin/cef")
        runBusy(steamFirstBoot ? L("Starting Steam for the first time — it downloads and unpacks its own client") : "Starting \(pin.name)",
                expected: steamFirstBoot ? L("usually 15–25 minutes; long quiet stretches are normal") : nil,
                done: .handedOff,
                stop: .killBottle(bottle, label: L("Stop")),
                cleanup: { [weak self] in self?.launchingPins.remove(pin.id) }) { [self] in
            let runner = WineRunner(paths: paths, engine: engine, bottle: bottle)
            var extra = [String: String]()
            // A Steam client left running by a game launch answers a new steam.exe by swallowing
            // it (issue #33). Ask it to show its window instead, and leave the wineserver alone:
            // a game may still be running under it.
            await BottleStore.preflight(runner: runner, bottle: bottle) { line in Task { @MainActor in self.appendLog(line) } }
            if isSteamUI(pin), let shown = try await runner.showRunningSteam(onOutput: { line in Task { @MainActor in self.appendLog(line) } }) {
                await MainActor.run { self.appendLog("Steam was already running; asked it to show its window") }
                if shown.crashedEarly { /* the forward exits at once by design; not a crash */ }
                return
            }
            if isSteamUI(pin), bottle.settings.sync != SyncMode.none {
                try? runner.kill()                      // restart the wineserver so sync=none takes effect
                try? await Task.sleep(for: .seconds(2))
                extra = ["WINEMSYNC": "0", "WINEESYNC": "0"]
            }
            // The process outlives "starting": busy covers the start only, then the Steam row
            // (a client) or a session (anything else) carries it, and the app stays free (0.6).
            let launch = Task<LaunchResult, Error> {
                if isSteamUI(pin) {
                    let (r, resumed) = try await runner.startResumingKnownSteamCrash(pin: pin, extraEnvironment: extra) { line in
                        Task { @MainActor in
                            self.appendLog(line)
                            if line.contains("relaunching so it resumes") {
                                self.stage = L("Steam crashed at a known spot — relaunching to resume the update")
                            }
                        }
                    }
                    if resumed { await MainActor.run { self.appendLog("resumed after the known crash") } }
                    return r
                }
                return try await runner.start(pin: pin, extraEnvironment: extra) { line in Task { @MainActor in self.appendLog(line) } }
            }
            let markers = SessionWatch.markers(executable: bottle.resolve(windowsPath: pin.path))
            var waited = 0
            while true {
                if let result = await Self.finished(launch) {
                    if result.crashedEarly {
                        let current = pin.renderer ?? bottle.settings.renderer
                        await MainActor.run {
                            self.crashSuggestion = CrashSuggestion(program: pin.name, bottleName: bottle.name,
                                                                   renderer: Renderer.suggestion(after: current),
                                                                   logPath: result.log.path, current: current, seconds: Int(result.duration),
                                                                   alternateEngine: self.alternateEngine(for: bottle))
                        }
                    }
                    return
                }
                if isSteamUI(pin) {
                    // A first boot is "started" once the client is unpacked and running; the
                    // Steam row shows it from then on.
                    if runner.steamIsRunning(), FileManager.default.fileExists(atPath: cef.path) { return }
                } else if waited >= 6, SessionWatch.isAlive(markers: markers, ps: SessionWatch.currentProcessList()) {
                    await MainActor.run {
                        self.beginSession(GameSession(title: pin.name, bottleName: bottle.name, appid: nil, markers: markers,
                                                      renderer: (pin.renderer ?? bottle.settings.renderer).rawValue))
                    }
                    return
                }
                if !isSteamUI(pin), waited >= 360 {
                    throw HighballError.failed("\(pin.name) never started: no process of its own appeared in six minutes. Its log is in Details.")
                }
                try await Task.sleep(for: .seconds(2)); waited += 2
            }
        }
    }

    func update(_ bottle: Bottle) {
        do { try bottleStore.update(bottle); refresh() } catch { fail(error, bottle: bottle) }
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
        if let running = session(forAppID: game.appid) {
            fail(HighballError.failed("\(running.title) is already running."))
            return
        }
        let steam = bottle.driveC.appending(path: "Program Files (x86)/Steam/steam.exe")
        let entry = gameDB[game.appid]
        let renderer = entry?.effectiveRenderer()
        // Per-game launch args ride the db (e.g. windowed for legacy CS:GO on macOS 26, #21).
        let extraArgs = entry?.effectiveLaunchArgs() ?? []
        let markers = SessionWatch.markers(installdir: game.installdir)
        // The busy sheet covers the start only: Steam's client outlives the game and its launch
        // call says nothing about it, so the game's own processes decide when "starting" ends
        // and a session begins, and the app is free while the game runs (UX plan 0.6).
        runBusy("Starting \(game.name)", expected: L("a cold Steam client can take a couple of minutes"),
                done: .handedOff,
                stop: .killBottle(bottle, label: L("Stop"))) { [self] in
            let runner = WineRunner(paths: paths, engine: engine, bottle: bottle)
            // A running client would serve the launch with its own environment; when that is
            // not the game's, cold-start first (never under a running game, see SteamRestart).
            if let why = try await runner.restartSteamIfMismatched(renderer: renderer) {
                await MainActor.run { self.appendLog("Restarting Steam before \(game.name): \(why).") }
            }
            let launch = Task {
                try await runner.start(steam, arguments: ["-silent", "-applaunch", String(game.appid)] + extraArgs, renderer: renderer) { line in
                    Task { @MainActor in self.appendLog(line) }
                }
            }
            var waited = 0
            while waited < 360 {
                if SessionWatch.isAlive(markers: markers, ps: SessionWatch.currentProcessList()) {
                    await MainActor.run {
                        self.beginSession(GameSession(title: game.name, bottleName: bottle.name, appid: game.appid, markers: markers,
                                                      renderer: (renderer ?? bottle.settings.renderer).rawValue))
                    }
                    return
                }
                // The launch call returning early means the client died before handing off.
                if launch.isCancelled { break }
                if let result = await Self.finished(launch), result.crashedEarly {
                    let current = renderer ?? bottle.settings.renderer
                    await MainActor.run {
                        self.crashSuggestion = CrashSuggestion(program: game.name, bottleName: bottle.name,
                                                               renderer: Renderer.suggestion(after: current),
                                                               logPath: result.log.path, current: current, seconds: Int(result.duration),
                                                               alternateEngine: self.alternateEngine(for: bottle))
                    }
                    return
                }
                try await Task.sleep(for: .seconds(2)); waited += 2
            }
            throw HighballError.failed("\(game.name) never started. Steam accepted the launch but no game process appeared in six minutes; its log is in the bottle's Steam log.")
        }
    }

    /// The launch result when the task has already finished, nil while it still runs.
    private static func finished(_ task: Task<LaunchResult, Error>) async -> LaunchResult? {
        await withTaskGroup(of: LaunchResult?.self) { group in
            group.addTask { try? await task.value }
            group.addTask { try? await Task.sleep(for: .milliseconds(50)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Handle an .exe/.msi dropped on a bottle: run it (installer) inside the bottle.
    func runDropped(_ url: URL, in bottle: Bottle, andPin: Bool) {
        guard let engine = engine(for: bottle) else { return }
        runBusy("Running \(url.lastPathComponent)", stop: .killBottleThenRepair(bottle, label: L("Stop and repair"))) { [self] in
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
            // Repair is the escape hatch for a bottle whose 32-bit half never got built (#37);
            // refreshPrefix carries that check.
            try await BottleStore.refreshPrefix(runner: runner, bottle: bottle)
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
        runBusy("Starting \(game.app_title)", done: .handedOff, stop: .killBottle(bottle, label: L("Stop"))) { [self] in
            let store = epicStore
            // Fresh single-use token, fetched off the main thread right before launch.
            let info = try await Task.detached { try store.launchInfo(game.app_name) }.value
            let runner = WineRunner(paths: paths, engine: engine, bottle: bottle)
            let launch = Task {
                try await runner.start(info.executable, arguments: info.arguments,
                                       renderer: renderer, extraEnvironment: info.environment,
                                       workingDirectory: info.workingDirectory) { line in
                    Task { @MainActor in self.appendLog(line) }
                }
            }
            let markers = SessionWatch.markers(executable: info.executable)
            var waited = 0
            while waited < 360 {
                if let result = await Self.finished(launch) {
                    if result.crashedEarly {
                        let current = renderer ?? bottle.settings.renderer
                        await MainActor.run {
                            self.crashSuggestion = CrashSuggestion(program: game.app_title, bottleName: bottle.name,
                                                                   renderer: Renderer.suggestion(after: current),
                                                                   logPath: result.log.path, current: current, seconds: Int(result.duration),
                                                                   alternateEngine: self.alternateEngine(for: bottle))
                        }
                    }
                    return
                }
                if waited >= 6, SessionWatch.isAlive(markers: markers, ps: SessionWatch.currentProcessList()) {
                    await MainActor.run {
                        self.beginSession(GameSession(title: game.app_title, bottleName: bottle.name, appid: nil, markers: markers,
                                                      renderer: (renderer ?? bottle.settings.renderer).rawValue))
                    }
                    return
                }
                try await Task.sleep(for: .seconds(2)); waited += 2
            }
            throw HighballError.failed("\(game.app_title) never started: no process of its own appeared in six minutes. Its log is in Details.")
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

    /// Every engine manifest the app ships: the default one plus `engines/*.json` (previous
    /// engines kept for rollback, candidates offered in Advanced). A bottle can move to any of
    /// them; one that is not installed downloads first.
    static var knownManifests: [EngineManifest] {
        var urls: [URL] = []
        if let m = bundledManifest { urls.append(m) }
        if let dir = Bundle.main.resourceURL?.appending(path: "engines"),
           let more = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            urls += more.filter { $0.pathExtension == "json" }
        } else if let dir = repoRoot?.appending(path: "spike/engines"),
                  let more = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            urls += more.filter { $0.pathExtension == "json" }
        }
        var seen = Set<String>()
        return urls.compactMap { try? EngineManifest.load(from: $0) }.filter { seen.insert($0.id).inserted }
    }

    /// Installed-marker results per bottle, keyed by system.reg's modification time so the
    /// registry text (12 MB on a busy bottle) is read once per change, not on every render.
    private var installedTweaksCache: [String: (regModified: Date, ids: Set<String>)] = [:]
    func tweakIsInstalled(_ recipe: HighballKit.Recipe, in bottle: Bottle) -> Bool {
        let reg = bottle.url.appending(path: "system.reg")
        let modified = (try? FileManager.default.attributesOfItem(atPath: reg.path)[.modificationDate] as? Date) ?? .distantPast
        if let hit = installedTweaksCache[bottle.name], hit.regModified == modified { return hit.ids.contains(recipe.id) }
        let ids = Set(Self.tweakRecipes().filter { $0.isInstalled(in: bottle) }.map(\.id))
        installedTweaksCache[bottle.name] = (modified, ids)
        return ids.contains(recipe.id)
    }

    /// What the bottle's Engine picker lists: installed engines, then known ones to download.
    func offeredEngines(for bottle: Bottle) -> [EngineStore.OfferedEngine] {
        EngineStore.offeredEngines(installed: engines, known: Self.knownManifests, current: bottle.settings.engineID)
    }

    /// Moves a bottle to an engine by id, installing it first when it is only known from a
    /// bundled manifest. Licenses accepted on any installed engine carry over.
    func moveBottle(_ bottle: Bottle, toEngineID id: String) {
        guard !busy else { return }
        if let installed = engines.first(where: { $0.id == id }) { moveBottle(bottle, to: installed); return }
        guard let manifest = Self.knownManifests.first(where: { $0.id == id }) else { return }
        let accepted = Set(engines.flatMap { $0.manifest.acceptedLicenses ?? [] })
        let title = String(format: L("Downloading engine %@"), manifest.id)
        runBusy(title, expected: L("usually a few minutes"),
                done: DoneState(title: L("Engine switched"), ctaTitle: nil, cta: nil),
                stop: .cancelTask(label: L("Stop"))) { [self] in
            let fresh = try await engineStore.install(manifest, accepted: accepted) { name, received, total in
                Task { @MainActor in self.reportDownload(name, received: received, total: total) }
            }
            await MainActor.run { self.appendLog("engine \(fresh.id) installed"); self.refresh() }
            try await performMove(bottle, to: fresh)
        }
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
