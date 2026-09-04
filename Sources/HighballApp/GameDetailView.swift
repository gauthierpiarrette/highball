import SwiftUI
import HighballKit

/// A game's page: wide hero art, verdict chips, then the properties — with the bottle as a
/// property row carrying quick actions, never a prerequisite for Play.
struct GameDetailView: View {
    @Environment(AppState.self) private var state
    let item: LibraryItem
    @State private var showBottleSettings = false

    private var entry: GameDBEntry? { item.steamAppID.flatMap { state.gameDB[$0] } }
    private var bottle: Bottle? { item.bottleName.flatMap { name in state.bottles.first { $0.name == name } } }
    private var blocked: Bool { entry?.isBlocked == true }
    /// Light fixes auto-apply at Play; this button remains the manual (re-)apply path,
    /// mostly useful for heavy recipes and repair.
    private var fixRecipe: HighballKit.Recipe? { state.fixRecipe(for: item) }
    private var fixApplied: Bool {
        guard let fixRecipe, let bottle else { return false }
        return bottle.settings.recipes.contains(fixRecipe.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                HStack(spacing: 8) {
                    if let (label, color) = verdictLabel(entry?.status) {
                        Text(label)
                            .font(.system(size: 10.5, weight: .semibold).monospaced())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(color.opacity(0.22)))
                            .overlay(Capsule().stroke(color.opacity(0.8), lineWidth: 1))
                            .foregroundStyle(color)
                    }
                    if let r = entry?.renderer {
                        Text(r.rawValue.uppercased())
                            .font(.system(size: 10.5, weight: .medium).monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if blocked {
                        Text(entry?.anticheat?.names.first ?? "anti-cheat")
                            .font(.system(size: 10.5).monospaced())
                            .foregroundStyle(HB.bad)
                    }
                    SourceBadge(source: item.source)
                }
                if let notes = entry?.notes {
                    Text(notes).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: 620, alignment: .leading)
                }
                properties
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BottleBackdrop())
        .navigationTitle(item.title)
        .sheet(isPresented: $showBottleSettings) {
            if let bottle { BottleSettingsSheet(bottle: bottle) }
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .aspectRatio(460 / 215, contentMode: .fit)
                .frame(maxWidth: 640)
                .overlay(
                    AsyncImage(url: item.artworkWide ?? item.artworkTall) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            ZStack {
                                LinearGradient(colors: [HB.card, HB.ground], startPoint: .top, endPoint: .bottom)
                                Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(.quaternary)
                            }
                        }
                    }
                )
                .clipped()
            LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .bottom, endPoint: .center)
                .frame(maxWidth: 640)
            Text(item.title)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white).shadow(radius: 4)
                .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HB.cardStroke))
    }

    private var properties: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Bottle row: the runtime as a property with quick actions.
            HStack(spacing: 10) {
                Image(systemName: "cylinder.split.1x2").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.bottleName ?? L("Not installed in any bottle")).font(.callout.weight(.semibold))
                    if let bottle {
                        Text("\(bottle.settings.renderer.rawValue.uppercased()) · \(bottle.settings.engineID)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !item.otherBottles.isEmpty {
                        Text(String(format: L("Also installed in %@"), item.otherBottles.joined(separator: ", ")))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if item.installed {
                    if let fixRecipe, let bottle, !fixApplied {
                        Button(String(format: L("Apply %@ fix"), item.title)) {
                            state.applyRecipe(fixRecipe.id, to: bottle)
                        }
                        .disabled(state.busy)
                        .help(L("Sets this game up the way the compatibility database verified it — renderer, settings, dependencies."))
                    }
                    if let appid = item.steamAppID, let running = state.session(forAppID: appid) {
                        Text(L("Running")).font(.caption.bold()).foregroundStyle(HB.good)
                        Button(L("Stop")) { state.stopSession(running) }.buttonStyle(.bordered)
                    } else {
                        Button(L("Play")) { state.play(item) }
                            .buttonStyle(.borderedProminent).disabled(state.busy || blocked)
                    }
                    if bottle != nil, PlayLink.target(for: item) != nil {
                        Button { state.makeMacApp(for: item) } label: { Image(systemName: "macwindow.badge.plus") }
                            .help(L("Make a Mac app for this game in ~/Applications/Highball: open it from the Dock, Spotlight or Launchpad to play without opening Highball first."))
                    }
                    if bottle != nil {
                        Button { showBottleSettings = true } label: { Image(systemName: "gearshape") }
                        Button { if let b = bottle { NSWorkspace.shared.open(b.driveC) } } label: {
                            Image(systemName: "folder")
                        }
                    }
                } else if item.source == .epic {
                    Button(L("Install")) { state.install(item) }.disabled(state.busy)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(HB.card))

            Group {
                row(L("Source"), item.source == .steam
                    ? "Steam · \(item.steamAppID.map(String.init) ?? "")"
                    : item.source == .epic ? "Epic · \(item.epicAppName ?? "")" : L("Windows program"))
                if item.sizeOnDisk > 0 {
                    row(L("Size on disk"), ByteCountFormatter.string(fromByteCount: item.sizeOnDisk, countStyle: .file))
                }
                if let played = item.lastPlayed {
                    row(L("Last played"), played.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        .frame(maxWidth: 640)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.caption)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }
}
