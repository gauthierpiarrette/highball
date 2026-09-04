import SwiftUI
import HighballKit

/// One picker for an environment's graphics mode (canvas "Advanced: Settings"). Automatic
/// means the compatibility database decides per game, with the environment's own mode for games
/// without a verdict; picking a mode makes it explicit, and recipes then leave it alone.
struct GraphicsModePicker: View {
    @Environment(AppState.self) private var state
    let bottle: Bottle

    private var live: Bottle { state.bottles.first { $0.name == bottle.name } ?? bottle }
    private var d3dmetalAvailable: Bool { state.engine(for: live)?.rendererDir("d3dmetal") != nil }

    /// nil = Automatic.
    private var selection: Binding<Renderer?> {
        Binding(get: { live.settings.rendererExplicit ? live.settings.renderer : nil },
                set: { newValue in
                    var copy = live
                    if let r = newValue { copy.settings.renderer = r; copy.settings.rendererExplicit = true }
                    else { copy.settings.rendererExplicit = false }
                    state.update(copy)
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Picker(L("Graphics mode"), selection: selection) {
                    Text(L("Automatic")).tag(Renderer?.none)
                    Text(GamePageCopy.plainName(.dxmt)).tag(Renderer?.some(.dxmt))
                    Text(GamePageCopy.plainName(.dxvk)).tag(Renderer?.some(.dxvk))
                    if d3dmetalAvailable { Text(GamePageCopy.plainName(.d3dmetal)).tag(Renderer?.some(.d3dmetal)) }
                    Text(GamePageCopy.plainName(.wined3d)).tag(Renderer?.some(.wined3d))
                }
                .labelsHidden().frame(maxWidth: 260)
            }
            Text(live.settings.rendererExplicit
                 ? String(format: L("%@ for every game in this environment, whatever the database says."), GamePageCopy.plainName(live.settings.renderer))
                 : String(format: L("The mode verified for each game; %@ for games without a verdict."), GamePageCopy.plainName(live.settings.renderer)))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Installed Windows components as chips, with Add for the rest (canvas "Windows components").
struct WindowsComponentsRow: View {
    @Environment(AppState.self) private var state
    let bottle: Bottle

    var body: some View {
        let live = state.bottles.first { $0.name == bottle.name } ?? bottle
        let tweaks = AppState.tweakRecipes()
        let installed = tweaks.filter { live.settings.recipes.contains($0.id) || state.tweakIsInstalled($0, in: live) }
        let missing = tweaks.filter { r in !installed.contains { $0.id == r.id } }
        HStack(spacing: 6) {
            ForEach(installed, id: \.id) { r in
                Label(r.title, systemImage: "checkmark").font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(HB.good.opacity(0.18))).foregroundStyle(HB.good)
            }
            if installed.isEmpty { Text(L("None yet")).font(.caption).foregroundStyle(.secondary) }
            if !missing.isEmpty {
                Menu {
                    ForEach(missing, id: \.id) { r in
                        Button(r.title) { state.applyRecipe(r.id, to: live) }
                    }
                } label: { Text(L("Add")).font(.caption) }
                .menuStyle(.borderlessButton).fixedSize().disabled(state.busy)
            }
        }
    }
}
