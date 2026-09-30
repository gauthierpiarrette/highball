import HighballKit
import SwiftUI

enum AppSection: String, CaseIterable {
    case home, search, installed, downloads, steam, epic, programs, addGames, engines, settings
    var title: String {
        switch self {
        case .home: L("Home")
        case .search: L("Search")
        case .installed: L("Installed")
        case .downloads: L("Ready to download")
        case .steam: "Steam"
        case .epic: "Epic Games"
        case .programs: L("Programs")
        case .addGames: L("Add games")
        case .engines: L("Engines")
        case .settings: L("Settings")
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .installed: "gamecontroller"
        case .downloads: "arrow.down.circle"
        case .steam: "s.circle"
        case .epic: "e.circle"
        case .programs: "app.dashed"
        case .addGames: "plus.circle"
        case .engines: "gearshape.2"
        case .settings: "slider.horizontal.3"
        }
    }
}

enum AppRoute: Equatable {
    case game(LibraryItem), environment(String), environmentSettings(String), pinSettings(String, UUID)
    case newEnvironment, decision, engineTransition
}

/// A single navigation history, shared by games, settings and management tasks.
struct AppShell: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
        } detail: {
            VStack(spacing: 0) {
                if canGoBack {
                    HStack {
                        Button(action: back) { Label(L("Back"), systemImage: "chevron.left") }
                            .buttonStyle(.plain).keyboardShortcut("[", modifiers: .command)
                        Spacer()
                    }.padding(.horizontal, 28).padding(.vertical, 12)
                }
                page.frame(maxWidth: .infinity, maxHeight: .infinity)
                if state.decisionID != nil, state.navigation.last != .decision {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(HB.amber)
                        Text(L("An action needs your attention")).font(.callout)
                        Spacer()
                        Button(L("Review")) { state.navigate(.decision) }
                    }.padding(14).hbPanel().padding(.horizontal, 16)
                }
                ActivityStrip()
            }
            .background(BottleBackdrop())
            .animation(HB.motion(reduceMotion), value: state.navigation)
            .animation(HB.motion(reduceMotion), value: state.section)
            .animation(HB.motion(reduceMotion), value: state.engineChange != nil)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: state.decisionID, initial: true) { _, id in
            if id != nil {
                state.showLog = false; state.showGPTKLicense = false; state.showEpicSignIn = false; state.showErrorDetails = false
                state.navigate(.decision)
            }
            else { state.navigation.removeAll { $0 == .decision } }
        }
        .onChange(of: state.engineChange != nil, initial: true) { _, switching in
            if switching { state.navigate(.engineTransition) }
            else { state.navigation.removeAll { $0 == .engineTransition } }
        }
    }

    private var canGoBack: Bool {
        state.showLog || state.showGPTKLicense || state.showEpicSignIn || state.showErrorDetails || !state.navigation.isEmpty
    }

    private func back() {
        if state.showLog { state.showLog = false }
        else if state.showGPTKLicense { state.showGPTKLicense = false }
        else if state.showEpicSignIn { state.showEpicSignIn = false }
        else if state.showErrorDetails { state.showErrorDetails = false }
        else if state.navigation.last == .decision {
            state.goBack() // Pending actions remain available from the activity area.
        } else { state.goBack() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                HighballMark(size: 38)
                Text("Highball").font(.system(size: 17, weight: .semibold, design: .rounded))
            }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sidebarGroup(nil, [.search, .home])
                    sidebarGroup(L("Library"), [.installed, .downloads, .programs])
                    sidebarGroup(L("Stores"), [.steam, .epic])
                    sidebarGroup(L("Manage"), [.addGames, .engines])
                }.padding(.horizontal, 12)
            }
            SettingsNavItem(title: AppSection.settings.title, symbol: AppSection.settings.symbol,
                            selected: state.section == .settings) { state.select(.settings) }
                .padding(.horizontal, 12).padding(.top, 8)
            if let bottle = state.defaultBottle, let engine = state.engine(for: bottle) {
                Button { state.select(.engines) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(HB.good).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(GamePageCopy.shortEngineName(engine.manifest)).font(.caption.weight(.medium))
                            Text(bottle.name).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(12)
                }.buttonStyle(.plain).padding(8)
            }
        }
        .background(.regularMaterial)
    }

    private func sidebarGroup(_ title: String?, _ sections: [AppSection]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 5) }
            ForEach(sections, id: \.self) { section in
                SettingsNavItem(title: section.title, symbol: section.symbol, selected: state.section == section) {
                    state.select(section)
                }
            }
        }
    }

    private var showsEngineTransition: Bool {
        if state.section == .engines { return true }
        if state.navigation.last == .engineTransition { return true }
        if case .environmentSettings = state.navigation.last { return true }
        return false
    }

    @ViewBuilder private var page: some View {
        if state.showLog { ActivityPage() }
        else if state.showGPTKLicense { LicensePage() }
        else if state.showEpicSignIn { EpicAccountPage() }
        else if state.showErrorDetails { ErrorDetailsPage(text: state.errorDetailsText) }
        else if state.navigation.last == .decision { AppDecisions() }
        else if let change = state.engineChange, showsEngineTransition { EngineTransitionView(change: change) }
        else if let route = state.navigation.last { destination(route) }
        else if let missing = state.homeUnavailable {
            DecisionPage(title: L("Your Highball folder is not connected"), message: missing.path) {
                Button(L("Relaunch")) { AppState.relaunch() }
                Button(L("Use the default location")) { state.useDefaultHome() }
            }
        } else if state.needsOnboarding { OnboardingView() }
        else {
            switch state.section {
            case .engines: EnginePane()
            case .settings: SettingsView()
            case .addGames: AddGamesPage()
            default: LibraryView(section: state.section)
            }
        }
    }

    @ViewBuilder private func destination(_ route: AppRoute) -> some View {
        switch route {
        case .game(let item): GameDetailView(passedItem: item)
        case .newEnvironment: NewEnvironmentPage()
        case .decision: AppDecisions()
        case .engineTransition:
            if let change = state.engineChange { EngineTransitionView(change: change) }
            else { EnginePane() }
        case .environment(let name):
            if let bottle = state.bottles.first(where: { $0.name == name }) { BottleView(bottle: bottle) }
            else { missingEnvironment }
        case .environmentSettings(let name):
            if let bottle = state.bottles.first(where: { $0.name == name }) { EnvironmentSettingsPage(bottle: bottle) }
            else { missingEnvironment }
        case .pinSettings(let name, let id):
            if let bottle = state.bottles.first(where: { $0.name == name }), let pin = bottle.settings.pins.first(where: { $0.id == id }) {
                ScrollView { PinSettingsPage(pin: pin, bottle: bottle).frame(maxWidth: 680).padding(28) }
            } else { missingEnvironment }
        }
    }

    private var missingEnvironment: some View {
        ContentUnavailableView(L("Environment unavailable"), systemImage: "square.stack.3d.up",
                               description: Text(L("Choose another environment in Settings.")))
    }
}

