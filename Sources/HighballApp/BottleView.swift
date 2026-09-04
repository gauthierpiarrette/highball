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
    /// Pins that aren't one of the known launchers (dropped .exe files, custom programs).
    /// The filter itself lives in the Kit so the unified library shares one definition.
    private var customPins: [Pin] {
        bottle.settings.pins.filter { !LibraryIndex.isLauncherPin($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                launchersSection
                if !customPins.isEmpty { programsSection }
                HStack(spacing: 6) {
                    Button { state.chooseProgramToRun(in: bottle.name) } label: {
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
                Button { showSettings = true } label: { Label(L("Environment settings"), systemImage: "slider.horizontal.3") }
                    .help(L("Renderer, synchronization, Windows version…"))
                Menu {
                    Button(L("Show the Windows drive")) { NSWorkspace.shared.open(bottle.driveC) }
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
                    Task { @MainActor in state.pendingRunBottle = bottle.name; state.pendingRun = url }
                } else {
                    // Silently ignoring a drop reads as "nothing happened" (Reddit report) — say why.
                    Task { @MainActor in
                        state.errorMessage = String(format: L("'%@' isn't a Windows program. You can drop .exe, .msi or .bat files here."), url.lastPathComponent)
                    }
                }
            }
            return true
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
                            Button(L("Environment default")) { state.setPinRenderer(nil, pin: pin, in: bottle) }
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

// MARK: - Tiles

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
                    // Not the generic binding: picking a renderer here is an explicit choice,
                    // which recipes must never clobber afterwards (#29).
                    Picker(L("Renderer"), selection: Binding(
                        get: { (state.bottles.first { $0.name == bottle.name } ?? bottle).settings.renderer },
                        set: { newValue in
                            var copy = state.bottles.first { $0.name == bottle.name } ?? bottle
                            copy.settings.renderer = newValue
                            copy.settings.rendererExplicit = true
                            Task { @MainActor in state.update(copy) }
                        })) {
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
                                    state.licenseEngine = engine
                                    state.loadGPTKLicense()
                                    state.showGPTKLicense = true
                                }
                            }.controlSize(.small)
                        }
                    }
                    Toggle(L("Metal performance HUD"), isOn: binding(\.metalHUD))
                    Toggle(L("DXVK async shader compilation (experimental — can skip draws while a shader compiles)"), isOn: binding(\.dxvkAsync))
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
                    Toggle(L("Use ⌘C / ⌘V inside Windows apps"), isOn: binding(\.commandIsControl))
                    Text(L("Maps the Command keys to Ctrl, so Mac copy and paste work in Steam and games. Option becomes Alt so Alt-based bindings keep working. Off = Wine's default, where Command acts as Alt."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L("Games run with the environment’s sync (msync is fastest). Opening the Steam window restarts Windows processes with sync off — its interface needs it."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L("Advanced")) {
                    let offered = state.offeredEngines(for: state.bottles.first { $0.name == bottle.name } ?? bottle)
                    if offered.count > 1 {
                        Picker(L("Engine"), selection: Binding(
                            get: { (state.bottles.first { $0.name == bottle.name } ?? bottle).settings.engineID },
                            set: { newID in
                                let current = state.bottles.first { $0.name == bottle.name } ?? bottle
                                guard newID != current.settings.engineID else { return }
                                dismiss()   // the move runs in the busy sheet; two sheets on one window do not stack
                                state.moveBottle(current, toEngineID: newID)
                            })) {
                            ForEach(offered, id: \.id) { e in
                                Text(verbatim: e.missing ? "\(e.id) (\(L("missing")))" : e.installed ? e.id : "\(e.id) (\(L("download")))").tag(e.id)
                            }
                        }
                        .disabled(state.busy)
                        Text(L("Environments never change engine on their own. Switching re-runs the Windows setup when the Wine build differs; switching back is the same step. An engine marked download is fetched first."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField(L("DLL overrides"), text: binding(\.dllOverrides), prompt: Text(verbatim: "version=n,b;winmm=n,b"))
                        .font(.body.monospaced())
                    Text(L("Extra Wine DLL overrides for this environment, semicolon separated. Mods like Cyber Engine Tweaks need version=n,b."))
                        .font(.caption).foregroundStyle(.secondary)
                    EnvEditor(bottle: bottle)
                    Text(L("Environment variables, one KEY=VALUE per line. Applied to everything launched in this environment."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                let tweaks = AppState.tweakRecipes()
                if !tweaks.isEmpty {
                    Section(L("Dependencies")) {
                        ForEach(tweaks, id: \.id) { r in
                            HStack {
                                Text(r.title)
                                Spacer()
                                let live = state.bottles.first { $0.name == bottle.name } ?? bottle
                                if live.settings.recipes.contains(r.id) || state.tweakIsInstalled(r, in: live) {
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
                    Button(L("Delete environment…"), role: .destructive) { confirmDelete = true }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 560)
        .confirmationDialog(L("Delete this environment? Its Windows drive and everything installed in it are removed."),
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
                Text(L("Play Windows games on your Mac."))
                    .font(.title3).foregroundStyle(.secondary)
                Button {
                    state.getStarted()
                } label: {
                    Text(state.busy ? L("Setting up…") : L("Get started")).frame(minWidth: 190)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(HB.amber)
                .disabled(state.busy)
                .padding(.top, 6)
                Text(state.rosettaInstalled
                     ? L("Nothing to choose. The download takes a few minutes on most connections.")
                     : L("Nothing to choose. Highball installs Rosetta for you, then the download takes a few minutes."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
                Spacer().frame(height: 30)
                Text(L("Highball downloads a Wine engine from public upstream releases. Nothing is hosted by us."))
                    .font(.caption).foregroundStyle(.tertiary)
                Text(L("Wine LGPL · DXMT MIT · DXVK Zlib · engine builds by Gcenx and Sikarugir"))
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
                if let engine = state.licenseEngine ?? state.defaultEngine ?? state.engines.first, engine.rendererDir("d3dmetal") == nil {
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
                Text(L("Environment default")).tag(Renderer?.none)
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
