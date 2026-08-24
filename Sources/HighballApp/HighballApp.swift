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
                .tint(Color(red: 0.78, green: 0.55, blue: 0.20))
                .frame(minWidth: 820, minHeight: 560)
                .onAppear { state.refresh() }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: delegate.updaterController.updater)
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
                    List(selection: $state.selectedBottle) {
                        Section(L("Bottles")) {
                            ForEach(state.bottles, id: \.name) { bottle in
                                Label(bottle.name, systemImage: "wineglass")
                                    .tag(bottle.name)
                                    .contextMenu {
                                        Button(L("Stop all processes")) { state.killBottle(bottle) }
                                        Divider()
                                        Button(L("Delete bottle…"), role: .destructive) { pendingDelete = bottle.name }
                                    }
                            }
                        }
                        if let engine = state.engines.first {
                            Section(L("Engine")) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(engine.id).font(.caption).lineLimit(1)
                                    Text((try? engine.wineVersion()) ?? "")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230)
                    .toolbar {
                        Button { showCreate = true } label: { Label(L("New Bottle"), systemImage: "plus") }
                    }
                } detail: {
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
        .sheet(isPresented: $showCreate) { CreateBottleSheet() }
        .confirmationDialog("Delete bottle \"\(pendingDelete ?? "")\"? This removes its Windows drive and everything installed in it.",
                            isPresented: .init(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) { if let n = pendingDelete { state.deleteBottle(n) }; pendingDelete = nil }
            Button(L("Cancel"), role: .cancel) { pendingDelete = nil }
        }
        .sheet(isPresented: $state.showLog) { LogSheet() }
        .sheet(isPresented: $state.showGPTKLicense) { GPTKLicenseSheet() }
        .alert(L("Something went wrong"), isPresented: .init(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } })) {
            Button("OK") { state.errorMessage = nil }
        } message: { Text(state.errorMessage ?? "") }
        .alert(item: $state.crashSuggestion) { s in
            Alert(title: Text("\(s.program) exited right away"),
                  message: Text("That usually means the graphics backend doesn't suit it. Try \(s.renderer.rawValue.uppercased())? The log is at \(s.logPath)."),
                  primaryButton: .default(Text("Use \(s.renderer.rawValue.uppercased())")) {
                      if let name = state.selectedBottle, var bottle = state.bottles.first(where: { $0.name == name }) {
                          bottle.settings.renderer = s.renderer
                          state.update(bottle)
                      }
                  },
                  secondaryButton: .cancel(Text(L("Keep current"))))
        }
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
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }
}

struct LogSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if state.busy { ProgressView().controlSize(.small) }
                Text(state.busy ? state.busyTitle : L("Done")).font(.headline)
                Spacer()
                Button(state.busy ? "Hide" : "Close") { dismiss() }
            }
            if !state.stage.isEmpty {
                Label(state.stage, systemImage: "clock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