struct AddGamesPage: View {
    @Environment(AppState.self) private var state
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsHeading(title: L("Add games"), subtitle: L("Connect a store or choose a Windows program from your Mac."))
                HStack(spacing: 16) {
                    store("Steam", symbol: "gamecontroller", message: L("Install Steam, sign in and bring your library here."),
                          action: state.defaultBottle.map(state.steamInstalled) == true ? L("Open Steam") : L("Install Steam")) { state.installSteam() }
                    store("Epic Games", symbol: "bag", message: L("Connect your account to see and install the games you own."),
                          action: state.epicSignedIn ? L("Connected") : L("Connect account")) { state.showEpicSignIn = true }
                }
                store(L("A Windows program"), symbol: "folder", message: L("Choose an .exe, .msi or .bat, or drop it onto this window."), action: L("Choose a file…")) { state.chooseProgramToRun() }
                DisclosureGroup(L("More launchers")) {
                    VStack(spacing: 10) {
                        ForEach(BottleView.launcherMeta.filter { $0.id != "steam" }, id: \.id) { meta in
                            HStack {
                                Label(meta.short, systemImage: meta.symbol)
                                Spacer()
                                Button(state.launcherInstalled(meta.id) ? L("Open") : L("Install")) {
                                    state.openOrInstallLauncher(meta.id, short: meta.short)
                                }.disabled(state.busy || state.bottles.isEmpty)
                            }.padding(16).hbPanel()
                        }
                    }.padding(.top, 12)
                }
                if state.bottles.isEmpty {
                    Button(L("Prepare a Windows environment")) { state.makeDefaultEnvironment() }.disabled(state.busy)
                }
            }.padding(32)
        }
    }

    private func store(_ title: String, symbol: String, message: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action, action: perform).buttonStyle(HBActionStyle(primary: true))
                .disabled(state.busy || state.bottles.isEmpty || (title == "Epic Games" && state.epicSignedIn))
        }.padding(22).frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading).hbPanel()
    }
}
