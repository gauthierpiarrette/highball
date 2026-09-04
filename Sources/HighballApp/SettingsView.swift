import SwiftUI
import HighballKit

/// Advanced is the Settings window (⌘,): environments live here and nowhere else (UX plan §3.7,
/// canvas "Advanced: Settings"). Nothing here is needed to play a game.
struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TabView {
            EnvironmentsPane().tabItem { Label(L("Environments"), systemImage: "cylinder.split.1x2") }
            EnginePane().tabItem { Label(L("Engine"), systemImage: "gearshape.2") }
            TroubleshootingPane().tabItem { Label(L("Troubleshooting"), systemImage: "wrench.and.screwdriver") }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

/// One environment by default, more only when two games need settings that conflict.
struct EnvironmentsPane: View {
    @Environment(AppState.self) private var state
    @State private var selectedName: String?
    @State private var openName: String?
    @State private var pendingDelete: String?
    @State private var showCreate = false

    private var selected: Bottle? {
        state.bottles.first { $0.name == selectedName } ?? state.defaultBottle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Highball keeps your games in one Windows environment and looks after it. A second one is only for a game whose settings conflict with the others."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 8) {
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
                            Button(L("Delete…"), role: .destructive) { pendingDelete = damaged.name }.controlSize(.small)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(HB.card))
                    }
                }
            }
            .frame(maxHeight: 170)
            if let bottle = selected { details(bottle) }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button(L("New environment…")) { showCreate = true }.disabled(state.busy)
                if let b = selected {
                    Button(L("Repair")) { state.repairBottle(b) }.disabled(state.busy)
                    Button(L("Full page…")) { openName = b.name }
                }
                Spacer()
                Text(L("Repair re-runs the Windows first boot. Games and Steam stay where they are."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .sheet(isPresented: .init(get: { openName != nil }, set: { if !$0 { openName = nil } })) {
            if let bottle = state.bottles.first(where: { $0.name == openName }) {
                NavigationStack {
                    BottleView(bottle: bottle)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { openName = nil } } }
                }
                .frame(minWidth: 820, minHeight: 620)
            }
        }
        .sheet(isPresented: $showCreate) { CreateBottleSheet() }
        .confirmationDialog("Delete environment \"\(pendingDelete ?? "")\"? This removes its Windows drive and everything installed in it, games included.",
                            isPresented: .init(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) { if let n = pendingDelete { state.deleteBottle(n) }; pendingDelete = nil }
            Button(L("Cancel"), role: .cancel) { pendingDelete = nil }
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
            selectedName = bottle.name
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "cylinder.split.1x2").foregroundStyle(isSelected ? HB.amber : .secondary)
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
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 10).fill(HB.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? HB.amber.opacity(0.6) : HB.cardStroke))
        .contextMenu {
            Button(L("Full page…")) { openName = bottle.name }
            Button(L("Stop all processes")) { state.killBottle(bottle) }
            Button(L("Duplicate")) { state.duplicateBottle(bottle) }
            Button(L("Repair (re-run the Windows first boot)")) { state.repairBottle(bottle) }
            Divider()
            Button(L("Delete…"), role: .destructive) { pendingDelete = bottle.name }
                .disabled(state.deletingBottles.contains(bottle.name))
        }
    }

    private func details(_ bottle: Bottle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row(L("Graphics mode")) { GraphicsModePicker(bottle: bottle) }
            Divider().padding(.vertical, 8)
            row(L("Windows components")) { WindowsComponentsRow(bottle: bottle) }
            Divider().padding(.vertical, 8)
            row(L("Files")) {
                Button(L("Show the Windows drive")) { NSWorkspace.shared.open(bottle.driveC) }
                    .buttonStyle(.link)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(HB.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(HB.cardStroke))
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label).font(.callout).frame(width: 150, alignment: .leading).padding(.top, 2)
            content()
            Spacer(minLength: 0)
        }
    }
}

struct EnginePane: View {
    @Environment(AppState.self) private var state
    @State private var showLicense = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("The engine is the Wine build and graphics layers Highball runs games with. Highball picks it; an update never moves an environment to a different Wine build on its own."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let engine = state.defaultEngine {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(engine.displayName).font(.headline)
                        Text(engine.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(String(format: L("Graphics layers: %@"), ["dxmt", "dxvk", "d3dmetal"].filter { engine.rendererDir($0) != nil }.map { GamePageCopy.plainName(Renderer(rawValue: $0) ?? .dxvk) }.joined(separator: ", ")))
                            .font(.caption).foregroundStyle(.secondary)
                        if engine.ships("d3dmetal"), engine.rendererDir("d3dmetal") == nil {
                            Button(L("Read Apple's licence and turn on DirectX 12 support…")) {
                                state.licenseEngine = engine; state.loadGPTKLicense(); showLicense = true
                            }.buttonStyle(.link).font(.caption)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let update = state.engineUpdate {
                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("A newer engine is available")).font(.headline)
                            Text(update.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Update engine")) { state.updateEngine() }.disabled(state.busy)
                    }
                }
            }
            if state.engines.count > 1 {
                Text(String(format: L("Installed engines: %@. An environment's engine is chosen on its own page."), state.engines.map(\.id).joined(separator: ", ")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .sheet(isPresented: $showLicense) { GPTKLicenseSheet() }
    }
}

struct TroubleshootingPane: View {
    @Environment(AppState.self) private var state
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("When a game misbehaves, the log of its last launch is what a report needs. Nothing here is sent anywhere without you."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(L("Show the logs folder")) { NSWorkspace.shared.open(state.paths.logs) }
                Button(L("Report a problem…")) {
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
                    Task.detached {
                        let url = BugReport.url(version: version)
                        await MainActor.run { NSWorkspace.shared.open(url) }
                    }
                }
                Button(L("Show the activity log")) { showLog = true }
            }
            if let b = state.defaultBottle {
                Divider()
                Text(String(format: L("If Steam or a game is stuck, stop the environment's processes; the next Play starts fresh. Environment: %@."), b.name))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("Stop all processes")) { state.killBottle(b) }.disabled(state.busy)
            }
            Spacer()
        }
        .padding(20)
        .sheet(isPresented: $showLog) { LogSheet() }
    }
}
