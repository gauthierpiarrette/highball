import HighballKit
import SwiftUI

// MARK: - Design tokens

enum HB {
    static let amber = Color(red: 0.86, green: 0.62, blue: 0.28)
    static let amberDeep = Color(red: 0.63, green: 0.40, blue: 0.11)
    static let ground = Color(red: 0.086, green: 0.070, blue: 0.048)
    static let card = Color.white.opacity(0.055)
    static let cardStroke = Color.white.opacity(0.08)
    static let good = Color(red: 0.45, green: 0.78, blue: 0.60)
    static let warn = amber
    static let bad = Color(red: 0.88, green: 0.48, blue: 0.48)

    static func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(1.4)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Bottle screen

struct BottleView: View {
    @Environment(AppState.self) private var state
    let bottle: Bottle

    static let launcherMeta: [(id: String, symbol: String, short: String)] = [
        ("steam", "gamecontroller.fill", "Steam"), ("epic-games", "e.circle.fill", "Epic Games"),
        ("battle-net", "shield.fill", "Battle.net"), ("gog-galaxy", "g.circle.fill", "GOG Galaxy"),
        ("ea-app", "e.square.fill", "EA app"), ("ubisoft-connect", "u.circle.fill", "Ubisoft"),
        ("rockstar", "r.circle.fill", "Rockstar"),
    ]

    @State private var droppedURL: URL?
    @State private var showSettings = false

    private var engine: InstalledEngine? { state.engine(for: bottle) }
    private var games: [SteamGame] {
        (state.gamesByBottle[bottle.name] ?? []).sorted { a, b in
            let va = state.gameDB[a.appid]?.status == "verified-local"
            let vb = state.gameDB[b.appid]?.status == "verified-local"
            if va != vb { return va }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
    /// Pins that aren't one of the known launchers (dropped .exe files, custom programs).
    private var customPins: [Pin] {
        let launcherNames = ["steam", "epic games", "battle.net", "gog galaxy", "ea app", "ubisoft connect", "rockstar launcher", "rockstar"]
        return bottle.settings.pins.filter { !launcherNames.contains($0.name.lowercased()) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                // Long operations used to be invisible unless the log sheet was open — the
                // Steam first-update looked frozen for 15-25 min. Surface the stage inline.
                if state.busy && !state.stage.isEmpty && !state.showLog {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text(state.stage).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(HB.card.opacity(0.8)))
                }
                gamesSection
                launchersSection
                if !customPins.isEmpty { programsSection }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BottleBackdrop())
        .navigationTitle(bottle.name)
        .navigationSubtitle(engine?.displayName ?? "")
        .toolbar {
            ToolbarItemGroup {
                if state.busy { ProgressView().controlSize(.small) }
                Button { showSettings = true } label: { Label(L("Bottle settings"), systemImage: "slider.horizontal.3") }
                    .help(L("Renderer, synchronization, Windows version…"))
                Menu {
                    Button(L("Open C: drive")) { NSWorkspace.shared.open(bottle.driveC) }
                    Button(L("Stop all processes")) { state.killBottle(bottle) }
                } label: { Label(L("More"), systemImage: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showSettings) { BottleSettingsSheet(bottle: bottle) }
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
    }

    // MARK: Games

    @ViewBuilder private var gamesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HB.eyebrow(L("Games"))
                if !games.isEmpty {
                    Text("\(games.count)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            if games.isEmpty {
                EmptyGamesCard(steamInstalled: SteamLibrary.steamRoot(of: bottle) != nil) {
                    if let pin = bottle.settings.pins.first(where: { $0.name.lowercased() == "steam" }) {
                        state.launch(pin: pin, in: bottle)
                    } else {
                        state.applyRecipe("steam", to: bottle)
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 16)], spacing: 16) {
                    ForEach(games) { game in
                        GameCard(game: game, entry: state.gameDB[game.appid], busy: state.busy) {
                            state.launchGame(game, in: bottle)
                        }
                    }
                }
            }
        }
    }

    // MARK: Launchers

    private var launchersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HB.eyebrow(L("Launchers"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 140), spacing: 12)], spacing: 12) {
                ForEach(Self.launcherMeta, id: \.id) { meta in
                    if AppState.recipe(meta.id) != nil {
                        let installed = bottle.settings.recipes.contains(meta.id)
                        let pin = bottle.settings.pins.first { $0.name.lowercased().hasPrefix(meta.short.lowercased().prefix(5)) }
                        LauncherTile(title: meta.short, symbol: meta.symbol, installed: installed, busy: state.busy) {
                            if installed, let pin { state.launch(pin: pin, in: bottle) }
                            else { state.applyRecipe(meta.id, to: bottle) }
                        }
                        .contextMenu {
                            if installed, let pin {
                                Button(L("Open")) { state.launch(pin: pin, in: bottle) }
                                Button(L("Remove from list"), role: .destructive) { state.removePin(pin, from: bottle) }
                            }
                        }
                    }
                }
            }
            Text(L("Kernel anti-cheat titles (Valorant, Fortnite, Destiny 2…) can’t work through Wine — check the compatibility database before big downloads."))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    // MARK: Custom programs

