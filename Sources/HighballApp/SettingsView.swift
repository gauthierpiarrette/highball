import SwiftUI
import HighballKit

extension SettingsTab {
    var title: String {
        switch self {
        case .environments: L("Environments")
        case .engine: L("Engines")
        case .storage: L("Storage")
        case .updates: L("Updates")
        case .troubleshooting: L("Troubleshooting")
        }
    }
    var symbol: String {
        switch self {
        case .environments: "square.stack.3d.up"
        case .engine: "gearshape.2"
        case .storage: "internaldrive"
        case .updates: "arrow.down.circle"
        case .troubleshooting: "wrench.and.screwdriver"
        }
    }
}

/// Settings is a destination in the main window, with four simple content tabs.
struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let tabs: [SettingsTab] = [.environments, .storage, .updates, .troubleshooting]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("Settings")).font(.system(size: 32, weight: .bold, design: .rounded))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tabs, id: \.self) { tab in
                            FilterChip(label: tab.title, on: state.settingsTab == tab) { state.settingsTab = tab }
                        }
                    }.padding(5).hbGlass(radius: 22).padding(.vertical, 2)
                }
            }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 12)
            Group {
                switch state.settingsTab {
                case .environments: EnvironmentsPane()
                case .storage: StoragePane()
                case .updates: UpdatesPane()
                case .troubleshooting: TroubleshootingPane()
                case .engine: EnginePane()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(state.settingsTab).transition(.opacity)
        }.animation(HB.motion(reduceMotion), value: state.settingsTab)
    }
}

