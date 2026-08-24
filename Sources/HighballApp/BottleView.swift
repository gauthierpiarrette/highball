import HighballKit
import SwiftUI

struct BottleView: View {
    @Environment(AppState.self) private var state
    let bottle: Bottle

    private var engine: InstalledEngine? { state.engine(for: bottle) }
    private var d3dmetalAvailable: Bool { engine?.rendererDir("d3dmetal") != nil }
    private var d3dmetalPossible: Bool {
        guard let engine else { return false }
        return FileManager.default.fileExists(atPath: engine.frameworksDir.appending(path: "renderer/d3dmetal/wine").path)
    }

    @State private var droppedURL: URL?

    var body: some View {
        Form {
            Section {
                header
            }
            gamesSection
            Section(L("Programs")) {
                if bottle.settings.pins.isEmpty {
                    Text(L("Nothing installed yet — add a launcher below.")).foregroundStyle(.secondary)
                }
                ForEach(bottle.settings.pins) { pin in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(pin.name)
                            Text(pin.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let r = pin.renderer { RendererBadge(renderer: r) }
                        Button(L("Run")) { state.launch(pin: pin, in: bottle) }
                            .disabled(state.busy)
                    }
                    .contextMenu {
                        Menu("Renderer override") {
                            Button(L("Bottle default")) { state.setPinRenderer(nil, pin: pin, in: bottle) }
                            ForEach(Renderer.allCases, id: \.self) { r in
                                Button(r.rawValue.uppercased()) { state.setPinRenderer(r, pin: pin, in: bottle) }
                            }
                        }
                        Divider()
                        Button(L("Remove from list"), role: .destructive) { state.removePin(pin, from: bottle) }
                    }
                }
            }
            Section(L("Install a launcher")) {
                HStack(spacing: 8) {
                    ForEach(AppState.launcherRecipes.filter { id in !bottle.settings.recipes.contains(id) }, id: \.self) { id in
                        if let recipe = AppState.recipe(id) {
                            Button(recipe.title) { state.applyRecipe(id, to: bottle) }
                                .disabled(state.busy)
                        }
                    }
                }
                Text(L("Kernel anti-cheat titles (Valorant, Fortnite, Destiny 2…) can’t work through Wine — check the compatibility database before big downloads."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Graphics & compatibility")) {
                settings
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Highball")
        .navigationSubtitle(bottle.name)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, ["exe", "msi", "bat"].contains(url.pathExtension.lowercased()) else { return }
                Task { @MainActor in droppedURL = url }
            }
            return true
        }
        .confirmationDialog("Run \(droppedURL?.lastPathComponent ?? "") in this bottle?",
                            isPresented: .init(get: { droppedURL != nil }, set: { if !$0 { droppedURL = nil } }),
                            titleVisibility: .visible) {
            Button(L("Run")) { if let u = droppedURL { state.runDropped(u, in: bottle, andPin: false) }; droppedURL = nil }
            Button(L("Run and add to Programs")) { if let u = droppedURL { state.runDropped(u, in: bottle, andPin: true) }; droppedURL = nil }
            Button(L("Cancel"), role: .cancel) { droppedURL = nil }
        }
        .toolbar {
            Button { state.killBottle(bottle) } label: { Label(L("Stop all"), systemImage: "stop.circle") }
                .help("Kill every Windows process in this bottle (wineserver -k)")
        }
    }

    @ViewBuilder private var gamesSection: some View {
        let games = state.gamesByBottle[bottle.name] ?? []
        if !games.isEmpty {
            Section(L("Games")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                    ForEach(games) { game in
                        GameCard(game: game, entry: state.gameDB[game.appid], busy: state.busy) {
                            state.launchGame(game, in: bottle)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "wineglass.fill").font(.largeTitle).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(bottle.name).font(.title2.bold())
                Text("engine \(bottle.settings.engineID)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Open C: drive")) { NSWorkspace.shared.open(bottle.driveC) }
        }
    }

    @ViewBuilder private var settings: some View {
        Picker(L("Renderer"), selection: binding(\.renderer)) {
            Text(L("DXMT — D3D10/11 → Metal (default)")).tag(Renderer.dxmt)
            if d3dmetalAvailable {
                Text(L("D3DMetal — D3D11/12, Apple")).tag(Renderer.d3dmetal)
            }
            Text(L("DXVK — D3D9/10/11 → Vulkan")).tag(Renderer.dxvk)
            Text(L("WineD3D — slow fallback")).tag(Renderer.wined3d)
        }
        if !d3dmetalAvailable && d3dmetalPossible {
            HStack {
                Text(L("D3DMetal (needed for DirectX 12) requires accepting Apple’s Game Porting Toolkit license."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Review license…")) {
                    Task { @MainActor in
                        state.loadGPTKLicense()
                        state.showGPTKLicense = true
                    }
                }.controlSize(.small)
            }
        }
        Picker(L("Synchronization"), selection: binding(\.sync)) {
            Text(L("None — required for Steam/CEF launchers")).tag(SyncMode.none)
            Text(L("msync — fastest for most games")).tag(SyncMode.msync)
            Text("esync").tag(SyncMode.esync)
        }
        Picker(L("Windows version"), selection: binding(\.windowsVersion)) {
            ForEach(WindowsVersion.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        Toggle(L("Metal performance HUD"), isOn: binding(\.metalHUD))
        Toggle(L("Advertise AVX to games (Rosetta)"), isOn: binding(\.advertiseAVX))
        Toggle(L("DXVK async shader compilation (less stutter)"), isOn: binding(\.dxvkAsync))
        Picker(L("Frame rate cap"), selection: binding(\.fpsCap)) {
            Text(L("Uncapped")).tag(0)
            Text("30 fps").tag(30)
            Text("60 fps").tag(60)
            Text("120 fps").tag(120)
        }
        Text(L("Games run with the bottle’s sync (msync is fastest). Opening the Steam window restarts Windows processes with sync off — its interface needs it."))
            .font(.caption).foregroundStyle(.secondary)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<BottleSettings, T>) -> Binding<T> {
        Binding(
            get: { bottle.settings[keyPath: keyPath] },
            set: { newValue in
                var copy = bottle
                copy.settings[keyPath: keyPath] = newValue
                Task { @MainActor in state.update(copy) }
            })
    }
}

struct GameCard: View {
    let game: SteamGame
    let entry: GameDBEntry?
    let busy: Bool
    let play: () -> Void

    private var statusLabel: (String, Color)? {
        switch entry?.status {
        case "verified-local": return ("Verified", .green)
        case "reported-upstream": return ("Reported", .blue)
        case "community": return ("Community", .orange)
        case "blocked-anticheat": return ("Blocked — anti-cheat", .red)
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: game.headerImage) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                default:
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "gamecontroller").font(.title).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(game.name).font(.callout.weight(.semibold)).lineLimit(1)
            HStack {
                if let (label, color) = statusLabel {
                    Text(label)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .foregroundStyle(color)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.6)))
                }
                if let r = entry?.renderer {
                    Text(r.rawValue.uppercased()).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Play")) { play() }
                    .controlSize(.small)
                    .disabled(busy || !game.isReady || entry?.isBlocked == true)
            }
            if entry?.isBlocked == true {
                Text(entry?.notes ?? "Kernel anti-cheat — cannot work under Wine.")
                    .font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
        .help(entry?.notes ?? game.name)
    }
}

struct RendererBadge: View {
    let renderer: Renderer
    var body: some View {
        Text(renderer.rawValue.uppercased())
            .font(.caption2.monospaced())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.6)))
    }
}

struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @State private var acceptGPTK = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "wineglass.fill").font(.system(size: 52)).foregroundStyle(.tint)
            Text("Highball").font(.system(size: 34, weight: .heavy, design: .rounded))
            Text(L("Run Windows games on your Mac. Highball downloads a verified Wine engine (~500 MB) from public upstream releases — nothing is hosted by Highball itself."))
                .multilineTextAlignment(.center).frame(maxWidth: 440).foregroundStyle(.secondary)

            if !state.rosettaInstalled {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(L("Rosetta 2 is required"), systemImage: "exclamationmark.triangle")
                        Text("Run in Terminal:  softwareupdate --install-rosetta --agree-to-license").font(.caption.monospaced())
                    }
                }.frame(maxWidth: 440)
            }

            Toggle(isOn: $acceptGPTK) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Enable D3DMetal (DirectX 12 support)"))
                    HStack(spacing: 4) {
                        Text(L("Requires accepting")).font(.caption).foregroundStyle(.secondary)
                        Button(L("Apple’s Game Porting Toolkit license")) {
                            Task { @MainActor in
                                state.loadGPTKLicense()
                                state.showGPTKLicense = true
                            }
                        }.buttonStyle(.link).font(.caption)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: 440, alignment: .leading)

            Button {
                state.installDefaultEngine(acceptGPTK: acceptGPTK)
            } label: {
                Text(state.busy ? L("Installing…") : L("Install engine"))
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(state.busy || !state.rosettaInstalled)

            Text("Wine LGPL · DXMT MIT · DXVK Zlib · engine builds by Gcenx / Sikarugir — consider sponsoring them.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(40)
    }
}

struct GPTKLicenseSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apple Game Porting Toolkit — Software License Agreement").font(.headline)
            ScrollView {
                Text(state.gptkLicenseText)
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(width: 640, height: 380)
            .background(.quaternary.opacity(0.4))
            HStack {
                Text(L("Non-commercial use only · no modification · Apple hardware only"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Close")) { dismiss() }
                if let engine = state.engines.first, engine.rendererDir("d3dmetal") == nil {
                    Button(L("Accept & enable D3DMetal")) {
                        state.acceptGPTK(engine: engine)
                        dismiss()
                    }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
    }
}
