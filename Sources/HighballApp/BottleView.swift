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

    // epic-games is deliberately absent: its installer cannot pass its permission audit
    // under Wine (issue #14) — the Epic path is "Connect Epic account" (Legendary) below,
    // and showing an "Install Epic Games" tile above it contradicted that.
    static let launcherMeta: [(id: String, symbol: String, short: String)] = [
        ("steam", "gamecontroller.fill", "Steam"),
        ("battle-net", "shield.fill", "Battle.net"), ("gog-galaxy", "g.circle.fill", "GOG Galaxy"),
        ("ea-app", "e.square.fill", "EA app"), ("ubisoft-connect", "u.circle.fill", "Ubisoft"),
        ("rockstar", "r.circle.fill", "Rockstar"),
    ]

    @State private var showSettings = false
    @State private var editingPin: Pin?

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
                epicSection
                HStack(spacing: 6) {
                    Button { state.chooseProgramToRun() } label: {
                        Label(L("Run a Windows program…"), systemImage: "folder")
                    }.buttonStyle(.link)
                    Text(L("— or drop any .exe or .msi on this window")).font(.caption).foregroundStyle(.secondary)
                }
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
        .sheet(item: $editingPin) { p in PinSettingsSheet(pin: p, bottle: bottle) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                if ["exe", "msi", "bat"].contains(url.pathExtension.lowercased()) {
                    Task { @MainActor in state.pendingRun = url }
                } else {
                    // Silently ignoring a drop reads as "nothing happened" (Reddit report) — say why.
                    Task { @MainActor in
                        state.errorMessage = String(format: L("'%@' isn't a Windows program. You can drop .exe, .msi or .bat files here."), url.lastPathComponent)
                    }
                }
            }
            return true
        }
        .confirmationDialog("Run \(state.pendingRun?.lastPathComponent ?? "") in this bottle?",
                            isPresented: .init(get: { state.pendingRun != nil }, set: { if !$0 { state.pendingRun = nil } }),
                            titleVisibility: .visible) {
            Button(L("Run")) { if let u = state.pendingRun { state.runDropped(u, in: bottle, andPin: false) }; state.pendingRun = nil }
            Button(L("Run and add to Programs")) { if let u = state.pendingRun { state.runDropped(u, in: bottle, andPin: true) }; state.pendingRun = nil }
            Button(L("Cancel"), role: .cancel) { state.pendingRun = nil }
        }
    }

    // MARK: Epic

    @ViewBuilder private var epicSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HB.eyebrow(L("Epic Games"))
                if state.epicSignedIn {
                    Text("\(state.epicOwned.count)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
            }
            if !state.epicSignedIn {
                HStack(spacing: 10) {
                    Button(L("Connect Epic account…")) { state.showEpicSignIn = true }
                    Text(L("Installs go through the open source Legendary client, so the Epic launcher's broken install flow is never involved."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if state.epicLoading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("Loading your Epic library…")).font(.callout).foregroundStyle(.secondary) }
            } else if state.epicOwned.isEmpty {
                Text(L("No games on this Epic account yet. Claimed games appear here."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                // Same card component and grid metrics as the Steam section: one visual
                // language for games, whatever the store (library unification Phase 1).
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 16)], spacing: 16) {
                    ForEach(state.epicOwned, id: \.app_name) { g in
                        let installed = state.epicInstalled(g.app_name, in: bottle)
                        GameCard(model: GameCardModel(title: g.app_title, artwork: g.artworkWide,
                                                      entry: nil, installed: installed),
                                 busy: state.busy,
                                 play: { state.epicPlay(g, in: bottle) },
                                 install: { state.epicInstall(g, in: bottle) })
                        .contextMenu {
                            if installed {
                                ForEach(HighballKit.Renderer.allCases, id: \.self) { r in
                                    Button(String(format: L("Play with %@"), r.rawValue.uppercased())) {
                                        state.epicPlay(g, in: bottle, renderer: r)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { state.showEpicSignIn }, set: { state.showEpicSignIn = $0 })) {
            EpicSignInSheet()
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
                        GameCard(model: GameCardModel(title: game.name, artwork: game.headerImage,
                                                      entry: state.gameDB[game.appid], installed: game.isReady),
                                 busy: state.busy) {
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
                    if let recipe = AppState.recipe(meta.id) {
                        let installed = bottle.settings.recipes.contains(meta.id)
                        let pin = bottle.settings.pins.first { $0.name.lowercased().hasPrefix(meta.short.lowercased().prefix(5)) }
                        LauncherTile(title: meta.short, symbol: meta.symbol, installed: installed, busy: state.busy,
                                     blockedReason: recipe.blocked?.reason, flakyReason: recipe.flaky?.reason) {
                            if installed, let pin { state.launch(pin: pin, in: bottle) }
                            else { state.applyRecipe(meta.id, to: bottle) }
                        }
                        .contextMenu {
                            if installed, let pin {
                                Button(L("Open")) { state.launch(pin: pin, in: bottle) }
                                Button(L("Program settings…")) { editingPin = pin }
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
                        Button(L("Program settings…")) { editingPin = pin }
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

/// Source-neutral input for GameCard: one card component for every store, same geometry,
/// same affordances (library unification Phase 1 — Steam and Epic stop speaking different
/// visual languages on the same screen).
struct GameCardModel {
    var title: String
    var artwork: URL?
    var entry: GameDBEntry?
    /// Installed in the current bottle. False shows the card dimmed with an install
    /// affordance (when `install` is provided) instead of Play.
    var installed: Bool
}

struct GameCard: View {
    let model: GameCardModel
    let busy: Bool
    let play: () -> Void
    var install: (() -> Void)? = nil
    @State private var hovering = false

    private var verdict: (String, Color)? {
        switch model.entry?.status {
        case "verified-local": return (L("Verified"), HB.good)
        case "reported-upstream": return (L("Reported"), Color(red: 0.55, green: 0.70, blue: 0.90))
        case "community": return (L("Community"), HB.warn)
        case "blocked-anticheat": return (L("Blocked"), HB.bad)
        default: return nil
        }
    }
    private var blocked: Bool { model.entry?.isBlocked == true }
    private var playable: Bool { model.installed && !blocked && !busy }
    private var installable: Bool { !model.installed && install != nil && !blocked && !busy }

    var body: some View {
        Button(action: { if playable { play() } else if installable { install?() } }) {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .aspectRatio(460 / 215, contentMode: .fit)
                    .overlay(
                        AsyncImage(url: model.artwork) { phase in
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
                        .saturation(blocked ? 0.15 : (model.installed ? 1 : 0.45))
                        .brightness(model.installed ? 0 : -0.08)
                    )
                    .clipped()

                LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.35), .clear],
                               startPoint: .bottom, endPoint: .center)

                VStack(alignment: .leading, spacing: 5) {
                    Text(model.title)
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
                        if let r = model.entry?.renderer {
                            Text(r.rawValue.uppercased())
                                .font(.system(size: 9.5, weight: .medium).monospaced())
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        if blocked {
                            Text(model.entry?.anticheat?.names.first ?? "anti-cheat")
                                .font(.system(size: 9.5).monospaced())
                                .foregroundStyle(HB.bad.opacity(0.9))
                                .lineLimit(1)
                        }
                        if installable {
                            Text(L("Not installed"))
                                .font(.system(size: 9.5).monospaced())
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .padding(12)

                if hovering && (playable || installable) {
                    ZStack {
                        Color.black.opacity(0.25)
                        ZStack {
                            Circle().fill(playable ? HB.amber : Color.white.opacity(0.88))
                                .frame(width: 52, height: 52)
                                .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
                            Image(systemName: playable ? "play.fill" : "arrow.down")
                                .font(.system(size: 21, weight: .bold))
                                .foregroundStyle(Color(red: 0.13, green: 0.08, blue: 0.01))
                                .offset(x: playable ? 1.5 : 0)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(hovering ? HB.amber.opacity(0.55) : HB.cardStroke, lineWidth: 1))
            .scaleEffect(hovering && (playable || installable) ? 1.02 : 1)
            .shadow(color: .black.opacity(hovering ? 0.45 : 0.25), radius: hovering ? 14 : 7, y: 4)
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.22), value: hovering)
        .onHover { hovering = $0 }
        .help(model.entry?.notes ?? model.title)
        .accessibilityLabel("\(model.title), \(verdict?.0 ?? (model.installed ? "" : L("Not installed")))")
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
    var blockedReason: String? = nil
    var flakyReason: String? = nil
    let action: () -> Void
    @State private var hovering = false

    private var blocked: Bool { blockedReason != nil && !installed }
    private var flaky: Bool { flakyReason != nil && !installed && !blocked }

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
                Text(installed ? L("Open") : (blocked ? L("Blocked") : (flaky ? L("Flaky") : L("Install"))))
                    .font(.system(size: 9.5).monospaced())
                    .foregroundStyle(installed ? AnyShapeStyle(HB.good)
                                     : (blocked ? AnyShapeStyle(HB.bad.opacity(0.85))
                                        : (flaky ? AnyShapeStyle(HB.amber) : AnyShapeStyle(.tertiary))))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 11).fill(hovering && !blocked ? Color.white.opacity(0.09) : HB.card))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(hovering && !blocked ? HB.amber.opacity(0.4) : HB.cardStroke))
            .opacity(blocked ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busy || blocked)
        .help(blockedReason.map { L("Blocked on the current engine: ") + $0 }
              ?? flakyReason.map { L("Known issues: ") + $0 } ?? "")
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
    /// Live slider value while dragging; nil means "read the saved dpiScale". Applied on release
    /// only, so dragging doesn't fire a wine registry write on every step.
    @State private var dpiDraft: Double? = nil

    private var currentDpi: Int { (state.bottles.first { $0.name == bottle.name } ?? bottle).settings.dpiScale }
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
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L("Display scaling"))
                            Spacer()
                            Text("\(Int(((dpiDraft ?? Double(currentDpi)) / 96 * 100).rounded()))%")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(
                            value: Binding(get: { dpiDraft ?? Double(currentDpi) }, set: { dpiDraft = $0 }),
                            in: 96...240, step: 24,
                            onEditingChanged: { editing in
                                if !editing, let v = dpiDraft {
                                    state.setDpi(Int(v.rounded()), in: state.bottles.first { $0.name == bottle.name } ?? bottle)
                                    dpiDraft = nil
                                }
                            })
                    }
                    Text(L("Scales the Windows desktop and UI, 100% to 250%. Launchers and desktop apps follow it; many full-screen games set their own resolution and won't. Above 100% uses native Retina pixels, so heavy games may run slower."))
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
                Section(L("Advanced")) {
                    TextField(L("DLL overrides"), text: binding(\.dllOverrides), prompt: Text(verbatim: "version=n,b;winmm=n,b"))
                        .font(.body.monospaced())
                    Text(L("Extra Wine DLL overrides for this bottle, semicolon separated. Mods like Cyber Engine Tweaks need version=n,b."))
                        .font(.caption).foregroundStyle(.secondary)
                    EnvEditor(bottle: bottle)
                    Text(L("Environment variables, one KEY=VALUE per line. Applied to everything launched in this bottle."))
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


struct EpicSignInSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Connect your Epic account")).font(.title2.bold())
            Text(L("1. Open Epic's sign-in page and log in.\n2. The page ends by showing an authorizationCode.\n3. Paste that code here."))
                .font(.callout).foregroundStyle(.secondary)
            Button(L("Open Epic sign-in page")) { NSWorkspace.shared.open(EpicStore.loginURL) }
            TextField(L("authorizationCode"), text: $code).textFieldStyle(.roundedBorder).frame(width: 340)
            Text(L("Your password never touches Highball. The code is single use and connects through Legendary, the open source Epic client the Heroic launcher uses."))
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 360, alignment: .leading)
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Button(L("Connect")) {
                    dismiss()
                    state.epicSignIn(code: code.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(code.trimmingCharacters(in: .whitespaces).count < 8)
            }
        }
        .padding(24)
    }
}


/// Per-program settings: launch arguments, environment, renderer override in one place.
struct PinSettingsSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let bottle: Bottle
    @State private var pin: Pin
    @State private var argsText: String
    @State private var envText: String

    init(pin: Pin, bottle: Bottle) {
        self.bottle = bottle
        _pin = State(initialValue: pin)
        _argsText = State(initialValue: ArgumentLine.join(pin.arguments))
        _envText = State(initialValue: pin.environment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(pin.name).font(.title2.bold())
            Text(pin.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Launch arguments")).font(.callout.weight(.medium))
                TextField(L("-dx11 -skiplauncher \"an argument with spaces\""), text: $argsText)
                    .textFieldStyle(.roundedBorder).font(.body.monospaced())
                Text(L("Passed to the program on every launch. Quote arguments that contain spaces."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Environment")).font(.callout.weight(.medium))
                TextEditor(text: $envText)
                    .font(.body.monospaced()).frame(height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text(L("One KEY=VALUE per line, applied only to this program."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker(L("Renderer"), selection: $pin.renderer) {
                Text(L("Bottle default")).tag(Renderer?.none)
                ForEach(Renderer.allCases, id: \.self) { r in
                    Text(r.rawValue.uppercased()).tag(Renderer?.some(r))
                }
            }
            .pickerStyle(.menu)
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Button(L("Save")) {
                    pin.arguments = ArgumentLine.split(argsText)
                    var env: [String: String] = [:]
                    for line in envText.split(separator: "\n") {
                        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                        if parts.count == 2, !parts[0].trimmingCharacters(in: .whitespaces).isEmpty {
                            env[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1]
                        }
                    }
                    pin.environment = env
                    state.updatePin(pin, in: bottle)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Bottle environment editor: one KEY=VALUE per line, saved on every keystroke batch.
struct EnvEditor: View {
    @Environment(AppState.self) private var state
    let bottle: Bottle
    @State private var text: String = ""
    @State private var loaded = false

    var body: some View {
        TextEditor(text: $text)
            .font(.body.monospaced())
            .frame(height: 72)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .onAppear {
                guard !loaded else { return }
                loaded = true
                let env = (state.bottles.first { $0.name == bottle.name } ?? bottle).settings.environment
                text = env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            }
            .onChange(of: text) { _, newValue in
                var env: [String: String] = [:]
                for line in newValue.split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2, !parts[0].trimmingCharacters(in: .whitespaces).isEmpty {
                        env[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1]
                    }
                }
                var copy = state.bottles.first { $0.name == bottle.name } ?? bottle
                copy.settings.environment = env
                state.update(copy)
            }
    }
}