/// One environment by default, more only when two games need settings that conflict.
struct EnvironmentsPane: View {
    @Environment(AppState.self) private var state
    private var selected: Bottle? {
        state.bottles.first { $0.name == state.selectedEnvironmentName } ?? state.defaultBottle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsHeading(title: L("Environments"), subtitle: L("A home for your Windows games. Create another only when a game needs different settings."))
                Button { state.navigate(.newEnvironment) } label: {
                    Label(L("New environment"), systemImage: "plus")
                }.buttonStyle(HBActionStyle(primary: state.bottles.isEmpty)).disabled(state.busy)
                VStack(spacing: 10) {
                    ForEach(state.bottles, id: \.name) { bottle in
                        environmentCard(bottle)
                    }
                    ForEach(state.damagedBottles) { damaged in
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(damaged.name).font(.headline)
                                Text(damaged.reason).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L("Delete…"), role: .destructive) { state.pendingEnvironmentDeletion = damaged.name }
                                .buttonStyle(HBActionStyle())
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 16).fill(HB.card))
                    }
                }
                if let bottle = selected { details(bottle) }
            }
            .frame(maxWidth: 960, alignment: .leading).padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sizeText(_ bottle: Bottle) -> String {
        let bytes = state.libraryItems.filter { $0.bottleName == bottle.name }.reduce(Int64(0)) { $0 + $1.sizeOnDisk }
        return bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : ""
    }

    private func environmentCard(_ bottle: Bottle) -> some View {
        let isSelected = selected?.name == bottle.name
        let titles = state.libraryItems.filter { $0.bottleName == bottle.name }.count
        return Button {
            state.selectedEnvironmentName = bottle.name
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(isSelected ? HB.amber : .secondary)
                    .frame(width: 44, height: 44)
                    .background(HB.card, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(bottle.name).font(.headline)
                        if bottle.name == state.defaultBottle?.name {
                            Text(L("DEFAULT")).font(.system(size: 9, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(HB.good.opacity(0.2))).foregroundStyle(HB.good)
                        }
                        if state.deletingBottles.contains(bottle.name) {
                            Text(L("deleting…")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text([state.engine(for: bottle)?.displayName ?? bottle.settings.engineID,
                          String(format: L("%d titles"), titles),
                          sizeText(bottle)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(isSelected ? HB.amber : HB.cardStroke)
            }
            .padding(20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 16).fill(HB.card))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(isSelected ? HB.amber.opacity(0.6) : HB.cardStroke))
        .contextMenu {
            Button(L("Programs & launchers")) { state.navigate(.environment(bottle.name)) }
            Button(L("Stop all processes")) { state.killBottle(bottle) }
            Button(L("Duplicate")) { state.duplicateBottle(bottle) }
            Button(L("Repair (re-run the Windows first boot)")) { state.repairBottle(bottle) }
            Divider()
            Button(L("Delete…"), role: .destructive) { state.pendingEnvironmentDeletion = bottle.name }
                .disabled(state.deletingBottles.contains(bottle.name))
        }
    }

    private func details(_ bottle: Bottle) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(String(format: L("Settings for %@"), bottle.name))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            VStack(alignment: .leading, spacing: 10) {
                HB.eyebrow(L("Graphics mode"))
                GraphicsModePicker(bottle: bottle).controlSize(.large)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { environmentActions(bottle) }
                VStack(alignment: .leading, spacing: 12) { environmentActions(bottle) }
            }
            Divider()
            DisclosureGroup(L("Files & recovery")) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("Open the Windows drive, remove a program, or repair Windows setup without removing your games."))
                        .font(.callout).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { fileActions(bottle) }
                        VStack(alignment: .leading, spacing: 12) { fileActions(bottle) }
                    }
                }.padding(.top, 14)
            }.font(.callout.weight(.medium))
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading).hbPanel(radius: 22)
    }

    @ViewBuilder private func environmentActions(_ bottle: Bottle) -> some View {
        Button { state.navigate(.environmentSettings(bottle.name)) } label: {
            Label(L("Graphics & compatibility"), systemImage: "slider.horizontal.3")
        }.buttonStyle(HBActionStyle(primary: true))
            .help(L("Graphics, compatibility, engine, DLL overrides, environment variables and dependencies for this environment."))
        Button { state.navigate(.environment(bottle.name)) } label: {
            Label(L("Programs & launchers"), systemImage: "square.grid.2x2")
        }.buttonStyle(HBActionStyle())
    }

    @ViewBuilder private func fileActions(_ bottle: Bottle) -> some View {
        Button(L("Windows drive")) { NSWorkspace.shared.open(bottle.driveC) }
            .buttonStyle(HBActionStyle())
        Button(L("Uninstall programs")) { state.openUninstaller(in: bottle) }
            .buttonStyle(HBActionStyle())
            .help(L("Opens Windows' Add/Remove Programs for this environment, for programs you installed into it."))
        Button(L("Repair")) { state.repairBottle(bottle) }
            .buttonStyle(HBActionStyle()).disabled(state.busy)
    }

}

