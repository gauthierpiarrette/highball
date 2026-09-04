import AppKit
import HighballKit
import Sparkle
import SwiftUI

@main
struct HighballApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Highball") {
            ContentView()
                .environment(state)
                .tint(HB.amber)
                .preferredColorScheme(.dark)
                .frame(minWidth: 820, minHeight: 560)
                .onAppear { state.refresh(); state.sweepTrash(); delegate.appState = state }
                .onOpenURL { url in state.open(url: url) }
                .alert(String(format: L("Open %@ in Highball?"), state.pendingPlayLink?.title ?? ""),
                       isPresented: Binding(get: { state.pendingPlayLink != nil }, set: { if !$0 { state.pendingPlayLink = nil } })) {
                    Button(L("Play")) { if let item = state.pendingPlayLink { state.pendingPlayLink = nil; state.play(item) } }
                    Button(L("Cancel"), role: .cancel) { state.pendingPlayLink = nil }
                } message: { Text(L("This link did not come from one of your Highball apps, so it asks first.")) }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button(L("Run Windows Program…")) { state.chooseProgramToRun() }
                    .keyboardShortcut("o")
                    .disabled(state.selectedBottle == nil)
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: delegate.updaterController.updater)
                // Cleanup after a crash or a "leave running" quit — no Activity Monitor needed.
                Button(L("Stop All Windows Processes")) { state.killAllBottles() }
                // Pre-filled GitHub issue: version, chip/macOS, newest log tail (issue #7).
                Button(L("Report a Problem…")) {
                    NSWorkspace.shared.open(BugReport.url(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
                }
            }
        }
    }
}

