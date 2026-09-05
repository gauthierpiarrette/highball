import AppKit
import HighballKit
import Sparkle
import SwiftUI

@main
struct HighballApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var state = AppState()

    var body: some Scene {
        // The main window group is declared first: it is the scene SwiftUI opens at launch.
        // Settings comes after it and is non-restorable (SettingsView), so a session that ended
        // with only Settings open cannot come back as Settings alone (issue #58).
        WindowGroup("Highball", id: "main") {
            ContentView()
                // One library window handles every play link; without this SwiftUI opens a new
                // window per link, one per Mac-app stub started (issue #53).
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
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
                Button(L("A Windows program I have…")) { state.chooseProgramToRun() }
                    .keyboardShortcut("o")
                    .disabled(state.busy || state.bottles.isEmpty)
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
        Settings { SettingsView().environment(state).preferredColorScheme(.dark) }
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
        // The UI is dark by design (preferredColorScheme), but AppKit chrome (scroll bars,
        // alerts, menus, open panels) follows the window appearance, which stayed light on a
        // light-mode Mac: a pale scroll bar down a dark library. One appearance for everything.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Works as a bare SwiftPM executable during development: give it a real UI presence.
        // A bundled app is activated by macOS on its own; forcing it here would also drag
        // Highball in front of a game a Mac-app stub just started with `open -g` (issue #53).
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        // Issue #58: if window restoration brought back only the Settings window, open the main
        // one. SettingsView asks for it as it appears; this is the fallback once launch settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { MainWindow.ensureOpen() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Dock click with only Settings on screen: SwiftUI sees a visible window and opens nothing,
    /// so bring the main window back ourselves (issue #58).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !MainWindow.isOpen, MainWindow.opener != nil else { return true }
        MainWindow.ensureOpen()
        return false
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var state

    /// Where a dropped or chosen program runs: the environment page it came from, else the default.
    private var runTarget: Bottle? {
        state.bottles.first { $0.name == state.pendingRunBottle } ?? state.defaultBottle
    }

    var body: some View {
        @Bindable var state = state
        Group {
            if state.needsOnboarding {
                OnboardingView()
            } else {
                // One library, full width (UX plan Phase 1): no sidebar, no bottles in the way.
                // Environments and the engine live in Settings (⌘,).
                NavigationStack { LibraryView() }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button(state.defaultBottle.map(state.steamInstalled) == true ? L("Open Steam") : L("Install Steam")) { state.installSteam() }
                                Button(L("Connect Epic account…")) { state.showEpicSignIn = true }
                                Divider()
                                ForEach(BottleView.launcherMeta.filter { $0.id != "steam" }, id: \.id) { meta in
                                    Button(String(format: state.launcherInstalled(meta.id) ? L("Open %@") : L("Install %@"), meta.short)) {
                                        state.openOrInstallLauncher(meta.id, short: meta.short)
                                    }
                                }
                                Divider()
                                Button(L("A Windows program I have…")) { state.chooseProgramToRun() }
                            } label: {
                                Label(L("Add games"), systemImage: "plus")
                            }
                            .disabled(state.busy || state.bottles.isEmpty)
                        }
                        ToolbarItem(placement: .automatic) {
                            SettingsLink { Label(L("Settings"), systemImage: "gearshape") }
                        }
                    }
            }
        }
        // Everything that takes time lives on one strip at the bottom, never modal (UX plan 0.5).
        .safeAreaInset(edge: .bottom, spacing: 0) { ActivityStrip() }
        // A Windows program dropped anywhere on the window, or picked from Add games and ⌘O,
        // runs in the environment it was dropped on, else the default one.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                if ["exe", "msi", "bat"].contains(url.pathExtension.lowercased()) {
                    Task { @MainActor in state.pendingRunBottle = nil; state.pendingRun = url }
                } else {
                    Task { @MainActor in
                        state.fail(HighballError.failed(String(format: L("'%@' isn't a Windows program. You can drop .exe, .msi or .bat files here."), url.lastPathComponent)))
                    }
                }
            }
            return true
        }
        .confirmationDialog(String(format: L("Run %@ in %@?"), state.pendingRun?.lastPathComponent ?? "", runTarget?.name ?? ""),
                            isPresented: .init(get: { state.pendingRun != nil }, set: { if !$0 { state.pendingRun = nil; state.pendingRunBottle = nil } }),
                            titleVisibility: .visible) {
            Button(L("Run")) { if let u = state.pendingRun, let b = runTarget { state.runDropped(u, in: b, andPin: false) }; state.pendingRun = nil }
            Button(L("Run and add to Programs")) { if let u = state.pendingRun, let b = runTarget { state.runDropped(u, in: b, andPin: true) }; state.pendingRun = nil }
            Button(L("Cancel"), role: .cancel) { state.pendingRun = nil }
        }
        .sheet(isPresented: $state.showLog) { LogSheet() }
        .sheet(isPresented: $state.showGPTKLicense) { GPTKLicenseSheet() }
        // Asked at the first game that needs it, never at install (UX plan §3.5). Nothing
        // downloads: D3DMetal is already inside the engine and accepting flips a flag.
        .alert(String(format: L("%@ needs Apple's DirectX 12 support"), state.pendingD3DMetal?.item.title ?? ""),
               isPresented: .init(get: { state.pendingD3DMetal != nil }, set: { if !$0 { state.pendingD3DMetal = nil } }),
               presenting: state.pendingD3DMetal) { pending in
            Button(L("Turn it on and play")) { state.enableD3DMetalAndPlay() }
            if let other = GamePageCopy.otherWorkingRenderer(pending.item.steamAppID.flatMap { state.gameDB[$0] }) {
                Button(String(format: L("Play with %@"), GamePageCopy.plainName(other))) { state.playPendingD3DMetal(with: other) }
            }
            Button(L("Read Apple's licence")) {
                state.licenseEngine = pending.engine
                state.pendingD3DMetal = nil
                state.loadGPTKLicense(); state.showGPTKLicense = true
            }
            Button(L("Not now"), role: .cancel) { state.pendingD3DMetal = nil }
        } message: { pending in
            let entry = pending.item.steamAppID.flatMap { state.gameDB[$0] }
            Text(GamePageCopy.d3dMetalAsk(title: pending.item.title, entry: entry))
        }
        .sheet(isPresented: $state.showEpicSignIn) { EpicSignInSheet() }
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
            Button(L("Show the log")) { NSWorkspace.shared.open(URL(fileURLWithPath: s.logPath)) }
            Button(L("Keep current"), role: .cancel) {}
        } message: { s in
            // What was detected, then what it usually means, then the one next thing. No path
            // on this surface: the log is one click away (UX plan §3.6).
            let seen = String(format: L("It was running with %@ and quit after %d seconds without an error the app could read."),
                              s.current.rawValue.uppercased(), s.seconds)
            let next = s.alternateEngine.map { alt in
                String(format: L("That usually means the graphics mode doesn't suit it on this Mac. Highball can switch this bottle to %@, or move it to engine %@."),
                       s.renderer.rawValue.uppercased(), alt.id)
            } ?? String(format: L("That usually means the graphics mode doesn't suit it on this Mac. Highball can switch this bottle to %@."),
                        s.renderer.rawValue.uppercased())
            Text(seen + " " + next)
        }
    }
    private var crashTitle: String {
        guard let s = state.crashSuggestion else { return "" }
        return s.seconds < 2 ? String(format: L("%@ quit right away"), s.program) : String(format: L("%@ quit after %d seconds"), s.program, s.seconds)
    }
}

struct CreateBottleSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var name = "play"
    @State private var installSteam = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("New environment")).font(.title2.bold())
            TextField(L("Name"), text: $name).textFieldStyle(.roundedBorder).frame(width: 260)
            if let problem = nameProblem, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(L(problem)).font(.caption).foregroundStyle(.orange).frame(maxWidth: 380, alignment: .leading)
            }
            Toggle(L("Install Steam in it (recommended)"), isOn: $installSteam)
            Text(L("An environment is an isolated Windows install. First boot takes about 90 seconds; installing Steam adds a download and a slow one-time client update."))
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: 380, alignment: .leading)
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Button(state.busy ? L("Working…") : L("Create")) {
                    dismiss()
                    state.createBottle(name: name, recipeID: installSteam ? "steam" : nil)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(nameProblem != nil || state.busy)
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