struct EnginePane: View {
    @Environment(AppState.self) private var state
    private var selected: Bottle? { state.bottles.first { $0.name == state.selectedEngineEnvironmentName } ?? state.defaultBottle }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsHeading(title: L("Engines"), subtitle: L("Choose how your environment runs. Your games stay installed when you switch."))
                if let bottle = selected {
                    VStack(alignment: .leading, spacing: 16) {
                        if state.bottles.count > 1 {
                            Picker(L("Environment"), selection: Binding(get: { bottle.name }, set: { state.selectedEngineEnvironmentName = $0 })) {
                                ForEach(state.bottles, id: \.name) { Text($0.name).tag($0.name) }
                            }
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "gearshape.2.fill").font(.title2).foregroundStyle(HB.amber)
                            VStack(alignment: .leading, spacing: 5) {
                                HB.eyebrow(L("Current engine"))
                                Text(state.engine(for: bottle)?.displayName ?? bottle.settings.engineID).font(.headline)
                                Text(bottle.name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let engine = state.engine(for: bottle), engine.ships("d3dmetal"), engine.rendererDir("d3dmetal") == nil {
                            Button(L("Review Apple's DirectX 12 license…")) {
                                state.licenseEngine = engine; state.loadGPTKLicense(); state.showGPTKLicense = true
                            }.buttonStyle(.link)
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).hbPanel()
                    Text(L("Switching may restart Windows setup and stop running programs in this environment. Save your game first."))
                        .font(.caption).foregroundStyle(.secondary)
                    let offered = state.offeredEngines(for: bottle)
                    VStack(alignment: .leading, spacing: 12) {
                        HB.eyebrow(L("Installed engines"))
                        ForEach(offered.filter { $0.installed || $0.missing }, id: \.id) { choice in
                            engineRow(choice, bottle: bottle)
                        }
                    }
                    if offered.contains(where: { !$0.installed && !$0.missing }) {
                        DisclosureGroup(L("Other engines to download")) {
                            VStack(spacing: 10) {
                                ForEach(offered.filter { !$0.installed && !$0.missing }, id: \.id) { choice in
                                    engineRow(choice, bottle: bottle)
                                }
                            }.padding(.top, 12)
                        }.font(.callout.weight(.medium))
                    }
                    Button { state.navigate(.environmentSettings(bottle.name)) } label: {
                        Label(L("Graphics & compatibility"), systemImage: "slider.horizontal.3")
                    }.buttonStyle(HBActionStyle())
                } else {
                    ContentUnavailableView {
                        Label(L("No environment yet"), systemImage: "square.stack.3d.up")
                    } description: {
                        Text(L("Create an environment to choose its engine."))
                    } actions: {
                        Button(L("New environment")) { state.navigate(.newEnvironment) }
                            .buttonStyle(HBActionStyle(primary: true)).disabled(state.busy)
                    }
                }
                if state.engineUpdate != nil {
                    Button(L("Update engine")) { state.updateEngine() }.buttonStyle(HBActionStyle(primary: true)).disabled(state.busy)
                }
            }.frame(maxWidth: 960, alignment: .leading).padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func engineRow(_ offered: EngineStore.OfferedEngine, bottle: Bottle) -> some View {
        HStack(spacing: 12) {
            Image(systemName: offered.id == bottle.settings.engineID ? "checkmark.circle.fill" : "shippingbox")
                .foregroundStyle(offered.id == bottle.settings.engineID ? HB.good : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(engineTitle(offered)).font(.system(size: 15, weight: .semibold))
                Text(offered.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Text(offered.missing ? L("Missing") : offered.installed ? L("Installed") : L("Downloads when selected"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if offered.id == bottle.settings.engineID {
                Text(L("Active")).font(.caption.weight(.medium)).foregroundStyle(HB.good)
            } else {
                Button(offered.installed ? L("Switch") : L("Download & switch")) {
                    state.moveBottle(bottle, toEngineID: offered.id)
                }.buttonStyle(HBActionStyle()).disabled(state.busy || offered.missing)
            }
        }.padding(20).hbPanel(radius: 20)
    }

    private func engineTitle(_ offered: EngineStore.OfferedEngine) -> String {
        state.engines.first(where: { $0.id == offered.id })?.displayName
            ?? AppState.knownManifests.first(where: { $0.id == offered.id })?.displayName
            ?? offered.id
    }
}

struct StoragePane: View {
    @Environment(AppState.self) private var state
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsHeading(title: L("Storage"), subtitle: L("Keep your games, environments and engines together, on the drive that suits you."))
                VStack(alignment: .leading, spacing: 16) {
                    Label(L("Highball folder"), systemImage: "folder").font(.headline)
                    Text(state.paths.home.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { locationActions }
                        VStack(alignment: .leading, spacing: 12) { locationActions }
                    }
                    Text(L("Changing location moves your data and relaunches Highball after the copy is verified."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).hbPanel()
                VStack(alignment: .leading, spacing: 12) {
                    HB.eyebrow(L("Environments"))
                    ForEach(state.bottles, id: \.name) { bottle in
                        HStack {
                            Label(bottle.name, systemImage: "square.stack.3d.up")
                            Spacer()
                            Button(L("Show the Windows drive")) { NSWorkspace.shared.open(bottle.driveC) }.buttonStyle(HBActionStyle())
                        }.padding(16).hbPanel(radius: 14)
                    }
                }
            }.frame(maxWidth: 960, alignment: .leading).padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private var locationActions: some View {
        Button(L("Show in Finder")) { NSWorkspace.shared.open(state.paths.home) }
            .buttonStyle(HBActionStyle())
        Button(L("Change location…")) { state.chooseHome() }
            .buttonStyle(HBActionStyle()).disabled(state.busy)
        if HighballPaths.configuredHome() != nil {
            Button(L("Use default location")) { state.useDefaultHome() }
                .buttonStyle(HBActionStyle()).disabled(state.busy)
        }
    }

}

struct UpdatesPane: View {
    @Environment(AppState.self) private var state
    @AppStorage(UpdateChannels.betaDefaultsKey) private var betaUpdates = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsHeading(title: L("Updates"), subtitle: L("Keep Highball up to date. Choose stable releases or try new features early."))
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        HighballMark(size: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Highball").font(.headline)
                            Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let delegate = NSApp.delegate as? AppDelegate {
                            CheckForUpdatesView(updater: delegate.updaterController.updater)
                                .buttonStyle(HBActionStyle())
                        }
                    }
                    Divider()
                    Toggle(L("Get beta builds"), isOn: $betaUpdates).toggleStyle(.switch)
                        .onChange(of: betaUpdates) { _, on in
                            if on { (NSApp.delegate as? AppDelegate)?.updaterController.updater.checkForUpdatesInBackground() }
                        }
                    Text(L("Beta releases arrive early and are less tested. Turning this off keeps your current build until a newer stable release is available."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20).hbPanel()
                if let update = state.engineUpdate {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(L("A newer engine is available"), systemImage: "gearshape.2").font(.headline)
                        Text(update.id).font(.caption).foregroundStyle(.secondary)
                        Button(L("Update engine")) { state.updateEngine() }.buttonStyle(HBActionStyle(primary: true)).disabled(state.busy)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).hbPanel()
                }
            }.frame(maxWidth: 960, alignment: .leading).padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TroubleshootingPane: View {
    @Environment(AppState.self) private var state
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsHeading(title: L("Troubleshooting"), subtitle: L("Find a log, restart a stuck environment or get help with a game."))
                VStack(alignment: .leading, spacing: 16) {
                    Label(L("Logs & support"), systemImage: "doc.text.magnifyingglass").font(.headline)
                    Text(L("Your last launch log helps explain what happened. You can review it before reporting a problem."))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button(L("Show the logs folder")) { NSWorkspace.shared.open(state.paths.logs) }.buttonStyle(HBActionStyle())
                        Button(L("Last background task")) { state.showLog = true }.buttonStyle(HBActionStyle())
                    }
                    Button(L("Report a problem…")) {
                        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
                        Task.detached {
                            let url = BugReport.url(version: version)
                            await MainActor.run { NSWorkspace.shared.open(url) }
                        }
                    }.buttonStyle(.link)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).hbPanel()
                VStack(alignment: .leading, spacing: 12) {
                    HB.eyebrow(L("Recovery"))
                    ForEach(state.bottles, id: \.name) { bottle in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(bottle.name).font(.headline)
                            Text(L("Stop stuck programs or re-run Windows setup. Repair keeps games and Steam installed."))
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button(L("Stop all processes")) { state.killBottle(bottle) }.buttonStyle(HBActionStyle()).disabled(state.busy)
                                Button(L("Repair environment")) { state.repairBottle(bottle) }.buttonStyle(HBActionStyle()).disabled(state.busy)
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).hbPanel()
                    }
                }
            }.frame(maxWidth: 960, alignment: .leading).padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