/// "Check for Updates…" menu item, enabled/disabled by Sparkle's own state.
struct CheckForUpdatesView: View {
    @ObservedObject private var model: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.model = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button(L("Check for Updates…")) { updater.checkForUpdates() }
            .disabled(!model.canCheckForUpdates)
    }
}

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Sparkle: reads SUFeedURL and SUPublicEDKey from Info.plist; no-ops in bare dev builds without them.
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    /// Set from the App's onAppear so quit-time can reach the bottles.
    weak var appState: AppState?

    /// Wine processes survive the app (they're not children of its lifetime), so quitting while a
    /// game or Steam runs would strand them with no UI attached. Ask instead of leaking.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = appState, state.wineProcessesRunning() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("Windows programs are still running")
        alert.informativeText = L("Stop them and quit, or leave them running? A game left running keeps playing without Highball — quit it from inside the game when you're done.")
        alert.addButton(withTitle: L("Stop Everything & Quit"))
        alert.addButton(withTitle: L("Leave Running & Quit"))
        alert.addButton(withTitle: L("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            state.killAllBottles()
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Works as a bare SwiftPM executable during development: give it a real UI presence.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var showCreate = false
    @State private var pendingDelete: String?

    var body: some View {
        @Bindable var state = state
        Group {
            if state.needsOnboarding {
                OnboardingView()
            } else {
                NavigationSplitView {
                    List {
                        Section {
                            HStack(spacing: 9) {
                                if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"), let img = NSImage(contentsOf: url) {
                                    Image(nsImage: img).resizable().frame(width: 34, height: 34)
                                }
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("Highball").font(.system(size: 16, weight: .heavy, design: .rounded))
                                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                                        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        // One Library (Phase 2): the primary surface, above the bottles.
                        Section {
                            let onLibrary = state.pane == .library
                            Button {
                                state.pane = .library
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: onLibrary ? "square.grid.2x2.fill" : "square.grid.2x2")
                                        .foregroundStyle(onLibrary ? HB.amber : Color.secondary)
                                        .frame(width: 18)
                                    Text(L("Library")).fontWeight(onLibrary ? .semibold : .regular)
                                    Spacer()
                                    Text("\(state.libraryItems.count)")
                                        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 5).padding(.horizontal, 7)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(onLibrary ? HB.amber.opacity(0.16) : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .stroke(onLibrary ? HB.amber.opacity(0.35) : .clear))
                            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        }
                        Section(L("Bottles")) {
                            ForEach(state.bottles, id: \.name) { bottle in
                                let selected = state.selectedBottle == bottle.name && state.pane == .bottles
                                Button {
                                    state.selectedBottle = bottle.name
                                    state.pane = .bottles
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "wineglass\(selected ? ".fill" : "")")
                                            .foregroundStyle(selected ? HB.amber : Color.secondary)
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(bottle.name)
                                                .fontWeight(selected ? .semibold : .regular)
                                            // A large prefix takes a while to purge, and the row
                                            // used to sit there looking idle and clickable.
                                            if state.deletingBottles.contains(bottle.name) {
                                                Text(L("deleting…"))
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 5).padding(.horizontal, 7)
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(selected ? HB.amber.opacity(0.16) : .clear))
                                .overlay(RoundedRectangle(cornerRadius: 7)
                                    .stroke(selected ? HB.amber.opacity(0.35) : .clear))
                                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                                .contextMenu {
                                    Button(L("Stop all processes")) { state.killBottle(bottle) }
                                    Button(L("Duplicate bottle")) { state.duplicateBottle(bottle) }
                                    Button(L("Repair bottle (re-run first boot)")) { state.repairBottle(bottle) }
                                    Divider()
                                    Button(L("Delete bottle…"), role: .destructive) { pendingDelete = bottle.name }
                                        .disabled(state.deletingBottles.contains(bottle.name))
                                }
                            }
                            // A folder under bottles/ that isn't a loadable bottle still needs
                            // somewhere to be acted on. Before #38 it was simply invisible, which
                            // left its files stranded and its name unusable.
                            ForEach(state.damagedBottles) { damaged in
                                Button { pendingDelete = damaged.name } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(damaged.name)
                                            Text(L("damaged — click to delete"))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(damaged.reason)
                                .padding(.vertical, 5).padding(.horizontal, 7)
                                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                            }
                        }
                        if let engine = state.defaultEngine {
                            Section(L("Engine")) {
                                Label {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(engine.displayName).font(.caption)
                                        Text(engine.id).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                } icon: { Image(systemName: "gearshape.2").foregroundStyle(.secondary) }
                                if let update = state.engineUpdate {
                                    Button {
                                        state.updateEngine()
                                    } label: {
                                        Label {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(L("Update engine")).font(.caption)
                                                Text(update.id).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                            }
                                        } icon: { Image(systemName: "arrow.down.circle").foregroundStyle(.tint) }
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(state.busy)
                                    .help(L("Installs the newer engine this version of Highball ships. Bottles on the same Wine build move to it; the others stay on their engine until you switch them in the bottle's settings. Only changed components are downloaded."))
                                }
                            }
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230)
                    .toolbar {
                        Button { showCreate = true } label: { Label(L("New Bottle"), systemImage: "plus") }
                    }
                } detail: {
                    switch state.pane {
                    case .library:
                        NavigationStack { LibraryView() }
                    case .bottles:
                        if let name = state.selectedBottle,
                           let bottle = state.bottles.first(where: { $0.name == name }) {
                            BottleView(bottle: bottle)
                        } else {
                            ContentUnavailableView(L("No bottle selected"), systemImage: "wineglass",
                                                   description: Text(L("Create a bottle to install Steam and play.")))
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showCreate) { CreateBottleSheet() }
        .onChange(of: state.requestCreateBottle) { _, wants in
            if wants { showCreate = true; state.requestCreateBottle = false }
        }
        .confirmationDialog("Delete bottle \"\(pendingDelete ?? "")\"? This removes its Windows drive and everything installed in it.",
                            isPresented: .init(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) { if let n = pendingDelete { state.deleteBottle(n) }; pendingDelete = nil }
            Button(L("Cancel"), role: .cancel) { pendingDelete = nil }
        }
        .sheet(isPresented: $state.showLog) { LogSheet() }
        .sheet(isPresented: $state.showGPTKLicense) { GPTKLicenseSheet() }
        .sheet(isPresented: $state.showEpicSignIn) { EpicSignInSheet() }
        // Heavy fix at Play: installs take real time, so the cost is stated, never silent.
        .confirmationDialog(
            String(format: L("%@ needs a one-time setup to run the way it was verified."),
                   state.pendingHeavyFix?.item.title ?? ""),
            isPresented: .init(get: { state.pendingHeavyFix != nil },
                               set: { if !$0 { state.pendingHeavyFix = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("Install the fix first")) { state.confirmHeavyFix() }
            Button(L("Play without it")) { state.skipHeavyFix() }
            Button(L("Cancel"), role: .cancel) { state.pendingHeavyFix = nil }
        } message: {
            Text(state.pendingHeavyFix?.recipe.steps.compactMap(\.slowHint).first
                 ?? L("This installs the dependencies the compatibility database verified."))
        }
        // A partial delete succeeded — the bottle is gone and the name is free — so framing it as
        // a failure, with an invitation to file a bug, misreads what happened. Same alert, honest
        // title, and no Report button for something that is not a problem to report.
        .alert(state.errorIsPartialSuccess ? L("Some files couldn't be removed") : (state.errorRecovery.map { L($0.headline) } ?? L("Something went wrong")),
               isPresented: .init(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } })) {
            // One button that does the next thing, when the failure has one (UX plan §3.6).
            if let r = state.errorRecovery, let title = r.actionTitle, !state.errorIsPartialSuccess {
                Button(L(title)) {
                    let retry = state.errorRetry, bottle = state.errorBottle
                    state.errorMessage = nil
                    switch r.action {
                    case .retry: retry?()
                    case .repairBottle: if let bottle { state.repairBottle(bottle) } else { retry?() }
                    case .none: break
                    }
                }
            }
            Button(L("Details…")) { state.showErrorDetails = true; state.errorMessage = nil }
            if !state.errorIsPartialSuccess {
                Button(L("Report this problem…")) {
                    state.errorMessage = nil
                    NSWorkspace.shared.open(BugReport.url(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
                }
            }
            Button("OK", role: .cancel) { state.errorMessage = nil }
        } message: {
            // The meaning, in words; exit codes, paths and raw output live behind Details.
            Text(state.errorIsPartialSuccess ? (state.errorMessage ?? "") : (state.errorRecovery?.meaning ?? ""))
        }
        .sheet(isPresented: Binding(get: { state.showErrorDetails }, set: { state.showErrorDetails = $0 })) {
            ErrorDetailsSheet(text: state.errorDetailsText)
        }
        .alert(crashTitle, isPresented: Binding(get: { state.crashSuggestion != nil }, set: { if !$0 { state.crashSuggestion = nil } }),
               presenting: state.crashSuggestion) { s in
            Button("Use \(s.renderer.rawValue.uppercased())") {
                if var bottle = state.bottles.first(where: { $0.name == s.bottleName }) {
                    bottle.settings.renderer = s.renderer
                    bottle.settings.rendererExplicit = true   // the user picked it; recipes must not clobber it (#29)
                    state.update(bottle)
                }
            }
            if let alt = s.alternateEngine {
                Button(String(format: L("Try engine %@"), alt.id)) {
                    if let bottle = state.bottles.first(where: { $0.name == s.bottleName }) { state.moveBottle(bottle, to: alt) }
                }
            }
            Button(L("Keep current"), role: .cancel) {}
        } message: { s in
            if let alt = s.alternateEngine {
                Text("That usually means the graphics backend doesn't suit it. Try \(s.renderer.rawValue.uppercased())? If that fails too, the bottle can move to engine \(alt.id) and back. The log is at \(s.logPath).")
            } else {
                Text("That usually means the graphics backend doesn't suit it. Try \(s.renderer.rawValue.uppercased())? The log is at \(s.logPath).")
            }
        }
    }
    private var crashTitle: String {
        guard let s = state.crashSuggestion else { return "" }
        return "\(s.program) exited right away"
    }
}

struct CreateBottleSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var name = "play"
    @State private var installSteam = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("New bottle")).font(.title2.bold())
            TextField(L("Name"), text: $name).textFieldStyle(.roundedBorder).frame(width: 260)
            if let problem = nameProblem, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(L(problem)).font(.caption).foregroundStyle(.orange).frame(maxWidth: 380, alignment: .leading)
            }
            Toggle(L("Install Steam in it (recommended)"), isOn: $installSteam)
            Text(L("A bottle is an isolated Windows environment. First boot takes about 90 seconds; the Steam install adds a download and a slow one-time client update."))
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: 380, alignment: .leading)
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Button(L("Create")) {
                    dismiss()
                    state.createBottle(name: name, recipeID: installSteam ? "steam" : nil)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(nameProblem != nil)
            }
        }
        .padding(24)
    }

    private var nameProblem: String? { BottleStore.nameProblem(name) }
}

struct LogSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if state.busy {
                    ProgressView().controlSize(.small)
                } else if state.doneState != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text(state.busy ? state.busyTitle : (state.doneState?.title ?? L("Done"))).font(.headline)
                Spacer()
                Button(state.busy ? "Hide" : "Close") { dismiss() }
            }
            if !state.stage.isEmpty {
                Label(state.stage, systemImage: "clock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // Recipe-declared expectation for the current step ("takes 20–40 min, looks idle").
            // Shown while the step runs, so nobody has to guess whether it froze (#31).
            if state.busy, !state.stageHint.isEmpty {
                Label(state.stageHint, systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if state.busy, let started = state.busyStartedAt {
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    let mins = Int(ctx.date.timeIntervalSince(started) / 60)
                    let elapsed = mins < 1 ? L("just started") : String(format: L("running for %d min"), mins)
                    let liveness: String = {
                        guard let last = state.lastOutputAt else { return "" }
                        let quiet = ctx.date.timeIntervalSince(last)
                        if quiet < 90 { return " · " + L("active") }
                        // Quiet is expected during hinted-slow steps; the hint already explains it.
                        return state.stageHint.isEmpty ? " · " + L("quiet — can be normal, see Details") : ""
                    }()
                    Text(elapsed + (state.busyExpected.map { " · " + $0 } ?? "") + liveness)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !state.busy, let done = state.doneState, let ctaTitle = done.ctaTitle {
                Button(ctaTitle) { dismiss(); done.cta?() }
                    .buttonStyle(.borderedProminent)
            }
            DisclosureGroup(L("Details")) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(state.logLines.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.system(size: 11, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(i)
                            }
                        }
                    }
                    .onChange(of: state.logLines.count) { _, n in proxy.scrollTo(max(0, n - 1)) }
                    .frame(height: 240)
                    .background(.quaternary.opacity(0.4))
                }
            }
            .frame(width: 620)
        }
        .padding(16)
    }
}

/// The raw description of a failure: what a report needs, kept off the primary surface.
struct ErrorDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Details")).font(.title3.bold())
            ScrollView {
                Text(verbatim: text).font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(L("Copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                Spacer()
                Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 320)
    }
}
