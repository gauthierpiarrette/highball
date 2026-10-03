import AppKit
import HighballKit
import Sparkle
import SwiftUI

@main
struct HighballApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var state = AppState()

    var body: some Scene {
        // Every destination belongs to the main window, including Settings (⌘,).
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

        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L("Settings…")) { state.openSettings() }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button(L("Add games")) { state.select(.addGames); MainWindow.ensureOpen() }.keyboardShortcut("n")
                Button(L("Search")) { state.select(.search); MainWindow.ensureOpen() }.keyboardShortcut("f")
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

/// Sparkle asks which channels an install may see. Everyone sees stable; "Get beta builds"
/// in Settings adds the beta channel, where each release soaks a day or two first.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannels.allowed(beta: UserDefaults.standard.bool(forKey: UpdateChannels.betaDefaultsKey))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here because Sparkle holds its delegate weakly.
    let updaterDelegate: UpdaterDelegate
    /// Sparkle: reads SUFeedURL and SUPublicEDKey from Info.plist; no-ops in bare dev builds without them.
    let updaterController: SPUStandardUpdaterController

    override init() {
        let delegate = UpdaterDelegate()
        updaterDelegate = delegate
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        super.init()
    }
    var quitApproved = false

    /// Set from the App's onAppear so quit-time can reach the bottles.
    weak var appState: AppState? { didSet { flushPendingOpens() } }
    /// Files Finder asked us to open before the window existed (a double-click that launched the app).
    private var pendingOpens: [URL] = []

    /// Finder's double-click and Open With land here (issue #90); the app declares .exe, .msi and
    /// .bat in its Info.plist. A cold launch delivers them before the state is wired, so they wait.
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingOpens += urls
        flushPendingOpens()
    }

    private func flushPendingOpens() {
        guard let state = appState, !pendingOpens.isEmpty else { return }
        let urls = pendingOpens; pendingOpens = []
        Task { @MainActor in for url in urls { state.open(url: url) } }
    }

    /// Wine processes survive the app (they're not children of its lifetime), so quitting while a
    /// game or Steam runs would strand them with no UI attached. Ask instead of leaking.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = appState, state.wineProcessesRunning() else { return .terminateNow }
        if quitApproved { return .terminateNow }
        state.pendingQuit = true
        state.navigate(.decision)
        MainWindow.ensureOpen()
        NSApp.activate(ignoringOtherApps: true)
        return .terminateCancel
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
        // Restore the main surface if launch restoration did not produce a visible window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { MainWindow.ensureOpen() }
    }
    /// Closing the library while a game or Steam runs keeps Highball open in the Dock. Quitting
    /// there put the "still running" question on top of the game, with Stop as its default
    /// button, and a HoYoPlay user (discussion #132) read it as the game telling them to quit.
    /// A Dock click brings the window back (applicationShouldHandleReopen). With nothing from
    /// Windows running, closing the last window quits as before.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(appState?.wineProcessesRunning() ?? false)
    }

    /// Bring the main window back when the user reopens the app from the Dock.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !MainWindow.isOpen, MainWindow.opener != nil else { return true }
        MainWindow.ensureOpen()
        return false
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        AppShell()
            .onAppear { MainWindow.opener = { openWindow(id: "main") } }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if ["exe", "msi", "bat"].contains(url.pathExtension.lowercased()) {
                            state.pendingRunBottle = nil; state.pendingRun = url
                        } else {
                            state.fail(HighballError.failed(String(format: L("'%@' isn't a Windows program. You can drop .exe, .msi or .bat files here."), url.lastPathComponent)))
                        }
                    }
                }
                return true
            }
    }
}

struct NewEnvironmentPage: View {
    @Environment(AppState.self) private var state
    @State private var name = "play"
    @State private var installSteam = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 16) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 27, weight: .light)).foregroundStyle(HB.amber)
                        .frame(width: 64, height: 64).hbPanel(radius: 20)
                    SettingsHeading(title: L("New environment"), subtitle: L("A separate space for games that need their own settings."))
                }
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("Name")).font(.callout.weight(.semibold))
                        TextField(L("Name"), text: $name).textFieldStyle(.plain).font(.system(size: 16))
                            .padding(16).background(HB.ground.opacity(0.6), in: RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(HB.cardStroke))
                        if let problem = nameProblem, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text(L(problem)).font(.caption).foregroundStyle(HB.warn)
                        }
                    }
                    Divider().opacity(0.4)
                    HStack(spacing: 14) {
                        Image(systemName: "gamecontroller").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L("Install Steam")).font(.callout.weight(.semibold))
                            Text(L("Ready to sign in when setup finishes.")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(L("Install Steam"), isOn: $installSteam).labelsHidden().toggleStyle(.switch)
                    }
                }.padding(24).hbPanel(radius: 22)
                Label(L("First setup takes about 90 seconds. Steam adds a download and a one-time client update."), systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HBGlassGroup {
                    HStack(spacing: 12) {
                        Button(state.busy ? L("Working…") : L("Create environment")) {
                            state.goBack()
                            state.createBottle(name: name, recipeID: installSteam ? "steam" : nil)
                        }
                        .buttonStyle(HBActionStyle(primary: true)).keyboardShortcut(.defaultAction)
                        .disabled(nameProblem != nil || state.busy)
                        Button(L("Cancel")) { state.goBack() }.buttonStyle(HBActionStyle())
                    }
                }
            }
            .frame(maxWidth: 650, alignment: .leading).padding(36)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var nameProblem: String? { BottleStore.nameProblem(name) }
}

struct ActivityPage: View {
    @Environment(AppState.self) private var state

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
                Button(state.busy ? "Hide" : "Close") { state.showLog = false }
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
                Button(ctaTitle) { state.showLog = false; done.cta?() }
                    .buttonStyle(HBActionStyle(primary: true))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Activity log")).font(.caption).foregroundStyle(.secondary)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(state.logLines.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(i)
                            }
                        }
                    }
                    .onChange(of: state.logLines.count) { _, n in proxy.scrollTo(max(0, n - 1)) }
                    .onAppear { proxy.scrollTo(max(0, state.logLines.count - 1)) }
                    .frame(minHeight: 300, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.4))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
    }
}

/// The raw description of a failure: what a report needs, kept off the primary surface.
struct ErrorDetailsPage: View {
    @Environment(AppState.self) private var state
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
                Button(L("Done")) { state.showErrorDetails = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 320)
    }
}
