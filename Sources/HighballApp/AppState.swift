import Foundation
import HighballKit
import Observation

@Observable @MainActor
final class AppState {
    var engines: [InstalledEngine] = []
    var bottles: [Bottle] = []
    var selectedBottle: String?

    // Long-running work
    var busy = false
    var busyTitle = ""
    var logLines: [String] = []
    var showLog = false

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

    let paths = HighballPaths()
    var engineStore: EngineStore { EngineStore(paths: paths) }
    var bottleStore: BottleStore { BottleStore(paths: paths) }

    func refresh() {
        engines = (try? engineStore.installedEngines()) ?? []
        bottles = (try? bottleStore.list()) ?? []
        needsOnboarding = engines.isEmpty
        rosettaInstalled = FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta/rosetta")
        if selectedBottle == nil { selectedBottle = bottles.first?.name }
    }

    func engine(for bottle: Bottle) -> InstalledEngine? {
        (try? engineStore.engine(bottle.settings.engineID)) ?? engines.first
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
    }

    private func runBusy(_ title: String, showLogSheet: Bool = true, _ work: @escaping () async throws -> Void) {
        busy = true; busyTitle = title; logLines = []; showLog = showLogSheet
        Task {
            do { try await work() } catch { errorMessage = "\(error)" }
            busy = false
            refresh()
        }
    }

    // MARK: Actions

    func installDefaultEngine(acceptGPTK: Bool) {
        guard let manifestURL = Self.bundledManifest else {
            errorMessage = "No engine manifest found. Reinstall Highball."; return
        }
        runBusy("Installing engine — about 500 MB of verified downloads") { [self] in
            let manifest = try EngineManifest.load(from: manifestURL)
            var accepted: Set<String> = []
            if acceptGPTK { accepted.insert("apple-gptk-license-2023-08-17") }
            _ = try await engineStore.install(manifest, accepted: accepted) { name, _, _ in
                Task { @MainActor in self.appendLog("downloaded \(name)") }
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
        runBusy("Creating bottle '\(name)' — first boot takes about 90 seconds") { [self] in
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
        runBusy("Installing \(recipe.title)") { [self] in
            var runner = RecipeRunner(paths: paths, engine: engine, bottle: bottle)
            let notes = try await runner.apply(recipe) { line in Task { @MainActor in self.appendLog(line) } }
            for n in notes { await MainActor.run { self.appendLog("note: \(n)") } }
        }
    }

    func launch(pin: Pin, in bottle: Bottle) {
        guard let engine = engine(for: bottle) else { return }
        runBusy("Running \(pin.name)", showLogSheet: false) { [self] in
            let runner = WineRunner(paths: paths, engine: engine, bottle: bottle)
            let result = try await runner.start(pin: pin) { line in Task { @MainActor in self.appendLog(line) } }
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

    func killBottle(_ bottle: Bottle) {
        guard let engine = engine(for: bottle) else { return }
        try? WineRunner(paths: paths, engine: engine, bottle: bottle).kill()
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