    private var programsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HB.eyebrow(L("Programs"))
            VStack(spacing: 1) {
                ForEach(customPins) { pin in
                    HStack {
                        Image(systemName: "app.dashed").foregroundStyle(.secondary)
                        Text(pin.name)
                        if let r = pin.renderer { RendererBadge(renderer: r) }
                        Spacer()
                        Button(L("Run")) { state.launch(pin: pin, in: bottle) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(state.busy)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(HB.card)
                    .help(pin.path)
                    .contextMenu {
                        Menu(L("Renderer override")) {
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
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(HB.cardStroke))
        }
    }
}

/// Subtle warm wash so the surface reads as Highball's, not a system window.
struct BottleBackdrop: View {
    var body: some View {
        ZStack {
            HB.ground
            RadialGradient(colors: [HB.amber.opacity(0.09), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 720)
            RadialGradient(colors: [HB.amberDeep.opacity(0.06), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 900)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Game card: artwork-first, Play on hover

struct GameCard: View {
    let game: SteamGame
    let entry: GameDBEntry?
    let busy: Bool
    let play: () -> Void
    @State private var hovering = false

    private var verdict: (String, Color)? {
        switch entry?.status {
        case "verified-local": return (L("Verified"), HB.good)
        case "reported-upstream": return (L("Reported"), Color(red: 0.55, green: 0.70, blue: 0.90))
        case "community": return (L("Community"), HB.warn)
        case "blocked-anticheat": return (L("Blocked"), HB.bad)
        default: return nil
        }
    }
    private var blocked: Bool { entry?.isBlocked == true }
    private var playable: Bool { game.isReady && !blocked && !busy }

    var body: some View {
        Button(action: { if playable { play() } }) {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .aspectRatio(460 / 215, contentMode: .fit)
                    .overlay(
                        AsyncImage(url: game.headerImage) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                ZStack {
                                    LinearGradient(colors: [HB.card, HB.ground], startPoint: .top, endPoint: .bottom)
                                    Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(.quaternary)
                                }
                            }
                        }
                        .saturation(blocked ? 0.15 : 1)
                    )
                    .clipped()

                LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.35), .clear],
                               startPoint: .bottom, endPoint: .center)

                VStack(alignment: .leading, spacing: 5) {
                    Text(game.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(radius: 4)
                    HStack(spacing: 7) {
                        if let (label, color) = verdict {
                            Text(label)
                                .font(.system(size: 9.5, weight: .semibold).monospaced())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(color.opacity(0.22)))
                                .overlay(Capsule().stroke(color.opacity(0.8), lineWidth: 1))
                                .foregroundStyle(color)
                        }
                        if let r = entry?.renderer {
                            Text(r.rawValue.uppercased())
                                .font(.system(size: 9.5, weight: .medium).monospaced())
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        if blocked {
                            Text(entry?.anticheat?.names.first ?? "anti-cheat")
                                .font(.system(size: 9.5).monospaced())
                                .foregroundStyle(HB.bad.opacity(0.9))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(12)

                if hovering && playable {
                    ZStack {
                        Color.black.opacity(0.25)
                        ZStack {
                            Circle().fill(HB.amber)
                                .frame(width: 52, height: 52)
                                .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
                            Image(systemName: "play.fill")
                                .font(.system(size: 21, weight: .bold))
                                .foregroundStyle(Color(red: 0.13, green: 0.08, blue: 0.01))
                                .offset(x: 1.5)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(hovering ? HB.amber.opacity(0.55) : HB.cardStroke, lineWidth: 1))
            .scaleEffect(hovering && playable ? 1.02 : 1)
            .shadow(color: .black.opacity(hovering ? 0.45 : 0.25), radius: hovering ? 14 : 7, y: 4)
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.22), value: hovering)
        .onHover { hovering = $0 }
        .help(entry?.notes ?? game.name)
        .accessibilityLabel("\(game.name), \(verdict?.0 ?? "")")
    }
}

struct EmptyGamesCard: View {
    let steamInstalled: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 30))
                .foregroundStyle(HB.amber.opacity(0.8))
            Text(steamInstalled ? L("Your games will appear here") : L("Pour your first game"))
                .font(.system(size: 17, weight: .bold, design: .rounded))
            Text(steamInstalled
                 ? L("Install games inside Steam — they show up with artwork and a compatibility verdict.")
                 : L("Install Steam in this bottle to start playing your Windows library."))
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button(steamInstalled ? L("Open Steam") : L("Install Steam")) { action() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .background(RoundedRectangle(cornerRadius: 14).fill(HB.card))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
            .foregroundStyle(HB.cardStroke))
    }
}

struct LauncherTile: View {
    let title: String
    let symbol: String
    let installed: Bool
    let busy: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        Circle()
                            .fill(installed
                                  ? AnyShapeStyle(LinearGradient(colors: [HB.amber, HB.amberDeep], startPoint: .top, endPoint: .bottom))
                                  : AnyShapeStyle(HB.card))
                            .frame(width: 44, height: 44)
                        Image(systemName: symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(installed ? Color(red: 0.14, green: 0.09, blue: 0.02) : .secondary)
                    }
                    if !installed {
                        ZStack {
                            Circle().fill(HB.ground).frame(width: 17, height: 17)
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(HB.amber)
                        }
                        .offset(x: 3, y: 3)
                    }
                }
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Text(installed ? L("Open") : L("Install"))
                    .font(.system(size: 9.5).monospaced())
                    .foregroundStyle(installed ? AnyShapeStyle(HB.good) : AnyShapeStyle(.tertiary))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 11).fill(hovering ? Color.white.opacity(0.09) : HB.card))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(hovering ? HB.amber.opacity(0.4) : HB.cardStroke))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
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

// MARK: - Settings sheet (the Form belongs here, not on the main surface)

struct BottleSettingsSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let bottle: Bottle
    @State private var confirmDelete = false

    private var engine: InstalledEngine? { state.engine(for: bottle) }
    private var d3dmetalAvailable: Bool { engine?.rendererDir("d3dmetal") != nil }
    private var d3dmetalPossible: Bool {
        guard let engine else { return false }
        return FileManager.default.fileExists(atPath: engine.frameworksDir.appending(path: "renderer/d3dmetal/wine").path)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(bottle.name).font(.title3.bold())
                Text(engine?.displayName ?? "").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            Form {
                Section(L("Graphics")) {
                    Picker(L("Renderer"), selection: binding(\.renderer)) {
                        Text(L("DXMT — D3D10/11 → Metal (default)")).tag(Renderer.dxmt)
                        if d3dmetalAvailable { Text(L("D3DMetal — D3D11/12, Apple")).tag(Renderer.d3dmetal) }
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
                    Toggle(L("Metal performance HUD"), isOn: binding(\.metalHUD))
                    Toggle(L("DXVK async shader compilation (less stutter)"), isOn: binding(\.dxvkAsync))
                    Picker(L("Frame rate cap"), selection: binding(\.fpsCap)) {
                        Text(L("Uncapped")).tag(0)
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                        Text("120 fps").tag(120)
                    }
                    Toggle(L("Retina mode (native resolution)"), isOn: retinaBinding)
                    Text(L("Crisper text and UI at your display's full resolution. Heavy games may run slower — pair with the frame rate cap."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L("Compatibility")) {
                    Picker(L("Synchronization"), selection: binding(\.sync)) {
                        Text(L("msync — fastest for most games")).tag(SyncMode.msync)
                        Text(L("None — required for Steam/CEF launchers")).tag(SyncMode.none)
                        Text("esync").tag(SyncMode.esync)
                    }
                    Picker(L("Windows version"), selection: binding(\.windowsVersion)) {
                        ForEach(WindowsVersion.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle(L("Advertise AVX to games (Rosetta)"), isOn: binding(\.advertiseAVX))
                    Text(L("Games run with the bottle’s sync (msync is fastest). Opening the Steam window restarts Windows processes with sync off — its interface needs it."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                let tweaks = AppState.tweakRecipes()
                if !tweaks.isEmpty {
                    Section(L("Dependencies")) {
                        ForEach(tweaks, id: \.id) { r in
                            HStack {
                                Text(r.title)
                                Spacer()
                                if (state.bottles.first { $0.name == bottle.name } ?? bottle).settings.recipes.contains(r.id) {
                                    Label(L("Installed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
                                } else {
                                    Button(L("Install")) {
                                        state.applyRecipe(r.id, to: state.bottles.first { $0.name == bottle.name } ?? bottle)
                                    }.controlSize(.small)
                                }
                            }
                        }
                        Text(L("Windows runtimes some games need. Install them when a game complains about a missing runtime or refuses to start."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(L("Delete bottle…"), role: .destructive) { confirmDelete = true }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 560)
        .confirmationDialog(L("Delete this bottle? Its Windows drive and everything installed in it are removed."),
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) { dismiss(); state.deleteBottle(bottle.name) }
            Button(L("Cancel"), role: .cancel) {}
        }
    }

    private var retinaBinding: Binding<Bool> {
        Binding(
            get: { (state.bottles.first { $0.name == bottle.name } ?? bottle).settings.retinaMode },
            set: { on in state.setRetina(on, in: state.bottles.first { $0.name == bottle.name } ?? bottle) })
    }

    private func binding<T>(_ keyPath: WritableKeyPath<BottleSettings, T>) -> Binding<T> {
        Binding(
            get: { (state.bottles.first { $0.name == bottle.name } ?? bottle).settings[keyPath: keyPath] },
            set: { newValue in
                var copy = state.bottles.first { $0.name == bottle.name } ?? bottle
                copy.settings[keyPath: keyPath] = newValue
                Task { @MainActor in state.update(copy) }
            })
    }
}

// MARK: - Onboarding & license sheet

struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @State private var acceptGPTK = false

    var body: some View {
        ZStack {
            BottleBackdrop()
            VStack(spacing: 18) {
                if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"), let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().frame(width: 104, height: 104)
                        .shadow(color: HB.amber.opacity(0.35), radius: 18, y: 6)
                } else {
                    Image(systemName: "wineglass.fill").font(.system(size: 52)).foregroundStyle(.tint)
                }
                Text("Highball").font(.system(size: 36, weight: .heavy, design: .rounded))
                Text(L("Run Windows games on your Mac. Highball downloads a verified Wine engine (~500 MB) from public upstream releases — nothing is hosted by Highball itself."))
                    .multilineTextAlignment(.center).frame(maxWidth: 440).foregroundStyle(.secondary)

                if !state.rosettaInstalled {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(L("Rosetta 2 is required"), systemImage: "exclamationmark.triangle")
                            Text("softwareupdate --install-rosetta --agree-to-license").font(.caption.monospaced())
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
                    Text(state.busy ? L("Installing…") : L("Install engine")).frame(minWidth: 190)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state.busy || !state.rosettaInstalled)

                Text(L("Wine LGPL · DXMT MIT · DXVK Zlib · engine builds by Gcenx / Sikarugir — consider sponsoring them."))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(40)
        }
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
