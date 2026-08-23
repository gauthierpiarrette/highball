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

    var body: some View {
        Form {
            Section {
                header
            }
            Section("Programs") {
                if bottle.settings.pins.isEmpty {
                    Text("Nothing installed yet — add a launcher below.").foregroundStyle(.secondary)
                }
                ForEach(bottle.settings.pins) { pin in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(pin.name)
                            Text(pin.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let r = pin.renderer { RendererBadge(renderer: r) }
                        Button("Run") { state.launch(pin: pin, in: bottle) }
                            .disabled(state.busy)
                    }
                }
            }
            Section("Install a launcher") {
                HStack(spacing: 8) {
                    ForEach(AppState.launcherRecipes.filter { id in !bottle.settings.recipes.contains(id) }, id: \.self) { id in
                        if let recipe = AppState.recipe(id) {
                            Button(recipe.title) { state.applyRecipe(id, to: bottle) }
                                .disabled(state.busy)
                        }
                    }
                }
                Text("Kernel anti-cheat titles (Valorant, Fortnite, Destiny 2…) can’t work through Wine — check the compatibility database before big downloads.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Graphics & compatibility") {
                settings
            }
        }
        .formStyle(.grouped)
        .navigationTitle(bottle.name)
        .toolbar {
            Button { state.killBottle(bottle) } label: { Label("Stop all", systemImage: "stop.circle") }
                .help("Kill every Windows process in this bottle (wineserver -k)")
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
            Button("Open C: drive") { NSWorkspace.shared.open(bottle.driveC) }
        }
    }

    @ViewBuilder private var settings: some View {
        Picker("Renderer", selection: binding(\.renderer)) {
            Text("DXMT — D3D10/11 → Metal (default)").tag(Renderer.dxmt)
            if d3dmetalAvailable {
                Text("D3DMetal — D3D11/12, Apple").tag(Renderer.d3dmetal)
            }
            Text("DXVK — D3D9/10/11 → Vulkan").tag(Renderer.dxvk)
            Text("WineD3D — slow fallback").tag(Renderer.wined3d)
        }
        if !d3dmetalAvailable && d3dmetalPossible {
            HStack {
                Text("D3DMetal (needed for DirectX 12) requires accepting Apple’s Game Porting Toolkit license.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Review license…") {
                    state.loadGPTKLicense()
                    state.showGPTKLicense = true
                }.controlSize(.small)
            }
        }
        Picker("Synchronization", selection: binding(\.sync)) {
            Text("None — required for Steam/CEF launchers").tag(SyncMode.none)
            Text("msync — fastest for most games").tag(SyncMode.msync)
            Text("esync").tag(SyncMode.esync)
        }
        Picker("Windows version", selection: binding(\.windowsVersion)) {
            ForEach(WindowsVersion.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        Toggle("Metal performance HUD", isOn: binding(\.metalHUD))
        Toggle("Advertise AVX to games (Rosetta)", isOn: binding(\.advertiseAVX))
    }

    private func binding<T>(_ keyPath: WritableKeyPath<BottleSettings, T>) -> Binding<T> {
        Binding(
            get: { bottle.settings[keyPath: keyPath] },
            set: { newValue in
                var copy = bottle
                copy.settings[keyPath: keyPath] = newValue
                state.update(copy)
            })
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
            Text("Run Windows games on your Mac. Highball downloads a verified Wine engine (~500 MB) from public upstream releases — nothing is hosted by Highball itself.")
                .multilineTextAlignment(.center).frame(maxWidth: 440).foregroundStyle(.secondary)

            if !state.rosettaInstalled {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Rosetta 2 is required", systemImage: "exclamationmark.triangle")
                        Text("Run in Terminal:  softwareupdate --install-rosetta --agree-to-license").font(.caption.monospaced())
                    }
                }.frame(maxWidth: 440)
            }

            Toggle(isOn: $acceptGPTK) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable D3DMetal (DirectX 12 support)")
                    HStack(spacing: 4) {
                        Text("Requires accepting").font(.caption).foregroundStyle(.secondary)
                        Button("Apple’s Game Porting Toolkit license") {
                            state.loadGPTKLicense()
                            state.showGPTKLicense = true
                        }.buttonStyle(.link).font(.caption)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: 440, alignment: .leading)

            Button {
                state.installDefaultEngine(acceptGPTK: acceptGPTK)
            } label: {
                Text(state.busy ? "Installing…" : "Install engine")
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
                Text("Non-commercial use only · no modification · Apple hardware only")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                if let engine = state.engines.first, engine.rendererDir("d3dmetal") == nil {
                    Button("Accept & enable D3DMetal") {
                        state.acceptGPTK(engine: engine)
                        dismiss()
                    }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
    }
}
