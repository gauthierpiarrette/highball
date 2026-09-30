import AppKit
import HighballKit
import SwiftUI

extension AppState {
    /// Stable identity lets a new request navigate once. Leaving the page never dismisses it.
    var decisionID: String? {
        if errorMessage != nil { return "error:\(errorMessage ?? "")" }
        if pendingQuit { return "quit" }
        if rosettaMissing { return "rosetta" }
        if pendingPlayLink != nil { return "play-link" }
        if pendingEnvironmentDeletion != nil { return "delete:\(pendingEnvironmentDeletion ?? "")" }
        if pendingRun != nil { return "run:\(pendingRun?.path ?? "")" }
        if pendingD3DMetal != nil { return "directx" }
        if pendingEngine != nil { return "engine" }
        if pendingUpdate != nil { return "update" }
        if pendingUninstall != nil { return "uninstall" }
        if rendererTrial != nil { return "renderer" }
        if modesetTrial != nil { return "display" }
        if pendingHome != nil { return "storage" }
        if crashSuggestion != nil { return "crash" }
        return nil
    }
}

/// Confirmations are ordinary pages in the detail column; the sidebar remains usable.
struct DecisionPage<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsHeading(title: title, subtitle: message)
                HBGlassGroup {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { actions() }
                        VStack(alignment: .leading, spacing: 12) { actions() }
                    }
                }.buttonStyle(HBActionStyle())
            }.padding(36).frame(maxWidth: 800, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AppDecisions: View {
    @Environment(AppState.self) private var state
    @ViewBuilder var body: some View {
        if state.errorMessage != nil { errorPage }
        else if state.pendingQuit { quitPage }
        else if state.rosettaMissing {
            DecisionPage(title: L("Rosetta is not working on this Mac"), message: L("Highball's Wine engine needs Rosetta, Apple's translation layer. Highball can install it now.")) {
                Button(L("Install Rosetta")) { state.rosettaMissing = false; state.installRosettaNow() }.buttonStyle(HBActionStyle(primary: true)).disabled(state.busy)
                Button(L("Not now")) { state.rosettaMissing = false }
            }
        } else if let item = state.pendingPlayLink {
            DecisionPage(title: String(format: L("Open %@ in Highball?"), item.title), message: L("This link did not come from one of your Highball apps, so it asks first.")) {
                Button(L("Play")) { state.pendingPlayLink = nil; state.play(item) }.buttonStyle(HBActionStyle(primary: true)).disabled(state.busy)
                Button(L("Cancel")) { state.pendingPlayLink = nil }
            }
        } else if let name = state.pendingEnvironmentDeletion {
            DecisionPage(title: String(format: L("Delete %@?"), name), message: L("This removes the environment's Windows drive, everything installed in it, and any game saves kept inside it.")) {
                Button(L("Delete environment"), role: .destructive) { state.pendingEnvironmentDeletion = nil; state.deleteBottle(name) }.disabled(state.busy)
                Button(L("Cancel")) { state.pendingEnvironmentDeletion = nil }
            }
        } else if let url = state.pendingRun { runPage(url) }
        else if state.pendingD3DMetal != nil { directXPage }
        else if state.pendingEngine != nil { enginePage }
        else if state.pendingUpdate != nil { updatePage }
        else if let pending = state.pendingUninstall {
            DecisionPage(title: String(format: L("Remove %@?"), pending.item.title), message: Uninstall.confirmation(route: pending.route, sizeOnDisk: pending.item.sizeOnDisk)) {
                if Uninstall.isActionable(pending.route) { Button(L("Remove"), role: .destructive) { state.uninstallConfirmed() }.disabled(state.busy) }
                Button(L("Cancel")) { state.pendingUninstall = nil }
            }
        } else if state.rendererTrial != nil { rendererPage }
        else if let trial = state.modesetTrial {
            DecisionPage(title: String(format: L("Scale %@ to the screen next time?"), trial.title), message: L("Highball can have Wine report fullscreen size changes as done and scale the game to the screen. This changes only this game; undo it under Advanced on its page.")) {
                Button(L("Scale it to the screen")) { state.acceptModesetTrial() }.buttonStyle(HBActionStyle(primary: true))
                Button(L("Not now")) { state.modesetTrial = nil }
            }
        } else if let target = state.pendingHome {
            DecisionPage(title: String(format: L("Move Highball's data to %@?"), target.lastPathComponent), message: homeMessage(target)) {
                Button(L("Move now")) { state.moveHome(to: target) }.buttonStyle(HBActionStyle(primary: true)).disabled(state.busy)
                Button(L("Cancel")) { state.pendingHome = nil }
            }
        } else if state.crashSuggestion != nil { crashPage }
        else { ContentUnavailableView(L("You're all set"), systemImage: "checkmark.circle") }
    }

    private func runPage(_ url: URL) -> some View {
        let target = state.bottles.first { $0.name == state.pendingRunBottle } ?? state.defaultBottle
        return DecisionPage(title: String(format: L("Run %@?"), url.lastPathComponent), message: target.map { String(format: L("This program will run in %@."), $0.name) } ?? L("Prepare an environment before running this program.")) {
            if let target {
                Button(L("Run")) { state.pendingRun = nil; state.pendingRunBottle = nil; state.runDropped(url, in: target, andPin: false) }.disabled(state.busy)
                Button(L("Run and add to Programs")) { state.pendingRun = nil; state.pendingRunBottle = nil; state.runDropped(url, in: target, andPin: true) }.disabled(state.busy)
            }
            Button(L("Cancel")) { state.pendingRun = nil; state.pendingRunBottle = nil }
        }
    }

    @ViewBuilder private var directXPage: some View {
        if let pending = state.pendingD3DMetal {
            DecisionPage(title: String(format: L("%@ needs Apple's DirectX 12 support"), pending.item.title), message: GamePageCopy.d3dMetalAsk(title: pending.item.title, entry: state.gameDB.entry(for: pending.item))) {
                Button(L("Turn it on and play")) { state.enableD3DMetalAndPlay() }.buttonStyle(HBActionStyle(primary: true)).disabled(state.busy)
                if let other = GamePageCopy.otherWorkingRenderer(state.gameDB.entry(for: pending.item)) {
                    Button(String(format: L("Play with %@"), GamePageCopy.plainName(other))) { state.playPendingD3DMetal(with: other) }.disabled(state.busy)
                } else if state.gameDB.entry(for: pending.item)?.effectiveRenderer() != .d3dmetal {
                    Button(String(format: L("Play with %@"), GamePageCopy.plainName(.dxmt))) { state.playPendingD3DMetal(with: .dxmt) }.disabled(state.busy)
                }
                Button(L("Read Apple's licence")) {
                    state.licenseEngine = pending.engine; state.loadGPTKLicense(); state.showGPTKLicense = true
                }
                Button(L("Not now")) { state.pendingD3DMetal = nil }
            }
        }
    }

    @ViewBuilder private var enginePage: some View {
        if let pending = state.pendingEngine {
            DecisionPage(title: String(format: L("%@ needs the %@ engine"), pending.recipe.title, GamePageCopy.shortEngineName(pending.manifest)), message: GamePageCopy.engineAsk(recipe: pending.recipe, manifest: pending.manifest, installed: state.engines.contains { $0.id == pending.manifest.id })) {
                Button(L("Move this environment")) { state.moveEnvironment(for: pending.recipe, bottle: pending.bottle, to: pending.manifest) }.disabled(state.busy)
                Button(String(format: L("New environment for %@"), pending.recipe.title)) { state.createEnvironment(for: pending.recipe, on: pending.manifest) }.disabled(state.busy)
                Button(L("Not now")) { state.pendingEngine = nil }
            }
        }
    }

    @ViewBuilder private var updatePage: some View {
        if let pending = state.pendingUpdate {
            DecisionPage(title: String(format: L("%@ needs a newer Highball"), pending.recipe.title), message: GamePageCopy.updateAsk(recipe: pending.recipe, engineID: pending.engineID, canPlay: pending.play != nil)) {
                Button(L("Check for Updates…")) { state.pendingUpdate = nil; (NSApp.delegate as? AppDelegate)?.updaterController.updater.checkForUpdates() }
                if pending.play != nil { Button(L("Play without the fix")) { state.playWithoutTheFix() }.disabled(state.busy) }
                Button(L("Not now")) { state.pendingUpdate = nil }
            }
        }
    }

    @ViewBuilder private var rendererPage: some View {
        if let trial = state.rendererTrial {
            DecisionPage(title: String(format: L("Try %@ for %@ next time?"), GamePageCopy.plainName(trial.next), trial.title), message: L("A different graphics mode may suit this game better. This changes only this game; undo it under Advanced on its page.")) {
                Button(String(format: L("Use %@ for this game"), GamePageCopy.plainName(trial.next))) { state.acceptRendererTrial() }
                Button(L("Report how it went…")) { state.rendererTrial = nil; reportProblem() }
                Button(L("Not now")) { state.rendererTrial = nil }
            }
        }
    }

    private var errorPage: some View {
        DecisionPage(title: state.errorIsPartialSuccess ? L("Some files couldn't be removed") : (state.errorRecovery.map { L($0.headline) } ?? L("Something went wrong")), message: state.errorIsPartialSuccess ? (state.errorMessage ?? "") : (state.errorRecovery?.meaning ?? state.errorMessage ?? "")) {
            if let recovery = state.errorRecovery, let title = recovery.actionTitle, !state.errorIsPartialSuccess {
                Button(L(title)) {
                    let retry = state.errorRetry, bottle = state.errorBottle
                    state.errorMessage = nil
                    switch recovery.action {
                    case .retry: retry?()
                    case .repairBottle: if let bottle { state.repairBottle(bottle) } else { retry?() }
                    case .reinstallEngine(let id): state.reinstallEngine(id)
                    case .none: break
                    }
                }
            }
            Button(L("Details")) { state.showErrorDetails = true }
            if !state.errorIsPartialSuccess { Button(L("Report this problem…")) { state.errorMessage = nil; reportProblem() } }
            Button(L("Dismiss")) { state.errorMessage = nil }
        }
    }

    @ViewBuilder private var crashPage: some View {
        if let suggestion = state.crashSuggestion {
            let title = String(format: L("%@ quit after %d seconds"), suggestion.program, suggestion.seconds)
            DecisionPage(title: title, message: String(format: L("It was running with %@ and quit without an error the app could read. You can try another graphics mode or engine."), suggestion.current.rawValue.uppercased())) {
                Button(String(format: L("Use %@ for this game"), GamePageCopy.plainName(suggestion.renderer))) {
                    state.crashSuggestion = nil
                    if let id = suggestion.itemID { state.setRendererOverride(suggestion.renderer, for: id) }
                    else if var bottle = state.bottles.first(where: { $0.name == suggestion.bottleName }) {
                        bottle.settings.renderer = suggestion.renderer; bottle.settings.rendererExplicit = true; state.update(bottle)
                    }
                }
                if let engine = suggestion.alternateEngine {
                    Button(String(format: L("Try engine %@"), engine.id)) {
                        state.crashSuggestion = nil
                        if let bottle = state.bottles.first(where: { $0.name == suggestion.bottleName }) { state.moveBottle(bottle, to: engine) }
                    }.disabled(state.busy)
                }
                Button(L("Show the log")) { NSWorkspace.shared.open(URL(fileURLWithPath: suggestion.logPath)) }
                Button(L("Keep current")) { state.crashSuggestion = nil }
            }
        }
    }

    private var quitPage: some View {
        DecisionPage(title: L("Windows programs are still running"), message: L("Stop them and quit, or leave them running? A game left running keeps playing without Highball.")) {
            Button(L("Stop Everything & Quit")) { state.killAllBottles(); quit() }
            Button(L("Leave Running & Quit")) { quit() }
            Button(L("Cancel")) { state.pendingQuit = false }
        }
    }

    private func quit() {
        state.pendingQuit = false
        (NSApp.delegate as? AppDelegate)?.quitApproved = true
        NSApp.terminate(nil)
    }

    private func reportProblem() {
        NSWorkspace.shared.open(BugReport.url(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
    }

    private func homeMessage(_ target: URL) -> String {
        let copy = String(format: L("Engines, environments and downloads copy to %@, get checked, and are then removed from %@. Highball relaunches when it is done. Nothing is removed until the copy checks out."), target.path, state.paths.home.path)
        return HighballPaths.locationWarning(target).map { L($0) + "\n\n" + copy } ?? copy
    }
}
